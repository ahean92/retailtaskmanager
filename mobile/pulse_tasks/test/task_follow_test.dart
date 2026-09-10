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
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/data/unsent.dart';
import 'package:pulse_tasks/models/notification.dart';
import 'package:pulse_tasks/models/task.dart';
import 'package:pulse_tasks/models/task_view.dart';
import 'package:pulse_tasks/ui/task_detail_screen.dart';
import 'support/fake_server.dart';
import 'support/test_env.dart';

/// Подписка с телефона (#37136): «Следить» и «Не следить» — офлайн-очередью, как
/// взятие. Главное здесь — порядок: отписка убирает задачу из списка сразу, а не когда
/// сервер подтвердит («ушла после синхронизации» читается как «кнопка не работает»), и
/// повтор очереди второй подписки не создаёт. Настоящий sqlite (ffi): очередь, REPLACE
/// «передумал» и наложение на кэш живут в схеме.

int _seq = 0;

/// Сервер, который отвечает на подписку как настоящий: 200 без тела, 403 с телом на
/// невидимую задачу, и умеет «пропадать».
class _Server {
  final calls = <String>[]; // POST-попытки, включая оборвавшиеся
  bool down = false;
  final refuse403 = <String>{}; // ручки, отвечающие отказом по существу

  late final Session session;
  late final ApiClient api;

  _Server(Settings settings, {bool geoRequired = false}) {
    session = Session(
      login: 'follow${DateTime.now().microsecondsSinceEpoch}_${_seq++}',
      name: 'Иванов И.И.',
      token: 'token',
      signedIn: true,
      performerId: 'p1',
      geoRequired: geoRequired,
    );
    api = ApiClient(settings, session, client: MockClient((request) async {
      final action = actionOf(request);
      if (request.method == 'POST') {
        calls.add(action);
        if (down) throw const SocketException('нет сети');
        if (refuse403.contains(action)) {
          final id = (jsonDecode(request.body) as Map)['id'];
          return http.Response.bytes(
              utf8.encode(jsonEncode({
                'error': 'forbidden',
                'message': 'Нет доступа к задаче: $id',
              })),
              403,
              headers: {'content-type': 'application/json; charset=utf-8'});
        }
        return http.Response('', 200);
      }
      if (down) throw const SocketException('нет сети');
      return okJson('[]');
    }));
  }

  int posts(String action) => calls.where((a) => a == action).length;
}

Future<AppControllers> _repo(Settings settings, _Server server,
    List<Map<String, Object?>> fetched) async {
  final app = AppControllers(
      api: server.api, settings: settings, session: server.session);
  await app.account.updateSettings(settings); // открывает базу этого логина
  for (final j in fetched) {
    await app.repo.db.tasks
        .insertLocalTask(Task.fromJson(j.cast<String, dynamic>()));
  }
  await app.repo.reloadLocal();
  return app;
}

TaskView? _find(AppControllers app, String id) {
  for (final v in app.repo.tasks) {
    if (v.id == id) return v;
  }
  return null;
}

