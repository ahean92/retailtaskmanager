import 'dart:convert';

import 'json.dart';
import 'task_file.dart';

/// Сообщение ленты задачи (#36844). С сервера (`apiTaskComments`) — с серверным id и
/// серверным временем; из очереди телефона — с ключом `local:<clientId>`, временем
/// постановки в очередь и [pending]: такое ещё не доехало и в ленте помечено.
/// [clientId] у серверного сообщения есть, только если оно рождено телефоном, — по нему
/// локальная строка очереди схлопывается с серверной, когда ответ на POST потерялся.
class TaskComment {
  final String id;
  final String? clientId;
  final String? author;
  final bool mine;
  final String? dateTime; // серверное время, как экспортирует lsFusion
  final String? text;
  final List<TaskFileRef> files;
  final bool pending;

  /// Локальный снимок ещё не отправленного сообщения — показывается из файла, пока
  /// сервер не отдал его миниатюрой.
  final String? photoPath;

  /// Отказ сервера при последней попытке отправить это сообщение (не обрыв сети) —
  /// подпись под пузырём: без неё застрявшее «не отправлено» объяснить нечем.
  final String? sendError;

  const TaskComment({
    required this.id,
    this.clientId,
    this.author,
    this.mine = false,
    this.dateTime,
    this.text,
    this.files = const [],
    this.pending = false,
    this.photoPath,
    this.sendError,
  });

  factory TaskComment.fromJson(Map<String, dynamic> j) => TaskComment(
        id: '${j['id']}',
        clientId: jsonText(j['clientId']),
        author: jsonText(j['author']),
        mine: _flag(j['mine']),
        dateTime: jsonText(j['dateTime']),
        text: jsonText(j['text']),
        files: TaskFileRef.listFrom(j['files']),
      );

  /// Строка кэша `comment_cache`.
  Map<String, Object?> toMap(String taskId) => {
        'taskId': taskId,
        'id': id,
        'clientId': clientId,
        'author': author,
        'mine': mine ? 1 : 0,
        'dateTime': dateTime,
        'text': text,
        'filesJson': jsonEncode([for (final f in files) f.toJson()]),
      };

  factory TaskComment.fromMap(Map<String, Object?> m) => TaskComment(
        id: m['id'] as String,
        clientId: m['clientId'] as String?,
        author: m['author'] as String?,
        mine: m['mine'] == 1,
        dateTime: m['dateTime'] as String?,
        text: m['text'] as String?,
        files: TaskFileRef.listFrom(m['filesJson']),
      );

  /// Строка очереди `comment_outbox` — сообщение, которого сервер ещё не видел.
  factory TaskComment.pendingFrom(Map<String, Object?> row,
          {String? sendError}) =>
      TaskComment(
        id: 'local:${row['clientId']}',
        clientId: row['clientId'] as String?,
        mine: true,
        dateTime: row['createdAt'] as String?,
        text: row['text'] as String?,
        pending: true,
        photoPath: row['photoPath'] as String?,
        sendError: sendError,
      );

  DateTime? get when => dateTime == null ? null : DateTime.tryParse(dateTime!);

  bool get hasPhoto => photoPath != null || files.any((f) => f.image);

  // lsFusion не экспортирует NULL: флаг либо true, либо ключа нет вовсе
  static bool _flag(Object? v) => jsonFlag(v);
}
