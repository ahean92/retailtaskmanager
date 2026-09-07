import 'package:sqflite/sqflite.dart';

import '../../models/task.dart';
import '../../models/task_status.dart';

/// One queued, not-yet-synced status change.
class OutboxEntry {
  final String taskId;
  final String statusId;
  final String? statusName;

  /// Когда изменение легло в очередь — экран «Не отправлено» показывает это время
  /// (#36916). Nullable ради вызовов, которым момент не нужен.
  final String? createdAt;
  const OutboxEntry(this.taskId, this.statusId, this.statusName,
      {this.createdAt});
}

/// Задачи и статусы в кэше плюс две очереди по задаче: смена статуса и
/// взятие/возврат из пула (#36836). Строки кэша — как их отдал сервер; поверх
/// них очереди накладывает репозиторий при чтении.
class TasksDao {
  TasksDao(this._db);

  final Database _db;

  /// Replace the cached list with the server's answer — except the tasks born on this
  /// phone whose creation has not reached the server yet: those are the only rows the
  /// server can neither confirm nor deny, so they survive every refresh (#36716).
  ///
  /// A fetched task carrying one of our queued UUIDs is the server saying «создание
  /// доехало» — even if the POST's own answer was lost on the way back. The creation
  /// queue entry closes on the spot and the local row yields to the server one, which
  /// is what keeps the task from showing up twice. Снимки автора (#36914) закрытие
  /// создания НЕ трогает: они едут своей очередью и после него — задача, вернувшаяся
  /// с сервера, ещё ждёт свои кадры.
  Future<void> replaceTasks(List<Task> tasks) async {
    await _db.transaction((txn) async {
      final rows = await txn.query('task_outbox');
      final pending = {for (final r in rows) r['clientId'] as String};
      // Переживают замену строки задач, у которых жив ЛЮБОЙ шаг жизненного цикла, а
      // не только создание: create мог уехать, а start/finish застрять — fetch, не
      // вернувший такую задачу (сервер успел её закрыть, или создание ещё едет),
      // иначе стёр бы карточку «Завершена — не отправлена» посреди дожима.
      final keep = {
        ...pending,
        for (final r in await txn.query('start_outbox', columns: ['taskId']))
          r['taskId'] as String,
        for (final r in await txn.query('finish_outbox', columns: ['taskId']))
          r['taskId'] as String,
        // снимки, ещё не уехавшие (#36914), — такой же живой шаг, как старт и
        // завершение: карточка, где они показаны «ожидает отправки», не должна
        // исчезнуть из-под человека, пока кадр лежит только у него в телефоне
        for (final r in await txn.query('task_file_outbox', columns: ['taskId']))
          r['taskId'] as String,
      };
      for (final t in tasks) {
        final cid = t.clientId;
        if (cid == null) continue;
        // сервер вернул задачу сам — его строка главнее местной, какой бы шаг ни был
        // в очереди (очереди адресуются UUID'ом и без строки)
        keep.remove(cid);
        if (pending.remove(cid)) {
          await txn
              .delete('task_outbox', where: 'clientId = ?', whereArgs: [cid]);
        }
      }
      if (keep.isEmpty) {
        await txn.delete('tasks');
      } else {
        final marks = List.filled(keep.length, '?').join(',');
        await txn.delete('tasks',
            where: 'id NOT IN ($marks)', whereArgs: [...keep]);
      }
      final batch = txn.batch();
      for (final t in tasks) {
        batch.insert('tasks', t.toMap(),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
  }

  /// One task the phone just gave birth to — straight into the cache, so the list shows
  /// it in the same frame. Survives refreshes via the task_outbox check above.
  Future<void> insertLocalTask(Task t) async {
    await _db.insert('tasks', t.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Task>> getTasks() async {
    final rows = await _db.query('tasks');
    return rows.map(Task.fromMap).toList();
  }

  /// Update just the cached status of one task (after a confirmed sync), so the
  /// list reflects server truth without waiting for a full refresh. Статус-очередь
  /// рождённой на телефоне задачи ключуется UUID'ом, а строка после первой
  /// синхронизации несёт ST-номер — обновление ищет по обоим адресам.
  Future<void> updateTaskStatus(
      String taskId, String statusId, String? statusName) async {
    await _db.update(
      'tasks',
      {'statusId': statusId, 'status': statusName},
      where: 'id = ? OR clientId = ?',
      whereArgs: [taskId, taskId],
    );
  }

  Future<void> replaceStatuses(List<TaskStatus> statuses) async {
    await _db.transaction((txn) async {
      await txn.delete('statuses');
      final batch = txn.batch();
      for (final s in statuses) {
        batch.insert('statuses', s.toMap(),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
  }

  Future<List<TaskStatus>> getStatuses() async {
    final rows = await _db.query('statuses', orderBy: 'sortingOrder ASC');
    return rows.map(TaskStatus.fromMap).toList();
  }

  Future<void> enqueue(String taskId, String statusId, String? statusName,
      String createdAtIso) async {
    await _db.insert(
      'outbox',
      {
        'taskId': taskId,
        'statusId': statusId,
        'statusName': statusName,
        'createdAt': createdAtIso,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> dequeue(String taskId) async {
    await _db.delete('outbox', where: 'taskId = ?', whereArgs: [taskId]);
  }

  /// Pending changes keyed by task id (one latest change per task).
  Future<Map<String, OutboxEntry>> getOutbox() async {
    final rows = await _db.query('outbox', orderBy: 'createdAt ASC');
    return {
      for (final r in rows)
        r['taskId'] as String: OutboxEntry(
          r['taskId'] as String,
          r['statusId'] as String,
          r['statusName'] as String?,
          createdAt: r['createdAt'] as String?,
        )
    };
  }

  /// action — 'take' | 'release'. REPLACE поверх противоположного намерения по той же
  /// задаче — снятие ещё не ушедшего взятия не оставляет в очереди ничего лишнего.
  Future<void> enqueueTake(
      String taskId, String action, String createdAtIso) async {
    await _db.insert(
      'take_outbox',
      {'taskId': taskId, 'action': action, 'createdAt': createdAtIso},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Map<String, Object?>>> getTakeOutbox() async {
    return _db.query('take_outbox', orderBy: 'createdAt ASC');
  }

  /// Сверка по action несёт гонку в полёте: пока взятие ехало на сервер, человек мог
  /// передумать, и его строку в очереди REPLACE'ом сменило снятие — ответ взятия не
  /// должен снести намерение, записанное позже него.
  Future<void> dequeueTake(String taskId, String action) async {
    await _db.delete('take_outbox',
        where: 'taskId = ? AND action = ?', whereArgs: [taskId, action]);
  }

  /// Привести строку кэша к состоянию взятия, которое сервер только что подтвердил
  /// (ответом ручки или телом 409) — иначе до следующего refresh задача прыгала бы
  /// обратно в прежнюю группу. NULL здесь — значение, а не «не трогать»: снятие
  /// честно стирает имя и время.
  Future<void> updateTaskTake(String taskId,
      {String? takenById,
      String? takenBy,
      String? takenAt,
      required bool mine,
      required bool canTake}) async {
    await _db.update(
      'tasks',
      {
        'takenById': takenById,
        'takenBy': takenBy,
        'takenAt': takenAt,
        'mine': mine ? 1 : null,
        'canTake': canTake ? 1 : null,
      },
      where: 'id = ?',
      whereArgs: [taskId],
    );
  }
}
