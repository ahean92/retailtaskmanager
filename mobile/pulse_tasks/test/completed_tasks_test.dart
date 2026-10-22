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
import 'package:pulse_tasks/models/place.dart';
import 'package:pulse_tasks/models/task.dart';
import 'package:pulse_tasks/models/task_view.dart';
import 'package:pulse_tasks/ui/past_check_screen.dart';
import 'package:pulse_tasks/ui/task_detail_screen.dart';
import 'package:pulse_tasks/ui/task_list_screen.dart';
import 'support/fake_server.dart';
import 'support/test_env.dart';

/// «Выполненные» и переход из уведомления по закрытой задаче (15.10): архив закрытых
/// (выполненные и отменённые) живёт в том же кэше задач своей половиной (closedScope),
/// refresh тянет его своим заходом (archive=1), а задачи, которой нет в рабочем списке,
/// телефон дожимает по id — закрытая открывается карточкой, а не сообщением «задачи
/// нет». Настоящий sqlite (ffi): половины кэша и REPLACE между ними живут в схеме.

int _seq = 0;

/// Сервер с тремя режимами apiTasks, как у настоящего: список, архив (archive=1) и
/// одна задача по taskId. [down] — «нет сети».
class _Server {
  final requests = <Map<String, String>>[]; // параметры каждого запроса apiTasks

  /// GET вне apiTasks — (ручка, параметры): видно, куда ушёл экран результата.
  final gets = <(String, Map<String, String>)>[];
  List<Map<String, Object?>> tasks = [];
  List<Map<String, Object?>> closed = [];
  Map<String, Object?>? byId;
  bool down = false;

  late final Session session;
  late final ApiClient api;

  _Server(Settings settings) {
    session = Session(
      login: 'done${DateTime.now().microsecondsSinceEpoch}_${_seq++}', // логин уникален и между прогонами: имя базы содержит его, а новый тест сортировки пишет prefs
      name: 'Иванов И.И.',
      token: 'token',
      signedIn: true,
      performerId: 'p1',
      geoRequired: false,
    );
    api = ApiClient(settings, session, client: MockClient((request) async {
      final action = actionOf(request);
      if (action != 'apiTasks') {
        if (request.method == 'GET') {
          gets.add((action, request.url.queryParameters));
        }
        return okJson('[]');
      }
      final q = request.url.queryParameters;
      requests.add(q);
      if (down) throw const SocketException('нет сети');
      if (q['taskId'] != null) {
        return okJson(byId == null ? '[]' : jsonEncode([byId]));
      }
      if (q['archive'] != null) return okJson(jsonEncode(closed));
      return okJson(jsonEncode(tasks));
    }));
  }
}

Future<AppControllers> _app(Settings settings, _Server server) async {
  final app = AppControllers(
      api: server.api, settings: settings, session: server.session);
  await app.account.updateSettings(settings); // открывает базу этого логина
  app.location.place = Place(
      objects: [], latitude: 53.9, longitude: 27.56, answered: true);
  return app;
}

