import 'package:sqflite/sqflite.dart';

/// Бланк одной задачи: кэш полей и очереди ответов — значения, итог, снимки
/// пунктов и их удаление (#36946), ячейки и строки таблиц (#36943).
class FillDao {
  FillDao(this._db);

  final Database _db;

  Future<void> saveFillCache(String taskId, String fieldsJson,
      String optionsJson, String infoJson, String fetchedAtIso,
      {String columnsJson = '[]',
      String rowsJson = '[]',
      String subjectsJson = '{}'}) async {
    await _db.insert(
      'fill_cache',
      {
        'taskId': taskId,
        'fieldsJson': fieldsJson,
        'optionsJson': optionsJson,
        'infoJson': infoJson,
        'columnsJson': columnsJson,
        'rowsJson': rowsJson,
        'subjectsJson': subjectsJson,
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
      String? refId,
      String? refName,
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
        'refId': refId,
        'refName': refName,
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

  /// Строка отложенного итога целиком — экрану «Не отправлено» нужно и время
  /// постановки в очередь, а [getResolutionOutbox] отдаёт только сам итог.
  Future<Map<String, Object?>?> getResolutionEntry(String taskId) async {
    final rows = await _db
        .query('fill_resolution', where: 'taskId = ?', whereArgs: [taskId]);
    return rows.isEmpty ? null : rows.first;
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

  /// Снимок уехал. [serverIdx] — индекс, под которым он лёг на сервере (#36946):
  /// сервер его в ответе не называет, но назначает по правилу «максимум + 1», так что
  /// отправитель его знает; сверка с `photoIndexes` при загрузке бланка потом
  /// подтверждает или поправляет догадку.
  Future<void> markFillPhotoUploaded(String taskId, String fieldCode, int idx,
      {int? serverIdx}) async {
    await _db.update(
        'fill_photos', {'uploaded': 1, if (serverIdx != null) 'serverIdx': serverIdx},
        where: 'taskId = ? AND fieldCode = ? AND idx = ?',
        whereArgs: [taskId, fieldCode, idx]);
  }

  /// Результат сверки с сервером: этот локальный снимок лежит там под таким индексом.
  Future<void> setFillPhotoServerIdx(
      String taskId, String fieldCode, int idx, int serverIdx) async {
    await _db.update('fill_photos', {'serverIdx': serverIdx},
        where: 'taskId = ? AND fieldCode = ? AND idx = ?',
        whereArgs: [taskId, fieldCode, idx]);
  }

  Future<void> deleteFillPhoto(
      String taskId, String fieldCode, int idx) async {
    await _db.delete('fill_photos',
        where: 'taskId = ? AND fieldCode = ? AND idx = ?',
        whereArgs: [taskId, fieldCode, idx]);
  }

  /// Поставить в очередь удаление кадра по его СЕРВЕРНОМУ индексу. Повтор по тому же
  /// индексу — та же строка (ключ), а не вторая отправка.
  Future<void> enqueuePhotoDelete(String taskId, String fieldCode, int serverIdx,
      String createdAtIso) async {
    await _db.insert(
      'fill_photo_deletes',
      {
        'taskId': taskId,
        'fieldCode': fieldCode,
        'serverIdx': serverIdx,
        'createdAt': createdAtIso,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Map<String, Object?>>> getPhotoDeletes(String taskId) async {
    return _db.query('fill_photo_deletes',
        where: 'taskId = ?', whereArgs: [taskId], orderBy: 'createdAt ASC');
  }

  Future<void> dequeuePhotoDelete(
      String taskId, String fieldCode, int serverIdx) async {
    await _db.delete('fill_photo_deletes',
        where: 'taskId = ? AND fieldCode = ? AND serverIdx = ?',
        whereArgs: [taskId, fieldCode, serverIdx]);
  }

  /// Снять очередь удалений целого пункта — «Удалить все» отменяет поштучные
  /// удаления: пустое фото в apiSetFieldPhoto стирает набор целиком, и отправлять
  /// после него удаления по индексам не по чему.
  Future<void> clearPhotoDeletes(String taskId, String fieldCode) async {
    await _db.delete('fill_photo_deletes',
        where: 'taskId = ? AND fieldCode = ?', whereArgs: [taskId, fieldCode]);
  }

  Future<void> enqueueCell(
      String taskId, String fieldCode, String rowKey, String colCode,
      {double? number, String? text, required String createdAtIso}) async {
    await _db.insert(
      'fill_cell_outbox',
      {
        'taskId': taskId,
        'fieldCode': fieldCode,
        'rowKey': rowKey,
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
      String taskId, String fieldCode, String rowKey, String colCode) async {
    await _db.delete('fill_cell_outbox',
        where: 'taskId = ? AND fieldCode = ? AND rowKey = ? AND colCode = ?',
        whereArgs: [taskId, fieldCode, rowKey, colCode]);
  }

  /// Поставить в очередь создание строки. Ключ выдаёт телефон, поэтому повторная
  /// постановка того же ключа — это та же строка, а не вторая.
  Future<void> enqueueAddRow(String taskId, String fieldCode, String rowKey,
      {String? subjectId,
      String? subjectName,
      required String createdAtIso}) async {
    await _db.insert(
      'fill_row_outbox',
      {
        'taskId': taskId,
        'fieldCode': fieldCode,
        'rowKey': rowKey,
        'op': 'add',
        'subjectId': subjectId,
        'subjectName': subjectName,
        'createdAt': createdAtIso,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Поставить в очередь удаление строки — и снять с неё всё, что ещё не уехало.
  ///
  /// Строка, рождённая на этом телефоне и удалённая до отправки, не попадает на
  /// сервер вовсе: её `add` уходит из очереди вместе с правками ячеек, и слать нечего
  /// (`ждёт отправки: 0`, а не «создать и тут же удалить»). У серверной строки
  /// правки ячеек тоже снимаются — они адресуют строку, которой сейчас не станет.
  Future<void> enqueueDeleteRow(String taskId, String fieldCode, String rowKey,
      {required String createdAtIso}) async {
    await _db.transaction((txn) async {
      final pendingAdd = await txn.query('fill_row_outbox',
          where: 'taskId = ? AND fieldCode = ? AND rowKey = ? AND op = ?',
          whereArgs: [taskId, fieldCode, rowKey, 'add']);
      await txn.delete('fill_cell_outbox',
          where: 'taskId = ? AND fieldCode = ? AND rowKey = ?',
          whereArgs: [taskId, fieldCode, rowKey]);
      if (pendingAdd.isNotEmpty) {
        await txn.delete('fill_row_outbox',
            where: 'taskId = ? AND fieldCode = ? AND rowKey = ?',
            whereArgs: [taskId, fieldCode, rowKey]);
        return;
      }
      await txn.insert(
        'fill_row_outbox',
        {
          'taskId': taskId,
          'fieldCode': fieldCode,
          'rowKey': rowKey,
          'op': 'delete',
          'createdAt': createdAtIso,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  /// Операции строк по порядку постановки: строка создаётся раньше, чем правятся её
  /// ячейки, а порядок в очереди и есть этот порядок.
  Future<List<Map<String, Object?>>> getRowOutbox(String taskId) async {
    return _db.query('fill_row_outbox',
        where: 'taskId = ?', whereArgs: [taskId], orderBy: 'createdAt ASC');
  }

  Future<void> dequeueRow(
      String taskId, String fieldCode, String rowKey) async {
    await _db.delete('fill_row_outbox',
        where: 'taskId = ? AND fieldCode = ? AND rowKey = ?',
        whereArgs: [taskId, fieldCode, rowKey]);
  }
}
