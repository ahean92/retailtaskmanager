import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/local_db.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/data/simple_controller.dart';
import 'package:pulse_tasks/models/quick_create.dart';
import 'package:pulse_tasks/models/task.dart';
import 'support/test_env.dart';
import 'support/fake_server.dart';

/// Выполнение поручения фотоотчётом (#36872).
///
/// Проверяется то, что тикет называет своим: чем открывать задачу — решает СЕРВЕР;
/// снимок, комментарий и завершение уходят по порядку и переживают отсутствие связи;
/// отказ сервера («Приложите фото выполненной работы») доезжает до человека отказом,
/// а не «выполнено» — ради этого и разделён finish на сервере.
///
/// Настоящий sqlite (ffi), как в offline_create_test: очереди живут в схеме, и
/// подменять её моками — значит не проверить ничего.

int _seq = 0;
const _uuid = '22222222-2222-4222-8222-222222222222';

Future<LocalDb> _openDb() async =>
    LocalDb.open('t36872_${DateTime.now().microsecondsSinceEpoch}_${_seq++}');

/// Сервер, записывающий мутации в порядке прихода и умеющий «пропадать» и отказывать.
class _Server {
  final calls = <String>[];
  final bodies = <(String, String)>[];
  bool down = false;
  final failWith = <String, (int, String)>{};

  late final Session session;
  late final ApiClient api;

  _Server(Settings settings) {
    session = Session(
      login: 'petrov${_seq++}',
      name: 'Петров П.П.',
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
        // байтами и с charset: сообщение констрейнта — кириллица, а http.Response со
        // строкой кодирует её latin1 и падает, чего настоящий сервер не делает
        if (fail != null) {
          return http.Response.bytes(utf8.encode(fail.$2), fail.$1,
              headers: {'content-type': 'application/json; charset=utf-8'});
        }
        bodies.add((action, request.body));
        return http.Response('', 200);
      }
      if (down) throw const SocketException('нет сети');
      final body = action == 'apiSimpleInfo' ? '{}' : '[]';
      return okJson(body);
    }));
  }

  List<String> postsOf(String action) =>
      [for (final (a, b) in bodies) if (a == action) b];
}

Task _task({String? executionKind, String typeId = 'issue', bool? requirePhoto}) =>
    Task(
      id: 'ST000042',
      name: 'Убрать витрину',
      object: 'Магазин №1',
      objectId: 'b24',
      typeId: typeId,
      executionKind: executionKind,
      requirePhoto: requirePhoto,
    );

Future<File> _shot(String name) async {
  final dir = await Directory.systemTemp.createTemp('pulse36872');
  final f = File('${dir.path}/$name.jpg');
  await f.writeAsBytes([1, 2, 3]);
  return f;
}