void main() {
  initTestEnv();

  late Settings settings;
  late _Server server;
  late Directory docs;

  setUp(() {
    resetMockStores();
    settings = Settings(baseUrl: 'http://test.local:9080');
    server = _Server(settings);
    // карточка задачи читает кэш снимков из каталога приложения — на настольной
    // машине его никто не подставляет
    docs = Directory.systemTemp.createTempSync('pulse_docs');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => docs.path);
  });

  tearDown(() {
    if (docs.existsSync()) docs.deleteSync(recursive: true);
  });

  test('refresh: архив ложится в «Выполненные» свежими сверху, список не трогает',
      () async {
    server.tasks = [
      {'id': 'ST1', 'name': 'Живая', 'assigned': true, 'mine': true},
    ];
    server.closed = [
      {
        'id': 'ST9',
        'name': 'Отменённая',
        'statusId': 'canceled',
        'status': 'Отменено',
        'closedAt': '2026-10-14 10:00',
      },
      {
        'id': 'ST8',
        'name': 'Выполненная',
        'statusId': 'done',
        'status': 'Выполнено',
        'closedAt': '2026-10-15 09:00',
      },
    ];
    final app = await _app(settings, server);
    await app.repo.refresh();

    expect(
        server.requests.where((q) => q['archive'] != null), hasLength(1),
        reason: 'архив — своим заходом тем же refresh');
    expect(app.repo.tasks.map((v) => v.id), ['ST1'],
        reason: 'рабочий список закрытыми не разбавляется');
    expect(app.repo.closedTasks.map((v) => v.id), ['ST8', 'ST9'],
        reason: 'свежие закрытия сверху');
    final v = app.repo.viewOf('ST9')!;
    expect(v.group, TaskGroup.done);
    expect(v.archived, isTrue);
    expect(v.readOnly, isTrue, reason: 'история читается, работы на ней нет');
    expect(app.repo.viewOf('ST8')!.task.closedAt, '2026-10-15 09:00');
    app.dispose();
  });

  test('старый сервер: строки архивного ответа без closedAt отсеиваются', () async {
    server.tasks = [
      {'id': 'ST1', 'name': 'Живая', 'assigned': true},
    ];
    // сервер до 15.10 про archive не знает: параметр молча пропущен, отдаёт открытые
    server.closed = [
      {'id': 'ST1', 'name': 'Живая', 'assigned': true},
    ];
    final app = await _app(settings, server);
    await app.repo.refresh();

    expect(app.repo.error, isNull);
    expect(app.repo.closedTasks, isEmpty,
        reason: 'открытые строки в «Выполненных» — не архив, а непонимание');
    app.dispose();
  });

  test('refresh заменяет архив целиком: выпавшая из окна строка уходит', () async {
    server.closed = [
      {'id': 'ST8', 'closedAt': '2026-10-15 09:00', 'statusId': 'done'},
      {'id': 'ST7', 'closedAt': '2026-09-01 09:00', 'statusId': 'done'},
    ];
    final app = await _app(settings, server);
    await app.repo.refresh();
    expect(app.repo.closedTasks.map((v) => v.id), ['ST8', 'ST7']);

    // неделю спустя ST7 выпала из 30-дневного окна сервера
    server.closed = [
      {'id': 'ST8', 'closedAt': '2026-10-15 09:00', 'statusId': 'done'},
    ];
    await app.repo.refresh();
    expect(app.repo.closedTasks.map((v) => v.id), ['ST8']);
    app.dispose();
  });

  test('loadTaskById: закрытая ложится в архив, открытая — в рабочий список',
      () async {
    server.byId = {
      'id': 'ST9',
      'name': 'Отменённая',
      'statusId': 'canceled',
      'closedAt': '2026-10-14 10:00',
    };
    final app = await _app(settings, server);
    var v = await app.repo.loadTaskById('ST9');

    expect(server.requests.single['taskId'], 'ST9');
    expect(v, isNotNull, reason: 'переход из уведомления довёл до карточки');
    expect(v!.group, TaskGroup.done);
    expect(v.archived, isTrue);

    // та же ручка про открытую задачу — это отставший список, а не архив
    server.byId = {
      'id': 'ST2',
      'name': 'Живая',
      'assigned': true,
      'mine': true,
    };
    v = await app.repo.loadTaskById('ST2');
    expect(v!.group, TaskGroup.mine,
        reason: 'closedAt нет — строка рабочая, до ближайшего refresh');
    expect(app.repo.closedTasks.map((c) => c.id), ['ST9']);
    app.dispose();
  });

  test('loadTaskById: задачи нет или сети — null, кэш цел', () async {
    server.closed = [
      {'id': 'ST8', 'closedAt': '2026-10-15 09:00', 'statusId': 'done'},
    ];
    final app = await _app(settings, server);
    await app.repo.refresh();

    expect(await app.repo.loadTaskById('ST404'), isNull,
        reason: 'не участник и несуществующий id — пустой ответ');

    server.down = true;
    expect(await app.repo.loadTaskById('ST8'), isNull,
        reason: 'офлайн — не причина открывать пустую карточку');
    expect(app.repo.closedTasks.map((c) => c.id), ['ST8'],
        reason: 'неудачная попытка кэш не ломает');
    app.dispose();
  });

  testWidgets('карточка архивной: плашка «отменена», рабочих действий нет',
      (tester) async {
    await tester.runAsync(() async {
      final app = await _app(settings, server);
      await app.repo.db.tasks.upsertFetched(
          Task.fromJson({
            'id': 'ST9',
            'name': 'Отменённая проверка',
            'statusId': 'canceled',
            'status': 'Отменено',
            'closedAt': '2026-10-14 10:00',
            'executionKind': 'fill',
          }),
          closed: true);
      await app.repo.reloadLocal();

      await tester.pumpWidget(MultiProvider(
        providers: app.providers,
        child: const MaterialApp(home: TaskDetailScreen(taskId: 'ST9')),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.textContaining('Задача отменена'), findsOneWidget);
      expect(find.text('Отменено'), findsWidgets,
          reason: 'пилюля статуса остаётся при себе');
      // бланк, взятие, статусы, «Следить» — работы по закрытой нет
      expect(find.textContaining('Продолжить'), findsNothing);
      expect(find.text('Выполнить'), findsNothing);
      expect(find.byIcon(Icons.more_vert), findsNothing,
          reason: 'второстепенных действий у архива нет');
      app.dispose();
    });
  });

  testWidgets('карточка архивной с выполнением: «Результат» открывает сданное',
      (tester) async {
    await tester.runAsync(() async {
      final app = await _app(settings, server);
      await app.repo.db.tasks.upsertFetched(
          Task.fromJson({
            'id': 'ST8',
            'name': 'Выполненная проверка',
            'statusId': 'done',
            'status': 'Выполнено',
            'closedAt': '2026-10-15 09:00',
            'executionKind': 'fill',
            'executions': [
              {
                'id': 101,
                'dateTime': '2026-10-15 09:00',
                'executor': 'Иванов И.И.',
                'finished': true,
                'result': 'Пройдено',
              }
            ],
          }),
          closed: true);
      await app.repo.reloadLocal();

      await tester.pumpWidget(MultiProvider(
        providers: app.providers,
        child: const MaterialApp(home: TaskDetailScreen(taskId: 'ST8')),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Результат'), findsOneWidget,
          reason: 'у выполненной с бланком — просмотр результата, не работы');

      await tester.tap(find.text('Результат'));
      await tester.pump();
      // реальная асинхронность (runAsync): дождаться, пока экран сходит за info
      for (var i = 0;
          i < 50 &&
              server.gets.every((g) => g.$1 != 'apiExecutionInfo');
          i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(PastCheckScreen), findsOneWidget,
          reason: 'вход ведёт в просмотрщик бланка на чтение');
      final info = server.gets
          .where((g) => g.$1 == 'apiExecutionInfo')
          .map((g) => g.$2)
          .toList();
      expect(info, isNotEmpty, reason: 'сданное заполнение читается с сервера');
      expect(info.last, {'id': 'ST8'},
          reason: 'своё заполнение задачи, а не прошлая проверка (prev)');
      app.dispose();
    });
  });

  testWidgets('карточка архивной: автору «Результат» не положен', (tester) async {
    await tester.runAsync(() async {
      final app = await _app(settings, server);
      await app.repo.db.tasks.upsertFetched(
          Task.fromJson({
            'id': 'ST7',
            'name': 'Чужая выполненная',
            'statusId': 'done',
            'status': 'Выполнено',
            'closedAt': '2026-10-15 09:00',
            'executionKind': 'fill',
            'authored': true,
            'executions': [
              {
                'id': 102,
                'dateTime': '2026-10-15 09:00',
                'executor': 'Сидоров С.С.',
                'finished': true,
              }
            ],
          }),
          closed: true);
      await app.repo.reloadLocal();

      await tester.pumpWidget(MultiProvider(
        providers: app.providers,
        child: const MaterialApp(home: TaskDetailScreen(taskId: 'ST7')),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // сервер сданное автору не отдаёт (canView — исполнитель и принимающий):
      // кнопки нет, у автора на карточке блок выполнений
      expect(find.text('Результат'), findsNothing);
      app.dispose();
    });
  });

  testWidgets('список: чип «Выполненные», строки за ним с датой закрытия',
      (tester) async {
    await tester.runAsync(() async {
      final app = await _app(settings, server);
      app.repo.tasks = [
        TaskView(
            Task(id: 'ST1', name: 'Живая', assigned: true, mine: true),
            null,
            null,
            false,
            group: TaskGroup.mine),
      ];
      app.repo.closedTasks = [
        TaskView(
            Task(
                id: 'ST8',
                name: 'Выполненная',
                statusId: 'done',
                status: 'Выполнено',
                closedAt: '2026-10-15T09:00:00'),
            'done',
            'Выполнено',
            false,
            closed: true,
            archived: true,
            group: TaskGroup.done),
      ];
      await tester.pumpWidget(MultiProvider(
        providers: app.providers,
        child: const MaterialApp(home: TaskListScreen()),
      ));
      await tester.pumpAndSettle();

      // «мои» выбраны сразу — живая задача на экране, архив за своим чипом
      expect(find.text('Живая'), findsOneWidget);
      expect(find.text('Выполненная'), findsNothing);
      expect(find.text('Выполненные'), findsOneWidget);

      await tester.tap(find.text('Выполненные'));
      await tester.pumpAndSettle();
      expect(find.text('Выполненная'), findsOneWidget);
      expect(find.textContaining('закрыта 15.10'), findsOneWidget,
          reason: 'когда закрылась — рядом со статусом');
      app.dispose();
    });
  });

  testWidgets('«Выполненные»: ручная сортировка применяется, «По умолчанию» — закрытиями сверху',
      (tester) async {
    await tester.runAsync(() async {
      final app = await _app(settings, server);
      app.repo.tasks = [
        TaskView(
            Task(id: 'ST1', name: 'Живая', assigned: true, mine: true),
            null,
            null,
            false,
            group: TaskGroup.mine),
      ];
      // закрытия идут вразнобой со сроками: любой из двух порядков узнаётся по факту
      TaskView closedOne(String id, String name, String closedAt,
              String? deadline) =>
          TaskView(
              Task(
                  id: id,
                  name: name,
                  statusId: 'done',
                  status: 'Выполнено',
                  closedAt: closedAt,
                  deadline: deadline),
              'done',
              'Выполнено',
              false,
              closed: true,
              archived: true,
              group: TaskGroup.done);
      app.repo.closedTasks = [
        closedOne('ST7', 'Бессрочная', '2026-10-16T12:00:00', null),
        closedOne('ST8', 'Поздняя', '2026-10-15T09:00:00', '2026-10-20'),
        closedOne('ST9', 'Срочная', '2026-10-14T10:00:00', '2026-10-10'),
      ];
      await tester.pumpWidget(MultiProvider(
        providers: app.providers,
        child: const MaterialApp(home: TaskListScreen()),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Выполненные'));
      await tester.pumpAndSettle();

      // «По умолчанию»: свежие закрытия сверху — 16.10, 15.10, 14.10
      double top(String name) => tester.getTopLeft(find.text(name)).dy;
      expect(top('Бессрочная') < top('Поздняя') && top('Поздняя') < top('Срочная'),
          isTrue,
          reason: 'без ручной сортировки архив — закрытиями сверху');

      // «По сроку»: ранние первыми (просроченные сами всплывают), без срока — в конец
      await tester.tap(find.byTooltip('Сортировка и фильтры'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('По сроку'));
      await tester.pumpAndSettle();
      expect(top('Срочная') < top('Поздняя') && top('Поздняя') < top('Бессрочная'),
          isTrue,
          reason: 'ручная сортировка применяется и к архиву');
      app.dispose();
    });
  });
}
