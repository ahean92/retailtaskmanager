import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:pulse_tasks/app_controllers.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/fill_controller.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/data/task_repository.dart';
import 'package:pulse_tasks/models/fill.dart';
import 'package:pulse_tasks/ui/fill_screen.dart';
import 'package:pulse_tasks/ui/task_detail_screen.dart';
import 'support/test_env.dart';
import 'support/fake_server.dart';

/// Счётчик «Заполнение N из M» на карточке задачи (#37411, п. 5). Кэш бланка
/// заводит вход в экран заполнения, а карточка освежает строку, не трогая
/// кандидатов, которые сама не читала, и заводит её только по уже заведённому
/// выполнению (поля с датой заполнения).
/// Ответы уходят на сервер мимо кэша — карточка обязана показывать выполнение
/// как оно есть: освежать протухший кэш при связи и считать поверх кэша то,
/// что ещё не уехало. Настоящий sqlite (ffi): и кэш, и очередь — реальные
/// строки, моком это не проверить.

int _seq = 0;

/// Три текстовых поля одного раздела; [answered] добавляет ответ каждому.
List<Map<String, Object?>> _fields({int answered = 0}) => [
      for (var i = 1; i <= 3; i++)
        {
          'sectionIndex': 1,
          'section': 'Зал',
          'fieldIndex': i,
          'code': 'f$i',
          'name': 'Пункт $i',
          if (i <= answered) 'text': 'ок',
        },
    ];

class _Server {
  final calls = <String>[];
  List<Map<String, Object?>> fields = _fields();

  /// Ответ сервера 6.2 по задаче без заполнения: агрегат отвечает 200 с одним
  /// info.verdict, без полей — пока apiStartExecution не заведёт выполнение.
  bool noFieldsUntilStart = false;

  /// Кандидаты справочника в агрегате — что бланк привозит с собой в кэш.
  List<Map<String, Object?>> subjects = const [];

  /// Дата заполнения в info: выполнение на сервере уже заведено (взято у коллеги,
  /// начато на другом устройстве). Без неё ответ о заведённом не говорит.
  String? date;

  late final Session session;
  late final ApiClient api;

  _Server(Settings settings) {
    session = Session(
      login: 'orlov${_seq++}', // логин уникален: имя базы содержит его
      name: 'Орлов О.О.',
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
              'name': 'Проверка зала',
              'objectId': 'o1',
              'typeId': 'checklist',
              'statusId': 'in_progress',
              'assigned': true,
            }
          ]));
        case 'apiStartExecution':
          return okJson('[]');
        case 'apiExecutionBundle':
          final started = calls.contains('apiStartExecution');
          final noFields = noFieldsUntilStart && !started;
          return okJson(bundleJson(
            info: noFields
                ? {'verdict': 'Не пройдено'}
                : {
                    'object': 'Магазин №1',
                    'total': 3,
                    'answered': 0,
                    if (date != null) 'date': date,
                  },
            fields: noFields ? const [] : fields,
            subjects: subjects,
          ));
        default:
          return okJson('[]');
      }
    }));
  }
}

Future<AppControllers> _repo(Settings settings, _Server server) async {
  final app = AppControllers(
      api: server.api, settings: settings, session: server.session);
  await app.account.updateSettings(settings); // открывает базу этого логина
  await app.repo.refresh();
  return app;
}

/// Крутит кадры, пока не выполнится условие: настоящие sqlite и MockClient
/// внутри runAsync живут своим временем, pumpAndSettle его не даёт (как в
/// fill_required_jump_test).
Future<void> _until(bool Function() done, WidgetTester tester) async {
  for (var i = 0; i < 100 && !done(); i++) {
    await tester.pump(const Duration(milliseconds: 50));
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// Дать осесть фоновым кругам, которых ждать нечем: момент для проверки
/// «круга не было» должен наступить после того, как он мог бы случиться.
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 200));

/// Снимаем экран до dispose приложения (как closeForm в fill_required_jump_test):
/// живой под закрытой базой экран роняет тест уже после его конца — его фоновые
/// чтения не успевают дожить до ответа.
Future<void> _closeScreen(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await Future<void>.delayed(const Duration(milliseconds: 100));
  await tester.pump();
}

