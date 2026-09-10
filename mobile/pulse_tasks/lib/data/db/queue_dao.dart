import 'package:sqflite/sqflite.dart';

import '../../models/task.dart';

import 'simple_dao.dart';

/// Жизненный цикл задачи, рождённой на телефоне (#36716): создание, старт,
/// завершение, снимки к задаче (#36914) — и всё, что про «ждёт отправки» по
/// задаче в целом: множество задач с очередями, счётчик неотправленного и
/// причины последних неудач (#36916).
class QueueDao {
  QueueDao(this._db, {required SimpleDao simple}) : _simple = simple;

  final Database _db;

  /// Старт поручения лежит в своей очереди — спросить о нём можно только её.
  final SimpleDao _simple;

  /// Everything this person has changed that the server has not confirmed yet: statuses,
  /// field values, table cells, the pending outcome and photos still waiting to go up.
  ///
  /// Counted across every queue rather than the status one alone, because this is the
  /// number the sign-out asks about — «сколько изменений останутся неотправленными» is a
  /// promise that has to hold for the photo taken in the aisle, not just for the tick in
  /// the list. The legacy `checklist_*` queues are left out: nothing in the app drains
  /// them any more, so counting them would show a number that can never fall.
  Future<int> pendingChanges() async {
    final r = await _db.rawQuery('''
      SELECT (SELECT COUNT(*) FROM outbox)
           + (SELECT COUNT(*) FROM fill_outbox)
           + (SELECT COUNT(*) FROM fill_cell_outbox)
           + (SELECT COUNT(*) FROM fill_row_outbox)
           + (SELECT COUNT(*) FROM fill_resolution)
           + (SELECT COUNT(*) FROM fill_photos WHERE uploaded = 0)
           + (SELECT COUNT(*) FROM fill_photo_deletes)
           + (SELECT COUNT(*) FROM task_outbox)
           + (SELECT COUNT(*) FROM start_outbox)
           + (SELECT COUNT(*) FROM finish_outbox)
           + (SELECT COUNT(*) FROM take_outbox)
           + (SELECT COUNT(*) FROM watch_outbox)
           + (SELECT COUNT(*) FROM comment_outbox)
           + (SELECT COUNT(*) FROM task_file_outbox)
           + (SELECT COUNT(*) FROM simple_photos WHERE uploaded = 0)
           + (SELECT COUNT(*) FROM simple_comment_outbox)
           + (SELECT COUNT(*) FROM simple_start_outbox)
           + (SELECT COUNT(*) FROM simple_finish_outbox) AS pending''');
    return (r.first['pending'] as int?) ?? 0;
  }

