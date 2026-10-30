import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/local_db.dart';
import 'package:pulse_tasks/data/unsent.dart';
import 'package:pulse_tasks/models/task.dart';
import 'support/test_env.dart';

/// «Убрать из очереди» для отклонённых сервером операций (#37349): отказ («Бланк
/// заполняет другой», 403 создания, завершённый бланк) — это приговор, который не
/// изменится, и человек, прочитав причину, решает убрать хвост; обрыв связи —
/// временный, кнопки не даём. Проверяется флаг причины (миграция v36), удаление
/// строк только своей операции и untouched-соседи.

int _seq = 0;

Future<LocalDb> _openDb() async =>
    LocalDb.open('t37349d_${DateTime.now().microsecondsSinceEpoch}_${_seq++}');

void main() {
  initTestEnv();

  setUp(() {
    resetMockStores();
  });

  test('отказ сервера помечен, обрыв связи — нет: кнопка различает их', () async {
    final db = await _openDb();
    await db.tasks.insertLocalTask(Task.fromJson(const {
      'id': 'ST1',
      'name': 'Проверить ценники',
    }));
    await db.fill.enqueueField('ST1', 'f1',
        type: 'text', text: 'ответ', createdAtIso: '2026-10-30T10:00:00');

    await noteSyncFailure(db, UnsentKind.fill, 'ST1',
        ApiException('Бланк заполняет Крылов Иван', status: 409));
    var ops = await loadUnsentOps(db);
    expect(ops, hasLength(1));
    expect(ops.first.refused, isTrue,
        reason: 'сервер ответил отказом — этой операции можно предложить уборку');
    expect(ops.first.error, contains('Отклонено сервером'));

    // сеть пропала — «подождать», не «решать»: убирать нечего, уедет сама
    await noteSyncFailure(
        db, UnsentKind.fill, 'ST1', const SocketException('нет сети'));
    ops = await loadUnsentOps(db);
    expect(ops.first.refused, isFalse,
        reason: 'обрыв связи — не отказ сервера, кнопки быть не должно');
  });

  test('убрать отклонённый бланк: хвост уходит, соседние операции и кэш — нет',
      () async {
    final db = await _openDb();
    await db.tasks.insertLocalTask(Task.fromJson(const {
      'id': 'ST1',
      'name': 'Проверить ценники',
    }));
    await db.fill.enqueueField('ST1', 'f1',
        type: 'text', text: 'ответ', createdAtIso: '2026-10-30T10:00:00');
    await db.queues.enqueueFinish('ST1', '2026-10-30T10:01:00');
    await db.tasks.enqueue('ST1', 's2', 'В работе', '2026-10-30T10:02:00');
    await db.fill.saveFillCache('ST1', '[]', '[]', '{}', '2026-10-30T10:03:00');

    await noteSyncFailure(db, UnsentKind.fill, 'ST1',
        ApiException('Бланк заполняет Крылов Иван', status: 409));
    final op = (await loadUnsentOps(db)).singleWhere((o) => o.kind == UnsentKind.fill);

    await discardUnsentOp(db, op);

    expect(await db.fill.getFieldOutbox('ST1'), isEmpty,
        reason: 'ответы отклонённого бланка убраны');
    expect(await db.queues.hasFinish('ST1'), isFalse,
        reason: 'отложенное завершение — часть той же операции бланка');
    expect((await loadUnsentOps(db)).map((o) => o.kind),
        [UnsentKind.status],
        reason: 'смена статуса — другая операция, её не трогали');
    expect(await db.fill.getFillCache('ST1'), isNotNull,
        reason: 'кэш бланка остаётся: убирают очередь, а не просмотр');
    expect((await db.queues.getSyncErrors()).keys,
        isNot(contains('fill:ST1')),
        reason: 'причина ушла вместе с операцией');
  });

  test('отклонённое создание уходит вместе с задачей целиком', () async {
    final db = await _openDb();
    // задача, рождённая на телефоне: id = clientId, создание в task_outbox,
    // снимок автора — в очереди файлов (как ставит createLocalTask)
    await db.queues.createLocalTask(
      Task.fromJson(const {'id': 'cid-1', 'clientId': 'cid-1', 'name': 'Внеплановая'}),
      payloadJson: '{"clientId":"cid-1"}',
      photos: const {'p1': '/tmp/nowhere.jpg'},
      createdAtIso: '2026-10-30T10:00:00',
    );

    await noteSyncFailure(db, UnsentKind.create, 'cid-1',
        ApiException('Нет доступа', status: 403));
    final ops = await loadUnsentOps(db);
    final create = ops.singleWhere((o) => o.kind == UnsentKind.create);
    expect(create.refused, isTrue);

    await discardUnsentOp(db, create);

    expect(await loadUnsentOps(db), isEmpty,
        reason: 'без создания нет и его хвоста — файлы ушли вместе с задачей');
    expect(await db.tasks.getTasks(), isEmpty);
  });
}
