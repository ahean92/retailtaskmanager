import 'dart:convert';

/// Файл, приложенный к задаче, — как его отдаёт сервер: id (им же файл скачивается
/// через `apiTaskFile`), имя и признак «картинка», по которому рисуется миниатюра, а не
/// значок файла.
///
/// Одна модель на два места, потому что на сервере это один класс `TaskFile`: вложение
/// сообщения ленты (#36844, `apiTaskComments.files`) и снимок проблемы, приложенный к
/// самой задаче (#36842, `apiTasks.files`). Право на скачивание — одно и то же
/// `canDownload`, ручка — одна и та же. [dateTime] и [author] приходят только со вторыми:
/// в ленте их несёт само сообщение.
class TaskFileRef {
  final String id;
  final String? name;
  final bool image;
  final String? dateTime;
  final String? author;

  const TaskFileRef({
    required this.id,
    this.name,
    this.image = false,
    this.dateTime,
    this.author,
  });

  factory TaskFileRef.fromJson(Map<String, dynamic> j) => TaskFileRef(
        id: '${j['id']}',
        name: j['name']?.toString(),
        image: flag(j['image']),
        dateTime: j['dateTime']?.toString(),
        author: j['author']?.toString(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        if (name != null) 'name': name,
        if (image) 'image': true,
        if (dateTime != null) 'dateTime': dateTime,
        if (author != null) 'author': author,
      };

  /// lsFusion не экспортирует NULL: флаг либо true, либо ключа нет вовсе.
  static bool flag(Object? v) =>
      v == true || v == 1 || (v is String && v.toLowerCase() == 'true');

  /// Список файлов из JSON-массива или из строки кэша sqlite — обе формы встречаются
  /// на одном и том же пути «сервер → база → экран».
  static List<TaskFileRef> listFrom(Object? v) {
    final raw = _decode(v);
    if (raw is! List) return const [];
    return [
      for (final e in raw)
        if (e is Map) TaskFileRef.fromJson(e.cast<String, dynamic>()),
    ];
  }
}

/// Выполнение задачи (#36842): одна попытка сделать работу — кто, когда, с каким
/// результатом и со снимком «стало», если он есть.
///
/// Выполнений на задаче может быть несколько (так устроен `Execution` с самого начала),
/// и до этой задачи в приложении их не было видно вовсе. [photoId] — файл задачи,
/// зеркалированный из фото выполнения: качается той же ручкой `apiTaskFile`, что и
/// снимок проблемы.
class TaskExecution {
  final String id;
  final String? dateTime;
  final String? executor;
  final bool finished;
  final String? result;
  final String? photoId;

  const TaskExecution({
    required this.id,
    this.dateTime,
    this.executor,
    this.finished = false,
    this.result,
    this.photoId,
  });

  factory TaskExecution.fromJson(Map<String, dynamic> j) => TaskExecution(
        id: '${j['id']}',
        dateTime: j['dateTime']?.toString(),
        executor: j['executor']?.toString(),
        finished: TaskFileRef.flag(j['finished']),
        result: j['result']?.toString(),
        photoId: j['photoId'] == null ? null : '${j['photoId']}',
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        if (dateTime != null) 'dateTime': dateTime,
        if (executor != null) 'executor': executor,
        if (finished) 'finished': true,
        if (result != null) 'result': result,
        if (photoId != null) 'photoId': photoId,
      };

  DateTime? get when => dateTime == null ? null : DateTime.tryParse(dateTime!);

  static List<TaskExecution> listFrom(Object? v) {
    final raw = _decode(v);
    if (raw is! List) return const [];
    return [
      for (final e in raw)
        if (e is Map) TaskExecution.fromJson(e.cast<String, dynamic>()),
    ];
  }
}

Object? _decode(Object? v) {
  if (v is! String) return v;
  if (v.isEmpty) return null;
  try {
    return jsonDecode(v);
  } catch (_) {
    return null;
  }
}
