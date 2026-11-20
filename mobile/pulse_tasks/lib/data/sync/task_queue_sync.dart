import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart' show DatabaseException;

import '../../models/task.dart';
import '../../models/task_status.dart';
import '../../models/task_view.dart';
import '../api_client.dart';
import '../error_journal.dart';
import '../local_db.dart';
import '../session.dart';
import '../user_base.dart';
import 'outbox_drain.dart';

// Синхронизаторы очередей намерений над списком задач (#36836, #37136, #37158 и смены
// статуса): человек жмёт — строка ложится в очередь, список перестраивается в этом же
// кадре, отправка идёт следом. Каждый домен в своём файле, а список и наложение
// очередей на него — в TaskRepository. Сюда — то, что у доменов общее.

/// Адрес полосы о проигранной гонке: задача и тот, кто её взял. Не const и без
/// равенства по полям: полосы различаются по identity — «та же, что была до fetch».
class TakeHolder {
  final String taskId;
  final String holderId;
  TakeHolder(this.taskId, this.holderId);
}

/// Что синхронизатору нужно от списка задач. Собирает его TaskRepository из своих
/// полей — наружу репозиторий этим не открывается.
class TaskSyncContext {
  TaskSyncContext({
    required this.base,
    required this.session,
    required this.api,
    required this.drain,
    required this.reload,
    required this.refresh,
    required this.notify,
    required this.setError,
    required this.noteStop,
    required this.notice,
    required this.tasks,
    required this.viewOf,
    required this.statusById,
  });

  final UserBase base;
  final Session session;
  final ApiClient api;

  /// Отправка и вердикт о сети — общие со списком (см. TaskRepository.drain).
  final OutboxDrain drain;

  /// Перечитать список из базы — очереди легли поверх.
  final Future<void> Function() reload;

  /// Спросить сервер о свежей выдаче.
  final Future<void> Function() refresh;

  /// Разбудить экраны списка.
  final void Function() notify;

  /// Текст ошибки синхронизации для баннера списка.
  final void Function(String text) setError;

  /// Цепочка остановилась на обрыве связи — сказать об этом баннером.
  final void Function() noteStop;

  /// Полоса на списке и главной: проигранная гонка, отказ подписки, отказ решения.
  final void Function(String? text, [TakeHolder? of]) notice;

  final List<TaskView> Function() tasks;
  final TaskView? Function(String taskId) viewOf;
  final TaskStatus? Function(String? id) statusById;
}

/// Одна очередь намерений — взятия, подписки, решения: старейшая запись первой,
/// очередь перечитывается после каждой (человек мог передумать, пока запись была в
/// полёте), строка кэша приводится к подтверждённому состоянию до снятия строки
/// очереди. Возвращает именно ИДУЩИЙ проход, когда он есть: «await sync() вернулся»
/// всегда означает «попытка отправки состоялась» — запись, легшая в очередь до
/// вызова, этим проходом уже видна.
abstract class QueueSync {
  QueueSync(this.ctx);

  final TaskSyncContext ctx;

  Future<void>? _run;

  /// Подпись прохода в журнале ошибок.
  @protected
  String get where;

  /// Один проход по очереди; false — цепочка остановилась на обрыве связи.
  @protected
  Future<bool> drainOnce();

  Future<void> sync() {
    final running = _run;
    if (running != null) return running;
    final run = _body().whenComplete(() => _run = null);
    _run = run;
    return run;
  }

  Future<void> _body() async {
    if (!ctx.session.isActive || ctx.base.db == null) return;
    try {
      if (!await drainOnce()) ctx.noteStop();
    } on DatabaseException {
      // база закрылась прямо под дренажем (выход из аккаунта): очередь цела в
      // sqlite и дожмётся следующим входом — тихо прерваться лучше, чем уронить
      // unawaited-цепочку unhandled-исключением
    } catch (e, stack) {
      // не закрытая база, а ошибка — молча её не глотаем
      ErrorJournal.record(e, stack, kind: ErrorJournal.sync, where: where);
    } finally {
      await ctx.reload();
    }
  }

  /// Намерение легло в очередь: список перестраивается в этом же кадре, отправка —
  /// следом.
  @protected
  Future<void> enqueued() async {
    await ctx.reload();
    unawaited(sync());
  }
}

/// Строка кэша задачи по любому её адресу — ST-номеру или UUID.
Future<Task?> cachedTask(LocalDb db, String id) async {
  for (final t in await db.tasks.getTasks()) {
    if (t.id == id || t.clientId == id) return t;
  }
  return null;
}