void main() {
  initTestEnv();

  late Settings settings;
  late _Server server;
  late Directory docs;

  setUp(() {
    resetMockStores();
    // каталог приложения для path_provider — как в task_detail_test: без него
    // кэш миниатюр в тесте не существует
    docs = Directory.systemTemp.createTempSync('pulse_docs');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => docs.path);
    settings = Settings(baseUrl: 'http://test.local:9080');
    server = _Server(settings);
  });

  tearDown(() {
    if (docs.existsSync()) docs.deleteSync(recursive: true);
  });

  group('свежесть кэша', () {
    test('без даты и старше 30 секунд — протух, свежий — нет', () {
      final now = DateTime(2026, 10, 26, 12, 0, 0);
      expect(fillCacheStale(null, now), isTrue,
          reason: 'кэша нет — тянуть безусловно');
      expect(fillCacheStale('не дата', now), isTrue,
          reason: 'нечитаемая дата — честнее переспросить');
      expect(fillCacheStale('2026-10-26T11:59:29', now), isTrue,
          reason: '31 секунда — уже протух');
      expect(fillCacheStale('2026-10-26T11:59:31', now), isFalse,
          reason: '29 секунд — ещё свежий');
    });
  });

  group('экран', () {
    // настоящий sqlite не живёт в FakeAsync-зоне testWidgets — работа с базой и
    // сетью идёт внутри runAsync, где время и I/O настоящие
    testWidgets('заполненное офлайн видно сразу: очередь поверх кэша',
        (tester) async {
      await tester.runAsync(() async {
        final app = await _repo(settings, server);
        final db = app.repo.localDb!;

        // свежий пустой кэш (как после входа в бланк) + два ответа в очереди
        await db.fill.saveFillCache('ST1', jsonEncode(_fields()), '[]', '{}',
            DateTime.now().toIso8601String());
        for (final code in ['f1', 'f2']) {
          await db.fill.enqueueField('ST1', code,
              type: 'text', text: 'да', createdAtIso: DateTime.now().toIso8601String());
        }
        server.calls.clear();

        await tester.pumpWidget(MultiProvider(
          providers: app.providers,
          child: const MaterialApp(home: TaskDetailScreen(taskId: 'ST1')),
        ));
        await _until(
            () => find.text('Заполнение 2 из 3').evaluate().isNotEmpty,
            tester);
        await _settle();
        await tester.pump();

        expect(find.text('Заполнение 2 из 3'), findsOneWidget,
            reason: 'ответы ещё в очереди, но человек их уже внёс — карточка '
                'обязана считать их заполненными');
        expect(server.calls, isNot(contains('apiExecutionBundle')),
            reason: 'кэш свежий — лишнего круга нет');

        await _closeScreen(tester);
        app.dispose();
      });
    });

    testWidgets('протухший кэш при связи карточка освежает сама',
        (tester) async {
      await tester.runAsync(() async {
        server.fields = _fields(answered: 3); // на сервере всё заполнено
        final app = await _repo(settings, server);
        final db = app.repo.localDb!;

        // пустой кэш двухминутной давности: так выглядит задача, заполненная и
        // завершённая с телефона без повторного захода в бланк
        await db.fill.saveFillCache(
            'ST1',
            jsonEncode(_fields()),
            '[]',
            '{}',
            DateTime.now()
                .subtract(const Duration(minutes: 2))
                .toIso8601String());

        await tester.pumpWidget(MultiProvider(
          providers: app.providers,
          child: const MaterialApp(home: TaskDetailScreen(taskId: 'ST1')),
        ));
        await _until(
            () => find.text('Заполнение 3 из 3').evaluate().isNotEmpty,
            tester);

        expect(server.calls, contains('apiExecutionBundle'),
            reason: 'кэш протух и сеть есть — карточка перечитывает сама');
        expect(find.text('Заполнение 3 из 3'), findsOneWidget,
            reason: 'цифра — из свежего ответа, а не из кэша на момент входа '
                'в бланк');

        await _closeScreen(tester);
        app.dispose();
      });
    });

    testWidgets('свежий кэш не перечитывается — цифра из кэша без круга',
        (tester) async {
      await tester.runAsync(() async {
        final app = await _repo(settings, server);
        final db = app.repo.localDb!;

        // свежий кэш с ответами: только что писан, переспрашивать нечего
        await db.fill.saveFillCache(
            'ST1',
            jsonEncode(_fields(answered: 3)),
            '[]',
            '{}',
            DateTime.now().toIso8601String());
        server.calls.clear();

        await tester.pumpWidget(MultiProvider(
          providers: app.providers,
          child: const MaterialApp(home: TaskDetailScreen(taskId: 'ST1')),
        ));
        await _until(
            () => find.text('Заполнение 3 из 3').evaluate().isNotEmpty,
            tester);
        await _settle();
        await tester.pump();

        expect(find.text('Заполнение 3 из 3'), findsOneWidget);
        expect(server.calls, isNot(contains('apiExecutionBundle')),
            reason: 'открытие-закрытие подряд не плодит кругов — в этом и '
                'смысл ограничения свежести');

        await _closeScreen(tester);
        app.dispose();
      });
    });
  });

  group('задача без заполнения (ответ 6.2 — только verdict)', () {
    testWidgets('карточка не отравляет кэш, бланк стартует и даёт поля',
        (tester) async {
      await tester.runAsync(() async {
        server.noFieldsUntilStart = true; // выполнения на сервере ещё нет
        final app = await _repo(settings, server);
        final db = app.repo.localDb!;

        // карточка первой — основной путь «список → карточка → Заполнить»
        await tester.pumpWidget(MultiProvider(
          providers: app.providers,
          child: const MaterialApp(home: TaskDetailScreen(taskId: 'ST1')),
        ));
        await _until(() => server.calls.contains('apiExecutionBundle'), tester);
        await _settle();
        await tester.pump();

        expect(server.calls, isNot(contains('apiStartExecution')),
            reason: 'карточка только читает — выполнение заводит бланк');
        expect(await db.fill.getFillCache('ST1'), isNull,
            reason: 'ответ без полей карточка не сохраняет: пустая строка '
                'кэша выглядела бы заведённым выполнением и прятала бы старт '
                'от следующего открытия бланка');
        expect(find.textContaining('Заполнение'), findsNothing,
            reason: 'прогресса из ответа без полей нет — и блок его не рисует');

        // «Заполнить» сразу после карточки
        await tester.pumpWidget(MultiProvider(
          providers: app.providers,
          child: MaterialApp(
            home: Navigator(
              onGenerateRoute: (_) => MaterialPageRoute(
                  builder: (_) => const FillScreen(taskId: 'ST1')),
            ),
          ),
        ));
        // плитка называется с номером пункта: «1. Пункт 1»
        await _until(
            () => find.textContaining('Пункт 1').evaluate().isNotEmpty,
            tester);

        expect(server.calls, contains('apiStartExecution'),
            reason: 'кэш не доказывал заведённое выполнение — бланк завёл его');
        expect(find.textContaining('Пункт 1'), findsOneWidget);
        expect(find.text('Полей нет'), findsNothing);

        await _closeScreen(tester);
        app.dispose();
      });
    });

    testWidgets('пустая строка кэша — с телефонов до правки — лечится стартом',
        (tester) async {
      await tester.runAsync(() async {
        server.noFieldsUntilStart = true;
        final app = await _repo(settings, server);
        final db = app.repo.localDb!;

        // строка, которую писала карточка раньше: полей нет, даты заполнения нет
        await db.fill.saveFillCache('ST1', '[]', '[]',
            jsonEncode({'verdict': 'Не пройдено'}),
            DateTime.now().toIso8601String());

        await tester.pumpWidget(MultiProvider(
          providers: app.providers,
          child: MaterialApp(
            home: Navigator(
              onGenerateRoute: (_) => MaterialPageRoute(
                  builder: (_) => const FillScreen(taskId: 'ST1')),
            ),
          ),
        ));
        await _until(
            () => find.textContaining('Пункт 1').evaluate().isNotEmpty,
            tester);

        expect(server.calls, contains('apiStartExecution'),
            reason: 'пустой кэш не доказывает заведённое выполнение');
        final row = await db.fill.getFillCache('ST1');
        expect((jsonDecode(row!['fieldsJson'] as String) as List), isNotEmpty,
            reason: 'пустая строка перезаписана настоящим бланком');

        await _closeScreen(tester);
        app.dispose();
      });
    });
  });

  group('кэш и карточка', () {
    testWidgets('возврат на карточку не стирает кандидатов справочника',
        (tester) async {
      await tester.runAsync(() async {
        final app = await _repo(settings, server);
        final db = app.repo.localDb!;

        // кэш, как его оставляет бланк: поля, дата заполнения и кандидаты;
        // протух — карточка освежит его сама при связи
        final seededAt = DateTime.now()
            .subtract(const Duration(minutes: 2))
            .toIso8601String();
        await db.fill.saveFillCache(
          'ST1',
          jsonEncode(_fields()),
          '[]',
          jsonEncode({'object': 'Магазин №1', 'date': '2026-11-01T09:00:00'}),
          seededAt,
          subjectsJson: jsonEncode({
            'f1': [
              {'subjectId': 's1', 'name': 'Молоко'}
            ]
          }),
        );
        server.calls.clear();

        await tester.pumpWidget(MultiProvider(
          providers: app.providers,
          child: const MaterialApp(home: TaskDetailScreen(taskId: 'ST1')),
        ));
        await _until(() => server.calls.contains('apiExecutionBundle'), tester);
        await _settle();
        await tester.pump();

        final row = await db.fill.getFillCache('ST1');
        expect(row?['fetchedAt'], isNot(seededAt),
            reason: 'протухший кэш карточка освежила — агрегат ходил');
        expect(row?['subjectsJson'] as String?, contains('Молоко'),
            reason: 'карточка обновляет строку, не трогая кандидатов, '
                'которые сама не читала');

        // связь пропала: бланк открывается по кэшу, поиск — по кандидатам
        final offlineApi = ApiClient(settings, server.session,
            client: MockClient(
                (r) async => throw Exception('нет сети')));
        final c = FillController(db: db, api: offlineApi, taskId: 'ST1');
        await c.load();
        expect(c.error, isNull, reason: 'кэш есть — бланк открывается и без связи');
        final found = await c.searchRowSubjects(c.fields.first, 'молоко');
        expect(found.map((e) => e.name), contains('Молоко'),
            reason: 'кандидаты пережили возврат на карточку — офлайн-поиск '
                'и скан по коду работают');
        c.dispose();

        await _closeScreen(tester);
        app.dispose();
      });
    });

    testWidgets('заведённое выполнение карточка кэширует — бланк открывается без связи',
        (tester) async {
      await tester.runAsync(() async {
        server.date = '2026-11-01T09:00:00'; // выполнение уже есть на сервере
        final app = await _repo(settings, server);
        final db = app.repo.localDb!;

        await tester.pumpWidget(MultiProvider(
          providers: app.providers,
          child: const MaterialApp(home: TaskDetailScreen(taskId: 'ST1')),
        ));
        await _until(
            () => find.text('Заполнение 0 из 3').evaluate().isNotEmpty,
            tester);
        await _closeScreen(tester);

        final row = await db.fill.getFillCache('ST1');
        expect(row, isNotNull,
            reason: 'поля с датой — выполнение заведено: строку можно завести, '
                'бланк сочтёт её доказательством, а не пропустит старт зря');

        // связь пропала: бланк открывается по строке, заведённой карточкой
        final offlineApi = ApiClient(settings, server.session,
            client: MockClient((r) async => throw Exception('нет сети')));
        final offline = FillController(db: db, api: offlineApi, taskId: 'ST1');
        await offline.load();
        expect(offline.error, isNull,
            reason: 'задачу открывали при связи — без связи бланк есть');
        expect(offline.fields, hasLength(3));
        offline.dispose();

        // связь вернулась: выполнение доказано кэшем — старт не нужен
        server.calls.clear();
        final online = FillController(db: db, api: server.api, taskId: 'ST1');
        await online.load();
        expect(server.calls, isNot(contains('apiStartExecution')),
            reason: 'старт и замер места — только когда выполнение не доказано');
        online.dispose();

        app.dispose();
      });
    });

    testWidgets('ответ с полями без даты карточка показывает, но в базу не кладёт',
        (tester) async {
      await tester.runAsync(() async {
        final app = await _repo(settings, server); // server.date == null
        final db = app.repo.localDb!;

        await tester.pumpWidget(MultiProvider(
          providers: app.providers,
          child: const MaterialApp(home: TaskDetailScreen(taskId: 'ST1')),
        ));
        await _until(
            () => find.text('Заполнение 0 из 3').evaluate().isNotEmpty,
            tester);

        expect(find.text('Заполнение 0 из 3'), findsOneWidget,
            reason: 'счётчик — из ответа в памяти');
        expect(await db.fill.getFillCache('ST1'), isNull,
            reason: 'без даты заполнения ответ заведённого выполнения не '
                'доказывает — строку заводит бланк после старта');

        await _closeScreen(tester);
        app.dispose();
      });
    });

    test('строку, которую успел завести бланк, карточка не перезаписывает',
        () async {
      final app = await _repo(settings, server);
      final db = app.repo.localDb!;

      // бланк завёл строку с кандидатами, пока ответ карточки был в пути
      await db.fill.saveFillCache('ST1', jsonEncode(_fields(answered: 1)), '[]',
          jsonEncode({'date': '2026-11-01T09:00:00'}),
          DateTime.now().toIso8601String(),
          subjectsJson: jsonEncode({
            'f1': [
              {'subjectId': 's1', 'name': 'Молоко'}
            ]
          }));
      await db.fill.insertFillCacheIfAbsent('ST1',
          fieldsJson: jsonEncode(_fields()),
          optionsJson: '[]',
          infoJson: jsonEncode({'date': '2026-11-01T09:00:00'}),
          columnsJson: '[]',
          rowsJson: '[]',
          fetchedAtIso: DateTime.now().toIso8601String());

      final row = await db.fill.getFillCache('ST1');
      expect(row?['subjectsJson'] as String?, contains('Молоко'),
          reason: 'REPLACE стёр бы офлайн-справочник');
      expect(row?['fieldsJson'] as String?, contains('ок'),
          reason: 'ответы бланка не откатываются ответом карточки');

      app.dispose();
    });
  });

  group('нечитаемый кэш', () {
    test('бланк открывается: кэш считается отсутствующим', () async {
      final app = await _repo(settings, server);
      final db = app.repo.localDb!;

      await db.fill.saveFillCache('ST1', 'не JSON вовсе', '[]', '{}',
          DateTime.now().toIso8601String());

      final c = FillController(db: db, api: server.api, taskId: 'ST1');
      await c.load();

      expect(c.loading, isFalse,
          reason: 'нечитаемый кэш — как отсутствующий: загрузка доезжает '
          'до сервера и завершается, а не висит');
      expect(c.fields, isNotEmpty, reason: 'поля приехали с сервера');
      final row = await db.fill.getFillCache('ST1');
      expect((jsonDecode(row!['fieldsJson'] as String) as List), isNotEmpty,
          reason: 'испорченная строка перезаписана');

      c.dispose();
      app.dispose();
    });
  });

  group('overlayOutbox', () {
    test('ответы полей, фото-очередь, строки и ячейки — поверх кэша', () {
      final fields = assembleFillFields(
        [
          ..._fields(),
          {
            'sectionIndex': 2,
            'section': 'Склад',
            'fieldIndex': 1,
            'code': 'tab',
            'name': 'Таблица',
            'type': 'table',
            'allowManual': true,
          },
          {
            'sectionIndex': 2,
            'section': 'Склад',
            'fieldIndex': 2,
            'code': 'shot',
            'name': 'Фото',
            'type': 'photo',
          },
        ],
        [],
        [
          {'fieldCode': 'tab', 'colCode': 'qty', 'type': 'number'},
        ],
        [],
      );

      overlayOutbox(
        fields,
        fieldOutbox: [
          {'fieldCode': 'f1', 'text': 'да'},
        ],
        rowOutbox: [
          {
            'fieldCode': 'tab',
            'rowKey': 'k1',
            'op': 'add',
            'subjectName': 'Молоко',
          },
        ],
        cellOutbox: [
          {'fieldCode': 'tab', 'rowKey': 'k1', 'colCode': 'qty', 'number': 2.0},
        ],
        pendingPhotoPaths: {
          'shot': ['/tmp/p1.jpg'],
        },
      );

      final byCode = {for (final f in fields) f.code: f};
      expect(byCode['f1']!.answered, isTrue, reason: 'ответ из очереди');
      expect(byCode['f2']!.answered, isFalse, reason: 'без ответа — пусто');
      final tab = byCode['tab']!;
      expect(tab.answered, isTrue,
          reason: 'строка с заполненной ячейкой — таблица отвечена');
      expect(tab.rows.single.subject, 'Молоко');
      expect(tab.rows.single.numbers['qty'], 2.0);
      expect(byCode['shot']!.answered, isTrue,
          reason: 'неотправленный кадр для поля-фото — уже ответ');
    });
  });
}
