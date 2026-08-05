import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/task.dart';
import '../models/task_status.dart';

/// One queued, not-yet-synced status change.
class OutboxEntry {
  final String taskId;
  final String statusId;
  final String? statusName;
  const OutboxEntry(this.taskId, this.statusId, this.statusName);
}

/// Local offline store: cached tasks + status dictionary + an outbox of pending
/// status changes. The outbox is the source of truth for a task's *effective*
/// status until the change is confirmed by the server.
class LocalDb {
  final Database _db;
  LocalDb(this._db);

  static Future<LocalDb> open() async {
    final dir = await getDatabasesPath();
    final path = p.join(dir, 'pulse_tasks.db');
    final db = await openDatabase(path,
        version: 6, onCreate: _onCreate, onUpgrade: _onUpgrade);
    return LocalDb(db);
  }

  static Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE tasks (
        id TEXT PRIMARY KEY,
        name TEXT, object TEXT, address TEXT,
        type TEXT, typeId TEXT,
        status TEXT, statusId TEXT,
        priority TEXT, assignedTo TEXT, assigneeId TEXT,
        deadline TEXT, progress INTEGER, subtitle TEXT
      )''');
    await db.execute('''
      CREATE TABLE statuses (
        id TEXT PRIMARY KEY, name TEXT, closed INTEGER, sortingOrder INTEGER
      )''');
    await db.execute('''
      CREATE TABLE outbox (
        taskId TEXT PRIMARY KEY,
        statusId TEXT NOT NULL,
        statusName TEXT,
        createdAt TEXT NOT NULL
      )''');
    await _createChecklistTables(db);
    await _createPhotoTable(db);
    await _createFillTables(db);
  }

  static Future<void> _onUpgrade(Database db, int oldV, int newV) async {
    if (oldV < 2) await _createChecklistTables(db);
    if (oldV < 3) await _createPhotoTable(db);
    if (oldV < 4) {
      await _createFillTables(db); // current schema (incl. v5 table-cell bits)
    } else if (oldV < 5) {
      await db.execute('ALTER TABLE fill_cache ADD COLUMN columnsJson TEXT');
      await db.execute('ALTER TABLE fill_cache ADD COLUMN rowsJson TEXT');
      await _createCellOutbox(db);
    }
    if (oldV < 6) await _migratePhotosToMulti(db);
  }

  /// v6: a field may hold several photos. sqlite cannot widen a primary key in place,
  /// so the table is rebuilt and existing rows are carried over as photo #0 — pending
  /// uploads survive the upgrade, which matters because they may be the only copy.
  static Future<void> _migratePhotosToMulti(Database db) async {
    await db.execute('''
      CREATE TABLE fill_photos_v6 (
        taskId TEXT NOT NULL, fieldCode TEXT NOT NULL, idx INTEGER NOT NULL DEFAULT 0,
        path TEXT, uploaded INTEGER NOT NULL DEFAULT 0, createdAt TEXT NOT NULL,
        PRIMARY KEY (taskId, fieldCode, idx)
      )''');
    await db.execute('''
      INSERT INTO fill_photos_v6 (taskId, fieldCode, idx, path, uploaded, createdAt)
      SELECT taskId, fieldCode, 0, path, uploaded, createdAt FROM fill_photos''');
    await db.execute('DROP TABLE fill_photos');
    await db.execute('ALTER TABLE fill_photos_v6 RENAME TO fill_photos');
  }

  static Future<void> _createChecklistTables(Database db) async {
    await db.execute('''
      CREATE TABLE checklist_cache (
        taskId TEXT PRIMARY KEY,
        itemsJson TEXT, optionsJson TEXT,
        object TEXT, checklist TEXT, threshold REAL,
        fetchedAt TEXT
      )''');
    await db.execute('''
      CREATE TABLE checklist_outbox (
        taskId TEXT NOT NULL, si INTEGER NOT NULL, ii INTEGER NOT NULL,
        numeric INTEGER, optionIndex INTEGER, value REAL, comment TEXT,
        createdAt TEXT NOT NULL,
        PRIMARY KEY (taskId, si, ii)
      )''');
  }

  static Future<void> _createPhotoTable(Database db) async {
    // path NULL = a pending "clear the photo on the server" intent.
    await db.execute('''
      CREATE TABLE checklist_photos (
        taskId TEXT NOT NULL, si INTEGER NOT NULL, ii INTEGER NOT NULL,
        path TEXT, uploaded INTEGER NOT NULL DEFAULT 0,
        createdAt TEXT NOT NULL,
        PRIMARY KEY (taskId, si, ii)
      )''');
  }

  // --- generic fillable engine (Filling) ---
  static Future<void> _createFillTables(Database db) async {
    await db.execute('''
      CREATE TABLE fill_cache (
        taskId TEXT PRIMARY KEY,
        fieldsJson TEXT, optionsJson TEXT, infoJson TEXT,
        columnsJson TEXT, rowsJson TEXT,
        fetchedAt TEXT
      )''');
    await db.execute('''
      CREATE TABLE fill_outbox (
        taskId TEXT NOT NULL, fieldCode TEXT NOT NULL, type TEXT,
        optionCode TEXT, number REAL, text TEXT, boolVal INTEGER, dateVal TEXT, comment TEXT,
        createdAt TEXT NOT NULL,
        PRIMARY KEY (taskId, fieldCode)
      )''');
    await db.execute('''
      CREATE TABLE fill_resolution (
        taskId TEXT PRIMARY KEY, resolution TEXT NOT NULL, createdAt TEXT NOT NULL
      )''');
    // idx is part of the key: a field holds several shots, and one photo of a display
    // case is rarely enough to document what is wrong with it.
    await db.execute('''
      CREATE TABLE fill_photos (
        taskId TEXT NOT NULL, fieldCode TEXT NOT NULL, idx INTEGER NOT NULL DEFAULT 0,
        path TEXT, uploaded INTEGER NOT NULL DEFAULT 0, createdAt TEXT NOT NULL,
        PRIMARY KEY (taskId, fieldCode, idx)
      )''');
    await _createCellOutbox(db);
  }

  // pending, not-yet-synced table cell edits, keyed by (task, field, row, column)
  static Future<void> _createCellOutbox(Database db) async {
    await db.execute('''
      CREATE TABLE fill_cell_outbox (
        taskId TEXT NOT NULL, fieldCode TEXT NOT NULL,
        rowIndex INTEGER NOT NULL, colCode TEXT NOT NULL,
        number REAL, text TEXT, createdAt TEXT NOT NULL,
        PRIMARY KEY (taskId, fieldCode, rowIndex, colCode)
      )''');
  }

  // --- tasks ---

  Future<void> replaceTasks(List<Task> tasks) async {
    await _db.transaction((txn) async {
      await txn.delete('tasks');
      final batch = txn.batch();
      for (final t in tasks) {
        batch.insert('tasks', t.toMap(),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
  }

  Future<List<Task>> getTasks() async {
    final rows = await _db.query('tasks');
    return rows.map(Task.fromMap).toList();
  }

  /// Update just the cached status of one task (after a confirmed sync), so the
  /// list reflects server truth without waiting for a full refresh.
  Future<void> updateTaskStatus(
      String taskId, String statusId, String? statusName) async {
    await _db.update(
      'tasks',
      {'statusId': statusId, 'status': statusName},
      where: 'id = ?',
      whereArgs: [taskId],
    );
  }

  // --- statuses ---

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

  // --- outbox ---

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
        )
    };
  }

  // --- checklist cache + answer outbox ---

  Future<void> saveChecklistCache(String taskId, String itemsJson,
      String optionsJson, String? object, String? checklist, double? threshold,
      String fetchedAtIso) async {
    await _db.insert(
      'checklist_cache',
      {
        'taskId': taskId,
        'itemsJson': itemsJson,
        'optionsJson': optionsJson,
        'object': object,
        'checklist': checklist,
        'threshold': threshold,
        'fetchedAt': fetchedAtIso,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Map<String, Object?>?> getChecklistCache(String taskId) async {
    final rows = await _db
        .query('checklist_cache', where: 'taskId = ?', whereArgs: [taskId]);
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> enqueueAnswer(String taskId, int si, int ii,
      {required bool numeric,
      int? optionIndex,
      double? value,
      String? comment,
      required String createdAtIso}) async {
    await _db.insert(
      'checklist_outbox',
      {
        'taskId': taskId,
        'si': si,
        'ii': ii,
        'numeric': numeric ? 1 : 0,
        'optionIndex': optionIndex,
        'value': value,
        'comment': comment,
        'createdAt': createdAtIso,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Map<String, Object?>>> getAnswerOutbox(String taskId) async {
    return _db.query('checklist_outbox',
        where: 'taskId = ?', whereArgs: [taskId], orderBy: 'createdAt ASC');
  }

  Future<void> dequeueAnswer(String taskId, int si, int ii) async {
    await _db.delete('checklist_outbox',
        where: 'taskId = ? AND si = ? AND ii = ?', whereArgs: [taskId, si, ii]);
  }

  // --- checklist evidence photos ---

  /// Record (or replace) a photo intent for one item. `path == null` means a
  /// pending clear (remove the photo from the server). Always resets `uploaded`.
  Future<void> savePhoto(String taskId, int si, int ii, String? path,
      String createdAtIso) async {
    await _db.insert(
      'checklist_photos',
      {
        'taskId': taskId,
        'si': si,
        'ii': ii,
        'path': path,
        'uploaded': 0,
        'createdAt': createdAtIso,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// All photo rows for a task (for overlaying local photos onto items).
  Future<List<Map<String, Object?>>> getPhotos(String taskId) async {
    return _db
        .query('checklist_photos', where: 'taskId = ?', whereArgs: [taskId]);
  }

  /// Photo rows not yet confirmed by the server (for syncing).
  Future<List<Map<String, Object?>>> getPendingPhotos(String taskId) async {
    return _db.query('checklist_photos',
        where: 'taskId = ? AND uploaded = 0',
        whereArgs: [taskId],
        orderBy: 'createdAt ASC');
  }

  Future<void> markPhotoUploaded(String taskId, int si, int ii) async {
    await _db.update('checklist_photos', {'uploaded': 1},
        where: 'taskId = ? AND si = ? AND ii = ?', whereArgs: [taskId, si, ii]);
  }

  Future<void> deletePhoto(String taskId, int si, int ii) async {
    await _db.delete('checklist_photos',
        where: 'taskId = ? AND si = ? AND ii = ?', whereArgs: [taskId, si, ii]);
  }

  // --- generic fillable engine: cache + field outbox + resolution + photos ---

  Future<void> saveFillCache(String taskId, String fieldsJson,
      String optionsJson, String infoJson, String fetchedAtIso,
      {String columnsJson = '[]', String rowsJson = '[]'}) async {
    await _db.insert(
      'fill_cache',
      {
        'taskId': taskId,
        'fieldsJson': fieldsJson,
        'optionsJson': optionsJson,
        'infoJson': infoJson,
        'columnsJson': columnsJson,
        'rowsJson': rowsJson,
        'fetchedAt': fetchedAtIso,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Map<String, Object?>?> getFillCache(String taskId) async {
    final rows =
        await _db.query('fill_cache', where: 'taskId = ?', whereArgs: [taskId]);
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> enqueueField(String taskId, String fieldCode,
      {required String type,
      String? optionCode,
      double? number,
      String? text,
      bool? boolVal,
      String? dateVal,
      String? comment,
      required String createdAtIso}) async {
    await _db.insert(
      'fill_outbox',
      {
        'taskId': taskId,
        'fieldCode': fieldCode,
        'type': type,
        'optionCode': optionCode,
        'number': number,
        'text': text,
        'boolVal': boolVal == null ? null : (boolVal ? 1 : 0),
        'dateVal': dateVal,
        'comment': comment,
        'createdAt': createdAtIso,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Map<String, Object?>>> getFieldOutbox(String taskId) async {
    return _db.query('fill_outbox',
        where: 'taskId = ?', whereArgs: [taskId], orderBy: 'createdAt ASC');
  }

  Future<void> dequeueField(String taskId, String fieldCode) async {
    await _db.delete('fill_outbox',
        where: 'taskId = ? AND fieldCode = ?', whereArgs: [taskId, fieldCode]);
  }

  Future<void> setResolutionOutbox(
      String taskId, String resolution, String createdAtIso) async {
    await _db.insert(
      'fill_resolution',
      {'taskId': taskId, 'resolution': resolution, 'createdAt': createdAtIso},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<String?> getResolutionOutbox(String taskId) async {
    final rows = await _db
        .query('fill_resolution', where: 'taskId = ?', whereArgs: [taskId]);
    return rows.isEmpty ? null : rows.first['resolution'] as String?;
  }

  Future<void> clearResolutionOutbox(String taskId) async {
    await _db
        .delete('fill_resolution', where: 'taskId = ?', whereArgs: [taskId]);
  }

  /// Next free local index for a field's photos — photos are appended, never replaced.
  Future<int> nextPhotoIndex(String taskId, String fieldCode) async {
    final r = await _db.rawQuery(
        'SELECT COALESCE(MAX(idx), -1) + 1 AS next FROM fill_photos '
        'WHERE taskId = ? AND fieldCode = ?',
        [taskId, fieldCode]);
    return (r.first['next'] as int?) ?? 0;
  }

  Future<void> saveFillPhoto(String taskId, String fieldCode, int idx,
      String? path, String createdAtIso) async {
    await _db.insert(
      'fill_photos',
      {
        'taskId': taskId,
        'fieldCode': fieldCode,
        'idx': idx,
        'path': path,
        'uploaded': 0,
        'createdAt': createdAtIso,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Map<String, Object?>>> getFillPhotos(String taskId) async {
    return _db.query('fill_photos',
        where: 'taskId = ?', whereArgs: [taskId], orderBy: 'fieldCode, idx');
  }

  Future<List<Map<String, Object?>>> getPendingFillPhotos(String taskId) async {
    return _db.query('fill_photos',
        where: 'taskId = ? AND uploaded = 0',
        whereArgs: [taskId],
        orderBy: 'createdAt ASC');
  }

  Future<void> markFillPhotoUploaded(
      String taskId, String fieldCode, int idx) async {
    await _db.update('fill_photos', {'uploaded': 1},
        where: 'taskId = ? AND fieldCode = ? AND idx = ?',
        whereArgs: [taskId, fieldCode, idx]);
  }

  Future<void> deleteFillPhoto(
      String taskId, String fieldCode, int idx) async {
    await _db.delete('fill_photos',
        where: 'taskId = ? AND fieldCode = ? AND idx = ?',
        whereArgs: [taskId, fieldCode, idx]);
  }

  // --- table cells (one queued edit per cell) ---

  Future<void> enqueueCell(
      String taskId, String fieldCode, int rowIndex, String colCode,
      {double? number, String? text, required String createdAtIso}) async {
    await _db.insert(
      'fill_cell_outbox',
      {
        'taskId': taskId,
        'fieldCode': fieldCode,
        'rowIndex': rowIndex,
        'colCode': colCode,
        'number': number,
        'text': text,
        'createdAt': createdAtIso,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Map<String, Object?>>> getCellOutbox(String taskId) async {
    return _db.query('fill_cell_outbox',
        where: 'taskId = ?', whereArgs: [taskId], orderBy: 'createdAt ASC');
  }

  Future<void> dequeueCell(
      String taskId, String fieldCode, int rowIndex, String colCode) async {
    await _db.delete('fill_cell_outbox',
        where:
            'taskId = ? AND fieldCode = ? AND rowIndex = ? AND colCode = ?',
        whereArgs: [taskId, fieldCode, rowIndex, colCode]);
  }
}