void main() {
  initTestEnv();

  late Settings settings;
  late _Server server;
  late Directory docs;

  setUp(() {
    resetMockStores();
    // снимки живут файлами в каталоге приложения — на настольной машине его никто
    // не подставляет, поэтому подставляем сами
    docs = Directory.systemTemp.createTempSync('pulse_docs36872');
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

  group('чем открывать задачу — решает сервер', () {
    test('признак сервера сильнее списка типов на клиенте', () {
      // тип 'issue' в клиентском списке бланковых не значится и значиться не должен
      expect(_task(executionKind: 'simple').opensSimple, isTrue);
      expect(_task(executionKind: 'simple').opensFill, isFalse);
      // а тип 'form' с бланком открывается бланком, потому что так сказал сервер
      expect(_task(executionKind: 'fill', typeId: 'form').opensFill, isTrue);
      expect(_task(executionKind: 'fill', typeId: 'form').opensSimple, isFalse);
      // «сервер сказал: открывать нечем» — ни тем, ни другим, даже для типа из списка
      expect(_task(executionKind: '', typeId: 'checklist').opensFill, isFalse);
    });

    test('старый сервер признака не шлёт — работает прежний список типов', () {
      expect(_task(typeId: 'checklist').opensFill, isTrue);
      expect(_task(typeId: 'form').opensFill, isTrue);
      // ...и поручение у такого сервера по-прежнему не открывается ничем: экран
      // простого выполнения появляется только по его слову
      expect(_task(typeId: 'issue').opensFill, isFalse);
      expect(_task(typeId: 'issue').opensSimple, isFalse);
    });

    test('признак и требование фото переживают кэш', () {
      final t = _task(executionKind: 'simple', requirePhoto: true);
      final back = Task.fromMap(t.toMap());
      expect(back.executionKind, 'simple');
      expect(back.requirePhoto, isTrue);
      expect(back.opensSimple, isTrue);
    });

    test('пресет создания несёт вид выполнения — для задач, рождённых офлайн', () {
      // без этого поручение, созданное в подвале, не открылось бы ничем до первой
      // синхронизации: у локальной строки признака взяться больше неоткуда
      final p = QuickPreset.fromJson({
        'code': 'issue36872',
        'title': 'Поручение с фото',
        'typeId': 'issue',
        'executionKind': 'simple',
        'requirePhoto': true,
      });
      expect(p.executionKind, 'simple');
      final local = Task(
          id: 'uuid',
          clientId: 'uuid',
          typeId: p.typeId,
          executionKind: p.executionKind,
          requirePhoto: p.requirePhoto ? true : null);
      expect(local.opensSimple, isTrue);
      expect(local.requirePhoto, isTrue);
    });

    test('признак читается из ответа сервера', () {
      final t = Task.fromJson({
        'id': 'ST000042',
        'typeId': 'issue',
        'executionKind': 'simple',
        'requirePhoto': true,
      });
      expect(t.opensSimple, isTrue);
      expect(t.requirePhoto, isTrue);
    });
  });

  group('очередь отчёта', () {
    test('уходит строго по порядку: старт → фото → комментарий → завершение',
        () async {
      final db = await _openDb();
      final photo = await _shot('done');
      await db.enqueueSimpleStart('ST000042', '2026-08-24T10:00:00.000',
          lat: 53.9, lon: 27.56);
      await db.saveSimplePhoto('ST000042', 0, photo.path, '2026-08-24T10:01');
      await db.enqueueSimpleComment(
          'ST000042', 'Витрина убрана', '2026-08-24T10:02');
      await db.enqueueSimpleFinish('ST000042', '2026-08-24T10:03',
          lat: 53.91, lon: 27.57);

      final c = SimpleExecutionController(
          db: db, api: server.api, taskId: 'ST000042');
      await c.syncAll(refreshInfo: false);

      expect(server.calls, [
        'apiStartSimple',
        'apiSetSimplePhoto',
        'apiSetSimpleComment',
        'apiFinishSimple',
      ]);
      // координаты и время момента действия уехали из строк очереди, а не из
      // момента отправки (#36838)
      final start = jsonDecode(server.postsOf('apiStartSimple').single) as Map;
      expect(start['lat'], 53.9);
      expect(start['at'], '2026-08-24T10:00:00');
      final finish = jsonDecode(server.postsOf('apiFinishSimple').single) as Map;
      expect(finish['lat'], 53.91);
      // очереди пусты
      expect(await db.hasSimpleStart('ST000042'), isFalse);
      expect(await db.getPendingSimplePhotos('ST000042'), isEmpty);
      expect(await db.getSimpleComment('ST000042'), isNull);
      expect(await db.hasSimpleFinish('ST000042'), isFalse);
      expect(c.finished, isTrue);
      await db.close();
    });

    test('завершение не обгоняет свой снимок', () async {
      final db = await _openDb();
      final photo = await _shot('later');
      await db.saveSimplePhoto('ST000042', 0, photo.path, '2026-08-24T10:01');
      await db.enqueueSimpleFinish('ST000042', '2026-08-24T10:03');
      // фото сервер не принимает, связь при этом жива
      server.failWith['apiSetSimplePhoto'] = (500, 'boom');

      final c = SimpleExecutionController(
          db: db, api: server.api, taskId: 'ST000042');
      await c.syncAll(refreshInfo: false);

      // завершение даже не пробовали: задача не должна закрыться без фотографии
      expect(server.calls, ['apiSetSimplePhoto']);
      expect(await db.hasSimpleFinish('ST000042'), isTrue);
      expect(c.finished, isFalse);
      await db.close();
    });

    test('создание задачи — барьер и для отчёта', () async {
      final db = await _openDb();
      await db.createLocalTask(
        const Task(id: _uuid, clientId: _uuid, name: 'Убрать', typeId: 'issue'),
        payloadJson: jsonEncode({
          'clientId': _uuid,
          'typeId': 'issue',
          'objectId': 'b24',
          'name': 'Убрать',
          'requirePhoto': true,
        }),
        createdAtIso: '2026-08-24T10:00:00.000',
      );
      await db.enqueueSimpleStart(_uuid, '2026-08-24T10:00:30.000');
      server.failWith['apiCreateTask'] = (500, 'boom');

      final c =
          SimpleExecutionController(db: db, api: server.api, taskId: _uuid);
      await c.syncAll(refreshInfo: false);

      // одна попытка создания — и ни одного шага отчёта следом: сервер этой задачи
      // не знает, и старт ответил бы «not found»
      expect(server.calls, ['apiCreateTask']);
      expect(await db.hasSimpleStart(_uuid), isTrue);
      expect(c.lastSyncError, isNotNull);
      await db.close();
    });
  });

  group('завершение', () {
    test('без фото при requirePhoto кнопка недоступна, и сервер не зовётся',
        () async {
      final db = await _openDb();
      // требование фото известно из СПИСКА задач — до всякого ответа сервера по
      // выполнению: задача, созданная в подвале, к нему ещё не ходила
      final c = SimpleExecutionController(
          db: db, api: server.api, taskId: 'ST000042', requirePhotoHint: true);

      expect(c.requirePhoto, isTrue);
      expect(c.canFinish, isFalse);
      expect(await c.finish(), isFalse);
      expect(c.error, 'Приложите фото выполненной работы');
      expect(server.calls, isEmpty);
      await db.close();
    });

    test('офлайн — выполнено локально, уедет при связи', () async {
      final db = await _openDb();
      final photo = await _shot('offline');
      final c = SimpleExecutionController(
          db: db, api: server.api, taskId: 'ST000042', requirePhotoHint: true);
      server.down = true;
      await c.addPhoto(photo.path);

      expect(await c.finish(), isTrue);
      expect(c.finished, isTrue);
      expect(await db.hasSimpleFinish('ST000042'), isTrue);

      // связь вернулась — дренаж репозитория дожимает всё сам, без экрана
      server.down = false;
      await SimpleExecutionController.drainAll(db, server.api);
      expect(server.postsOf('apiSetSimplePhoto'), hasLength(1));
      expect(server.postsOf('apiFinishSimple'), hasLength(1));
      expect(await db.hasSimpleFinish('ST000042'), isFalse);
      await db.close();
    });

    test('сервер отверг завершение — экран говорит почему, а не «выполнено»',
        () async {
      final db = await _openDb();
      final c = SimpleExecutionController(
          db: db, api: server.api, taskId: 'ST000042');
      // ровно тот отказ, который отдаёт CONSTRAINT простого выполнения
      server.failWith['apiFinishSimple'] =
          (500, 'Приложите фото выполненной работы');

      expect(await c.finish(), isFalse);
      expect(c.finished, isFalse);
      expect(c.error, contains('Приложите фото выполненной работы'));
      // и завершение не осталось висеть в очереди: экран сказал «не удалось»
      expect(await db.hasSimpleFinish('ST000042'), isFalse);
      await db.close();
    });

    test('отказ на дожиме очереди снимает завершение и объясняет причину',
        () async {
      final db = await _openDb();
      final photo = await _shot('queued');
      final c = SimpleExecutionController(
          db: db, api: server.api, taskId: 'ST000042');
      server.down = true;
      await c.addPhoto(photo.path); // снимок остался в очереди
      server.down = false;
      server.failWith['apiFinishSimple'] =
          (500, 'Приложите фото выполненной работы');

      expect(await c.finish(), isFalse);
      expect(c.finished, isFalse);
      expect(c.error, contains('Приложите фото'));
      expect(await db.hasSimpleFinish('ST000042'), isFalse);
      // снимок при этом уехал — отказ завершения его не отменяет
      expect(server.postsOf('apiSetSimplePhoto'), hasLength(1));
      await db.close();
    });
  });

  group('отказ сервера читается человеком', () {
    test('из Java-обёртки достаётся сообщение констрейнта', () {
      // ровно то тело, которым стенд отвечает на завершение без фото
      const body = 'lsfusion.interop.base.exception.RemoteInternalException '
          'Внутренняя ошибка сервера: lsfusion.server.logics.action.flow.LSFException '
          'Приложите фото выполненной работы\n'
          '\tat lsfusion.server.logics.action.flow.ThrowExceptionAction.executeInternal';
      expect(ApiClient.humanError(body), 'Приложите фото выполненной работы');
    });

    test('подробности констрейнта после разделителя отброшены', () {
      const body = 'LSFException Приложите фото выполненной работы'
          '-----------------------------------------|Выполнение с фотоотчётом';
      expect(ApiClient.humanError(body), 'Приложите фото выполненной работы');
    });

    test('компактный отказ ручки показывается своим message, а не JSON-ом', () {
      // тело 403 от гвардов доступа (ApiCommon): человеку — message, код — машине
      expect(
          ApiClient.humanError(
              '{"error":"forbidden","message":"Нет доступа к задаче: ST000001"}'),
          'Нет доступа к задаче: ST000001');
      expect(
          ApiClient.humanError(
              '{"error":"notPerformer","message":"Учётная запись не является исполнителем: petrov"}'),
          'Учётная запись не является исполнителем: petrov');
    });

    test('непонятное тело показывается как есть, а не проглатывается', () {
      expect(ApiClient.humanError('boom'), 'boom');
      expect(ApiClient.humanError(''), '');
      // фигурная скобка без валидного JSON — прежний разбор, тело как есть
      expect(ApiClient.humanError('{oops'), '{oops');
    });

    test('и до экрана доезжает именно оно', () async {
      final db = await _openDb();
      final c = SimpleExecutionController(
          db: db, api: server.api, taskId: 'ST000042');
      server.failWith['apiFinishSimple'] = (
        500,
        'lsfusion.interop.base.exception.RemoteInternalException '
            'Внутренняя ошибка сервера: '
            'lsfusion.server.logics.action.flow.LSFException '
            'Приложите фото выполненной работы\n\tat lsfusion.server'
      );
      expect(await c.finish(), isFalse);
      expect(c.error, 'Приложите фото выполненной работы');
      await db.close();
    });
  });

  test('снимков может быть несколько, «убрать все» стирает набор и на сервере',
      () async {
    final db = await _openDb();
    final first = await _shot('one');
    final second = await _shot('two');
    final c =
        SimpleExecutionController(db: db, api: server.api, taskId: 'ST000042');
    await c.addPhoto(first.path);
    await c.addPhoto(second.path);
    await c.syncAll(refreshInfo: false);
    expect(server.postsOf('apiSetSimplePhoto'), hasLength(2));
    expect(c.photoPaths, hasLength(2));

    // на сервере набор уже есть — «убрать все» обязано доехать туда пустым фото
    c.serverPhotoCount = 2;
    await c.clearPhotos();
    await c.syncAll(refreshInfo: false);
    final last = jsonDecode(server.postsOf('apiSetSimplePhoto').last) as Map;
    expect(last['photo'], '');
    expect(c.photoPaths, isEmpty);
    await db.close();
  });
}
