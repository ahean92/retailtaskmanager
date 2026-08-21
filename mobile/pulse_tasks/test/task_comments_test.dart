import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/comment_controller.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/data/task_repository.dart';
import 'package:pulse_tasks/models/comment.dart';
import 'package:pulse_tasks/models/task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Переписка по задаче (#36844): сообщение пишут без связи — оно в ленте сразу и в
/// очереди; ретрай несёт тот же clientId и не задваивает; непрочитанное гаснет на
/// телефоне раньше, чем узнает сервер; авторская задача — отдельная группа и только
/// для чтения. Настоящий sqlite (ffi): очередь, кэш ленты и отметка «прочитано до»
/// живут в схеме, и мокать их — значит не проверить ничего.

int _seq = 0;

/// Сервер, который отвечает на переписку как настоящий: лента по id задачи, 200 без
/// тела на сообщение и отметку, и умеет «пропадать» — целиком или только на POST.
class _Server {
  final calls = <String>[]; // POST-попытки, включая оборвавшиеся
  final bodies = <(String, Map<String, dynamic>)>[]; // (действие, тело)
  bool down = false;
  bool postDown = false; // чтение живо, запись рвётся — «ответ потерялся»
  final failWith = <String, int>{}; // действие → HTTP-статус отказа
  final comments = <String, List<Map<String, Object?>>>{}; // лента по задаче

  late final Session session;
  late final ApiClient api;

  _Server(Settings settings) {
    session = Session(
      // логин уникален и в прогоне, и между прогонами: имя базы содержит его, а
      // файл ffi-sqlite переживает запуск — прошлый кэш ленты иначе пережил бы тест
      login: 'ivanov${DateTime.now().microsecondsSinceEpoch}_${_seq++}',
      name: 'Иванов И.И.',
      token: 'token',
      signedIn: true,
      performerId: 'p1',
    );
    api = ApiClient(settings, session, client: MockClient((request) async {
      final action = request.url.path.split('.').last;
      if (request.method == 'POST') {
        calls.add(action); // попытка записывается до «обрыва сети»
        if (down || postDown) throw const SocketException('нет сети');
        final fail = failWith[action];
        if (fail != null) return http.Response('boom', fail);
        bodies.add((
          action,
          (jsonDecode(request.body) as Map).cast<String, dynamic>()
        ));
        return http.Response('', 200);
      }
      if (down) throw const SocketException('нет сети');
      if (action == 'apiTaskComments') {
        final id = request.url.queryParameters['id'];
        return _json(comments[id] ?? const []);
      }
      return _json(const []);
    }));
  }

  static http.Response _json(Object body) => http.Response.bytes(
      utf8.encode(jsonEncode(body)), 200,
      headers: {'content-type': 'application/json; charset=utf-8'});

  List<Map<String, dynamic>> sent(String action) =>
      [for (final b in bodies) if (b.$1 == action) b.$2];
}

/// Репозиторий с открытой базой этого логина и серверной выдачей в кэше.
Future<TaskRepository> _repo(Settings settings, _Server server,
    List<Map<String, Object?>> fetched) async {
  final repo = TaskRepository(
      api: server.api, settings: settings, session: server.session);
  await repo.updateSettings(settings); // открывает базу этого логина
  for (final j in fetched) {
    await repo.db.insertLocalTask(Task.fromJson(j.cast<String, dynamic>()));
  }
  await repo.reloadLocal();
  return repo;
}

TaskView _view(TaskRepository repo, String id) =>
    repo.tasks.firstWhere((v) => v.id == id);

