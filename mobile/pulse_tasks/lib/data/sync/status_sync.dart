import 'dart:async';

import '../../models/task_status.dart';
import '../api_client.dart';
import '../local_db.dart';
import '../unsent.dart';
import 'task_queue_sync.dart';

/// Смена статуса задачи: очередь статусов и её дренаж.
class StatusSync {
  StatusSync(this.ctx);

  final TaskSyncContext ctx;

  /// Очередь статусов сейчас едет — индикатор на списке.
  bool syncing = false;

  /// Отказанная сервером смена статуса снята с очереди — полоса на списке задач до
  /// крестика (см. [_noticeRefusal]). Хранится одно, последнее: стопка сообщений —
  /// уже не сообщение, а журнал.
  String? notice;

  /// Change a task's status: record it locally (instant, offline-safe) and try
  /// to push right away.
  Future<void> set(String taskId, TaskStatus status) async {
    final db = ctx.base.db;
    if (db == null) return;
    await db.tasks.enqueue(
        taskId, status.id, status.name, DateTime.now().toIso8601String());
    await ctx.reload();
    unawaited(_push());
  }

  /// Смена ушла — и допустимые переходы в кэше устарели: сервер считал их от прежнего
  /// статуса (Task.nextStatusIds), а куда задачу можно перевести теперь, знает только
  /// он. Отказанная сервером смена — тем более: свежая выдача возвращает задаче её
  /// статус и убирает из карточки то, что правилами больше не разрешено.
  Future<void> _push() async {
    if (await sync()) await ctx.refresh();
  }

  /// Drain the outbox to the server, oldest first. Stops on the first network
  /// failure and keeps the remaining entries for a later retry.
  ///
  /// Отказ сервера здесь — не «повезёт в следующий раз», а приговор этому переходу:
  /// сервер ответил словом для человека (правила переходов, гварды ручки), и тот же
  /// запрос получит тот же отказ всегда. Такая строка с очереди снимается, слово
  /// сервера показывается плашкой на списке ([notice]), а следом refresh возвращает
  /// задаче серверный статус. Не разбираемый отказ (ApiException с «HTTP …» — голый
  /// код без текста) строку оставляет: вдруг это разовый сбой.
  ///
  /// Only ever the signed-in person's own queue: the base being drained is theirs, and
  /// nobody else's entries are reachable from it — which is what keeps one worker's change
  /// from reaching the server under another worker's account.
  ///
  /// True — очередь поговорила с сервером и кэшу нужна свежая выдача: хоть одна
  /// смена принята либо отказанная навсегда смена снята с очереди.
  Future<bool> sync() async {
    final db = ctx.base.db;
    if (syncing || !ctx.session.isActive || db == null) return false;
    syncing = true;
    ctx.notify();
    var sent = false;
    final refusedOff = <({OutboxEntry entry, ApiException error})>[];
    try {
      final outbox = await db.tasks.getOutbox();
      // барьер #36716: статус задачи, чьё создание ещё не уехало, не отправляется —
      // он ушёл бы к серверу, который такой задачи не знает. И статус задачи с
      // застрявшим finish тоже придерживается: иначе он обгонит завершение, и 'done'
      // финиша перезапишет его — хронология пользователя инвертируется. Записи
      // остаются в очереди и уйдут заходом после того, как drainLocalTasks дожмёт.
      final creating = await db.queues.getCreateTaskIds();
      final finishing = await db.queues.getFinishTaskIds();
      final ready = [
        for (final e in outbox.values)
          if (!creating.contains(e.taskId) && !finishing.contains(e.taskId)) e
      ];
      // отказ по статусу одной задачи её строку оставляет, а следующие едут; обрыв
      // связи оставляет в очереди всё до следующего захода
      final go = await ctx.drain.each(ready, (entry) async {
        await ctx.api.setStatus(entry.taskId, entry.statusId);
        await db.tasks.updateTaskStatus(
            entry.taskId, entry.statusId, entry.statusName);
        await db.tasks.dequeue(entry.taskId, createdAt: entry.createdAt);
        sent = true;
      },
          kind: UnsentKind.status,
          taskOf: (e) => e.taskId,
          onRefused: (e, ex) {
            if (ex.message.startsWith('HTTP')) {
              ctx.setError('Не удалось синхронизировать: ${ex.message}');
            } else {
              refusedOff.add((entry: e, error: ex));
            }
          });
      if (!go) ctx.noteStop();
      if (refusedOff.isNotEmpty) {
        // причина уже записана дренажем в sync_errors; без строки в очереди она
        // вычистится при следующей сборке «Не отправлено» (pruneSyncErrors)
        for (final r in refusedOff) {
          // отказ — этой смене, а не той, что человек мог выбрать, пока она ехала
          await db.tasks.dequeue(r.entry.taskId, createdAt: r.entry.createdAt);
        }
        _noticeRefusal(refusedOff);
      }
    } catch (_) {
      // база закрылась прямо под дренажем (выход из аккаунта, конец работы
      // приложения): очередь цела в sqlite и дожмётся следующим входом — как у
      // взятий, подписок и решений
      if (identical(ctx.base.db, db)) rethrow;
    } finally {
      syncing = false;
      await ctx.reload();
    }
    return sent || refusedOff.isNotEmpty;
  }

  /// Человек обязан узнать, что его выбор не состоялся: в момент тапа карточка
  /// ответила «отменена/сохранена», а слово сервера пришло позже, из очереди.
  /// Одна смена — словами сервера, несколько — счётом: стопку чужих фраз никто
  /// не дочитает. Плашка гаснет крестиком; задача уже возвращена серверному
  /// статусу свежей выдачей.
  void _noticeRefusal(List<({OutboxEntry entry, ApiException error})> refused) {
    notice = refused.length == 1
        ? 'Смена статуса не принята: ${refused.single.error.message}'
        : 'Не приняты смены статуса: ${refused.length} задач';
  }
}
