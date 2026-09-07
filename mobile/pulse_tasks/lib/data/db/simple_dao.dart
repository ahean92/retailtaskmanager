import 'package:sqflite/sqflite.dart';

/// Простое выполнение — фотоотчёт с комментарием (#36872): кэш состояния,
/// снимки, комментарий, старт и завершение своими очередями.
class SimpleDao {
  SimpleDao(this._db);

  final Database _db;

  /// Ответ apiSimpleInfo как есть — экран рисуется по нему и без сети.
  Future<void> saveSimpleInfo(String taskId, String infoJson) async {
    await _db.insert(
      'simple_cache',
      {
        'taskId': taskId,
        'infoJson': infoJson,
        'fetchedAt': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Map<String, Object?>?> getSimpleCache(String taskId) async {
    final rows = await _db
        .query('simple_cache', where: 'taskId = ?', whereArgs: [taskId]);
    return rows.isEmpty ? null : rows.first;
  }

  Future<int> nextSimplePhotoIndex(String taskId) async {
    final r = await _db.rawQuery(
        'SELECT COALESCE(MAX(idx), -1) + 1 AS next FROM simple_photos '
        'WHERE taskId = ?',
        [taskId]);
    return (r.first['next'] as int?) ?? 0;
  }

  Future<void> saveSimplePhoto(
      String taskId, int idx, String? path, String createdAtIso) async {
    await _db.insert(
      'simple_photos',
      {
        'taskId': taskId,
        'idx': idx,
        'path': path,
        'uploaded': 0,
        'createdAt': createdAtIso,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Map<String, Object?>>> getSimplePhotos(String taskId) async {
    return _db.query('simple_photos',
        where: 'taskId = ?', whereArgs: [taskId], orderBy: 'idx');
  }

  Future<List<Map<String, Object?>>> getPendingSimplePhotos(
      String taskId) async {
    return _db.query('simple_photos',
        where: 'taskId = ? AND uploaded = 0',
        whereArgs: [taskId],
        orderBy: 'createdAt ASC');
  }

  Future<void> markSimplePhotoUploaded(String taskId, int idx) async {
    await _db.update('simple_photos', {'uploaded': 1},
        where: 'taskId = ? AND idx = ?', whereArgs: [taskId, idx]);
  }

  Future<void> deleteSimplePhoto(String taskId, int idx) async {
    await _db.delete('simple_photos',
        where: 'taskId = ? AND idx = ?', whereArgs: [taskId, idx]);
  }

  /// Комментарий, ещё не ушедший на сервер. Одна строка на задачу: правка затирает
  /// предыдущую — отправлять черновики промежуточных редакций некому и незачем.
  Future<void> enqueueSimpleComment(
      String taskId, String? text, String createdAtIso) async {
    await _db.insert(
      'simple_comment_outbox',
      {'taskId': taskId, 'text': text, 'createdAt': createdAtIso},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Map<String, Object?>?> getSimpleComment(String taskId) async {
    final rows = await _db.query('simple_comment_outbox',
        where: 'taskId = ?', whereArgs: [taskId]);
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> dequeueSimpleComment(String taskId) async {
    await _db.delete('simple_comment_outbox',
        where: 'taskId = ?', whereArgs: [taskId]);
  }

  Future<void> enqueueSimpleStart(String taskId, String createdAtIso,
      {double? lat, double? lon}) async {
    await _db.insert(
      'simple_start_outbox',
      {'taskId': taskId, 'createdAt': createdAtIso, 'lat': lat, 'lon': lon},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<bool> hasSimpleStart(String taskId) async {
    final rows = await _db.query('simple_start_outbox',
        where: 'taskId = ?', whereArgs: [taskId]);
    return rows.isNotEmpty;
  }

  Future<Map<String, Object?>?> getSimpleStartEntry(String taskId) async {
    final rows = await _db.query('simple_start_outbox',
        where: 'taskId = ?', whereArgs: [taskId]);
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> dequeueSimpleStart(String taskId) async {
    await _db.delete('simple_start_outbox',
        where: 'taskId = ?', whereArgs: [taskId]);
  }

  Future<void> enqueueSimpleFinish(String taskId, String createdAtIso,
      {double? lat, double? lon}) async {
    await _db.insert(
      'simple_finish_outbox',
      {'taskId': taskId, 'createdAt': createdAtIso, 'lat': lat, 'lon': lon},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<bool> hasSimpleFinish(String taskId) async {
    final rows = await _db.query('simple_finish_outbox',
        where: 'taskId = ?', whereArgs: [taskId]);
    return rows.isNotEmpty;
  }

  Future<Map<String, Object?>?> getSimpleFinishEntry(String taskId) async {
    final rows = await _db.query('simple_finish_outbox',
        where: 'taskId = ?', whereArgs: [taskId]);
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> dequeueSimpleFinish(String taskId) async {
    await _db.delete('simple_finish_outbox',
        where: 'taskId = ?', whereArgs: [taskId]);
  }

  /// Задачи, по которым осталось что-то отправить простым выполнением — их обходит
  /// дренаж при возврате связи, чтобы отчёт уехал и без открытого экрана.
  Future<Set<String>> getSimpleQueueTaskIds() async {
    final ids = <String>{};
    for (final table in const [
      'simple_start_outbox',
      'simple_finish_outbox',
      'simple_comment_outbox',
    ]) {
      for (final r in await _db.query(table, columns: ['taskId'])) {
        ids.add(r['taskId'] as String);
      }
    }
    for (final r in await _db.query('simple_photos',
        columns: ['taskId'], where: 'uploaded = 0')) {
      ids.add(r['taskId'] as String);
    }
    return ids;
  }
}
