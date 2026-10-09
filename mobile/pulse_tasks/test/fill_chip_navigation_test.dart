import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:pulse_tasks/app_controllers.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/models/fill.dart';
import 'package:pulse_tasks/models/place.dart';
import 'package:pulse_tasks/ui/fill_screen.dart';
import 'package:pulse_tasks/ui/widgets/fill_field_tile.dart';
import 'support/fake_server.dart';
import 'support/test_env.dart';

/// Навигация по разделам бланка не имеет права терять набранное (#37411):
/// коммит полей идёт по потере фокуса, а чипы разделов видны при открытой
/// клавиатуре — прыжок по чипу (и свайп) утилизирует страницу В фокусе, и
/// листенер расфокуса не успевает. Оба пути обязаны заканчиваться текстом в
/// модели и на сервере, а не «поле снова пустое».
///
/// Настоящий sqlite (ffi) — как в task_elsewhere_test: очередь отправки живёт
/// в схеме, и проверять её моком — значит не проверить ничего.

/// Уникален и между прогонами: база sqlite (ffi) — реальный файл по имени
/// логина, и кэш бланка от прошлого прогона ломает порядок загрузки в тесте.
final int _runId = DateTime.now().microsecondsSinceEpoch;
int _seq = 0;

class _Server {
  final calls = <String>[];

  /// Тела apiSetField: код поля → текст. По ним видно, что набранное доехало
  /// до сервера, а не просто осталось на экране.
  final textByField = <String, String>{};

  /// Поля бланка: по умолчанию два текстовых в двух разделах; тест длинных
  /// названий подменяет список целиком.
  List<Map<String, Object?>> fields = [
    {
      'sectionIndex': 1,
      'section': 'Зал',
      'fieldIndex': 1,
      'code': 't1',
      'name': 'Заметка о зале',
    },
    {
      'sectionIndex': 2,
      'section': 'Склад',
      'fieldIndex': 1,
      'code': 't2',
      'name': 'Заметка о складе',
    }
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
              'total': 2,
              'finished': false,
            }
          ]));
        case 'apiExecutionFields':
          // по умолчанию — два текстовых поля в двух разделах (без type —
          // текст, как отдаёт сервер по умолчанию)
          return okJson(jsonEncode(fields));
        case 'apiSetField':
          final b = jsonDecode(request.body) as Map<String, dynamic>;
          final t = b['text'] as String?;
          if (t != null) textByField[b['field'] as String] = t;
          return okJson('[]');
        default:
          return okJson('[]');
      }
    }));
  }
}

