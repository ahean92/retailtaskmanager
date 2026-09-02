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
import 'package:pulse_tasks/data/task_repository.dart';
import 'package:pulse_tasks/models/task.dart';
import 'support/test_env.dart';
import 'support/fake_server.dart';

/// Задача, рождённая на телефоне (#36716): очередь создания — барьер для всех
/// остальных очередей этой задачи. Порядок create → start → значения → фото →
/// завершение написан в FillController явно, и эти тесты — та самая явность:
/// цепочка уходит по порядку, обрывается целиком и доезжает после «появления связи».
///
/// Настоящий sqlite (ffi) вместо моков: очереди, сид бланка и коллапс дубля по
/// clientId живут в схеме, и подменять её — значит не проверить ничего.

int _seq = 0;

const _uuid = '11111111-1111-4111-8111-111111111111';

Future<LocalDb> _openDb() async =>
    LocalDb.open('t36716_${DateTime.now().microsecondsSinceEpoch}_${_seq++}');

/// Сервер, который записывает мутации в порядке прихода и умеет «пропадать».
class _Server {
  final calls = <String>[]; // POST-попытки, включая оборвавшиеся
  final bodies = <(String, String)>[]; // (действие, тело) — для проверки полей
  bool down = false;
  final failWith = <String, int>{}; // действие → HTTP-статус отказа

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
      final action = actionOf(request);
      if (request.method == 'POST') {
        calls.add(action); // попытка записывается до «обрыва сети»
        if (down) throw const SocketException('нет сети');
        final fail = failWith[action];
        if (fail != null) return http.Response('boom', fail);
        bodies.add((action, request.body));
        return http.Response('', 200);
      }
      if (down) throw const SocketException('нет сети');
      // GET-чтения бланка: пустых ответов контроллеру достаточно
      final body = action == 'apiExecutionInfo' ? '{}' : '[]';
      return okJson(body);
    }));
  }

  List<String> postsOf(String action) =>
      [for (final (a, b) in bodies) if (a == action) b];
}

Task _localTask(String uuid) => Task(
      id: uuid,
      clientId: uuid,
      name: 'Витрина',
      object: 'Магазин №1',
      objectId: 'b24',
      typeId: 'form',
      status: 'Ожидает отправки',
    );

