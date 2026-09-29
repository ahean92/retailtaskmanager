import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:pulse_tasks/app_controllers.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/fill_controller.dart';
import 'package:pulse_tasks/data/local_db.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/data/simple_controller.dart';
import 'package:pulse_tasks/data/unsent.dart';
import 'package:pulse_tasks/models/task.dart';
import 'package:pulse_tasks/models/task_status.dart';
import 'package:pulse_tasks/models/task_view.dart';
import 'package:pulse_tasks/ui/task_detail_screen.dart';
import 'support/fake_server.dart';
import 'support/test_env.dart';

/// Приёмка результата на телефоне (#37158; сервер — #37157).
///
/// Проверяется то, что тикет ставит условием готовности: сданная задача уходит из
/// «Моих» в «На приёмке»; принимающий находит её в «Ждут моей приёмки» и решает — в
/// том числе без связи; двое решили по-разному — второй видит, кто успел; возвращённая
/// снова у исполнителя, и повторное выполнение начинается заново, не затирая прежнего.
///
/// Настоящий sqlite (ffi), как в take_task_test: очередь решений, наложение на кэш и
/// миграция живут в схеме, и мок не проверил бы ни одного из них.

int _seq = 0;

const _statuses = <Map<String, Object?>>[
  {'id': 'new', 'name': 'Новый', 'sortingOrder': 1},
  {'id': 'in progress', 'name': 'В работе', 'sortingOrder': 2},
  {'id': 'acceptance', 'name': 'На приёмке', 'sortingOrder': 3},
  {'id': 'done', 'name': 'Выполнено', 'closed': true, 'sortingOrder': 4},
  {'id': 'canceled', 'name': 'Отменено', 'closed': true, 'sortingOrder': 5},
];

/// Сервер, который отвечает на решение как настоящий: 200 без тела, 409 с тем, кто
/// успел, отказ текстом исключения — и умеет «пропадать».
class _Server {
  /// Все попытки POST с телами — включая оборвавшиеся «без сети».
  final attempts = <(String, Map<String, dynamic>)>[];

  /// Дошедшие до сервера POST.
  final delivered = <(String, Map<String, dynamic>)>[];

  /// Дошедшие GET — по ним видно, докуда дошёл фоновый цикл синхронизации.
  final gets = <String>[];
  bool down = false;

  /// Ответ ручки не 200: статус и тело как есть.
  final replies = <String, (int, String)>{};
  List<Map<String, Object?>> tasks = const [];
  Map<String, Object?> simpleInfo = const {};
  Map<String, Object?> fillInfo = const {};

  late final Session session;
  late final ApiClient api;

  _Server(Settings settings, {bool geoRequired = false}) {
    session = Session(
      // логин уникален: имя базы содержит его, а файлы баз переживают прогон
      login: 'acc${DateTime.now().microsecondsSinceEpoch}_${_seq++}',
      name: 'Иванов И.И.',
      token: 'token',
      signedIn: true,
      performerId: 'p1',
      geoRequired: geoRequired,
    );
    api = ApiClient(settings, session, client: MockClient((request) async {
      final action = actionOf(request);
      if (request.method == 'POST') {
        final body = request.body.isEmpty
            ? <String, dynamic>{}
            : (jsonDecode(request.body) as Map).cast<String, dynamic>();
        attempts.add((action, body)); // попытка — до «обрыва сети»
        if (down) throw const SocketException('нет сети');
        delivered.add((action, body));
        final reply = replies[action];
        if (reply != null) {
          return http.Response.bytes(utf8.encode(reply.$2), reply.$1,
              headers: {'content-type': 'application/json; charset=utf-8'});
        }
        return http.Response('', 200);
      }
      if (down) throw const SocketException('нет сети');
      gets.add(action);
      return switch (action) {
        'apiTasks' => okJson(jsonEncode(tasks)),
        'apiStatuses' => okJson(jsonEncode(_statuses)),
        'apiSimpleInfo' => okJson(jsonEncode(simpleInfo)),
        'apiExecutionInfo' => okJson(jsonEncode(fillInfo)),
        _ => okJson('[]'),
      };
    }));
  }

