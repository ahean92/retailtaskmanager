import '../../models/task.dart';
import '../api_client.dart';
import '../local_db.dart';
import '../unsent.dart';
import 'task_queue_sync.dart';

/// Взятие задачи из пула подразделения и снятие с себя (#36836).
class TakeSync extends QueueSync {
  TakeSync(super.ctx);

  @override
  String get where => 'syncTakes';

  /// Взять задачу на себя: намерение — строкой в очередь (мгновенно и
  /// офлайн-безопасно, как смена статуса), список перестраивается в этом же кадре,
  /// отправка — следом.
  Future<void> take(String taskId) => _enqueue(taskId, 'take');

  /// Снять с себя — тем же путём. Поверх ещё не ушедшего взятия строка очереди просто
  /// заменяется: это и есть «откат снимает пометку и ничего больше» — ответы бланка не
  /// трогаются нигде, а снятие невзятой задачи сервер отвечает пустым 200.
  Future<void> release(String taskId) => _enqueue(taskId, 'release');

  Future<void> _enqueue(String taskId, String action) async {
    final db = ctx.base.db;
    if (db == null) return;
    await db.tasks.enqueueTake(taskId, action, DateTime.now().toIso8601String());
    await enqueued();
  }

  /// Дренаж очереди взятий — старейшая запись первой, с перечитыванием очереди после
  /// каждой: пока запись была в полёте, человек мог передумать (REPLACE строки на
  /// противоположное действие), и ответ обогнанного взятия не должен снести намерение,
  /// записанное позже него, — сверку по action делает dequeueTake. Отказ сервера без
  /// адресата (500 «Take failed» и т.п.) запись оставляет: повтор взятия безопасен и
  /// уйдёт следующим циклом.
  @override
  Future<bool> drainOnce() async {
    LocalDb? db;
    final session = ctx.session;
    return ctx.drain.eachNext(() async {
      db = ctx.base.db; // вышли из аккаунта прямо под дренажем — очередь кончилась
      final rows = await db?.tasks.getTakeOutbox();
      return rows == null || rows.isEmpty ? null : rows.first;
    }, (entry) async {
      final local = db!;
      final id = entry['taskId'] as String;
      final action = entry['action'] as String;
      final refusal = action == 'take'
          ? await ctx.api.takeTask(id)
          : await ctx.api.releaseTask(id);
      if (refusal == null) {
        // принято. Строка кэша приводится к подтверждённому состоянию до
        // dequeue — между ними её не успеет перезаписать параллельный fetch, и
        // задача не мигнёт прежней группой до следующего refresh
        if (action == 'take') {
          await local.tasks.updateTaskTake(id,
              takenById: session.performerId,
              takenBy: session.name.isEmpty ? session.login : session.name,
              takenAt: DateTime.now().toIso8601String(),
              mine: true,
              canTake: false);
        } else {
          // снятая мной вернулась в пул: раз сервер снятие принял, взять её
          // можно снова — это его же canTake, каким он был до взятия
          await local.tasks.updateTaskTake(id,
              takenById: null,
              takenBy: null,
              takenAt: null,
              mine: false,
              canTake: true);
        }
      } else {
        // задачу держит другой (409, а у снятия и 403 notOwner): строка
        // переезжает в «взяты коллегами» с именем и временем успевшего, человеку
        // — заметное сообщение. Ответы бланка не трогаются: «взял» на сервере —
        // координация, а не блокировка.
        if (refusal.takenById != null) {
          await local.tasks.updateTaskTake(id,
              takenById: refusal.takenById,
              takenBy: refusal.takenBy,
              takenAt: refusal.takenAt,
              mine: false,
              canTake: false);
        }
        _noteRefusal(id, refusal);
      }
      await local.tasks.dequeueTake(id, action);
    }, kind: UnsentKind.take, taskOf: (e) => e['taskId'] as String);
  }

  /// «Задачу уже взял Иванов, 10:42» — а не «не получилось».
  void _noteRefusal(String taskId, TakeRefusal refusal) {
    String? name;
    for (final v in ctx.tasks()) {
      if (v.id == taskId) {
        name = v.task.name ?? v.task.object;
        break;
      }
    }
    final what = name == null ? 'Задачу' : 'Задачу «$name»';
    if (refusal.takenBy == null && refusal.takenById == null) {
      ctx.notice(refusal.message ?? '$what взять не удалось');
      return;
    }
    final when = takenAtText(refusal.takenAt);
    final holder = refusal.takenById;
    ctx.notice(
        '$what уже взял ${refusal.takenBy ?? 'другой сотрудник'}'
        '${when == null ? '' : ', $when'}',
        holder == null ? null : TakeHolder(taskId, holder));
  }
}
