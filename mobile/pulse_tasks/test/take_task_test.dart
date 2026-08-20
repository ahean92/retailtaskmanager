import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/data/task_repository.dart';
import 'package:pulse_tasks/models/task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Пул подразделения и взятие на себя (#36836): группировка списка — по серверным
/// флагам, взятие офлайн — с пометкой и откатом. Настоящий sqlite (ffi): очередь
/// взятий, REPLACE «передумал» и наложение на кэш живут в схеме.

int _seq = 0;

/// Сервер, который отвечает на взятие как настоящий: 200 без тела, 409 с именем и
/// временем успевшего, и умеет «пропадать».
class _Server {
  final calls = <String>[]; // POST-попытки, включая оборвавшиеся
  bool down = false;
  final conflict409 = <String, Map<String, Object?>>{}; // действие → тело 409

  late final Session session;
  late final ApiClient api;

  _Server(Settings settings) {
    session = Session(
      login: 'ivanov${_seq++}', // логин уникален: имя базы содержит его
      name: 'Иванов И.И.',
      token: 'token',
      signedIn: true,
      performerId: 'p1',
    );
    api = ApiClient(settings, session, client: MockClient((request) async {
      final action = request.url.path.split('.').last;
      if (request.method == 'POST') {
        calls.add(action); // попытка записывается до «обрыва сети»
        if (down) throw const SocketException('нет сети');
        final conflict = conflict409[action];
        if (conflict != null) {
          return http.Response.bytes(
              utf8.encode(jsonEncode(conflict)), 409,
              headers: {'content-type': 'application/json; charset=utf-8'});
        }
        return http.Response('', 200);
      }
      if (down) throw const SocketException('нет сети');
      return http.Response.bytes(utf8.encode('[]'), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    }));
  }
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
  await repo.syncTakes(); // очередь пуста — это просто перечитать кэш в память
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

  test('группировка — по серверным флагам, строка без ключей — «мои»', () async {
    final repo = await _repo(settings, server, [
      {'id': 'ST1', 'name': 'Личная', 'mine': true},
      {'id': 'ST2', 'name': 'Пул', 'canTake': true},
      {
        'id': 'ST3',
        'name': 'Чужая',
        'takenById': 'p2',
        'takenBy': 'Петров П.П.',
        'takenAt': '2026-01-15T10:42:00',
      },
      {'id': 'ST4', 'name': 'Старый сервер'},
      {
        'id': 'ST5',
        'name': 'Взятая мной',
        'mine': true,
        'takenById': 'p1',
        'takenBy': 'Иванов И.И.',
      },
    ]);

    expect(_view(repo, 'ST1').group, TaskGroup.mine);
    expect(_view(repo, 'ST2').group, TaskGroup.free);
    expect(_view(repo, 'ST3').group, TaskGroup.taken);
    expect(_view(repo, 'ST4').group, TaskGroup.mine,
        reason: 'выдача старого сервера вся назначена лично');
    expect(_view(repo, 'ST5').group, TaskGroup.mine);

    // кнопки: «взять» — только по серверному canTake, «снять» — только у своей
    expect(_view(repo, 'ST2').canTake, isTrue);
    expect(_view(repo, 'ST3').canTake, isFalse);
    expect(_view(repo, 'ST1').releasable, isFalse,
        reason: 'личная не взята — снимать нечего');
    expect(_view(repo, 'ST5').releasable, isTrue);
    repo.dispose();
  });

  test('взятие офлайн: пометка «ожидает подтверждения», со связью — доезжает',
      () async {
    final repo = await _repo(settings, server, [
      {'id': 'ST2', 'name': 'Пул', 'canTake': true},
    ]);
    server.down = true;

    await repo.takeTask('ST2');
    await repo.syncTakes(); // присоединиться к дренажу, упёршемуся в «нет сети»

    var v = _view(repo, 'ST2');
    expect(v.group, TaskGroup.mine, reason: 'взятая — сразу в «моих»');
    expect(v.takePending, isTrue);
    expect(v.takenBy, 'Иванов И.И.');
    expect(v.canTake, isFalse, reason: 'взятую не предлагают взять ещё раз');
    expect(repo.pendingCount, 1);
    expect(await repo.db.pendingChanges(), 1,
        reason: 'предупреждение при выходе считает и взятие');

    // связь вернулась — уехало и подтвердилось
    server.down = false;
    await repo.syncTakes();

    expect(server.calls.where((a) => a == 'apiTakeTask'), hasLength(2),
        reason: 'попытка офлайн + доезд');
    v = _view(repo, 'ST2');
    expect(v.takePending, isFalse);
    expect(v.group, TaskGroup.mine);
    expect(v.takenById, 'p1');
    expect(repo.pendingCount, 0);
    repo.dispose();
  });

  test('конфликт: задача переезжает к коллеге с именем и временем, не молча',
      () async {
    final repo = await _repo(settings, server, [
      {'id': 'ST2', 'name': 'Витрина', 'canTake': true},
    ]);
    server.conflict409['apiTakeTask'] = {
      'error': 'alreadyTaken',
      'takenById': 'p2',
      'takenBy': 'Петров П.П.',
      'takenAt': '2026-01-15T10:42:00',
    };

    await repo.takeTask('ST2');
    await repo.syncTakes();

    final v = _view(repo, 'ST2');
    expect(v.group, TaskGroup.taken, reason: 'строка не исчезла, а переехала');
    expect(v.takenBy, 'Петров П.П.');
    expect(v.takePending, isFalse);
    expect(await repo.db.getTakeOutbox(), isEmpty,
        reason: 'проигранная гонка не ретраится');
    // заметное сообщение — с именем и временем того, кто успел
    expect(repo.takeNotice, contains('Витрина'));
    expect(repo.takeNotice, contains('Петров П.П.'));
    expect(repo.takeNotice, contains('15.01 10:42'));

    repo.dismissTakeNotice();
    expect(repo.takeNotice, isNull);
    repo.dispose();
  });

  test('снятие возвращает в «свободные», и взять можно снова', () async {
    final repo = await _repo(settings, server, [
      {
        'id': 'ST5',
        'name': 'Взятая мной',
        'mine': true,
        'takenById': 'p1',
        'takenBy': 'Иванов И.И.',
        'takenAt': '2026-01-15T09:00:00',
      },
    ]);

    await repo.releaseTask('ST5');
    var v = _view(repo, 'ST5');
    expect(v.group, TaskGroup.free, reason: 'в том же кадре, не после сервера');
    expect(v.takenBy, isNull);

    await repo.syncTakes(); // 200 доехал
    expect(server.calls, contains('apiReleaseTask'));
    v = _view(repo, 'ST5');
    expect(v.group, TaskGroup.free);
    expect(v.canTake, isTrue, reason: 'снятую можно взять обратно сразу');
    expect(await repo.db.getTakeOutbox(), isEmpty);
    repo.dispose();
  });

  test('«взял и передумал» офлайн: уезжает одно снятие, взятие не отправляется',
      () async {
    final repo = await _repo(settings, server, [
      {'id': 'ST2', 'name': 'Пул', 'canTake': true},
    ]);
    server.down = true;

    await repo.takeTask('ST2');
    await repo.syncTakes();
    await repo.releaseTask('ST2'); // откат снимает пометку и ничего больше
    await repo.syncTakes();

    final queued = await repo.db.getTakeOutbox();
    expect(queued, hasLength(1), reason: 'REPLACE, а не две записи');
    expect(queued.single['action'], 'release');
    expect(_view(repo, 'ST2').group, TaskGroup.free);

    server.down = false;
    server.calls.clear();
    await repo.syncTakes();
    // на сервер уехало только снятие; снятие невзятой задачи — пустой 200
    expect(server.calls, ['apiReleaseTask']);
    expect(await repo.db.getTakeOutbox(), isEmpty);
    repo.dispose();
  });

  test('обрыв сети посреди дренажа: очередь цела и доезжает следующим циклом',
      () async {
    final repo = await _repo(settings, server, [
      {'id': 'ST2', 'name': 'Пул', 'canTake': true},
      {'id': 'ST6', 'name': 'Пул-2', 'canTake': true},
    ]);
    server.down = true;

    await repo.takeTask('ST2');
    await repo.takeTask('ST6');
    await repo.syncTakes();
    expect(await repo.db.getTakeOutbox(), hasLength(2));
    expect(repo.online, isFalse);

    server.down = false;
    await repo.syncTakes();
    expect(await repo.db.getTakeOutbox(), isEmpty);
    expect(_view(repo, 'ST2').takenById, 'p1');
    expect(_view(repo, 'ST6').takenById, 'p1');
    repo.dispose();
  });
}