/// Человек стоит на объекте задачи; координаты — чтобы refresh было что
/// отправить (как _at в task_elsewhere_test).
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

  testWidgets('набранный текст не пропадает при прыжке по чипу раздела',
      (tester) async {
    await tester.runAsync(() async {
      final app = await openForm();
      await tester.pumpWidget(MultiProvider(
        providers: app.providers,
        child: const MaterialApp(home: FillScreen(taskId: 'ST1')),
      ));
      await until(
          () => find.byType(TextField).evaluate().isNotEmpty, tester);
      expect(find.textContaining('Заметка о зале'), findsOneWidget);

      // печатает с открытой клавиатурой и, не закрывая её, прыгает по чипу
      // в другой раздел — ровно тот жест, который терял текст
      await tester.enterText(find.byType(TextField), 'набрано у полки');
      await tester.pump();
      await tester.tap(find.text('Склад'));
      // pumpAndSettle внутри runAsync не селится (см. task_elsewhere_test) —
      // ждём появления второго раздела кадрами
      await until(
          () => find.textContaining('Заметка о складе').evaluate().isNotEmpty,
          tester);
      await until(() => server.textByField['t1'] != null, tester);

      // вернулся в раздел — поле держит набранное, и сервер его видел.
      // Автоскролл чипов уводит «Зал» за край полосы — сначала вернуть его
      // в вьюпорт, иначе тап не попадёт
      await tester.ensureVisible(find.text('Зал'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Зал'));
      await until(
          () => find.textContaining('набрано у полки').evaluate().isNotEmpty,
          tester);
      expect(find.text('набрано у полки'), findsOneWidget);
      expect(server.textByField['t1'], 'набрано у полки');

      await closeForm(tester);
    });
  });

  // Полоса чипов разделов ограничена общим полем экрана (16), как заголовок
  // и карточки полей: скролл сохраняется, но чипы обрезаются границей поля,
  // а не краем экрана.
  testWidgets('полоса чипов разделов — в общих полях экрана', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const sections = [
      'Витрина и выкладка сезонного ассортимента',
      'Оборудование и инвентарь торгового зала',
      'Ценники и ценовое оформление',
      'Кассовая зона и расчётный узел',
      'Склад и подсобные помещения',
    ];
    server.fields = [
      for (var i = 0; i < sections.length; i++)
        {
          'sectionIndex': i + 1,
          'section': sections[i],
          'fieldIndex': 1,
          'code': 'f$i',
          'name': 'Поле ${i + 1}',
        }
    ];
    await tester.runAsync(() async {
      final app = await openForm();
      await tester.pumpWidget(MultiProvider(
        providers: app.providers,
        child: const MaterialApp(home: FillScreen(taskId: 'ST1')),
      ));
      await until(() => find.byType(TextField).evaluate().isNotEmpty, tester);

      final strip = tester.getRect(
          find.byKey(const ValueKey('sectionChipStrip')));
      expect(strip.left, 16.0, reason: 'полоса начинается на общем поле');
      expect(strip.right, 304.0, reason: 'полоса кончается на общем поле (320−16)');

      await closeForm(tester);
    });
  });

  // Сами редакторы при утилизации В фокусе (закрытие экрана с набранным
  // текстом): свайп-страницы это не проверяет — сфокусированный EditableText
  // держит свою страницу keep-alive'ом (wantKeepAlive = hasFocus), и прямой
  // тест утилизации виджета честнее обхода PageView.
  group('коммит по утилизации редакторов', () {
    FillField textField() => FillField(
        sectionIndex: 1, fieldIndex: 1, code: 't1', name: 'Заметка', type: 'text');

    Widget host(FillField f,
        {void Function(String?)? onText,
        void Function(String?)? onComment,
        void Function(FillRowData, FillColumn, double?)? onCell,
        void Function(FillRowData, FillColumn, String?)? onCellText}) {
      return MaterialApp(
        home: Scaffold(
          body: FillFieldTile(
            field: f,
            onOption: (_) {},
            onNumber: (_) {},
            onText: onText ?? (_) {},
            onBool: (_) {},
            onDatePick: () {},
            onScan: () {},
            onComment: onComment ?? (_) {},
            onPhoto: () {},
            onRemovePhoto: () {},
            onDeleteShot: (_) {},
            onCell: onCell ?? (_, __, ___) {},
            onCellText: onCellText,
            onAddRow: (_, __, {code}) async => null,
            onDeleteRow: (_) {},
            onRowSubjectSearch: (_, {allItems = false}) async => const [],
            onRef: (_, __) {},
            onRefSearch: (_) async => const [],
          ),
        ),
      );
    }

    testWidgets('текстовое поле: тайл утилизировали в фокусе — текст уехал',
        (tester) async {
      final sent = <String>[];
      await tester.pumpWidget(
          host(textField(), onText: (t) => sent.add(t ?? '')));
      await tester.enterText(find.byType(TextField), 'набрано до закрытия');
      await tester.pump();
      await tester.pumpWidget(const SizedBox()); // утилизация без расфокуса
      expect(sent, ['набрано до закрытия']);
    });

    testWidgets('примечание: тайл утилизировали в фокусе — текст уехал',
        (tester) async {
      final sent = <String>[];
      await tester.pumpWidget(
          host(textField(), onComment: (t) => sent.add(t ?? '')));
      await tester.tap(find.text('Примечание'));
      await tester.pump();
      await tester.enterText(find.byType(TextField).last, 'уточнение');
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      expect(sent, ['уточнение']);
    });

    testWidgets('ячейки таблицы: утилизация в фокусе коммитит и текст, и число',
        (tester) async {
      final textCells = <String>[];
      final numCells = <double?>[];
      const colMark =
          FillColumn(fieldCode: 'positions', code: 'mark', type: 'text');
      const colFact =
          FillColumn(fieldCode: 'positions', code: 'fact', type: 'number');
      final row = FillRowData(1, rowKey: 'k1');
      final f = FillField(
          sectionIndex: 1,
          fieldIndex: 1,
          code: 'positions',
          name: 'Позиции',
          type: 'table',
          columns: [colMark, colFact],
          rows: [row]);
      await tester.pumpWidget(host(f,
          onCell: (_, __, v) => numCells.add(v),
          onCellText: (_, __, v) => textCells.add(v ?? '')));
      // первая колонка — текстовая ячейка, вторая — числовая
      await tester.enterText(find.byType(TextField).at(0), 'серия А');
      await tester.pump();
      await tester.enterText(find.byType(TextField).at(1), '3,5');
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      expect(textCells, ['серия А']);
      expect(numCells, [3.5]); // запятая — валидный десятичный разделитель
    });
  });
}
