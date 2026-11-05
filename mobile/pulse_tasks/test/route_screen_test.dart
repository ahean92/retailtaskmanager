import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:pulse_tasks/app_controllers.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/geo.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/models/route.dart';
import 'package:pulse_tasks/ui/home_screen.dart';
import 'package:pulse_tasks/ui/route_screen.dart';
import 'fake_phone.dart';
import 'support/fake_server.dart';
import 'support/test_env.dart';

int _seq = 0;

const _stand = '''
{"id":"403389","date":"2026-10-26","status":"active","statusName":"В работе","passed":1,"total":3,
 "stops":[
  {"address":"г. Пинск, ул. Первомайская, 158","latitude":52,"name":"Санта №18, Пинск","objectId":"p18","longitude":26.01,
   "tasks":[{"name":"Проверка категории РЫБА \\u2014 Пинск","id":"ST000004","deadline":"2026-08-03"},
            {"name":"Приёмка поставки \\u2014 Пинск","id":"ST000006","deadline":"2026-08-05","done":true}]},
  {"address":"г. Ганцевичи, ул. Строителей, 12","latitude":52,"name":"Санта №92, Ганцевичи","passed":true,"objectId":"g92","longitude":26.06,
   "tasks":[{"name":"Пересчёт бакалеи \\u2014 Ганцевичи","id":"ST000008","deadline":"2026-08-06","done":true}]},
  {"name":"Санта №44, Лунинец","objectId":"l44",
   "tasks":[{"name":"Проверка ценников \\u2014 Лунинец","id":"ST000011"}]}
 ]}
''';

String _today() {
  final d = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)}';
}

Map<String, Object?> _stop(String id, String name,
        {bool passed = false, List<Map<String, Object?>>? tasks}) =>
    {
      'objectId': id,
      'name': name,
      'address': 'г. $name',
      'latitude': 52,
      'longitude': 26,
      if (passed) 'passed': true,
      'tasks': tasks ??
          [
            {'id': 'T-$id', 'name': 'Проверка — $name', if (passed) 'done': true}
          ],
    };

class _Server {
  Map<String, Object?>? route;
  int routeStatus = 200;
  bool down = false;
  final builds = <Map<String, dynamic>>[];
  final orders = <Map<String, dynamic>>[];
  String? refuseOrder;

  late final Session session;
  late final ApiClient api;

  _Server(Settings settings) {
    session = Session(
      login: 'route${DateTime.now().microsecondsSinceEpoch}_${_seq++}',
      name: 'Ковалёв А.',
      token: 'token',
      signedIn: true,
      performerId: 'p1',
      geoRequired: false,
    );
    api = ApiClient(settings, session, client: MockClient((request) async {
      final action = actionOf(request);
      if (!action.contains('Route')) return okJson('[]');
      if (down) throw const SocketException('нет сети');
      switch (action) {
        case 'apiRoute':
          if (routeStatus != 200) {
            return http.Response('not found', routeStatus);
          }
          return okJson(jsonEncode(route ?? {}));
        case 'apiBuildRoute':
          builds.add(jsonDecode(request.body));
          route = {
            'id': '501',
            'date': _today(),
            'status': 'built',
            'statusName': 'Собран',
            'passed': 0,
            'total': 3,
            'stops': [
              _stop('p18', 'Пинск'),
              _stop('k31', 'Кобрин'),
              _stop('b23', 'Брест'),
            ],
          };
          return okJson(jsonEncode(route));
        case 'apiRouteOrder':
          final body = jsonDecode(request.body)
              as Map<String, dynamic>;
          orders.add(body);
          if (refuseOrder != null) {
            return http.Response.bytes(
                utf8.encode(jsonEncode(
                    {'error': 'notInRoute', 'message': refuseOrder})),
                400,
                headers: {'content-type': 'application/json; charset=utf-8'});
          }
          final stops = (route!['stops'] as List).cast<Map<String, Object?>>();
          final byId = {for (final s in stops) s['objectId']: s};
          route = {
            ...route!,
            'stops': [for (final id in body['objects'] as List) byId[id]],
          };
          return okJson(jsonEncode(route));
      }
      return okJson('[]');
    }));
  }
}

Future<AppControllers> _app(Settings settings, _Server server,
    {GeoFix? fix}) async {
  final app = AppControllers(
      api: server.api,
      settings: settings,
      session: server.session,
      geo: Geo(platform: FakePhone(measured: fix, remembered: fix)));
  await app.account.updateSettings(settings);
  return app;
}

Widget _host(AppControllers app) => MultiProvider(
      providers: app.providers,
      child: const MaterialApp(home: RouteScreen()),
    );

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

List<String> _order(WidgetTester tester) {
  final ids = <String>[];
  for (final e in tester.widgetList(find.byWidgetPredicate(
      (w) => w.key is ValueKey<String> &&
          (w.key as ValueKey<String>).value.startsWith('route-stop-')))) {
    ids.add((e.key as ValueKey<String>).value.substring('route-stop-'.length));
  }
  return ids;
}