TaskView _view(AppControllers app, String id) => _find(app, id)!;

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

  test('«Не следить» офлайн: задача уходит из «Наблюдаю» сразу, со связью — и из кэша',
      () async {
    final app = await _repo(settings, server, [
      {'id': 'ST1', 'name': 'Моя', 'assigned': true, 'mine': true},
      {
        'id': 'ST2',
        'name': 'Чужая проверка',
        'watched': true,
        'following': true,
      },
    ]);
    expect(_view(app, 'ST2').group, TaskGroup.watched);
    expect(_view(app, 'ST2').following, isTrue);
    server.down = true;

    await app.repo.unfollowTask('ST2');
    await app.repo.syncWatches(); // присоединиться к дренажу, упёршемуся в «нет сети»

    expect(_find(app, 'ST2'), isNull,
        reason: 'список перестраивается сразу, не дожидаясь сервера');
    expect(_find(app, 'ST1'), isNotNull, reason: 'остальное не тронуто');
    expect(app.repo.pendingCount, 1);
    expect(app.repo.unsentOps.single.kind, UnsentKind.watch);
    expect(app.repo.unsentOps.single.detail, 'Не следить за задачей');
    expect(app.repo.unsentOps.single.title, 'Чужая проверка',
        reason: 'строка очереди узнаётся по имени задачи, пока та в кэше');
    expect(await app.repo.db.queues.pendingChanges(), 1,
        reason: 'предупреждение при выходе считает и отписку');

    // связь вернулась — уехало, строка ушла и из кэша: обнулённый признак у неё
    // читался бы как «назначена» (#36844), и задача уехала бы в «Мои»
    server.down = false;
    await app.repo.syncWatches();

    expect(server.posts('apiUnfollowTask'), 2, reason: 'попытка офлайн + доезд');
    expect(app.repo.pendingCount, 0);
    expect((await app.repo.db.tasks.getTasks()).map((t) => t.id), ['ST1']);
    expect(_find(app, 'ST2'), isNull);
    app.dispose();
  });

  test('«Следить» на поставленной мной: группа та же, пометка и «Не следить»',
      () async {
    final app = await _repo(settings, server, [
      {'id': 'ST3', 'name': 'Поручение', 'authored': true},
    ]);
    var v = _view(app, 'ST3');
    expect(v.canFollow, isTrue, reason: 'автору подписка даёт срок и завершение');
    expect(v.following, isFalse);
    server.down = true;

    await app.repo.followTask('ST3');
    await app.repo.syncWatches();

    v = _view(app, 'ST3');
    expect(v.group, TaskGroup.authored,
        reason: '«Наблюдаю» — только то, за чем лишь наблюдаю');
    expect(v.following, isTrue, reason: 'кнопка сменилась сразу, офлайн');
    expect(v.watched, isTrue, reason: 'пометка «наблюдаю» на строке списка');
    expect(v.watchPending, isTrue);
    expect(v.canFollow, isFalse);
    expect(v.readOnly, isTrue, reason: 'авторская и так только для чтения');

    server.down = false;
    await app.repo.syncWatches();
    v = _view(app, 'ST3');
    expect(v.watchPending, isFalse);
    expect(v.following, isTrue, reason: 'подтверждённое держится и без очереди');
    expect(v.task.following, isTrue, reason: 'строка кэша приведена к серверу');
    app.dispose();
  });

  test('повтор очереди второй подписки не создаёт: одна строка на задачу', () async {
    final app = await _repo(settings, server, [
      {'id': 'ST3', 'name': 'Поручение', 'authored': true},
    ]);
    server.down = true;

    await app.repo.followTask('ST3');
    await app.repo.followTask('ST3'); // двойной тап в подвале
    await app.repo.syncWatches();
    expect(await app.repo.db.tasks.getWatchOutbox(), hasLength(1));
    expect(app.repo.pendingCount, 1);

    // передумал до связи — в очереди остаётся одно последнее намерение
    await app.repo.unfollowTask('ST3');
    await app.repo.syncWatches(); // дождаться попытки, упёршейся в «нет сети»
    final rows = await app.repo.db.tasks.getWatchOutbox();
    expect(rows.single['action'], 'unfollow');
    expect(_view(app, 'ST3').following, isFalse);

    server.calls.clear();
    server.down = false;
    await app.repo.syncWatches();
    expect(server.calls, ['apiUnfollowTask'],
        reason: 'подписка, которую передумали, на сервер не уезжает');
    expect(app.repo.pendingCount, 0);
    expect(_view(app, 'ST3').group, TaskGroup.authored,
        reason: 'авторская после отписки остаётся на месте');
    app.dispose();
  });

  test('отказ по подписке (задача больше не видна): строка снята, человеку сказано',
      () async {
    final app = await _repo(settings, server, [
      {'id': 'ST3', 'name': 'Поручение', 'authored': true},
    ]);
    server.refuse403.add('apiFollowTask');

    await app.repo.followTask('ST3');
    await app.repo.syncWatches();

    expect(await app.repo.db.tasks.getWatchOutbox(), isEmpty,
        reason: 'ответ по существу от повтора не изменится — ретраить нечего');
    expect(app.repo.takeNotice, contains('Поручение'));
    expect(app.repo.takeNotice, contains('Нет доступа к задаче'));
    expect(_view(app, 'ST3').following, isFalse,
        reason: 'кэш остался серверным — подписки нет');
    app.dispose();
  });

  test('«Следить» — не в «Моих» и не при подписке подразделением', () async {
    final app = await _repo(settings, server, [
      {'id': 'ST1', 'name': 'Моя', 'assigned': true, 'mine': true},
      {'id': 'ST2', 'name': 'Пул', 'assigned': true, 'canTake': true},
      {
        'id': 'ST4',
        'name': 'Взял коллега',
        'assigned': true,
        'takenById': 'p2',
        'takenBy': 'Петров П.П.',
      },
      {'id': 'ST5', 'name': 'Отдел следит', 'watched': true},
      {
        'id': 'ST6',
        'name': 'Слежу и я, и отдел',
        'watched': true,
        'following': true,
      },
    ]);
    expect(_view(app, 'ST1').canFollow, isFalse,
        reason: 'исполнителю и так приходит всё по своей задаче');
    expect(_view(app, 'ST2').canFollow, isTrue);
    expect(_view(app, 'ST4').canFollow, isTrue,
        reason: 'ради «Проверка завершена» по задаче коллеги');
    final team = _view(app, 'ST5');
    expect(team.group, TaskGroup.watched);
    expect(team.following, isFalse, reason: 'подписку отдела с телефона не снять');
    expect(team.canFollow, isFalse, reason: 'уведомления у него уже есть');
    expect(_view(app, 'ST6').following, isTrue);
    app.dispose();
  });

  test('гео-гейт не касается наблюдаемой, авторская — под ним, как была', () async {
    server = _Server(settings, geoRequired: true);
    final app = await _repo(settings, server, [
      {'id': 'ST2', 'name': 'Слежу', 'watched': true, 'objectId': 'o9'},
      {'id': 'ST3', 'name': 'Поручение', 'authored': true, 'objectId': 'o9'},
      {'id': 'ST1', 'name': 'Моя', 'assigned': true, 'objectId': 'o9'},
    ]);
    // человек нигде не стоит — всё «не здесь», кроме наблюдаемой
    expect(_view(app, 'ST2').elsewhere, isFalse,
        reason: 'работы по ней нет — защищать гейтом нечего');
    expect(_view(app, 'ST3').elsewhere, isTrue, reason: 'правило #36844 не тронуто');
    expect(_view(app, 'ST1').elsewhere, isTrue);
    app.dispose();
  });

  test('пометка «по подписке» читается из ленты и переживает отметку прочтения', () {
    final n = NotificationItem.fromJson({
      'event': 'fillingFinished',
      'date': '2026-09-10',
      'taskId': 'ST2',
      'watching': true,
    });
    expect(n.watching, isTrue);
    expect(n.copyWith(viewed: true).watching, isTrue);
    expect(NotificationItem.fromJson({'event': 'overdue'}).watching, isFalse,
        reason: 'старый сервер ключа не шлёт — пометки нет');
  });

  testWidgets('карточка: «Не следить» у личной подписки, у отдела — объяснение',
      (tester) async {
    await tester.runAsync(() async {
      final app = await _repo(settings, server, [
        {
          'id': 'ST2',
          'name': 'Чужая проверка',
          'watched': true,
          'following': true,
          'assignedTo': 'Петров П.П.',
        },
        {
          'id': 'ST5',
          'name': 'Отдел следит',
          'watched': true,
          'assignedTo': 'Петров П.П.',
        },
      ]);
      await tester.pumpWidget(MultiProvider(
        providers: app.providers,
        child: const MaterialApp(home: TaskDetailScreen(taskId: 'ST2')),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Не следить'), findsOneWidget);
      expect(find.textContaining('в составе подразделения'), findsNothing);

      await tester.pumpWidget(MultiProvider(
        providers: app.providers,
        child: const MaterialApp(home: TaskDetailScreen(taskId: 'ST5')),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Не следить'), findsNothing);
      expect(find.text('Следить'), findsNothing);
      expect(find.textContaining('в составе подразделения'), findsOneWidget);
      app.dispose();
    });
  });
}
