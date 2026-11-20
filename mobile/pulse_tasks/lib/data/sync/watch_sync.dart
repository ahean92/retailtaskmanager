import '../api_client.dart';
import '../local_db.dart';
import '../unsent.dart';
import 'task_queue_sync.dart';

/// Подписка на задачу — «Следить» и «Не следить» (#37136).
class WatchSync extends QueueSync {
  WatchSync(super.ctx);

  @override
  String get where => 'syncWatches';

  /// «Следить»: намерение — строкой в очередь, как взятие, список и карточка
  /// перестраиваются в этом же кадре, отправка — следом. Работает и в самолётном
  /// режиме: подписка нужна ради уведомлений, а не ради ответа сервера прямо сейчас.
  Future<void> follow(String taskId) => _enqueue(taskId, 'follow');

  /// «Не следить» — тем же путём. Задача, которая была здесь только ради наблюдения,
  /// уходит из списка сразу (см. наложение в TaskRepository._reload); поверх ещё не
  /// ушедшей подписки строка очереди просто заменяется — «подписался и передумал» не
  /// шлёт ничего лишнего.
  Future<void> unfollow(String taskId) => _enqueue(taskId, 'unfollow');

  Future<void> _enqueue(String taskId, String action) async {
    final db = ctx.base.db;
    if (db == null) return;
    await db.tasks
        .enqueueWatch(taskId, action, DateTime.now().toIso8601String());
    await enqueued();
  }

  /// Дренаж очереди подписок — тем же приёмом, что взятия ([TakeSync]): старейшая
  /// запись первой, очередь перечитывается после каждой (человек мог передумать, пока
  /// запись ехала).
  @override
  Future<bool> drainOnce() async {
    LocalDb? db;
    return ctx.drain.eachNext(() async {
      db = ctx.base.db; // вышли из аккаунта прямо под дренажем — очередь кончилась
      final local = db;
      if (local == null) return null;
      // барьер #36716: подписка на задачу, чьё создание ещё едет, ждёт его — сервер
      // такой задачи пока не знает и ответил бы «нет доступа». Строка остаётся и
      // уйдёт заходом после того, как drainLocalTasks дожмёт создание
      final creating = await local.queues.getCreateTaskIds();
      for (final r in await local.tasks.getWatchOutbox()) {
        if (!creating.contains(r['taskId'])) return r;
      }
      return null;
    }, (entry) async {
      final local = db!;
      final id = entry['taskId'] as String;
      final action = entry['action'] as String;
      if (action == 'follow') {
        final refusal = await ctx.api.followTask(id);
        if (refusal == null) {
          // строка кэша — к подтверждённому состоянию до dequeue, как у взятий:
          // между ними её не перезапишет параллельный fetch
          await local.tasks.updateTaskWatch(id, following: true, watched: true);
        } else {
          // задача перестала быть видна, пока подписка ехала (переназначили,
          // сменили автора): от повтора ответ не изменится — строку снимаем и
          // говорим человеку той же полосой, что и о проигранном взятии
          ctx.notice(
              'Следить за задачей «${_nameOf(id)}» не получилось: $refusal');
        }
      } else {
        await ctx.api.unfollowTask(id);
        // Задача, которая была на телефоне только ради наблюдения, уходит из кэша:
        // обнулить признак у такой строки нельзя — без assigned, authored и watched
        // она читается как назначенная (#36844) и уехала бы в «Мои». Если за ней
        // следит ещё и подразделение, ближайший refresh вернёт её в «Наблюдаю».
        final row = await cachedTask(local, id);
        if (row != null &&
            row.assigned != true &&
            row.authored != true &&
            row.reviewing != true) {
          await local.tasks.deleteTask(id);
        } else {
          await local.tasks
              .updateTaskWatch(id, following: false, watched: false);
        }
      }
      await local.tasks.dequeueWatch(id, action);
    }, kind: UnsentKind.watch, taskOf: (e) => e['taskId'] as String);
  }

  /// Как задача зовётся в сообщении: названием, объектом или номером.
  String _nameOf(String taskId) {
    final v = ctx.viewOf(taskId);
    return v?.task.name ?? v?.task.object ?? taskId;
  }
}
