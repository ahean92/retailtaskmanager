import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/fill_controller.dart';
import 'package:pulse_tasks/data/local_db.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/data/simple_controller.dart';
import 'package:pulse_tasks/data/task_repository.dart';
import 'package:pulse_tasks/models/task.dart';
import 'support/test_env.dart';
import 'support/fake_server.dart';

/// Политика дренажа офлайн-очередей — одна на бланк, отчёт поручения, статусы и
/// взятия, и здесь она записана сценариями, а не словами:
///
///   - обрыв связи (любое исключение, кроме ответа сервера) — стоп всей цепочки,
///     строка остаётся, online = false; следующие шаги даже не пробуются;
///   - отказ сервера на барьерном шаге (создание, старт) — стоп цепочки: полям
///     несуществующего выполнения ехать некуда; online = true — сервер ответил;
///   - отказ сервера по обычной строке (поле, снимок, статус) — строка остаётся с
///     причиной в sync_errors, а цикл идёт дальше по следующим строкам и шагам;
///   - завершение уходит только по пустым очередям тела: застрявшая строка держит
///     его, и это правильно.
///
/// Настоящий sqlite (ffi): очереди и их порядок живут в схеме.

int _seq = 0;
const _uuid = '33333333-3333-4333-8333-333333333333';

Future<LocalDb> _openDb() async =>
    LocalDb.open('tpolicy_${DateTime.now().microsecondsSinceEpoch}_${_seq++}');

/// Сервер, который отказывает выборочно — по ручке И по телу запроса: «отвергни
/// поле f1, но прими f2» иначе не выразить. Умеет «пропадать» целиком.
class _Server {
  final calls = <String>[]; // POST-попытки, включая оборвавшиеся
  bool down = false;
  int? Function(String action, String body) fail = (_, __) => null;

  late final Session session;
  late final ApiClient api;

  _Server(Settings settings) {
    session = Session(
      login: 'sidorov${_seq++}', // логин уникален: имя базы содержит его
      name: 'Сидоров С.С.',
      token: 'token',
      signedIn: true,
      performerId: 'p1',
    );
    api = ApiClient(settings, session, client: MockClient((request) async {
      final action = actionOf(request);
      if (request.method == 'POST') {
        calls.add(action); // попытка записывается до «обрыва сети»
        if (down) throw const SocketException('нет сети');
        final status = fail(action, request.body);
        if (status != null) return http.Response('boom', status);
        return http.Response('', 200);
      }
      if (down) throw const SocketException('нет сети');
      return okJson(action == 'apiExecutionInfo' ? '{}' : '[]');
    }));
  }
}

Future<File> _shot() async {
  final dir = await Directory.systemTemp.createTemp('pulse_policy');
  final f = File('${dir.path}/shot.jpg');
  await f.writeAsBytes([1, 2, 3]);
  return f;
}

