import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/data/task_repository.dart';
import 'package:pulse_tasks/models/place.dart';
import 'package:pulse_tasks/models/task.dart';
import 'package:pulse_tasks/models/task_status.dart';
import 'package:pulse_tasks/ui/fill_screen.dart';
import 'package:pulse_tasks/ui/task_detail_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Задачи других объектов — видны, но только для чтения (#36837): сервер отдаёт всё
/// назначенное, «здесь или не здесь» решает телефон сравнением объекта задачи с
/// выбранным в шапке. Настоящий sqlite (ffi): elsewhere и сортировка накладываются
/// на кэш при каждом _reload, и жить они обязаны в том же пути, что и офлайн.

int _seq = 0;

/// Сервер, у которого можно подменить выдачу apiTasks посреди теста, — и который
/// считает вызовы: гвард бланка обязан не только скрыть поля, но и не начать
/// выполнение (startExecution) на сервере.
class _Server {
  final calls = <String>[];
  List<Map<String, Object?>> tasks = [];

  late final Session session;
  late final ApiClient api;

  _Server(Settings settings, {bool geoRequired = true}) {
    session = Session(
      login: 'ivanov${_seq++}', // логин уникален: имя базы содержит его
      name: 'Иванов И.И.',
      token: 'token',
      signedIn: true,
      performerId: 'p1',
      geoRequired: geoRequired,
    );
    api = ApiClient(settings, session, client: MockClient((request) async {
      final action = request.url.path.split('.').last;
      calls.add(action);
      final body = action == 'apiTasks' ? jsonEncode(tasks) : '[]';
      return http.Response.bytes(utf8.encode(body), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    }));
  }
}

/// Человек стоит на [objectId]; координаты — чтобы refresh было что отправить.
Place _at(String? objectId) => Place(
      objects: [
        const NearbyObject(id: 'o1', name: 'Магазин №1', distance: 40),
        const NearbyObject(id: 'o2', name: 'Магазин №2', distance: 70),
      ],
      objectId: objectId,
      latitude: 53.9,
      longitude: 27.56,
      answered: true,
    );

Future<TaskRepository> _repo(Settings settings, _Server server,
    {Place? place}) async {
  final repo = TaskRepository(
      api: server.api, settings: settings, session: server.session);
  await repo.updateSettings(settings); // открывает базу этого логина
  if (place != null) repo.place = place;
  await repo.refresh();
  return repo;
}

TaskView _view(TaskRepository repo, String id) =>
    repo.tasks.firstWhere((v) => v.id == id);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Settings settings;
  late _Server server;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    settings = Settings(baseUrl: 'http://test.local:9080');
    server = _Server(settings);
  });

  group('elsewhere и сортировка', () {
    test('чужие объекты помечены и уходят вниз по расстоянию', () async {
      server.tasks = [
        {'id': 'FAR', 'name': 'Дальняя', 'objectId': 'o3', 'distance': 5200.0},
        {'id': 'HERE1', 'name': 'Здесь 1', 'objectId': 'o1', 'distance': 40.0},
        {'id': 'NOWHERE', 'name': 'Без координат'},
        {'id': 'NEAR', 'name': 'Ближняя', 'objectId': 'o2', 'distance': 70.0},
        {'id': 'HERE2', 'name': 'Здесь 2', 'objectId': 'o1', 'distance': 40.0},
      ];
      final repo = await _repo(settings, server, place: _at('o1'));

      expect(_view(repo, 'HERE1').elsewhere, isFalse);
      expect(_view(repo, 'HERE2').elsewhere, isFalse);
      expect(_view(repo, 'NEAR').elsewhere, isTrue);
      expect(_view(repo, 'FAR').elsewhere, isTrue);
      expect(_view(repo, 'NOWHERE').elsewhere, isTrue,
          reason: 'задача без объекта — не «здесь»: подтвердить присутствие не по чему');

      // маршрут: здесь (в порядке сервера) → остальные по расстоянию → без него
      expect(repo.tasks.map((v) => v.id).toList(),
          ['HERE1', 'HERE2', 'NEAR', 'FAR', 'NOWHERE']);
      repo.dispose();
    });

    test('пока объект не определён — чужое всё', () async {
      server.tasks = [
        {'id': 'T1', 'name': 'Задача', 'objectId': 'o1', 'distance': 40.0},
      ];
      final repo = await _repo(settings, server, place: _at(null));

      expect(_view(repo, 'T1').elsewhere, isTrue);
      repo.dispose();
    });

    test('роль без геопривязки работает отовсюду — elsewhere не бывает', () async {
      server = _Server(settings, geoRequired: false);
      server.tasks = [
        {'id': 'B', 'name': 'Вторая', 'objectId': 'o9', 'distance': 9000.0},
        {'id': 'A', 'name': 'Первая', 'objectId': 'o1', 'distance': 40.0},
      ];
      final repo = await _repo(settings, server, place: _at('o1'));

      expect(repo.tasks.every((v) => !v.elsewhere), isTrue);
      expect(repo.tasks.map((v) => v.id).toList(), ['B', 'A'],
          reason: 'без геопривязки порядок серверной выдачи не трогается');
      repo.dispose();
    });

    test('смена объекта перекрашивает список из кэша, без сервера', () async {
      server.tasks = [
        {'id': 'T1', 'name': 'На первом', 'objectId': 'o1', 'distance': 40.0},
        {'id': 'T2', 'name': 'На втором', 'objectId': 'o2', 'distance': 70.0},
      ];
      final repo = await _repo(settings, server, place: _at('o1'));
      expect(_view(repo, 'T2').elsewhere, isTrue);

      // новое место + локальное перечитывание кэша — ни одного нового вызова
      // сервера (сам selectNearby-путь, с его unawaited-синхронизацией вдогонку,
      // проходится виджет-тестом бланка ниже)
      repo.place = _at('o2');
      final callsBefore = server.calls.length;
      await repo.syncTakes(); // очередь пуста — это просто перечитать кэш в память

      expect(_view(repo, 'T2').elsewhere, isFalse);
      expect(_view(repo, 'T1').elsewhere, isTrue);
      expect(server.calls.length, callsBefore);
      repo.dispose();
    });
  });

  group('refresh без выбранного объекта', () {
    test('спрашивает сервер и пишет непустой ответ', () async {
      server.tasks = [
        {'id': 'T1', 'name': 'Задача', 'objectId': 'o1', 'distance': 40.0},
      ];
      final repo = await _repo(settings, server, place: _at(null));

      expect(server.calls, contains('apiTasks'),
          reason: 'в дороге список нужнее всего — fetch больше не ждёт объекта');
      expect(repo.tasks, hasLength(1));
      repo.dispose();
    });

    test('пустой ответ «ниоткуда» кэш не затирает', () async {
      server.tasks = [
        {'id': 'T1', 'name': 'Задача', 'objectId': 'o1', 'distance': 40.0},
      ];
      final repo = await _repo(settings, server, place: _at('o1'));
      expect(repo.tasks, hasLength(1));

      // отъехал от всех объектов, а старый сервер ответил на «ниоткуда» пустотой
      repo.place = _at(null);
      server.tasks = [];
      await repo.refresh();
      expect(repo.tasks, hasLength(1),
          reason: 'кэш — единственное, что есть у человека в дороге');

      // с выбранным объектом пустой ответ — честное «задач нет», кэш заменяется
      repo.place = _at('o1');
      await repo.refresh();
      expect(repo.tasks, isEmpty);
      repo.dispose();
    });
  });

  group('деталь задачи', () {
    // без базы и сети: экран рисует то, что уже вычислил репозиторий, — сами
    // вычисления elsewhere разобраны группой выше на настоящем sqlite
    Future<TaskRepository> pumpDetail(WidgetTester tester,
        {required bool away}) async {
      final repo = TaskRepository(
          api: server.api, settings: settings, session: server.session)
        ..tasks = [
          TaskView(
              const Task(
                id: 'ST1',
                name: 'Проверка витрин',
                object: 'Магазин №2',
                objectId: 'o2',
                distance: 3400.0,
                typeId: 'checklist',
              ),
              'new',
              'Новая',
              false,
              elsewhere: away),
        ]
        ..statuses = const [
          TaskStatus(id: 'new', name: 'Новая'),
          TaskStatus(id: 'done', name: 'Выполнена', closed: true),
        ];
      await tester.pumpWidget(ChangeNotifierProvider<TaskRepository>.value(
        value: repo,
        child: const MaterialApp(home: TaskDetailScreen(taskId: 'ST1')),
      ));
      await tester.pumpAndSettle();
      return repo;
    }

    testWidgets('вне объекта: баннер, заполнение и статусы погашены',
        (tester) async {
      final repo = await pumpDetail(tester, away: true);

      expect(find.textContaining('Вы не на этом объекте'), findsOneWidget);
      expect(find.textContaining('3,4 км'), findsWidgets);

      final fill = tester.widget<FilledButton>(find.widgetWithText(
          FilledButton, 'Заполнить чек-лист'));
      expect(fill.onPressed, isNull, reason: 'заполнять — только на месте');

      final chip = tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Выполнена'));
      expect(chip.onSelected, isNull, reason: 'смена статуса — тоже работа');

      // история — не работа: просмотр прошлой проверки остаётся доступным
      expect(find.text('Прошлая проверка'), findsOneWidget);
      repo.dispose();
    });

    testWidgets('на объекте всё работает как раньше', (tester) async {
      final repo = await pumpDetail(tester, away: false);

      expect(find.textContaining('Вы не на этом объекте'), findsNothing);
      final fill = tester.widget<FilledButton>(find.widgetWithText(
          FilledButton, 'Заполнить чек-лист'));
      expect(fill.onPressed, isNotNull);
      final chip = tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Выполнена'));
      expect(chip.onSelected, isNotNull);
      repo.dispose();
    });
  });

  group('бланк', () {
    // настоящий sqlite не живёт в FakeAsync-зоне testWidgets — вся работа с базой
    // и сетью идёт внутри runAsync, где время и I/O настоящие
    testWidgets('вне объекта не открывается и выполнение не начинает',
        (tester) async {
      await tester.runAsync(() async {
        server.tasks = [
          {
            'id': 'ST1',
            'name': 'Проверка',
            'objectId': 'o2',
            'distance': 3400.0,
            'typeId': 'checklist',
          },
        ];
        final repo = await _repo(settings, server, place: _at('o1'));
        final callsBefore = server.calls.length;

        await tester.pumpWidget(ChangeNotifierProvider<TaskRepository>.value(
          value: repo,
          child: const MaterialApp(home: FillScreen(taskId: 'ST1')),
        ));
        await tester.pumpAndSettle();

        expect(find.text('Вы не на этом объекте'), findsOneWidget);
        expect(
            find.textContaining('сохранено и синхронизируется'), findsOneWidget);
        expect(server.calls.length, callsBefore,
            reason: 'открытие вне объекта не смеет дёргать startExecution');
        repo.dispose();
      });
    });

    testWidgets('вернулся на объект — бланк оживает без переоткрытия',
        (tester) async {
      await tester.runAsync(() async {
        server.tasks = [
          {
            'id': 'ST1',
            'name': 'Проверка',
            'objectId': 'o2',
            'distance': 3400.0,
            'typeId': 'checklist',
          },
        ];
        final repo = await _repo(settings, server, place: _at('o1'));

        await tester.pumpWidget(ChangeNotifierProvider<TaskRepository>.value(
          value: repo,
          child: const MaterialApp(home: FillScreen(taskId: 'ST1')),
        ));
        await tester.pumpAndSettle();
        expect(find.text('Вы не на этом объекте'), findsOneWidget);

        // человек дошёл до второго магазина и выбрал его в шапке списка
        await repo.selectNearby('o2');
        // не pumpAndSettle: ожившему бланку нечего показать (MockClient отдаёт
        // пустые поля), и он крутит спиннер — у бесконечной анимации settle не
        // наступает никогда. Крутим кадры сами, пока сервер не увидит старт
        for (var i = 0; i < 50 && !server.calls.contains('apiStartExecution');
            i++) {
          await tester.pump(const Duration(milliseconds: 50));
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }

        expect(find.text('Вы не на этом объекте'), findsNothing);
        expect(server.calls, contains('apiStartExecution'),
            reason: 'отложенный load() стартует, когда человек снова на месте');
        // без dispose намеренно: у selectNearby есть unawaited-синхронизация
        // вдогонку, и закрытая под ней база роняет тест «после завершения»;
        // база одноразовая (логин уникален) и умрёт вместе с процессом
      });
    });
  });
}