  List<Map<String, dynamic>> deliveredOf(String action) =>
      [for (final (a, b) in delivered) if (a == action) b];

  List<Map<String, dynamic>> attemptsOf(String action) =>
      [for (final (a, b) in attempts) if (a == action) b];
}

/// Репозиторий с открытой базой этого логина, справочником статусов и строками
/// выдачи в кэше.
Future<AppControllers> _repo(_Server server, Settings settings,
    List<Map<String, Object?>> fetched) async {
  final app = AppControllers(
      api: server.api, settings: settings, session: server.session);
  await app.account.updateSettings(settings); // открывает базу этого логина
  await app.repo.db.tasks
      .replaceStatuses([for (final s in _statuses) TaskStatus.fromJson(s)]);
  for (final j in fetched) {
    await app.repo.db.tasks
        .insertLocalTask(Task.fromJson(j.cast<String, dynamic>()));
  }
  await app.repo.reloadLocal();
  return app;
}

TaskView _view(AppControllers app, String id) =>
    app.repo.tasks.firstWhere((v) => v.id == id);

/// Синхронизация, запущенная жестом в фоне (смена статуса, решение с экрана), — дать
/// ей договорить до закрытия базы: иначе она упадёт на закрытой базе уже после теста
/// и уронит соседний.
Future<void> _settle(AppControllers app) async {
  var quiet = 0;
  for (var i = 0; i < 200 && quiet < 10; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    quiet = app.repo.syncing || app.repo.loading ? 0 : quiet + 1;
  }
}

/// Строки выдачи, какими их отдаёт сервер #37157 разным участникам.
const _submitted = <String, Object?>{
  'id': 'S1',
  'name': 'Сданная',
  'statusId': 'acceptance',
  'status': 'На приёмке',
  'assigned': true,
  'needsAcceptance': true,
  'acceptor': 'Петров П.П.',
  'acceptorId': 'p9',
  'submittedAt': '2026-09-25T11:00:00',
};
const _awaiting = <String, Object?>{
  'id': 'R1',
  'name': 'Витрина',
  'statusId': 'acceptance',
  'status': 'На приёмке',
  'reviewing': true,
  'awaitingDecision': true,
  'acceptor': 'Иванов И.И.',
  'submittedAt': '2026-09-25T11:00:00',
  'assignedTo': 'Сидоров С.С.',
};