Map<String, Object?> _msg(String id, String author, String text, String at,
        {bool mine = false, String? clientId}) =>
    {
      'id': id,
      'author': author,
      'text': text,
      'dateTime': at,
      if (mine) 'mine': true,
      if (clientId != null) 'clientId': clientId,
    };

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

  test('офлайн: сообщение сразу в ленте с пометкой и в очереди; со связью уходит '
      'один раз и с тем же ключом', () async {
    final repo = await _repo(settings, server, [
      {'id': 'ST1', 'name': 'Витрина', 'assigned': true, 'commentCount': 0},
    ]);
    server.down = true;
    final c = TaskCommentsController(db: repo.db, api: repo.api, taskId: 'ST1');
    await c.load();
    expect(c.online, isFalse);

    await c.send('дверь подсобки закрыта');
    await c.syncAll(); // присоединиться к отправке, упёршейся в «нет сети»

    expect(c.items, hasLength(1));
    expect(c.items.single.pending, isTrue);
    expect(c.items.single.mine, isTrue);
    expect(c.items.single.text, 'дверь подсобки закрыта');
    expect(c.items.single.sendError, isNull, reason: 'обрыв сети — не отказ');
    await repo.reloadLocal();
    expect(_view(repo, 'ST1').commentCount, 1,
        reason: 'своё неотправленное считается в счётчике карточки');
    expect(_view(repo, 'ST1').unreadComments, 0,
        reason: 'своё непрочитанным не бывает');
    expect(repo.pendingCount, 1);
    expect(await repo.db.pendingChanges(), 1,
        reason: 'предупреждение при выходе считает и сообщение');

    // связь вернулась: дренаж репозитория дожимает без открытой ленты
    server.down = false;
    final clientId = c.items.single.clientId!;
    server.comments['ST1'] = [
      _msg('101', 'Иванов И.И.', 'дверь подсобки закрыта',
          '2026-08-21T10:00:00',
          mine: true, clientId: clientId),
    ];
    await repo.drainComments();

    // каждая syncAll — своя попытка (встаёт в очередь за идущей, а не сливается с
    // ней: строка, легшая после старта чужого прохода, иначе осталась бы без
    // попытки): отправка + явный sync офлайн, потом доезд
    expect(server.calls.where((a) => a == 'apiAddTaskComment'), hasLength(3),
        reason: 'две попытки офлайн + доезд');
    final sent = server.sent('apiAddTaskComment');
    expect(sent, hasLength(1));
    expect(sent.single['id'], 'ST1');
    expect(sent.single['clientId'], clientId,
        reason: 'ключ идемпотентности рождается с сообщением и не меняется');
    expect(sent.single['text'], 'дверь подсобки закрыта');
    expect(sent.single.containsKey('photo'), isFalse);
    expect(await repo.db.getAllCommentOutbox(), isEmpty);
    expect(repo.pendingCount, 0);

    await c.load();
    expect(c.items, hasLength(1));
    expect(c.items.single.pending, isFalse);
    expect(c.items.single.id, '101', reason: 'теперь это серверное сообщение');
    c.dispose();
    repo.dispose();
  });

  test('ответ на отправку потерян: строка очереди схлопывается с серверной, '
      'новых ключей не рождается', () async {
    final repo = await _repo(settings, server, [
      {'id': 'ST1', 'name': 'Витрина', 'assigned': true},
    ]);
    final c = TaskCommentsController(db: repo.db, api: repo.api, taskId: 'ST1');
    await c.load();

    server.postDown = true;
    await c.send('ключа нет');
    await c.syncAll();
    expect(c.items.single.pending, isTrue,
        reason: 'ответа не было — для телефона не ушло');
    final clientId = c.items.single.clientId!;

    // сервер на самом деле принял: лента уже несёт сообщение с нашим clientId, а
    // запись всё ещё рвётся — и всё равно не должно задвоиться
    server.comments['ST1'] = [
      _msg('102', 'Иванов И.И.', 'ключа нет', '2026-08-21T10:05:00',
          mine: true, clientId: clientId),
    ];
    await c.load();

    expect(c.items, hasLength(1),
        reason: 'строка очереди схлопнулась с серверной');
    expect(c.items.single.pending, isFalse);
    expect(c.items.single.id, '102');
    expect(await repo.db.getAllCommentOutbox(), isEmpty);
    expect(server.calls.where((a) => a == 'apiAddTaskComment'), hasLength(3),
        reason: 'три попытки одного и того же сообщения (отправка, явный sync, '
            'load) — и ни одного нового ключа');
    expect(server.sent('apiAddTaskComment'), isEmpty,
        reason: 'до сервера так ни одна и не дошла — и не надо, он его уже знает');
    c.dispose();
    repo.dispose();
  });

  test('отказ сервера: сообщение остаётся с подписью, «Убрать» чистит очередь',
      () async {
    final repo = await _repo(settings, server, [
      {'id': 'ST1', 'name': 'Витрина', 'assigned': true},
    ]);
    final c = TaskCommentsController(db: repo.db, api: repo.api, taskId: 'ST1');
    await c.load();
    server.failWith['apiAddTaskComment'] = 500;

    await c.send('мусор');
    await c.syncAll();
    expect(c.items.single.pending, isTrue);
    expect(c.items.single.sendError, contains('500'),
        reason: 'отказ сервера — не обрыв, и человек должен его видеть');
    expect(c.online, isTrue);

    await c.discard(c.items.single.clientId!);
    expect(c.items, isEmpty);
    expect(await repo.db.getAllCommentOutbox(), isEmpty);
    c.dispose();
    repo.dispose();
  });

  test('непрочитанное: без кэша — серверное число; прочитанное офлайн гасит бейдж '
      'сразу, отметка доезжает потом', () async {
    final repo = await _repo(settings, server, [
      {
        'id': 'ST1',
        'name': 'Витрина',
        'assigned': true,
        'commentCount': 2,
        'unreadComments': 2,
      },
    ]);
    expect(_view(repo, 'ST1').unreadComments, 2, reason: 'кэша нет — сервер');
    expect(_view(repo, 'ST1').commentCount, 2);

    server.comments['ST1'] = [
      _msg('201', 'Директор', 'ключ у охраны', '2026-08-21T09:00:00'),
      _msg('202', 'Директор', 'и второй тоже', '2026-08-21T09:30:00'),
    ];
    await repo.prefetchComments(); // ленту забрала синхронизация
    expect(_view(repo, 'ST1').unreadComments, 2,
        reason: 'кэш есть, отметки нет — столько же');

    server.down = true;
    final c = TaskCommentsController(db: repo.db, api: repo.api, taskId: 'ST1');
    await c.load();
    expect(c.items, hasLength(2), reason: 'офлайн — из кэша');
    expect(c.items.first.text, 'ключ у охраны');
    await c.markRead(); // то, что делает секция, показав ленту
    await repo.reloadLocal();
    expect(_view(repo, 'ST1').unreadComments, 0,
        reason: 'прочитано офлайн — бейдж гаснет, не дожидаясь сервера');
    expect(await repo.db.getPendingCommentReads(), hasLength(1));

    server.down = false;
    await repo.drainComments();
    final marks = server.sent('apiMarkTaskCommentsRead');
    expect(marks, hasLength(1));
    expect(marks.single['id'], 'ST1');
    expect(marks.single['upTo'], '2026-08-21T09:30:00',
        reason: 'до последнего показанного серверного сообщения, его временем');
    expect(await repo.db.getPendingCommentReads(), isEmpty);

    // новое сообщение на сервере: его счётчик обгоняет кэш — верим серверу, а
    // префетч догоняет ленту одной ручкой
    await repo.db.insertLocalTask(Task.fromJson({
      'id': 'ST1',
      'name': 'Витрина',
      'assigned': true,
      'commentCount': 3,
      'unreadComments': 1,
    }));
    await repo.reloadLocal();
    expect(_view(repo, 'ST1').unreadComments, 1);
    server.comments['ST1']!
        .add(_msg('203', 'Директор', 'зайди потом', '2026-08-21T11:00:00'));
    await repo.prefetchComments();
    expect(_view(repo, 'ST1').commentCount, 3);
    expect(_view(repo, 'ST1').unreadComments, 1,
        reason: 'кэш догнал: одно новее отметки');
    c.dispose();
    repo.dispose();
  });

  test('авторская задача: группа «Поставленные мной», только чтение и переписка',
      () async {
    final repo = await _repo(settings, server, [
      {'id': 'ST1', 'name': 'Моя', 'assigned': true, 'mine': true},
      {
        'id': 'ST2',
        'name': 'Поручение',
        'authored': true,
        'assignedTo': 'Петров П.П.',
      },
      {'id': 'ST3', 'name': 'Сам себе', 'authored': true, 'assigned': true,
        'mine': true},
      {'id': 'ST4', 'name': 'Старый сервер'},
    ]);
    expect(_view(repo, 'ST1').group, TaskGroup.mine);
    final v = _view(repo, 'ST2');
    expect(v.group, TaskGroup.authored);
    expect(v.authoredOnly, isTrue);
    expect(v.canTake, isFalse);
    expect(v.releasable, isFalse);
    expect(_view(repo, 'ST3').group, TaskGroup.mine,
        reason: 'сам себе поставил — исполнитель');
    expect(_view(repo, 'ST3').authoredOnly, isFalse);
    expect(_view(repo, 'ST4').group, TaskGroup.mine,
        reason: 'выдача старого сервера вся назначена лично');
    expect(_view(repo, 'ST4').authoredOnly, isFalse);
    repo.dispose();
  });

  test('модель сообщения: вложения и дорога через кэш', () {
    final c = TaskComment.fromJson({
      'id': 7,
      'author': 'Директор',
      'dateTime': '2026-08-21T10:42:00',
      'text': 'вот фото',
      'files': [
        {'id': 55, 'name': 'Фото к комментарию.jpg', 'image': true},
        {'id': 56, 'name': 'акт.pdf'},
      ],
    });
    expect(c.id, '7');
    expect(c.mine, isFalse, reason: 'ключа не было — чужое');
    expect(c.files, hasLength(2));
    expect(c.files.first.image, isTrue);
    expect(c.files.last.image, isFalse);
    expect(c.when, DateTime(2026, 8, 21, 10, 42));

    final back = TaskComment.fromMap(c.toMap('ST1'));
    expect(back.author, 'Директор');
    expect(back.files.map((f) => f.id), ['55', '56']);
    expect(back.files.first.image, isTrue);
    expect(back.files.last.name, 'акт.pdf');
  });
}
