import 'dart:convert';

/// Вложение к сообщению ленты, как его отдаёт `apiTaskComments`: id файла (им же файл
/// скачивается через `apiTaskFile`), имя и признак «картинка» — по нему рисуется
/// миниатюра, а не значок файла.
class CommentFile {
  final String id;
  final String? name;
  final bool image;

  const CommentFile({required this.id, this.name, this.image = false});

  factory CommentFile.fromJson(Map<String, dynamic> j) => CommentFile(
        id: '${j['id']}',
        name: j['name']?.toString(),
        image: TaskComment._flag(j['image']),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        if (name != null) 'name': name,
        if (image) 'image': true,
      };
}

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
  final List<CommentFile> files;
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
        clientId: _str(j['clientId']),
        author: _str(j['author']),
        mine: _flag(j['mine']),
        dateTime: _str(j['dateTime']),
        text: _str(j['text']),
        files: _files(j['files']),
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
        files: _files(m['filesJson']),
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

  static List<CommentFile> _files(Object? v) {
    Object? raw = v;
    if (raw is String) {
      if (raw.isEmpty) return const [];
      try {
        raw = jsonDecode(raw);
      } catch (_) {
        return const [];
      }
    }
    if (raw is! List) return const [];
    return [
      for (final e in raw)
        if (e is Map) CommentFile.fromJson(e.cast<String, dynamic>()),
    ];
  }

  static String? _str(Object? v) => v == null ? null : '$v';

  // lsFusion не экспортирует NULL: флаг либо true, либо ключа нет вовсе
  static bool _flag(Object? v) =>
      v == true || v == 1 || (v is String && v.toLowerCase() == 'true');
}