void main() {
  initTestEnv();

  late Settings settings;
  late _Server server;

  setUp(() {
    resetMockStores();
    settings = Settings(baseUrl: 'http://test.local:9080');
    server = _Server(settings);
  });

  group('бланк', () {
    test('отказ на старте — барьер: ответы не едут, сеть считается живой',
        () async {
      final db = await _openDb();
      await db.createLocalTask(
        const Task(id: _uuid, clientId: _uuid, name: 'Витрина', typeId: 'form'),
        payloadJson: jsonEncode({'clientId': _uuid, 'typeId': 'form'}),
        createdAtIso: '2026-09-07T10:00:00.000',
        queueStart: true,
      );
      await db.enqueueField(_uuid, 'clean',
          type: 'text', text: 'ок', createdAtIso: '2026-09-07T10:01:00.000');
      server.fail = (a, _) => a == 'apiStartExecution' ? 500 : null;

      final c = FillController(db: db, api: server.api, taskId: _uuid);
      await c.syncAll(refreshSummary: false);

      expect(server.calls, ['apiCreateTask', 'apiStartExecution'],
          reason: 'поле выполнения, которого нет, ехать не может');
      expect(await db.getCreateEntry(_uuid), isNull, reason: 'создание ушло');
      expect(await db.getStartEntry(_uuid), isNotNull, reason: 'старт остался');
      expect(await db.getFieldOutbox(_uuid), hasLength(1));
      expect(c.online, isTrue, reason: 'сервер ответил — это не офлайн');
      expect(c.lastSyncError, isNotNull);
      c.dispose();
      await db.close();
    });

    test('отказ по одному полю не держит остальные, но держит завершение',
        () async {
      final db = await _openDb();
      const id = 'ST-R';
      await db.enqueueField(id, 'f1',
          type: 'text', text: 'а', createdAtIso: '2026-09-07T10:00:00.000');
      await db.enqueueField(id, 'f2',
          type: 'text', text: 'б', createdAtIso: '2026-09-07T10:01:00.000');
      await db.setResolutionOutbox(id, 'passed', '2026-09-07T10:02:00.000');
      await db.enqueueFinish(id, '2026-09-07T10:03:00.000');
      server.fail = (a, body) =>
          a == 'apiSetField' && body.contains('"field":"f1"') ? 500 : null;

      final c = FillController(db: db, api: server.api, taskId: id);
      await c.syncAll(refreshSummary: false);

      expect(server.calls, ['apiSetField', 'apiSetField', 'apiSetResolution'],
          reason: 'f2 и итог уехали вслед за отвергнутым f1; finish — нет');
      final left = await db.getFieldOutbox(id);
      expect(left.map((e) => e['fieldCode']), ['f1']);
      expect(await db.getResolutionOutbox(id), isNull);
      expect(await db.getFinishEntry(id), isNotNull,
          reason: 'застрявшее поле держит завершение');
      expect(c.online, isTrue);
      expect(c.lastSyncError, isNotNull);
      expect((await db.getSyncErrors()).keys, contains('fill:$id'),
          reason: 'причина — под операцией экрана «Не отправлено»');
      c.dispose();
      await db.close();
    });

    test('обрыв связи — одна попытка, дальше цепочка не идёт', () async {
      final db = await _openDb();
      const id = 'ST-O';
      await db.enqueueField(id, 'f1',
          type: 'text', text: 'а', createdAtIso: '2026-09-07T10:00:00.000');
      await db.enqueueField(id, 'f2',
          type: 'text', text: 'б', createdAtIso: '2026-09-07T10:01:00.000');
      await db.setResolutionOutbox(id, 'passed', '2026-09-07T10:02:00.000');
      server.down = true;

      final c = FillController(db: db, api: server.api, taskId: id);
      await c.syncAll(refreshSummary: false);

      expect(server.calls, ['apiSetField'],
          reason: 'следующие строки упрутся в тот же обрыв — их не пробуют');
      expect(await db.getFieldOutbox(id), hasLength(2));
      expect(await db.getResolutionOutbox(id), 'passed');
      expect(c.online, isFalse);
      expect((await db.getSyncErrors())['fill:$id']?.message, 'Нет сети');
      c.dispose();
      await db.close();
    });
  });

  group('отчёт поручения', () {
    test('отказ по снимку не держит комментарий, но держит завершение',
        () async {
      final db = await _openDb();
      const id = 'ST-S';
      final shot = await _shot();
      await db.saveSimplePhoto(id, 1, shot.path, '2026-09-07T10:00:00.000');
      await db.enqueueSimpleComment(id, 'готово', '2026-09-07T10:01:00.000');
      await db.enqueueSimpleFinish(id, '2026-09-07T10:02:00');
      server.fail = (a, _) => a == 'apiSetSimplePhoto' ? 500 : null;

      final c = SimpleExecutionController(db: db, api: server.api, taskId: id);
      await c.syncAll(refreshInfo: false);

      expect(server.calls, ['apiSetSimplePhoto', 'apiSetSimpleComment']);
      expect(await db.getPendingSimplePhotos(id), hasLength(1));
      expect(await db.getSimpleComment(id), isNull);
      expect(await db.getSimpleFinishEntry(id), isNotNull,
          reason: 'застрявший снимок держит «Выполнено»');
      expect(c.online, isTrue);
      expect((await db.getSyncErrors()).keys, contains('simple:$id'));
      c.dispose();
      await db.close();
    });
  });

  group('репозиторий', () {
    Future<TaskRepository> repoWith(List<Map<String, Object?>> fetched) async {
      final repo = TaskRepository(
          api: server.api, settings: settings, session: server.session);
      await repo.updateSettings(settings); // открывает базу этого логина
      for (final j in fetched) {
        await repo.db.insertLocalTask(Task.fromJson(j.cast<String, dynamic>()));
      }
      return repo;
    }

    test('отказ на взятии — стоп без повтора по кругу, сеть живая', () async {
      final repo = await repoWith([
        {'id': 'ST2', 'name': 'Пул', 'canTake': true},
      ]);
      await repo.db.enqueueTake('ST2', 'take', '2026-09-07T10:00:00.000');
      server.fail = (a, _) => a == 'apiTakeTask' ? 500 : null;

      await repo.syncTakes();

      expect(server.calls, ['apiTakeTask'],
          reason: 'перечитывающий проход не зацикливается на отвергнутой строке');
      expect(await repo.db.getTakeOutbox(), hasLength(1));
      expect(repo.online, isTrue);
      expect((await repo.db.getSyncErrors()).keys, contains('take:ST2'));
      repo.dispose();
    });

    test('отказ по статусу одной задачи не держит статус другой', () async {
      final repo = await repoWith([
        {'id': 'ST1', 'name': 'Первая'},
        {'id': 'ST2', 'name': 'Вторая'},
      ]);
      await repo.db.enqueue('ST1', 's2', 'В работе', '2026-09-07T10:00:00.000');
      await repo.db.enqueue('ST2', 's2', 'В работе', '2026-09-07T10:01:00.000');
      server.fail = (a, body) =>
          a == 'apiSetStatus' && body.contains('"id":"ST1"') ? 500 : null;

      await repo.syncOutbox();

      expect(server.calls, ['apiSetStatus', 'apiSetStatus']);
      expect((await repo.db.getOutbox()).keys, ['ST1']);
      expect(repo.online, isTrue, reason: 'сервер ответил — это не офлайн');
      expect((await repo.db.getSyncErrors()).keys, contains('status:ST1'));
      repo.dispose();
    });
  });
}