void main() {
  initTestEnv();

  late Settings settings;
  late _Server server;

  setUp(() {
    resetMockStores();
    settings = Settings(baseUrl: 'http://test.local:9080');
    server = _Server(settings);
  });

  group('модель', () {
    test('разбирает ответ стенда как есть', () {
      final plan = RoutePlan.parse(_stand)!;
      expect(plan.id, '403389');
      expect(plan.status, 'active');
      expect(plan.passed, 1);
      expect(plan.total, 3);
      expect(plan.stops.map((s) => s.objectId), ['p18', 'g92', 'l44']);
      expect(plan.stops[1].passed, isTrue);
      expect(plan.stops[0].passed, isFalse);
      expect(plan.stops[0].tasks[1].done, isTrue);
      expect(plan.stops[0].tasks[0].deadline, DateTime(2026, 8, 3));
      expect(plan.stops[2].latitude, isNull);
    });

    test('пустой объект и пустое тело — маршрута нет', () {
      expect(RoutePlan.parse('{}'), isNull);
      expect(RoutePlan.parse(''), isNull);
      expect(RoutePlan.parse('[]'), isNull);
    });
  });

  group('контроллер', () {
    test('сборка шлёт координаты телефона, маршрут ложится в кэш', () async {
      final app = await _app(settings, server,
          fix: GeoFix(52.1, 26.2, DateTime.now()));
      await app.route.refresh();
      expect(app.route.plan, isNull);
      expect(await app.route.build(), isTrue);
      expect(server.builds.single['lat'], 52.1);
      expect(server.builds.single['lon'], 26.2);
      expect(app.route.plan!.stops.map((s) => s.objectId),
          ['p18', 'k31', 'b23']);
      app.dispose();

      final again = await _app(settings, server);
      server.down = true;
      await again.route.refresh();
      expect(again.route.plan?.id, '501',
          reason: 'без сети — последний маршрут из кэша');
      again.dispose();
    });

    test('без точки сборка уходит без координат', () async {
      final app = await _app(settings, server);
      expect(await app.route.build(), isTrue);
      expect(server.builds.single.containsKey('lat'), isFalse);
      app.dispose();
    });

    test('404 — сервер без маршрутов, входа нет и после перезапуска', () async {
      final app = await _app(settings, server);
      server.routeStatus = 404;
      await app.route.refresh();
      expect(app.route.supported, isFalse);
      app.dispose();

      final again = await _app(settings, server);
      server.down = true;
      await again.route.refresh();
      expect(again.route.supported, isFalse,
          reason: 'без сети — признак из кэша, а не «умеет» по умолчанию');
      again.dispose();

      final back = await _app(settings, server);
      server.down = false;
      server.routeStatus = 200;
      await back.route.refresh();
      expect(back.route.supported, isTrue,
          reason: 'ручка появилась — вход возвращается');
      back.dispose();
    });

    test('403 — учётка не исполнитель, входа нет', () async {
      final app = await _app(settings, server);
      server.routeStatus = 403;
      await app.route.refresh();
      expect(app.route.supported, isFalse);
      app.dispose();
    });

    test('перестановка уходит полным списком, отказ откатывает порядок',
        () async {
      final app = await _app(settings, server);
      await app.route.build();
      expect(await app.route.reorder(2, 0), isTrue);
      expect(server.orders.last, {
        'id': '501',
        'objects': ['b23', 'p18', 'k31'],
      });
      expect(app.route.plan!.stops.map((s) => s.objectId),
          ['b23', 'p18', 'k31']);

      server.refuseOrder = 'Объект не из маршрута: x99';
      expect(await app.route.reorder(0, 2), isFalse);
      expect(app.route.plan!.stops.map((s) => s.objectId),
          ['b23', 'p18', 'k31']);
      expect(app.route.error, 'Объект не из маршрута: x99');
      app.dispose();
    });

    test('без связи сборка и перестановка не уходят', () async {
      final app = await _app(settings, server);
      await app.route.build();
      app.repo.online = false;
      expect(await app.route.build(), isFalse);
      expect(await app.route.reorder(0, 1), isFalse);
      expect(app.route.error, 'Нужна связь');
      expect(server.builds, hasLength(1));
      expect(server.orders, isEmpty);
      app.dispose();
    });
  });

  group('экран', () {
    testWidgets('пустой: подсказка и «Собрать маршрут»; собранный — по порядку',
        (tester) async {
      await tester.runAsync(() async {
        final app = await _app(settings, server);
        await tester.pumpWidget(_host(app));
        await _settle(tester);
        expect(find.text('Маршрута на сегодня нет'), findsOneWidget);
        expect(find.text('Собрать маршрут'), findsOneWidget);

        await tester.tap(find.text('Собрать маршрут'));
        await _settle(tester);
        expect(find.text('Пройдено 0 из 3'), findsOneWidget);
        expect(find.text('Собран'), findsOneWidget);
        expect(_order(tester), ['p18', 'k31', 'b23']);
        expect(find.text('Дополнить'), findsOneWidget);
        expect(find.byKey(const Key('route-drag-k31')), findsOneWidget);
        app.dispose();
      });
    });

    testWidgets('перетаскивание за ручку меняет порядок на сервере',
        (tester) async {
      await tester.runAsync(() async {
        final app = await _app(settings, server);
        await app.route.build();
        await tester.pumpWidget(_host(app));
        await _settle(tester);
        final handle = find.byKey(const Key('route-drag-b23'));
        final gesture = await tester.startGesture(tester.getCenter(handle));
        await tester.pump(const Duration(milliseconds: 100));
        await gesture.moveBy(const Offset(0, -300));
        await tester.pump(const Duration(milliseconds: 100));
        await gesture.up();
        await _settle(tester);
        expect(server.orders.last['objects'], ['b23', 'p18', 'k31']);
        expect(_order(tester), ['b23', 'p18', 'k31']);
        app.dispose();
      });
    });

    testWidgets('главная: вход «Маршрут на сегодня» с прогрессом',
        (tester) async {
      await tester.runAsync(() async {
        final app = await _app(settings, server);
        await app.route.build();
        await tester.pumpWidget(MultiProvider(
          providers: app.providers,
          child: const MaterialApp(home: HomeScreen()),
        ));
        await _settle(tester);
        expect(find.text('Маршрут на сегодня: пройдено 0 из 3'), findsOneWidget);
        await tester.tap(find.byKey(const Key('home-route')));
        await _settle(tester);
        expect(find.text('Мой маршрут'), findsOneWidget);

        server.routeStatus = 404;
        await app.route.refresh();
        await tester.pageBack();
        await _settle(tester);
        expect(find.byKey(const Key('home-route')), findsNothing);
        app.dispose();
      });
    });

    testWidgets('частично пройденный: отметка у остановки, тап — её задачи',
        (tester) async {
      await tester.runAsync(() async {
        server.route = jsonDecode(_stand) as Map<String, Object?>;
        final app = await _app(settings, server);
        await app.route.refresh();
        await tester.pumpWidget(_host(app));
        await _settle(tester);
        expect(find.text('Пройдено 1 из 3'), findsOneWidget);
        expect(find.text('В работе'), findsOneWidget);
        expect(find.text('Пройдено'), findsOneWidget);
        expect(find.text('Осталось задач: 1 из 2'), findsOneWidget);

        await tester.tap(find.text('Санта №18, Пинск'));
        await _settle(tester);
        expect(find.byKey(const Key('route-task-ST000004')), findsOneWidget);
        expect(find.byKey(const Key('route-task-ST000006')), findsOneWidget);
        expect(find.textContaining('выполнена'), findsOneWidget);
        app.dispose();
      });
    });

    testWidgets('закрытый: всё пройдено, «Дополнить» остаётся', (tester) async {
      await tester.runAsync(() async {
        server.route = {
          'id': '502',
          'date': _today(),
          'status': 'closed',
          'statusName': 'Закрыт',
          'passed': 2,
          'total': 2,
          'stops': [
            _stop('p18', 'Пинск', passed: true),
            _stop('k31', 'Кобрин', passed: true),
          ],
        };
        final app = await _app(settings, server);
        await app.route.refresh();
        await tester.pumpWidget(_host(app));
        await _settle(tester);
        expect(find.text('Пройдено 2 из 2'), findsOneWidget);
        expect(find.text('Закрыт'), findsOneWidget);
        expect(find.byKey(const Key('route-build')), findsOneWidget);
        expect(find.text('Дополнить'), findsOneWidget);
        expect(find.byKey(const Key('route-drag-p18')), findsNothing);
        await tester.tap(find.text('Дополнить'));
        await _settle(tester);
        expect(server.builds, hasLength(1));
        app.dispose();
      });
    });

    testWidgets('без связи: последний маршрут, «Нужна связь», сборка недоступна',
        (tester) async {
      await tester.runAsync(() async {
        final app = await _app(settings, server);
        await app.route.build();
        server.down = true;
        app.repo.online = false;
        await tester.pumpWidget(_host(app));
        await _settle(tester);
        expect(find.byKey(const Key('route-offline')), findsOneWidget);
        expect(find.textContaining('Нужна связь'), findsOneWidget);
        expect(_order(tester), ['p18', 'k31', 'b23']);
        final button = tester.widget<FilledButton>(find.descendant(
            of: find.byKey(const Key('route-build')),
            matching: find.byWidgetPredicate((w) => w is FilledButton)));
        expect(button.onPressed, isNull);
        expect(find.byKey(const Key('route-drag-k31')), findsNothing);
        app.dispose();
      });
    });
  });
}