void main() {
  initTestEnv();

  late Settings settings;
  late _Server server;
  late Directory docs;

  setUp(() {
    resetMockStores();
    // снимки и кэши экранов живут файлами в каталоге приложения — на настольной
    // машине его никто не подставляет, поэтому подставляем сами
    docs = Directory.systemTemp.createTempSync('pulse_docs37158');
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

  group('группы списка — по признакам сервера', () {
    test('сданная у исполнителя — «На приёмке», а не «Мои» старой выдачи',
        () async {
      // ключей взятия у сданной нет (mine и canTake сервер у неё не считает) — по
      // правилу «строка без них — старая выдача» она ушла бы в «Мои»
      final app = await _repo(server, settings, [
        _submitted,
        {
          ..._submitted,
          'id': 'S2',
          'name': 'Взятая мной',
          'takenById': 'p1',
          'takenBy': 'Иванов И.И.',
        },
        {
          ..._submitted,
          'id': 'S3',
          'name': 'Взятая коллегой',
          'takenById': 'p2',
          'takenBy': 'Сидоров С.С.',
        },
      ]);

      final s1 = _view(app, 'S1');
      expect(s1.group, TaskGroup.submitted);
      expect(s1.onAcceptance, isTrue);
      expect(s1.readOnly, isTrue, reason: 'работа сдана — делать по ней нечего');
      expect(TaskFilter.open.matches(s1), isFalse,
          reason: 'плитка «Открытых» сданную не считает — и фильтр тоже');
      final s2 = _view(app, 'S2');
      expect(s2.group, TaskGroup.submitted,
          reason: 'не «взяты коллегами» под моим же именем');
      expect(s2.releasable, isFalse, reason: 'сданную с себя не снимают');
      expect(_view(app, 'S3').group, TaskGroup.taken,
          reason: 'взятая коллегой остаётся у коллег');
      app.dispose();
    });

    test('принимающий: ждёт решения — «Ждут моей приёмки», вернул — «На доработке»',
        () async {
      final app = await _repo(server, settings, [
        _awaiting,
        {
          'id': 'R2',
          'name': 'Возвращённая',
          'statusId': 'in progress',
          'status': 'В работе',
          'reviewing': true,
          'returned': true,
          'returnReason': 'нечитаемый ценник',
        },
        // автор-принимающий (на роли объекта никого — принимает автор)
        {..._awaiting, 'id': 'A1', 'name': 'Своя', 'authored': true},
        // исполнитель, которому вернули
        {
          'id': 'E1',
          'name': 'Вернули мне',
          'statusId': 'in progress',
          'assigned': true,
          'mine': true,
          'returned': true,
          'returnReason': 'переснять',
        },
      ]);

      final r1 = _view(app, 'R1');
      expect(r1.group, TaskGroup.awaiting);
      expect(r1.awaitingDecision, isTrue);
      expect(r1.readOnly, isTrue, reason: 'принимающий не выполняет');
      expect(TaskFilter.parse('acceptance'), TaskFilter.acceptance);
      expect(TaskFilter.acceptance.matches(r1), isTrue);
      final r2 = _view(app, 'R2');
      expect(r2.group, TaskGroup.rework);
      expect(r2.returned, isTrue);
      expect(r2.returnReason, 'нечитаемый ценник');
      expect(TaskFilter.acceptance.matches(r2), isFalse);
      expect(_view(app, 'A1').group, TaskGroup.awaiting,
          reason: 'решение — раньше авторства');
      final e1 = _view(app, 'E1');
      expect(e1.group, TaskGroup.mine, reason: 'возвращённая снова у исполнителя');
      expect(e1.returned, isTrue);
      expect(e1.returnReason, 'переснять');
      expect(e1.readOnly, isFalse);
      app.dispose();
    });

    test('решению геогейт не мешает: принимающий решает с любого объекта',
        () async {
      server = _Server(settings, geoRequired: true);
      final app = await _repo(server, settings, [
        {..._awaiting, 'objectId': 'b99'},
        {..._submitted, 'objectId': 'b99'},
      ]);
      expect(_view(app, 'R1').elsewhere, isFalse);
      expect(_view(app, 'S1').elsewhere, isTrue,
          reason: 'исполнительская задача по-прежнему под гейтом');
      app.dispose();
    });

    test('ждущему решения «Выполнено» не предлагается — принимают кнопкой', () {
      final all = [for (final s in _statuses) TaskStatus.fromJson(s)];
      final t = Task.fromJson({
        ..._awaiting,
        'nextStatuses': [
          {'id': 'done'},
          {'id': 'canceled'},
        ],
      });
      final awaiting = TaskView(t, 'acceptance', 'На приёмке', false,
          awaitingDecision: true);
      expect(awaiting.statusChoices(all).map((s) => s.id),
          ['acceptance', 'canceled']);
    });
  });

  group('сдача на телефоне', () {
    const work = <String, Object?>{
      'id': 'T1',
      'name': 'Поручение',
      'statusId': 'in progress',
      'status': 'В работе',
      'assigned': true,
      'mine': true,
      'needsAcceptance': true,
      'executionKind': 'simple',
    };

    test('завершение в очереди у задачи с приёмкой — сразу «На приёмке»',
        () async {
      final app = await _repo(server, settings, [
        work,
        {...work, 'id': 'T2', 'needsAcceptance': null},
      ]);
      await app.repo.db.simple
          .enqueueSimpleFinish('T1', '2026-09-25T11:00:00');
      await app.repo.db.simple
          .enqueueSimpleFinish('T2', '2026-09-25T11:00:00');
      await app.repo.reloadLocal();

      final t1 = _view(app, 'T1');
      expect(t1.group, TaskGroup.submitted, reason: 'из «Моих» — сразу');
      expect(t1.statusName, 'Сдана — не отправлена');
      expect(t1.onAcceptance, isTrue);
      final t2 = _view(app, 'T2');
      expect(t2.group, TaskGroup.mine, reason: 'без приёмки — как раньше');
      expect(t2.statusName, 'Завершена — не отправлена');
      app.dispose();
    });

    test('«Выполнено» в переключателе — сдача, «Отменено» — нет', () async {
      final app = await _repo(server, settings, [
        work,
        {...work, 'id': 'T2'},
        // «На приёмке» руками — сдача у любой задачи: так её понимает сервер
        {...work, 'id': 'T3', 'needsAcceptance': null},
      ]);
      server.down = true;
      await app.repo.setStatus('T1', TaskStatus.fromJson(_statuses[3]));
      await app.repo.setStatus('T2', TaskStatus.fromJson(_statuses[4]));
      await app.repo.setStatus('T3', TaskStatus.fromJson(_statuses[2]));
      await _settle(app);

      expect(_view(app, 'T1').group, TaskGroup.submitted);
      expect(_view(app, 'T1').statusName, 'Сдана — не отправлена');
      expect(_view(app, 'T2').group, TaskGroup.mine);
      expect(_view(app, 'T2').onAcceptance, isFalse);
      expect(_view(app, 'T3').group, TaskGroup.submitted);
      app.dispose();
    });

    test('исполнителю — «Сдать на приёмку», второго чипа «На приёмке» нет', () {
      final all = [for (final s in _statuses) TaskStatus.fromJson(s)];
      final next = [
        {'id': 'in progress'},
        {'id': 'acceptance'},
        {'id': 'done'},
        {'id': 'canceled'},
      ];
      final withAcceptance = TaskView(
          Task.fromJson({...work, 'nextStatuses': next}),
          'in progress',
          'В работе',
          false);
      expect(withAcceptance.statusChoices(all).map((s) => s.id),
          ['in progress', 'done', 'canceled']);
      // без приёмки «На приёмке» — единственный путь сдать, он остаётся
      final plain = TaskView(
          Task.fromJson({...work, 'needsAcceptance': null, 'nextStatuses': next}),
          'in progress',
          'В работе',
          false);
      expect(plain.statusChoices(all).map((s) => s.id),
          ['in progress', 'acceptance', 'done', 'canceled']);
    });
  });

  group('решение принимающего', () {
    test('принять без связи: строка уходит сразу, со связью уезжает тем же ключом',
        () async {
      final app = await _repo(server, settings, [_awaiting]);
      server.down = true;

      await app.repo.acceptTask('R1');
      await app.repo.syncDecisions(); // присоединиться к дренажу, упёршемуся в сеть

      expect(app.repo.viewOf('R1'), isNull,
          reason: 'принятая уходит из «Ждут моей приёмки» в этом же кадре');
      expect(app.repo.pendingCount, 1);
      expect(app.repo.unsentOps.single.kind, UnsentKind.decision);
      expect(app.repo.unsentOps.single.detail, 'Принять результат');
      expect(await app.repo.db.queues.pendingChanges(), 1,
          reason: 'предупреждение при выходе считает и решение');

      server.down = false;
      await app.repo.syncDecisions();

      final tries = server.attemptsOf('apiAcceptTask');
      expect(tries, hasLength(2), reason: 'попытка без сети + доезд');
      expect(tries.first['clientId'], isNotEmpty);
      expect(tries.last['clientId'], tries.first['clientId'],
          reason: 'ретрай — тем же ключом: сервер узнаёт повтор');
      expect(tries.last['id'], 'R1');
      expect((await app.repo.db.tasks.getTasks()).map((t) => t.id),
          isNot(contains('R1')),
          reason: 'принятая закрыта — выдача её больше не пришлёт');
      expect(app.repo.pendingCount, 0);
      app.dispose();
    });

    test('вернуть без связи: «На доработке» с причиной, уезжает причина',
        () async {
      final app = await _repo(server, settings, [_awaiting]);
      server.down = true;

      await app.repo.returnTask('R1', '  переснять ценник  ');
      await app.repo.syncDecisions();

      var v = _view(app, 'R1');
      expect(v.group, TaskGroup.rework);
      expect(v.awaitingDecision, isFalse);
      expect(v.returned, isTrue);
      expect(v.returnReason, 'переснять ценник');
      expect(v.statusId, 'in progress');
      expect(v.decisionPending, isTrue);

      server.down = false;
      await app.repo.syncDecisions();

      expect(server.deliveredOf('apiReturnTask').single['reason'],
          'переснять ценник');
      v = _view(app, 'R1');
      expect(v.decisionPending, isFalse);
      expect(v.group, TaskGroup.rework, reason: 'кэш — к подтверждённому');
      expect(v.task.returned, isTrue);
      expect(v.task.awaitingDecision, isNull);
      app.dispose();
    });

    test('передумал до отправки: уезжает только последнее решение', () async {
      final app = await _repo(server, settings, [_awaiting]);
      server.down = true;
      await app.repo.acceptTask('R1');
      await app.repo.syncDecisions();
      await app.repo.returnTask('R1', 'нет, переделать');
      await app.repo.syncDecisions();

      server.down = false;
      await app.repo.syncDecisions();

      expect(server.deliveredOf('apiAcceptTask'), isEmpty);
      expect(server.deliveredOf('apiReturnTask'), hasLength(1));
      app.dispose();
    });

    test('двое решили: второй видит, кто успел и когда, строка — по его решению',
        () async {
      final app = await _repo(server, settings, [
        _awaiting,
        {..._awaiting, 'id': 'R3', 'name': 'Касса'},
      ]);
      server.replies['apiAcceptTask'] = (
        409,
        jsonEncode({
          'error': 'alreadyDecided',
          'decision': 'returned',
          'decidedById': 'p2',
          'decidedBy': 'Сидоров С.С.',
          'decidedAt': '2026-01-15T10:42:00',
        })
      );

      await app.repo.acceptTask('R1');
      await app.repo.syncDecisions();

      expect(app.repo.takeNotice, contains('Витрина'));
      expect(app.repo.takeNotice, contains('уже возвращено на доработку'));
      expect(app.repo.takeNotice, contains('Сидоров С.С.'));
      expect(app.repo.takeNotice, contains('15.01 10:42'));
      final v = _view(app, 'R1');
      expect(v.group, TaskGroup.rework,
          reason: 'не молчаливый откат, а решение успевшего');
      expect(await app.repo.db.tasks.getDecisionOutbox(), isEmpty,
          reason: 'проигранный спор не ретраится');

      // и наоборот: успели принять — задача закрыта и уходит из списка
      server.replies['apiReturnTask'] = (
        409,
        jsonEncode({
          'error': 'alreadyDecided',
          'decision': 'accepted',
          'decidedById': 'p2',
          'decidedBy': 'Сидоров С.С.',
          'decidedAt': '2026-01-15T10:43:00',
        })
      );
      await app.repo.returnTask('R3', 'переделать');
      await app.repo.syncDecisions();
      expect(app.repo.viewOf('R3'), isNull);
      expect(app.repo.takeNotice, contains('уже принято: Сидоров С.С.'));
      app.dispose();
    });

    test('своё решение с другого телефона — «уже … вами», а не «успел другой»',
        () async {
      final app = await _repo(server, settings, [_awaiting]);
      server.replies['apiAcceptTask'] = (
        409,
        jsonEncode({
          'error': 'alreadyDecided',
          'decision': 'accepted',
          'decidedById': 'p1',
          'decidedBy': 'Иванов И.И.',
          'decidedAt': '2026-01-15T10:42:00',
        })
      );
      await app.repo.acceptTask('R1');
      await app.repo.syncDecisions();
      expect(app.repo.takeNotice, contains('уже принята вами'));
      app.dispose();
    });

    test('отказ по существу: решение снимается, строка — к слову сервера',
        () async {
      final app = await _repo(server, settings, [_awaiting]);
      server.replies['apiAcceptTask'] = (500, 'Not a reviewer of task: R1');

      await app.repo.acceptTask('R1');
      await app.repo.syncDecisions();

      expect(await app.repo.db.tasks.getDecisionOutbox(), isEmpty,
          reason: 'от повтора ответ не изменится — очередь не держится');
      expect(_view(app, 'R1').group, TaskGroup.awaiting);
      expect(app.repo.takeNotice, contains('не принято'));
      expect(app.repo.takeNotice, contains('Not a reviewer'));
      app.dispose();
    });
  });

  group('перевыполнение после возврата', () {
    Future<LocalDb> openDb() async => (await _repo(server, settings, [])).repo.db;

    Future<File> shot(String name) async {
      final f = File('${docs.path}/$name.jpg');
      await f.writeAsBytes([1, 2, 3]);
      return f;
    }

    /// Кэш сданного отчёта: «выполнено», один снимок, уехавший с этого телефона.
    Future<File> seedFinishedReport(LocalDb db) async {
      await db.simple.saveSimpleInfo(
          'T1',
          jsonEncode({
            'finished': true,
            'date': '2026-09-25T10:00:00',
            'photoCount': 1,
            'photoIndexes': '1',
            'comment': 'сделал',
          }));
      final f = await shot('old');
      await db.simple.saveSimplePhoto('T1', 0, f.path, '2026-09-25T10:05:00');
      await db.simple.markSimplePhotoUploaded('T1', 0);
      return f;
    }

    test('вернули — старт зовётся по «выполненному», прежние снимки уходят',
        () async {
      final db = await openDb();
      final old = await seedFinishedReport(db);
      server.simpleInfo = {'date': '2026-09-25T12:00:00'}; // сервер завёл новое

      final c = SimpleExecutionController(
          db: db, api: server.api, taskId: 'T1', restartHint: true);
      await c.load();

      expect(server.deliveredOf('apiStartSimple'), hasLength(1));
      expect(c.finished, isFalse, reason: 'работа — в новом выполнении');
      expect(c.photoPaths, isEmpty,
          reason: 'снимок прошлого раунда не кадр нового');
      expect(await db.simple.getSimplePhotos('T1'), isEmpty);
      expect(old.existsSync(), isFalse);
      c.dispose();
    });

    test('без возврата — как раньше: по выполненному старт не зовётся',
        () async {
      final db = await openDb();
      await seedFinishedReport(db);
      server.simpleInfo = {
        'finished': true,
        'date': '2026-09-25T10:00:00',
        'photoCount': 1,
        'photoIndexes': '1',
      };

      final c = SimpleExecutionController(db: db, api: server.api, taskId: 'T1');
      await c.load();

      expect(server.deliveredOf('apiStartSimple'), isEmpty);
      expect(c.finished, isTrue);
      expect(c.photoPaths, hasLength(1));
      c.dispose();
    });

    test('новое уже заведено (сервер ответил пустым стартом) — снимки на месте',
        () async {
      final db = await openDb();
      await seedFinishedReport(db);
      // перевыполнение завершено, но не сдано: сервер нового не заводит
      server.simpleInfo = {
        'finished': true,
        'date': '2026-09-25T10:00:00',
        'photoCount': 1,
        'photoIndexes': '1',
      };

      final c = SimpleExecutionController(
          db: db, api: server.api, taskId: 'T1', restartHint: true);
      await c.load();

      expect(server.deliveredOf('apiStartSimple'), hasLength(1));
      expect(c.photoPaths, hasLength(1),
          reason: 'то же выполнение — его снимки не трогаются');
      c.dispose();
    });

    test('без связи: старт в очереди, отчёт чистый, прежний — на сервере',
        () async {
      final db = await openDb();
      await seedFinishedReport(db);
      server.down = true;

      final c = SimpleExecutionController(
          db: db, api: server.api, taskId: 'T1', restartHint: true);
      await c.load();

      expect(await db.simple.hasSimpleStart('T1'), isTrue,
          reason: 'новое выполнение заведёт старт из очереди');
      expect(c.finished, isFalse);
      expect(c.photoPaths, isEmpty);
      expect(c.comment, isNull);
      expect(await db.simple.getSimpleCache('T1'), isNull);

      // сеть вернулась — старт уезжает первым, как у любой офлайн-смены
      server.down = false;
      server.simpleInfo = {'date': '2026-09-25T12:00:00'};
      await c.syncAll();
      expect(server.deliveredOf('apiStartSimple'), hasLength(1));
      expect(await db.simple.hasSimpleStart('T1'), isFalse);
      c.dispose();
    });

    test('сдача, возврат и перевыполнение одним телефоном — сервер ведёт раунды',
        () async {
      // сервер, который заводит выполнения как настоящий: старт — только если их нет
      // или задача возвращена после завершённого (Execution.restartable)
      final rounds = <Map<String, Object?>>[];
      var returned = false;
      // ответ на первое завершение теряется: сервер его принял, телефон — нет (на стенде
      // apiFinishSimple отвечает 15–19 с при тайм-ауте 20). Завершение дожмёт очередь, а
      // кэш экрана так и останется «не завершено» — перевыполнению это не помеха
      var loseFinishResponse = true;
      final api = ApiClient(settings, server.session,
          client: MockClient((r) async {
        final action = actionOf(r);
        if (r.method == 'POST') {
          final body = (jsonDecode(r.body) as Map).cast<String, dynamic>();
          if (action == 'apiFinishSimple' && loseFinishResponse) {
            rounds.last['finished'] = true;
            returned = false;
            throw const SocketException('ответ не дошёл');
          }
          switch (action) {
            case 'apiStartSimple':
              final restartable =
                  returned && rounds.isNotEmpty && rounds.last['finished'] == true;
              if (rounds.isEmpty || restartable) {
                rounds.add({'date': '2026-09-25T1${rounds.length}:00:00'});
              }
            case 'apiSetSimplePhoto':
              final n = (rounds.last['photoCount'] as int? ?? 0) + 1;
              rounds.last['photoCount'] = n;
              rounds.last['photoIndexes'] =
                  [for (var i = 1; i <= n; i++) i].join(',');
            case 'apiSetSimpleComment':
              rounds.last['comment'] = body['comment'];
            case 'apiFinishSimple':
              rounds.last['finished'] = true;
              returned = false; // сдача снимает признак возврата
          }
          return http.Response('', 200);
        }
        if (action == 'apiSimpleInfo') {
          return okJson(jsonEncode(
              rounds.isEmpty ? {'requirePhoto': true} : rounds.last));
        }
        return okJson('[]');
      }));
      final db = await openDb();

      // первый раунд: снимок, комментарий, «Сдать»; ответ на сдачу теряется
      final s1 = SimpleExecutionController(db: db, api: api, taskId: 'T1');
      await s1.load();
      await s1.addPhoto((await shot('r1')).path);
      await s1.setComment('Выложил');
      expect(await s1.finish(), isTrue, reason: 'без ответа — в очередь, как офлайн');
      s1.dispose();
      // повтор дожимает фоновый проход синхронизации — сервер его не замечает
      loseFinishResponse = false;
      await SimpleExecutionController.drainAll(db, api);
      expect(await db.simple.hasSimpleFinish('T1'), isFalse);
      expect(await db.simple.getSimplePhotos('T1'), hasLength(1));
      final cached = (jsonDecode((await db.simple.getSimpleCache('T1'))!['infoJson']
          as String) as Map);
      expect(cached['finished'], isNot(true),
          reason: 'ровно так было на стенде: кэш экрана не знает о завершении');

      // вернули — экран открывается с подсказкой возврата
      returned = true;
      final s2 = SimpleExecutionController(
          db: db, api: api, taskId: 'T1', restartHint: true);
      await s2.load();
      expect(rounds, hasLength(2), reason: 'новое выполнение поверх прежнего');
      expect(rounds.first['finished'], isTrue, reason: 'прежнее не тронуто');
      expect(s2.finished, isFalse);
      expect(s2.comment, isNull);
      expect(s2.photoPaths, isEmpty, reason: 'кадр прошлого раунда не кадр нового');
      s2.dispose();
    });

    test('экран закрыли, пока сдача ждёт ответа сервера, — завершение не падает',
        () async {
      // завершение на стенде отвечает 15–20 с, и уйти с экрана человек успевает
      final hold = Completer<void>();
      final api = ApiClient(settings, server.session,
          client: MockClient((r) async {
        final action = actionOf(r);
        if (action == 'apiFinishSimple') await hold.future;
        if (r.method == 'POST') return http.Response('', 200);
        return okJson(jsonEncode(action == 'apiSimpleInfo'
            ? {'date': '2026-09-25T10:00:00'}
            : []));
      }));
      final db = await openDb();
      final c = SimpleExecutionController(db: db, api: api, taskId: 'T1');
      await c.load();
      final finishing = c.finish();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      c.dispose(); // экран снят со стека
      hold.complete();
      expect(await finishing, isTrue);
    });

    test('бланк: вернули — новое выполнение, уехавшие снимки прошлого не держатся',
        () async {
      final db = await openDb();
      await db.fill.saveFillCache('T1', '[]', '[]',
          jsonEncode({'finished': true, 'date': '2026-09-25T10:00:00'}),
          '2026-09-25T10:10:00');
      final f = await shot('fold');
      await db.fill.saveFillPhoto('T1', 'F1', 0, f.path, '2026-09-25T10:05:00');
      await db.fill.markFillPhotoUploaded('T1', 'F1', 0, serverIdx: 1);
      server.fillInfo = {'date': '2026-09-25T12:00:00'};

      final c = FillController(
          db: db, api: server.api, taskId: 'T1', restartHint: true);
      await c.load();

      expect(server.deliveredOf('apiStartExecution'), hasLength(1));
      expect(c.finished, isFalse);
      expect(await db.fill.getFillPhotos('T1'), isEmpty);
      c.dispose();
    });
  });

  group('карточка принимающего', () {
    testWidgets('плашка решения; «Вернуть» без причины не отправляется',
        (tester) async {
      await tester.runAsync(() async {
        final app = await _repo(server, settings, [_awaiting]);
        await tester.pumpWidget(MultiProvider(
          providers: app.providers,
          child: const MaterialApp(home: TaskDetailScreen(taskId: 'R1')),
        ));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.text('Ждёт вашего решения'), findsOneWidget);
        expect(find.text('Посмотреть результат'), findsOneWidget);
        expect(find.byKey(const ValueKey('acceptTask')), findsOneWidget);
        expect(find.text('Выполнить'), findsNothing,
            reason: 'принимающий не выполняет');

        await tester.tap(find.byKey(const ValueKey('returnTask')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        final send = find.widgetWithText(FilledButton, 'Вернуть');
        expect(tester.widget<FilledButton>(send).onPressed, isNull,
            reason: 'пустой возврат кнопка не отправляет');

        await tester.enterText(
            find.byKey(const ValueKey('returnReason')), 'переснять');
        await tester.pump();
        expect(tester.widget<FilledButton>(send).onPressed, isNotNull);
        int feeds() =>
            server.gets.where((a) => a == 'apiNotifications').length;
        final feedsBefore = feeds();
        await tester.tap(send);
        // решение ложится в очередь — дождаться её, а не таймера снекбара
        for (var i = 0; i < 20 && app.repo.viewOf('R1')?.returned != true; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          await tester.pump();
        }
        expect(_view(app, 'R1').group, TaskGroup.rework);
        expect(_view(app, 'R1').returnReason, 'переснять');
        // решение с экрана зовёт полный цикл синхронизации — дождаться его
        // последнего шага (лента уведомлений), иначе он договорит на закрытой базе
        for (var i = 0; i < 250 && feeds() == feedsBefore; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        await _settle(app);
        app.dispose();
      });
    });

    testWidgets('исполнитель после возврата видит причину целиком',
        (tester) async {
      await tester.runAsync(() async {
        final app = await _repo(server, settings, [
          {
            'id': 'E1',
            'name': 'Вернули мне',
            'statusId': 'in progress',
            'status': 'В работе',
            'assigned': true,
            'mine': true,
            'returned': true,
            'returnReason': 'Ценник на верхней полке не виден — переснять ближе',
            'acceptor': 'Петров П.П.',
            'executionKind': 'simple',
            'needsAcceptance': true,
          },
        ]);
        await tester.pumpWidget(MultiProvider(
          providers: app.providers,
          child: const MaterialApp(home: TaskDetailScreen(taskId: 'E1')),
        ));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.text('Возвращено на доработку'), findsOneWidget);
        expect(find.byKey(const ValueKey('returnReasonText')), findsOneWidget);
        expect(
            find.text('Ценник на верхней полке не виден — переснять ближе'),
            findsOneWidget);
        expect(find.text('Выполнить'), findsOneWidget,
            reason: 'возвращённая — снова работа');
        app.dispose();
      });
    });
  });
}
