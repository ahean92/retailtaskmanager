import '../../models/task.dart';
import '../api_client.dart';
import '../client_id.dart';
import '../local_db.dart';
import '../unsent.dart';
import 'task_queue_sync.dart';

/// Решение по сданной задаче — принять или вернуть на доработку (#37158).
class DecisionSync extends QueueSync {
  DecisionSync(super.ctx);

  /// Статус, в который задачу ставит возврат (серверный doReturn), — им строка
  /// перекрашивается до ответа сервера.
  static const returnedStatusId = 'in progress';

  @override
  String get where => 'syncDecisions';

  /// Принять результат: решение — строкой в очередь с ключом идемпотентности, задача
  /// уходит из «Ждут моей приёмки» в этом же кадре (принятая — из списка вовсе),
  /// отправка — следом. Работает и в самолётном режиме: заведующий решает в зале, а не
  /// там, где есть сеть.
  Future<void> accept(String taskId) => _enqueue(taskId, 'accept', null);

  /// Вернуть на доработку с причиной — тем же путём. Пустую причину экран не
  /// отправляет, а сервер отверг бы.
  Future<void> giveBack(String taskId, String reason) =>
      _enqueue(taskId, 'return', reason.trim());

  Future<void> _enqueue(String taskId, String action, String? reason) async {
    final db = ctx.base.db;
    if (db == null) return;
    await db.tasks.enqueueDecision(taskId, newClientId(), action, reason,
        DateTime.now().toIso8601String());
    await enqueued();
  }

  /// Дренаж очереди решений — тем же приёмом, что взятия ([TakeSync]): старейшее
  /// первым, очередь перечитывается после каждого (человек мог передумать, пока решение
  /// ехало).
  @override
  Future<bool> drainOnce() async {
    LocalDb? db;
    return ctx.drain.eachNext(() async {
      db = ctx.base.db; // вышли из аккаунта прямо под дренажем — очередь кончилась
      final rows = await db?.tasks.getDecisionOutbox();
      return rows == null || rows.isEmpty ? null : rows.first;
    }, (entry) async {
      final local = db!;
      final id = entry['taskId'] as String;
      final key = entry['clientId'] as String;
      final accept = entry['action'] == 'accept';
      final reason = entry['reason'] as String?;
      // название — до того, как принятая уйдёт из кэша: сообщение о ней ещё впереди
      final title = await _titleOf(local, id);
      final DecisionConflict? conflict;
      try {
        conflict = accept
            ? await ctx.api.acceptTask(id, key)
            : await ctx.api.returnTask(id, key, reason ?? '');
      } on ApiException catch (e) {
        // Отказ по существу — задача уже не на приёмке, решать мне её нельзя: от
        // повтора ответ не изменится. Решение снимается, строка возвращается к слову
        // сервера, человеку — почему; очередь дальше не держится, как у подписок.
        await local.tasks.dequeueDecision(id, key);
        ctx.notice('Решение по задаче «$title» не принято: ${e.message}');
        return;
      }
      // Строка кэша — к подтверждённому состоянию до dequeue, как у взятий: между
      // ними её не перезапишет параллельный fetch. Принятая закрыта — выдача её
      // больше не пришлёт; возвращённая снова в работе.
      final acceptedNow = conflict == null ? accept : conflict.accepted;
      if (acceptedNow) {
        await local.tasks.deleteTask(id);
      } else {
        await local.tasks.updateTaskReturned(id,
            statusId: returnedStatusId,
            statusName: ctx.statusById(returnedStatusId)?.name,
            reason: conflict == null ? reason : null);
      }
      if (conflict != null) _noteConflict(title, conflict);
      await local.tasks.dequeueDecision(id, key);
    }, kind: UnsentKind.decision, taskOf: (e) => e['taskId'] as String);
  }

  /// «Уже принято: Иванов, 10:42» (#37158) — двое из подразделения-принимающего решили
  /// по-разному, и проигравший узнаёт, кто успел раньше, а не видит молчаливый откат.
  void _noteConflict(String title, DecisionConflict c) {
    final when = takenAtText(c.decidedAt);
    final at = when == null ? '' : ', $when';
    // своё же решение с другого телефона (или передуманное, пока первое ехало) —
    // не «кто-то успел», а «уже сделано»
    if (c.decidedById != null && c.decidedById == ctx.session.performerId) {
      ctx.notice('Задача «$title» уже '
          '${c.accepted ? 'принята' : 'возвращена на доработку'} вами$at');
      return;
    }
    final what = c.accepted ? 'уже принято' : 'уже возвращено на доработку';
    ctx.notice('Задача «$title» — $what: ${c.decidedBy ?? 'другой сотрудник'}$at');
  }

  /// Как задача зовётся в сообщении, по кэшу — строка с решением «принять» в списке
  /// уже не показана, и viewOf её не найдёт.
  static Future<String> _titleOf(LocalDb db, String taskId) async {
    final t = await cachedTask(db, taskId);
    return t?.name ?? t?.object ?? taskId;
  }
}