/// Задача как её кладёт repo.createTask: строка списка, тело apiCreateTask в очереди,
/// отложенный старт и бланк, посеянный «не от задачи» — из предзагруженного шаблона.
Future<void> _seedLifecycle(LocalDb db, String uuid, {bool start = true}) async {
  await db.createLocalTask(
    _localTask(uuid),
    payloadJson: jsonEncode({
      'clientId': uuid,
      'typeId': 'form',
      'objectId': 'b24',
      'name': 'Витрина',
      'created': '2026-08-14',
      'templateId': 'showcase',
    }),
    createdAtIso: '2026-08-14T10:00:00.000',
    queueStart: start,
    seedFieldsJson: jsonEncode([
      {
        'sectionIndex': 1,
        'section': 'Зал',
        'fieldIndex': 1,
        'code': 'clean',
        'name': 'Чистота витрины',
        'type': 'scale',
        'required': true,
      },
    ]),
    seedOptionsJson: jsonEncode([
      {'fieldCode': 'clean', 'code': 'ok', 'name': 'Чисто'},
      {
        'fieldCode': 'clean',
        'code': 'dirty',
        'name': 'Грязно',
        'nonconformity': true,
      },
    ]),
    seedInfoJson: jsonEncode({
      'object': 'Магазин №1',
      'template': 'Витрина (демо)',
      'finished': false,
      'total': 1,
    }),
  );
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

  test('цепочка уходит строго по порядку: create → start → поле → фото → finish',
      () async {
    final db = await _openDb();
    await _seedLifecycle(db, _uuid);
    // смена в подвале: ответ, фото и завершение уже лежат в очередях
    await db.enqueueField(_uuid, 'clean',
        type: 'scale', optionCode: 'dirty', createdAtIso: '2026-08-14T10:01');
    final dir = await Directory.systemTemp.createTemp('pulse_test');
    final photo = File('${dir.path}/shot.jpg');
    await photo.writeAsBytes([1, 2, 3]);
    await db.saveFillPhoto(_uuid, 'clean', 0, photo.path, '2026-08-14T10:02');
    await db.enqueueFinish(_uuid, '2026-08-14T10:03');

    final c = FillController(db: db, api: server.api, taskId: _uuid);
    await c.syncAll(refreshSummary: false);

    expect(server.calls, [
      'apiCreateTask',
      'apiStartExecution',
      'apiSetField',
      'apiSetFieldPhoto',
      'apiFinishExecution',
    ]);
    // создание несло ключ клиента — на нём держится идемпотентность повторов
    final createBody =
        jsonDecode(server.postsOf('apiCreateTask').single) as Map;
    expect(createBody['clientId'], _uuid);
    // все очереди пусты, задача завершена
    expect(await db.getCreateEntry(_uuid), isNull);
    expect(await db.hasStart(_uuid), isFalse);
    expect(await db.getFieldOutbox(_uuid), isEmpty);
    expect(await db.getPendingFillPhotos(_uuid), isEmpty);
    expect(await db.hasFinish(_uuid), isFalse);
    expect(c.finished, isTrue);
    await db.close();
  });

  test('сервер отверг создание — барьер держит всё остальное', () async {
    final db = await _openDb();
    await _seedLifecycle(db, _uuid);
    await db.enqueueField(_uuid, 'clean',
        type: 'scale', optionCode: 'ok', createdAtIso: '2026-08-14T10:01');
    await db.enqueueFinish(_uuid, '2026-08-14T10:03');
    server.failWith['apiCreateTask'] = 500;

    final c = FillController(db: db, api: server.api, taskId: _uuid);
    await c.syncAll(refreshSummary: false);

    // одна попытка создания — и ни одного поля следом
    expect(server.calls, ['apiCreateTask']);
    expect(await db.getCreateEntry(_uuid), isNotNull);
    expect(await db.hasStart(_uuid), isTrue);
    expect(await db.getFieldOutbox(_uuid), hasLength(1));
    expect(await db.hasFinish(_uuid), isTrue);
    expect(c.lastSyncError, isNotNull);
    await db.close();
  });

  test('сети нет — одна попытка, очереди целы, online=false', () async {
    final db = await _openDb();
    await _seedLifecycle(db, _uuid);
    await db.enqueueField(_uuid, 'clean',
        type: 'scale', optionCode: 'ok', createdAtIso: '2026-08-14T10:01');
    server.down = true;

    final c = FillController(db: db, api: server.api, taskId: _uuid);
    await c.syncAll(refreshSummary: false);

    expect(server.calls, ['apiCreateTask']);
    expect(await db.getCreateEntry(_uuid), isNotNull);
    expect(await db.getFieldOutbox(_uuid), hasLength(1));
    expect(c.online, isFalse);
    await db.close();
  });

  test('replaceTasks: несинхронизированная локальная переживает, дубль схлопывается',
      () async {
    final db = await _openDb();
    await _seedLifecycle(db, _uuid, start: false);

    // обычный refresh: сервер про нашу задачу ещё не знает — строка живёт
    await db.replaceTasks([
      Task.fromJson({'id': 'ST000200', 'name': 'Чужая задача'})
    ]);
    var ids = (await db.getTasks()).map((t) => t.id).toSet();
    expect(ids, {'ST000200', _uuid});

    // сервер вернул наш UUID: создание доехало (пусть даже ответ POST потерялся) —
    // локальная строка уступает серверной, второго экземпляра на экране нет
    await db.replaceTasks([
      Task.fromJson({'id': 'ST000201', 'clientId': _uuid, 'name': 'Витрина'})
    ]);
    ids = (await db.getTasks()).map((t) => t.id).toSet();
    expect(ids, {'ST000201'});
    // и очередь создания закрыта фактом выдачи
    expect(await db.getCreateEntry(_uuid), isNull);
    await db.close();
  });

  test('офлайн: load() рисует бланк из посеянного шаблона', () async {
    final db = await _openDb();
    await _seedLifecycle(db, _uuid);
    server.down = true;

    final c = FillController(db: db, api: server.api, taskId: _uuid);
    await c.load();

    expect(c.fields, hasLength(1));
    expect(c.fields.single.name, 'Чистота витрины');
    expect(c.fields.single.options, hasLength(2));
    expect(c.summary.template, 'Витрина (демо)');
    expect(c.online, isFalse);
    expect(c.error, isNull); // бланк есть — жаловаться не на что
    await db.close();
  });

  test('finish() офлайн становится в очередь, а со связью доезжает целиком',
      () async {
    final db = await _openDb();
    await _seedLifecycle(db, _uuid);
    server.down = true;

    final c = FillController(db: db, api: server.api, taskId: _uuid);
    await c.load();
    await c.setOption(c.fields.single, 'ok'); // обязательное поле отвечено

    expect(await c.finish(), isTrue,
        reason: 'офлайн-завершение обещано тикетом');
    expect(c.finished, isTrue);
    expect(await db.hasFinish(_uuid), isTrue);

    // «после появления связи на сервере оказывается обычная завершённая проверка»
    server.down = false;
    server.calls.clear();
    await c.syncAll(refreshSummary: false);
    expect(server.calls, [
      'apiCreateTask',
      'apiStartExecution',
      'apiSetField',
      'apiFinishExecution',
    ]);
    expect(await db.hasFinish(_uuid), isFalse);
    await db.close();
  });

  test('репозиторий: статус не обгоняет создание, дрейн доводит без экрана',
      () async {
    final repo = TaskRepository(
        api: server.api, settings: settings, session: server.session);
    await repo.updateSettings(settings); // открывает базу этого логина

    await _seedLifecycle(repo.db, _uuid);
    await repo.db.enqueueField(_uuid, 'clean',
        type: 'scale', optionCode: 'ok', createdAtIso: '2026-08-14T10:01');
    // обычная серверная задача со сменённым статусом — она-то уйти должна
    await repo.db
        .insertLocalTask(Task.fromJson({'id': 'ST000300', 'statusId': 'todo'}));
    await repo.db.enqueue('ST000300', 'done', 'Выполнена', '2026-08-14T10:02');
    // и статус самой локальной задачи, сменённый до синхронизации
    await repo.db.enqueue(_uuid, 'done', 'Выполнена', '2026-08-14T10:03');

    server.down = true;
    await repo.syncOutbox();
    // ни один статус не отправлен раньше создания её задачи: попытка была только
    // по серверной задаче
    expect(server.calls.where((a) => a == 'apiSetStatus'), hasLength(1));

    server.down = false;
    server.calls.clear();
    // «телефон в кармане»: связь появилась, экран задачи никто не открывал
    await repo.drainLocalTasks();
    await repo.syncOutbox();

    expect(server.calls.where((a) => a == 'apiCreateTask'), hasLength(1));
    final statusBodies = server.postsOf('apiSetStatus');
    // оба статуса в итоге ушли, и статус локальной задачи — по её UUID
    expect(statusBodies.where((b) => b.contains(_uuid)), hasLength(1));
    expect(statusBodies.where((b) => b.contains('ST000300')), hasLength(1));
    expect(await repo.db.getCreateEntry(_uuid), isNull);
    repo.dispose();
  });
}
