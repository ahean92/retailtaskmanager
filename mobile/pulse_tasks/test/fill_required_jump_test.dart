import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:pulse_tasks/app_controllers.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/models/place.dart';
import 'package:pulse_tasks/ui/fill_screen.dart';
import 'package:pulse_tasks/ui/widgets/fill_field_tile.dart';
import 'support/fake_server.dart';
import 'support/test_env.dart';

/// Отказ «Завершить» из-за незаполненных обязательных включает маршрут по дырам:
/// сразу ведёт к первой, кнопка над нижней панелью ходит по кругу со счётчиком
/// «текущее/всего» и гаснет с последней закрытой. Проверяется экран целиком —
/// прыжок это страницы пейджера и подсветка плитки, контроллером это не видно.
///
/// Настоящий sqlite (ffi) — как в fill_chip_navigation_test: очередь отправки
/// живёт в схеме, и проверять её моком — значит не проверить ничего.

/// Уникален и между прогонами: база sqlite (ffi) — реальный файл по имени
/// логина, и кэш бланка от прошлого прогона ломает порядок загрузки в тесте.
final int _runId = DateTime.now().microsecondsSinceEpoch;
int _seq = 0;

class _Server {
  final calls = <String>[];

  /// Тела apiSetField: код поля → текст. По ним видно, что ответ долетел.
  final textByField = <String, String>{};
  bool finished = false;

  /// Два обязательных в разных разделах + необязательное: у маршрута есть и
  /// куда прыгать, и что игнорировать.
  List<Map<String, Object?>> fields = [
    {
      'sectionIndex': 1,
      'section': 'Зал',
      'fieldIndex': 1,
      'code': 'r1',
      'name': 'Обязательное в зале',
      'required': true,
    },
    {
      'sectionIndex': 1,
      'section': 'Зал',
      'fieldIndex': 2,
      'code': 'note1',
      'name': 'Просто заметка',
    },
    {
      'sectionIndex': 2,
      'section': 'Склад',
      'fieldIndex': 1,
      'code': 'r2',
      'name': 'Обязательное на складе',
      'required': true,
    },
  ];

  late final Session session;
  late final ApiClient api;

  _Server(Settings settings) {
    session = Session(
      login: 'ivanov$_runId${_seq++}', // логин уникален: имя базы содержит его
      name: 'Иванов И.И.',
      token: 'token',
      signedIn: true,
      performerId: 'p1',
    );
    api = ApiClient(settings, session, client: MockClient((request) async {
      final action = actionOf(request);
      calls.add(action);
      switch (action) {
        case 'apiTasks':
          return okJson(jsonEncode([
            {
              'id': 'ST1',
              'name': 'Проверка',
              'objectId': 'o1',
              'distance': 40.0,
              'typeId': 'checklist',
            }
          ]));
        case 'apiExecutionInfo':
          return okJson(jsonEncode([
            {
              'object': 'Магазин №1',
              'template': 'Чек-лист',
              'hasScored': false,
              'percent': 0.0,
              'passed': false,
              'answered': 0,
              'total': 3,
              'finished': finished,
            }
          ]));
        case 'apiExecutionBundle':
          return okJson(bundleJson(
            info: {
              'object': 'Магазин №1',
              'template': 'Чек-лист',
              'hasScored': false,
              'percent': 0.0,
              'passed': false,
              'answered': 0,
              'total': 3,
              'finished': finished,
            },
            fields: fields,
          ));
        case 'apiSetField':
          final b = jsonDecode(request.body) as Map<String, dynamic>;
          final t = b['text'] as String?;
          if (t != null) textByField[b['field'] as String] = t;
          return okJson('[]');
        case 'apiFinishExecution':
          finished = true;
          return okJson('[]');
        default:
          return okJson('[]');
      }
    }));
  }
}

/// Человек стоит на объекте задачи; координаты — чтобы refresh было что
/// отправить (как в fill_chip_navigation_test).
Place _atObject() => Place(
      objects: const [
        NearbyObject(id: 'o1', name: 'Магазин №1', distance: 40),
      ],
      objectId: 'o1',
      latitude: 53.9,
      longitude: 27.56,
      answered: true,
    );

