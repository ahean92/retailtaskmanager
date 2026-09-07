import 'package:sqflite/sqflite.dart';

import '../../models/comment.dart';

/// Сводка кэша ленты одной задачи (#36844): сколько сообщений в кэше и сколько чужих
/// новее местной отметки «прочитано до». Из неё список собирает бейдж, не дёргая
/// сервер и не читая саму ленту.
class CommentStats {
  final int total;
  final int unread;
  const CommentStats(this.total, this.unread);
}

/// Переписка по задаче (#36844): кэш серверной ленты, очередь своих сообщений
/// с ключом идемпотентности и отметки «прочитано до».
class CommentsDao {
  CommentsDao(this._db);

  final Database _db;

  /// Заменить кэш ленты задачи ответом сервера. Строки очереди, чей clientId сервер
  /// уже вернул, закрываются тут же: ответ на POST мог потеряться по дороге, а само
  /// сообщение — доехать; без этого оно висело бы «не отправленным» и уехало бы ещё
  /// раз (сервер ответил бы повтором, но пузырь в ленте раздвоился бы до refresh).
  /// Возвращает пути локальных фото закрытых строк — файлы удаляет вызывающий, вне
  /// транзакции.
  Future<List<String>> replaceComments(
      String taskId, List<TaskComment> comments) async {
    final orphanPhotos = <String>[];
    await _db.transaction((txn) async {
      await txn
          .delete('comment_cache', where: 'taskId = ?', whereArgs: [taskId]);
      final batch = txn.batch();
      for (final c in comments) {
        batch.insert('comment_cache', c.toMap(taskId),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
      final known = {
        for (final c in comments)
          if (c.clientId != null) c.clientId!
      };
      if (known.isEmpty) return;
      final rows = await txn
          .query('comment_outbox', where: 'taskId = ?', whereArgs: [taskId]);
      for (final r in rows) {
        final cid = r['clientId'] as String;
        if (!known.contains(cid)) continue;
        final photo = r['photoPath'] as String?;
        if (photo != null) orphanPhotos.add(photo);
        await txn
            .delete('comment_outbox', where: 'clientId = ?', whereArgs: [cid]);
      }
    });
    return orphanPhotos;
  }

  Future<List<TaskComment>> getComments(String taskId) async {
    final rows = await _db.query('comment_cache',
        where: 'taskId = ?',
        whereArgs: [taskId],
        orderBy: 'dateTime ASC, id ASC');
    return rows.map(TaskComment.fromMap).toList();
  }

  Future<void> enqueueComment(String clientId, String taskId,
      {String? text, String? photoPath, required String createdAtIso}) async {
    await _db.insert(
      'comment_outbox',
      {
        'clientId': clientId,
        'taskId': taskId,
        'text': text,
        'photoPath': photoPath,
        'createdAt': createdAtIso,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Map<String, Object?>>> getCommentOutbox(String taskId) {
    return _db.query('comment_outbox',
        where: 'taskId = ?', whereArgs: [taskId], orderBy: 'createdAt ASC');
  }

  /// Вся очередь сообщений — для дренажа при синхронизации и счётчиков.
  Future<List<Map<String, Object?>>> getAllCommentOutbox() {
    return _db.query('comment_outbox', orderBy: 'createdAt ASC');
  }

  Future<void> dequeueComment(String clientId) async {
    await _db
        .delete('comment_outbox', where: 'clientId = ?', whereArgs: [clientId]);
  }

  /// Прочитано до [upTo] (серверное время последнего показанного сообщения) —
  /// монотонно: отметка, приехавшая из прошлого (переоткрыли старый кэш), назад
  /// ничего не откатывает. Новая отметка всегда ждёт отправки.
  Future<void> markCommentsRead(String taskId, String upTo) async {
    final rows = await _db
        .query('comment_read', where: 'taskId = ?', whereArgs: [taskId]);
    if (rows.isNotEmpty &&
        (rows.first['upTo'] as String).compareTo(upTo) >= 0) {
      return;
    }
    await _db.insert(
      'comment_read',
      {'taskId': taskId, 'upTo': upTo, 'pending': 1},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Отметка ушла на сервер — но только эта: если за время полёта легла более
  /// свежая, ей ещё ехать.
  Future<void> markCommentReadSent(String taskId, String upTo) async {
    await _db.update('comment_read', {'pending': 0},
        where: 'taskId = ? AND upTo = ?', whereArgs: [taskId, upTo]);
  }

  Future<List<Map<String, Object?>>> getPendingCommentReads() {
    return _db.query('comment_read', where: 'pending = 1');
  }

  /// Сводка кэша по задачам — см. [CommentStats]. Сравнение времён — разбором, а не
  /// строкой: формат серверного DATETIME не обязан совпадать с местным ISO.
  Future<Map<String, CommentStats>> commentStats() async {
    final marks = {
      for (final r in await _db.query('comment_read'))
        r['taskId'] as String: DateTime.tryParse(r['upTo'] as String)
    };
    final rows = await _db.query('comment_cache',
        columns: ['taskId', 'mine', 'dateTime']);
    final total = <String, int>{};
    final unread = <String, int>{};
    for (final r in rows) {
      final id = r['taskId'] as String;
      total[id] = (total[id] ?? 0) + 1;
      if (r['mine'] == 1) continue;
      final at = DateTime.tryParse((r['dateTime'] as String?) ?? '');
      final mark = marks[id];
      if (mark != null && at != null && !at.isAfter(mark)) continue;
      unread[id] = (unread[id] ?? 0) + 1;
    }
    return {
      for (final e in total.entries)
        e.key: CommentStats(e.value, unread[e.key] ?? 0)
    };
  }
}
