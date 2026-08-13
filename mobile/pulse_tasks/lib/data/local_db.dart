import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
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
///
/// One file per user rather than one file per device with a `userKey` column in every
/// table: nine tables and every query in them would have to remember the filter, and a
/// single forgotten `WHERE` gives the next person on the phone somebody else's tasks.
/// A file the other user's queries cannot even name isolates by construction, and the
/// schema stays exactly as it was — the version and [_onUpgrade] are shared by all files.
class LocalDb {
  final Database _db;

  /// Whose base this is — see [keyFor]. Evidence photos are filed under the same key, so
  /// `FillController` takes it from here instead of deriving the identity a second time.
  final String userKey;

  LocalDb(this._db, this.userKey);

  static Future<LocalDb> open(String userKey) async {
    final dir = await getDatabasesPath();
    final path = _pathFor(dir, userKey);
    await _adoptLegacyDatabase(dir, path);
    final db = await openDatabase(path,
        version: 8, onCreate: _onCreate, onUpgrade: _onUpgrade);
    return LocalDb(db, userKey);
  }

  static String _pathFor(String dir, String userKey) =>
      p.join(dir, 'pulse_tasks_$userKey.db');

  /// Closed when the person signs out — the base carries their name, and it must not stay
  /// open across a change of user.
  Future<void> close() => _db.close();

  /// Erase one person's base — «выйти и удалить данные», the half of it that lives in
  /// sqlite. Only the file named after that one identity is removed, so a phone shared by
  /// a shift keeps everybody else's tasks, queues and photos exactly where they were.
  ///
  /// The base has to be closed first: an open handle would be deleted out from under
  /// whatever still holds it. [deleteDatabase] takes the journal/WAL siblings with it.
  static Future<void> deleteFor(String userKey) async {
    await deleteDatabase(_pathFor(await getDatabasesPath(), userKey));
  }

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
           + (SELECT COUNT(*) FROM fill_resolution)
           + (SELECT COUNT(*) FROM fill_photos WHERE uploaded = 0) AS pending''');
    return (r.first['pending'] as int?) ?? 0;
  }

  /// Which file a person gets: the server address and the login together. The address is
  /// half of it on purpose — one and the same person on the test server and on the live one
  /// is looking at two different sets of tasks, and a single cache holding both would be
  /// wrong in whichever of them it was opened.
  ///
  /// The login is folded to lower case exactly as the platform treats it (see
  /// `Session.matches`), and the address loses its trailing slashes the same way
  /// `ApiClient` does, so `http://srv:9080/` and `http://srv:9080` are one installation
  /// rather than two bases.
  static String keyFor(String baseUrl, String login) {
    final server = baseUrl.trim().toLowerCase().replaceAll(RegExp(r'/+$'), '');
    final user = login.trim().toLowerCase();
    // The length of the address goes into the digest ahead of the two halves, so that no
    // pair can be re-cut into another one: without it an address and a login could be
    // glued into the same string as a shorter address and a longer login, and two people
    // would share a file. Half a sha256 is plenty for a file name, and it gives away
    // neither the address nor the login to whoever reads the directory listing.
    return sha256
        .convert(utf8.encode('${server.length}:$server$user'))
        .toString()
        .substring(0, 16);
  }

  /// The one base older builds kept for the whole device. It cannot simply be dropped: it
  /// may hold changes that never reached the server, and for a photo taken offline it is
  /// the only copy there is. Everything in it was made by the single person this device
  /// had, so the first sign-in after the update takes it over — the file is renamed into
  /// that person's name, once, and no legacy file is left for anybody else to adopt.
  static Future<void> _adoptLegacyDatabase(String dir, String path) async {
    final legacy = p.join(dir, 'pulse_tasks.db');
    if (!await databaseExists(legacy) || await databaseExists(path)) return;
    // the journal/WAL siblings travel with it — the last committed transaction may still
    // be sitting in them rather than in the .db file
    for (final suffix in const ['', '-journal', '-wal', '-shm']) {
      final f = File('$legacy$suffix');
      if (await f.exists()) await f.rename('$path$suffix');
    }
  }

  static Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE tasks (
        id TEXT PRIMARY KEY,
        name TEXT, object TEXT, objectId TEXT, address TEXT,
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
    await _createHomeTable(db);
    await _createPlaceTable(db);
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
    if (oldV < 7) await _createHomeTable(db);
    if (oldV < 8) {
      // the cached tasks stay: their objectId arrives with the next refresh, and until
      // then they belong to nobody's object — which is exactly what a NULL column says
      await db.execute('ALTER TABLE tasks ADD COLUMN objectId TEXT');
      await _createPlaceTable(db);
    }
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

  /// v7: the home screen the server drew for *this* person — their blocks, their numbers.
  /// It used to sit in shared_preferences, one per device, so the next person to sign in
  /// saw the previous one's dashboard until the server answered (and offline, for good).
  /// One row: a user has one home page.
  static Future<void> _createHomeTable(Database db) async {
    await db.execute('''
      CREATE TABLE home_cache (
        id INTEGER PRIMARY KEY, json TEXT NOT NULL, fetchedAt TEXT NOT NULL
      )''');
  }

  /// v8: where this person is standing — the object they picked, the neighbours with
  /// their distances, and when it was all measured. In the user's own base rather than in
  /// the device's settings: the object belongs to whoever is on shift, and the next person
  /// to sign in on this phone stands where they themselves stand. One row: a person is in
  /// one place.
  static Future<void> _createPlaceTable(Database db) async {
    await db.execute('''
      CREATE TABLE place_cache (
        id INTEGER PRIMARY KEY, json TEXT NOT NULL, locatedAt TEXT NOT NULL
      )''');
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

  // --- home screen ---

  Future<void> saveHome(String json, String fetchedAtIso) async {
    await _db.insert(
      'home_cache',
      {'id': 1, 'json': json, 'fetchedAt': fetchedAtIso},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<String?> getHome() async {
    final rows = await _db.query('home_cache', where: 'id = 1');
    return rows.isEmpty ? null : rows.first['json'] as String?;
  }

  // --- where this person is standing ---

  Future<void> savePlace(String json, String locatedAtIso) async {
    await _db.insert(
      'place_cache',
      {'id': 1, 'json': json, 'locatedAt': locatedAtIso},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<String?> getPlace() async {
    final rows = await _db.query('place_cache', where: 'id = 1');
    return rows.isEmpty ? null : rows.first['json'] as String?;
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

  /// Refresh only the cached `apiExecutionInfo` answer — the score moves after
  /// every synced edit, while fields and options change only on reload. A task
  /// with no cache row yet keeps none: half a cache is worse than no cache.
  Future<void> saveFillInfo(String taskId, String infoJson) async {
    await _db.update('fill_cache', {'infoJson': infoJson},
        where: 'taskId = ?', whereArgs: [taskId]);
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
