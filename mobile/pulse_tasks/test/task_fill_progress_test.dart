import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:pulse_tasks/app_controllers.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/models/fill.dart';
import 'package:pulse_tasks/ui/task_detail_screen.dart';
import 'support/test_env.dart';
import 'support/fake_server.dart';

/// Счётчик «Заполнение N из M» на карточке задачи (#37411, п. 5). Кэш бланка
/// пишут вход в экран заполнения и первое открытие карточки, а ответы уходят на
/// сервер мимо кэша — карточка обязана показывать выполнение как оно есть:
/// освежать протухший кэш при связи и считать поверх кэша то, что ещё не уехало.
/// Настоящий sqlite (ffi): и кэш, и очередь — реальные строки, моком это не
/// проверить.

/// Уникален и между прогонами: база sqlite (ffi) — реальный файл по имени логина,
/// и кэш бланка от прошлого прогона ломает проверки.
final int _runId = DateTime.now().microsecondsSinceEpoch;
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

  late final Session session;
  late final ApiClient api;

  _Server(Settings settings) {
    session = Session(
      login: 'orlov$_runId${_seq++}', // логин уникален: имя базы содержит его
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
        case 'apiExecutionBundle':
          return okJson(bundleJson(
            info: {'object': 'Магазин №1', 'total': 3, 'answered': 0},
            fields: fields,
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