void main() {
  initTestEnv();

  late Settings settings;
  late _Server server;

  setUp(() {
    resetMockStores();
    settings = Settings(baseUrl: 'http://test.local:9080');
    server = _Server(settings);
  });

  Future<AppControllers> openForm() async {
    final app = AppControllers(
        api: server.api, settings: settings, session: server.session);
    await app.account.updateSettings(settings); // открывает базу этого логина
    app.location.place = _atObject();
    await app.repo.refresh();
    return app;
  }

  /// Крутит кадры, пока не выполнится условие: настоящие sqlite и MockClient
  /// внутри runAsync живут своим временем, pumpAndSettle его не даёт.
  Future<void> until(bool Function() done, WidgetTester tester) async {
    for (var i = 0; i < 100 && !done(); i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  // Снимаем экран здесь, а не teardown'ом: dispose пересчитывает «не
  // отправлено» (#36916), и запросу надо дожить до ответа — иначе тест падает
  // по pending timers. База одноразовая (логин уникален) и умрёт с процессом.
  Future<void> closeForm(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump();
  }

  /// Плитка поля по тексту заголовка — к ней и ввод, и проверка подсветки.
  Finder tileOf(String label) => find.ancestor(
      of: find.textContaining(label), matching: find.byType(FillFieldTile));

  Future<void> pumpForm(WidgetTester tester, AppControllers app) =>
      tester.pumpWidget(MultiProvider(
        providers: app.providers,
        // Финиш делает pop: свой Navigator, чтобы корневой маршрут не трогать
        child: MaterialApp(
          home: Navigator(
            onGenerateRoute: (_) => MaterialPageRoute(
                builder: (_) => const FillScreen(taskId: 'ST1')),
          ),
        ),
      ));

  /// Открытый бланк, осевший на первом разделе: кнопка панели «Далее» (а не
  /// «Завершить» — он на последней) говорит, что перелистывание долетело и
  /// кнопки панели — уже этой страницы.
  Future<void> openSettled(WidgetTester tester) async {
    await until(() => find.byType(TextField).evaluate().isNotEmpty, tester);
    await until(
        () => find.text('Далее').evaluate().isNotEmpty, tester);
  }

  /// Уходит на последнюю страницу и жмёт «Завершить» — ровно жест, на котором
  /// человек узнаёт про незаполненные обязательные, — и ждёт отказа словами.
  Future<void> refuseFinish(WidgetTester tester) async {
    await tester.tap(find.text('Далее'));
    await until(() => find.text('Завершить').evaluate().isNotEmpty, tester);
    await tester.tap(find.text('Завершить'));
    await until(
        () => find
            .text('Заполните обязательные поля (2)')
            .evaluate()
            .isNotEmpty,
        tester);
  }

  testWidgets('отказ включает маршрут и сразу ведёт к первой дыре',
      (tester) async {
    await tester.runAsync(() async {
      final app = await openForm();
      await pumpForm(tester, app);
      await openSettled(tester);

      // до отказа кнопки нет — не дёргаем заранее
      expect(find.byKey(const ValueKey('requiredJumpButton')), findsNothing);

      await refuseFinish(tester);

      // автопереход вернул к первой дыре: бланк осел на «Зале» с маршрутом 1/2
      await until(
          () =>
              find.text('Далее').evaluate().isNotEmpty &&
              find.text('1/2').evaluate().isNotEmpty,
          tester);

      // отказ был местный: до сервера финиш не дошёл
      expect(server.calls, isNot(contains('apiFinishExecution')));

      // плитка-цель подсвечена, соседняя — нет
      expect(tester.widget<FillFieldTile>(tileOf('Обязательное в зале')).flash,
          isTrue);
      expect(tester.widget<FillFieldTile>(tileOf('Просто заметка')).flash,
          isFalse);

      await closeForm(tester);
    });
  });

  testWidgets('тапы ходят по дырам по кругу', (tester) async {
    await tester.runAsync(() async {
      final app = await openForm();
      await pumpForm(tester, app);
      await openSettled(tester);
      await refuseFinish(tester);
      await until(
          () =>
              find.text('Далее').evaluate().isNotEmpty &&
              find.text('1/2').evaluate().isNotEmpty,
          tester);

      await tester.tap(find.byKey(const ValueKey('requiredJumpButton')));
      await until(
          () =>
              find.text('Завершить').evaluate().isNotEmpty &&
              find.text('2/2').evaluate().isNotEmpty,
          tester);

      // за последней — снова первая
      await tester.tap(find.byKey(const ValueKey('requiredJumpButton')));
      await until(
          () =>
              find.text('Далее').evaluate().isNotEmpty &&
              find.text('1/2').evaluate().isNotEmpty,
          tester);

      await closeForm(tester);
    });
  });

  testWidgets('заполненное выпадает из маршрута, с последней дырой кнопка гаснет',
      (tester) async {
    await tester.runAsync(() async {
      final app = await openForm();
      await pumpForm(tester, app);
      await openSettled(tester);
      await refuseFinish(tester);
      await until(
          () =>
              find.text('Далее').evaluate().isNotEmpty &&
              find.text('1/2').evaluate().isNotEmpty,
          tester);

      // набираем первую дыру; тап кнопки расфокусит — ответ коммитится и
      // выпадает из маршрута, счётчик сжимается до одной дыры
      await tester.enterText(
          find.descendant(
              of: tileOf('Обязательное в зале'),
              matching: find.byType(TextField)),
          'готово');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('requiredJumpButton')));
      await until(
          () =>
              find.text('Завершить').evaluate().isNotEmpty &&
              find.text('1/1').evaluate().isNotEmpty,
          tester);
      await until(() => server.textByField['r1'] != null, tester);

      // последняя дыра: подсветка стоит на ней
      expect(
          tester
              .widget<FillFieldTile>(tileOf('Обязательное на складе'))
              .flash,
          isTrue);

      // заполняем и её: тап по кнопке прыжка расфокусит ввод — как и в живом
      // интерфейсе, коммит идёт по расфокусу — и с последней закрытой дырой
      // кнопка гаснет
      await tester.enterText(
          find.descendant(
              of: tileOf('Обязательное на складе'),
              matching: find.byType(TextField)),
          'готово тоже');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('requiredJumpButton')));
      await until(() => server.textByField['r2'] != null, tester);
      await until(
          () =>
              find.byKey(const ValueKey('requiredJumpButton')).evaluate().isEmpty,
          tester);
      expect(find.byKey(const ValueKey('requiredJumpButton')), findsNothing);

      // и «Завершить» теперь проходит — на сервер ушёл именно финиш
      await tester.tap(find.text('Завершить'));
      await until(
          () => find.text('Задача завершена').evaluate().isNotEmpty, tester);
      expect(server.calls, contains('apiFinishExecution'));

      await closeForm(tester);
    });
  });
}
