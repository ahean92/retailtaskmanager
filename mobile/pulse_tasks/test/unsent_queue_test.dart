import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/comment_controller.dart';
import 'package:pulse_tasks/data/local_db.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/data/unsent.dart';
import 'package:pulse_tasks/models/task.dart';
import 'support/test_env.dart';

/// Очередь отправки: показать состав и дать запустить руками (#36916).
///
/// Проверяется сборка списка операций — то, что человек видит на экране
/// «Не отправлено» и на бейдже шапки: группировка строк очередей в операции с
/// человеческими названиями, счётные формы, порядок «старейшие первыми», причина
/// последней неудачи у своей операции и её уборка после того, как операция уехала.
/// Настоящий sqlite (ffi): операции собираются из пятнадцати таблиц схемы, и мок
/// не проверил бы ничего.

int _seq = 0;

Future<LocalDb> _openDb() async =>
    LocalDb.open('t36916_${DateTime.now().microsecondsSinceEpoch}_${_seq++}');

void main() {
  initTestEnv();

  setUp(() {
    resetMockStores();
  });

  test('очереди одной задачи складываются в операции по-людски', () async {
    final db = await _openDb();
    await db.insertLocalTask(Task.fromJson(const {
      'id': 'ST1',
      'name': 'Проверить ценники',
    }));

    // бланк: два ответа, фото, итог, завершение — одна операция
    await db.enqueueField('ST1', 'f1',
        type: 'option',
        optionCode: 'ok',
        createdAtIso: '2026-08-27T10:00:00');
    await db.enqueueField('ST1', 'f2',
        type: 'text', text: 'мятая витрина', createdAtIso: '2026-08-27T10:01:00');
    await db.saveFillPhoto('ST1', 'f2', 0, '/tmp/x.jpg', '2026-08-27T10:02:00');
    await db.setResolutionOutbox('ST1', 'passed', '2026-08-27T10:03:00');
    await db.enqueueFinish('ST1', '2026-08-27T10:04:00');
    // и рядом — смена статуса, два сообщения, два снимка к задаче
    await db.enqueue('ST1', 's2', 'В работе', '2026-08-27T10:05:00');
    await db.enqueueComment('c1', 'ST1',
        text: 'первое', createdAtIso: '2026-08-27T10:06:00');
    await db.enqueueComment('c2', 'ST1',
        text: 'второе', createdAtIso: '2026-08-27T10:07:00');
    await db.enqueueTaskFile('p1', 'ST1',
        path: '/tmp/a.jpg', createdAtIso: '2026-08-27T10:08:00');
    await db.enqueueTaskFile('p2', 'ST1',
        path: '/tmp/b.jpg', createdAtIso: '2026-08-27T10:09:00');

    final ops = await loadUnsentOps(db);

    // бейдж обещает столько строк, сколько покажет экран
    expect(ops, hasLength(4));
    // старейшие первыми: бланк встал в очередь раньше всех
    expect(ops.map((o) => o.kind).toList(), [
      UnsentKind.fill,
      UnsentKind.status,
      UnsentKind.comment,
      UnsentKind.file,
    ]);
    for (final o in ops) {
      expect(o.title, 'Проверить ценники',
          reason: 'операция зовётся именем задачи, а не её id');
    }
    expect(ops[0].detail, 'Бланк: 2 ответа, 1 фото, итог, завершение');
    expect(ops[1].detail, 'Статус → «В работе»');
    expect(ops[2].detail, '2 сообщения');
    expect(ops[3].detail, '2 фото к задаче');
    expect(ops[0].queuedAt, DateTime.parse('2026-08-27T10:00:00'),
        reason: 'время операции — самая ранняя постановка в очередь');

    await db.close();
  });

  test('рождённая офлайн задача: создание и бланк — двумя операциями', () async {
    final db = await _openDb();
    const uuid = '11111111-1111-4111-8111-111111111111';
    await db.createLocalTask(
      Task.fromJson(const {'id': uuid, 'clientId': uuid, 'name': 'Обход зала'}),
      payloadJson: '{}',
      createdAtIso: '2026-08-27T09:00:00',
      queueStart: true,
    );

    final ops = await loadUnsentOps(db);
    expect(ops, hasLength(2));
    expect(ops[0].kind, UnsentKind.create);
    expect(ops[0].detail, 'Создание задачи');
    expect(ops[1].kind, UnsentKind.fill);
    expect(ops[1].detail, 'Бланк: начало работы');
    expect(ops[0].title, 'Обход зала');

    await db.close();
  });

  test('причина неудачи — по-людски, а не кодом HTTP', () {
    expect(syncFailureText(ApiException('Нет права на задачу', status: 403)),
        'Отклонено сервером: Нет права на задачу');
    expect(syncFailureText(TimeoutException('20s')), 'Сервер не ответил');
    expect(syncFailureText(const SocketException('unreachable')), 'Нет сети');
    // обёртка http-клиента без типа — обрыв распознаётся по тексту: именно такая
    // «ClientException with SocketException: … errno = 101» стояла баннером главной
    expect(
        syncFailureText(Exception(
            'ClientException with SocketException: Connection failed '
            '(OS Error: Network is unreachable, errno = 101)')),
        'Нет сети');
    expect(syncFailureText(const FileSystemException('read failed')),
        'Файл недоступен на устройстве');
    expect(syncFailureText(const FormatException('bad json')),
        'Непонятный ответ сервера');
  });

  test('причина цепляется к своей операции и уходит вместе с ней', () async {
    final db = await _openDb();
    await db.insertLocalTask(
        Task.fromJson(const {'id': 'ST2', 'name': 'Витрина'}));
    await db.enqueue('ST2', 's9', 'Готово', '2026-08-27T11:00:00');
    await noteSyncFailure(db, UnsentKind.status, 'ST2',
        ApiException('Статус закрыт', status: 409));

    var ops = await loadUnsentOps(db);
    expect(ops.single.error, 'Отклонено сервером: Статус закрыт');

    // операция уехала (dequeue) — причина не переживает её: успешный дожим не пишет
    // «успех», он опустошает очередь, а сборка вычищает осиротевшие причины
    await db.dequeue('ST2');
    ops = await loadUnsentOps(db);
    expect(ops, isEmpty);
    expect(await db.getSyncErrors(), isEmpty);

    await db.close();
  });

  test('дренаж записывает причину: обрыв сети под отправкой сообщения', () async {
    final db = await _openDb();
    final session = Session(
      login: 'sidorov${_seq++}',
      token: 'token',
      signedIn: true,
      performerId: 'p1',
    );
    final api = ApiClient(
        Settings(baseUrl: 'http://test.local:9080'), session,
        client: MockClient(
            (request) async => throw const SocketException('нет сети')));

    await db.insertLocalTask(
        Task.fromJson(const {'id': 'ST3', 'name': 'Склад'}));
    await db.enqueueComment('c9', 'ST3',
        text: 'не уедет', createdAtIso: '2026-08-27T12:00:00');

    await TaskCommentsController.drainAll(db, api);

    final ops = await loadUnsentOps(db);
    expect(ops.single.kind, UnsentKind.comment);
    expect(ops.single.error, 'Нет сети');

    await db.close();
  });
}