  /// Everything a new offline task needs, in one transaction: the visible list row,
  /// the queued apiCreateTask body and — for a template preset — the queued start plus
  /// a fill cache seeded from the preloaded template, so the form opens with no server
  /// anywhere near. Half of this committed and half not would be a task that can be
  /// seen but not synced, or synced but not seen.
  /// [photos] — снятые при создании кадры (#36914), парами «clientId файла → путь».
  /// Ложатся в ту же транзакцию: задача, у которой в списке нарисованы три снимка, но
  /// в очереди их нет, — ровно та потеря, ради которой всё это одной транзакцией.
  Future<void> createLocalTask(
    Task task, {
    required String payloadJson,
    Map<String, String> photos = const {},
    required String createdAtIso,
    bool queueStart = false,
    double? startLat,
    double? startLon,
    String? seedFieldsJson,
    String? seedOptionsJson,
    String? seedColumnsJson,
    String? seedInfoJson,
  }) async {
    await _db.transaction((txn) async {
      await txn.insert('tasks', task.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.insert(
        'task_outbox',
        {
          'clientId': task.id,
          'payload': payloadJson,
          'createdAt': createdAtIso,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      for (final e in photos.entries) {
        await txn.insert(
          'task_file_outbox',
          {
            'clientId': e.key,
            'taskId': task.id,
            'path': e.value,
            'createdAt': createdAtIso,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      if (queueStart) {
        await txn.insert(
          'start_outbox',
          {
            'taskId': task.id,
            'createdAt': createdAtIso,
            'lat': startLat,
            'lon': startLon,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      if (seedFieldsJson != null) {
        await txn.insert(
          'fill_cache',
          {
            'taskId': task.id,
            'fieldsJson': seedFieldsJson,
            'optionsJson': seedOptionsJson ?? '[]',
            'infoJson': seedInfoJson ?? '{}',
            'columnsJson': seedColumnsJson ?? '[]',
            'rowsJson': '[]',
            'fetchedAt': createdAtIso,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  /// The queued apiCreateTask of one task, or null once it has gone up.
  Future<Map<String, Object?>?> getCreateEntry(String taskId) async {
    final rows = await _db
        .query('task_outbox', where: 'clientId = ?', whereArgs: [taskId]);
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> dequeueCreate(String taskId) async {
    await _db
        .delete('task_outbox', where: 'clientId = ?', whereArgs: [taskId]);
  }

  /// Tasks whose creation is still queued — the rows replaceTasks keeps and the statuses
  /// syncOutbox must hold back (a status change cannot overtake the task itself).
  Future<Set<String>> getCreateTaskIds() async {
    final rows = await _db.query('task_outbox', columns: ['clientId']);
    return {for (final r in rows) r['clientId'] as String};
  }

  Future<bool> hasStart(String taskId) async {
    final rows = await _db
        .query('start_outbox', where: 'taskId = ?', whereArgs: [taskId]);
    return rows.isNotEmpty;
  }

  /// Кадр в очередь: снятый при создании — вместе с задачей (см. [createLocalTask]),
  /// досланный к готовой задаче — этим методом. [clientId] рождается вместе со
  /// снимком: по нему сервер узнаёт повтор, поэтому ретрай не двоит кадр на задаче.
  Future<void> enqueueTaskFile(String clientId, String taskId,
      {required String path, required String createdAtIso}) async {
    await _db.insert(
      'task_file_outbox',
      {
        'clientId': clientId,
        'taskId': taskId,
        'path': path,
        'createdAt': createdAtIso,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Неотправленные снимки одной задачи, старейший первым — карточка рисует их
  /// «ожидает отправки» тем же виджетом, что и приехавшие с сервера.
  Future<List<Map<String, Object?>>> getTaskFileOutbox(String taskId) {
    return _db.query('task_file_outbox',
        where: 'taskId = ?', whereArgs: [taskId], orderBy: 'createdAt ASC');
  }

  /// Вся очередь снимков — для дренажа при синхронизации.
  Future<List<Map<String, Object?>>> getAllTaskFileOutbox() {
    return _db.query('task_file_outbox', orderBy: 'createdAt ASC');
  }

  Future<void> dequeueTaskFile(String clientId) async {
    await _db.delete('task_file_outbox',
        where: 'clientId = ?', whereArgs: [clientId]);
  }

  /// The queued start whole — the sync needs its lat/lon/createdAt, because they, not
  /// the send moment, are where and when the work actually began (#36838).
  Future<Map<String, Object?>?> getStartEntry(String taskId) async {
    final rows = await _db
        .query('start_outbox', where: 'taskId = ?', whereArgs: [taskId]);
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> dequeueStart(String taskId) async {
    await _db.delete('start_outbox', where: 'taskId = ?', whereArgs: [taskId]);
  }

  /// Tasks whose queued start is still owed — counted into the list's pending marks,
  /// so «create уехал, старт застрял» не выглядит синхронизированным. Оба вида
  /// выполнения разом (#36872): метка на карточке отвечает на вопрос «уехало ли»,
  /// а не «какой ручкой уедет», и очередь у поручения своя.
  Future<Set<String>> getStartTaskIds() async {
    final rows = await _db.query('start_outbox', columns: ['taskId']);
    final simple = await _db.query('simple_start_outbox', columns: ['taskId']);
    return {
      for (final r in [...rows, ...simple]) r['taskId'] as String,
    };
  }

  Future<void> enqueueFinish(String taskId, String createdAtIso,
      {double? lat, double? lon}) async {
    await _db.insert(
      'finish_outbox',
      {'taskId': taskId, 'createdAt': createdAtIso, 'lat': lat, 'lon': lon},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<bool> hasFinish(String taskId) async {
    final rows = await _db
        .query('finish_outbox', where: 'taskId = ?', whereArgs: [taskId]);
    return rows.isNotEmpty;
  }

  /// The queued finish whole — see [getStartEntry].
  Future<Map<String, Object?>?> getFinishEntry(String taskId) async {
    final rows = await _db
        .query('finish_outbox', where: 'taskId = ?', whereArgs: [taskId]);
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> dequeueFinish(String taskId) async {
    await _db.delete('finish_outbox', where: 'taskId = ?', whereArgs: [taskId]);
  }

  /// Tasks marked done on the phone with the server still unaware — the list shows them
  /// as «завершена, не отправлена» until the finish goes up and the next refresh drops
  /// the row. Оба вида выполнения — см. [getStartTaskIds]; на этом же множестве стоит
  /// барьер очереди статусов, и поручение обязано его получить наравне с бланком.
  Future<Set<String>> getFinishTaskIds() async {
    final rows = await _db.query('finish_outbox', columns: ['taskId']);
    final simple = await _db.query('simple_finish_outbox', columns: ['taskId']);
    return {
      for (final r in [...rows, ...simple]) r['taskId'] as String,
    };
  }

  /// The task's own creation or start is still queued. While this is true, nothing else
  /// about the task may be sent — and a finish can only be queued, not performed.
  Future<bool> lifecyclePending(String taskId) async {
    return await getCreateEntry(taskId) != null || await hasStart(taskId);
  }

  /// То же для простого выполнения (#36872): создание задачи — общий барьер обоих
  /// видов, старт — свой.
  Future<bool> simpleLifecyclePending(String taskId) async {
    return await getCreateEntry(taskId) != null ||
        await _simple.hasSimpleStart(taskId);
  }

  /// Every task with any lifecycle step still queued — what the repository walks on
  /// reconnect, so an offline-born task drains to the server even if no screen of it
  /// is ever opened again.
  ///
  /// Ответы бланка — тоже (#36841): у СЕРВЕРНОЙ задачи, заполненной офлайн и
  /// закрытой без завершения, никакого шага жизненного цикла нет, и до этой правки
  /// её очередь полей уезжала только при следующем открытии бланка — «заполняется
  /// офлайн» держалось на том, что человек не выйдет с экрана до появления сети.
  Future<Set<String>> getLifecycleTaskIds() async {
    final create = await _db.query('task_outbox', columns: ['clientId']);
    final start = await _db.query('start_outbox', columns: ['taskId']);
    final finish = await _db.query('finish_outbox', columns: ['taskId']);
    final fields =
        await _db.query('fill_outbox', columns: ['taskId'], distinct: true);
    final cells = await _db.query('fill_cell_outbox',
        columns: ['taskId'], distinct: true);
    final rows =
        await _db.query('fill_row_outbox', columns: ['taskId'], distinct: true);
    final resolution = await _db.query('fill_resolution', columns: ['taskId']);
    final photos = await _db.query('fill_photos',
        columns: ['taskId'], where: 'uploaded = 0', distinct: true);
    final photoDeletes = await _db.query('fill_photo_deletes',
        columns: ['taskId'], distinct: true);
    return {
      for (final r in create) r['clientId'] as String,
      for (final r in start) r['taskId'] as String,
      for (final r in finish) r['taskId'] as String,
      for (final r in fields) r['taskId'] as String,
      for (final r in cells) r['taskId'] as String,
      for (final r in rows) r['taskId'] as String,
      for (final r in resolution) r['taskId'] as String,
      for (final r in photos) r['taskId'] as String,
      for (final r in photoDeletes) r['taskId'] as String,
    };
  }

  /// Записать причину последней неудачи операции. REPLACE: интересна последняя, а не
  /// история — журнал попыток человеку в поле не нужен, ему нужно «почему не ушло».
  Future<void> saveSyncError(String opKey, String message, String atIso) async {
    await _db.insert(
      'sync_errors',
      {'opKey': opKey, 'message': message, 'at': atIso},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Все записанные причины, ключ → (текст, время).
  Future<Map<String, ({String message, String at})>> getSyncErrors() async {
    final rows = await _db.query('sync_errors');
    return {
      for (final r in rows)
        r['opKey'] as String: (
          message: r['message'] as String,
          at: r['at'] as String,
        )
    };
  }

  /// Убрать причины, чьи операции уже уехали: успешный дожим не пишет «успех», он
  /// просто опустошает очередь — и причина без операции лишь пугала бы. Зовётся при
  /// каждой сборке списка операций, так что таблица не растёт бесконечно.
  Future<void> pruneSyncErrors(Set<String> liveKeys) async {
    if (liveKeys.isEmpty) {
      await _db.delete('sync_errors');
      return;
    }
    final marks = List.filled(liveKeys.length, '?').join(',');
    await _db.delete('sync_errors',
        where: 'opKey NOT IN ($marks)', whereArgs: [...liveKeys]);
  }
}
