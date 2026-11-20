import 'dart:async';
import 'dart:io';

import '../models/comment.dart';
import 'api_client.dart';
import 'conversation_controller.dart';
import 'execution_finish.dart';
import 'local_db.dart';
import 'sync/outbox_drain.dart';
import 'task_file_cache.dart';
import 'unsent.dart';

/// Лента комментариев одной задачи (#36844): кэш-первым, очередь отправки с ретраем
/// и ключом идемпотентности, отметка прочтения, миниатюры вложений с дисковым кэшем.
///
/// Тот же рисунок, что у бланка (FillController): сообщение пишут там же, где
/// заполняют бланк, — часто без связи. Очередь, отправка и подписи отказов — общие с
/// чатом, в [ConversationController]; здесь адрес (задача), лента и отметка прочтения.
class TaskCommentsController extends ConversationController {
  final String taskId;

  TaskCommentsController(
      {required super.db, required super.api, required this.taskId});

  List<TaskComment> items = const [];

  /// Отправка очереди и вердикт о сети — общая политика, см. [OutboxDrain]; причины
  /// ложатся под `comment:задача`.
  @override
  late final OutboxDrain drain =
      OutboxDrain(() => db, kind: UnsentKind.comment, taskId: taskId);

  @override
  String get syncKey => '${UnsentKind.comment}:$taskId';

  @override
  String get unsentTask => taskId;

  @override
  int get pendingCount => items.where((c) => c.pending).length;

  Future<void> load() async {
    loading = true;
    notifyListeners();
    try {
      await loadLocal();
    } catch (_) {
      // база закрылась, пока лента поднималась (выход из аккаунта, смена сервера):
      // показывать нечего и некому — экран уходит вместе с сессией
      loading = false;
      return;
    }
    final failure = await drain.attempt(() async {
      // своё — первым, чтобы ответ сервера ниже уже содержал его, а не догонял
      await syncAll();
      await _refresh();
      error = null;
    });
    if (failure != null && items.isEmpty) {
      // отказ сервера — его словами (сеть жива); обрыв связи — про кэш, которого нет
      error = loadFailureText(failure,
          offline: 'Нет связи — переписка ещё не загружалась');
    }
    loading = false;
    notifyListeners();
  }

  /// Кэш серверной ленты плюс своя очередь: неотправленные — в конце, они новее
  /// всего, что сервер успел вернуть, каким бы ни было расхождение часов.
  @override
  Future<void> loadLocal() async {
    final cached = await db.comments.getComments(taskId);
    final queued = await db.comments.getCommentOutbox(taskId);
    final list = [
      ...cached,
      for (final r in queued)
        TaskComment.pendingFrom(r,
            sendError: sendErrors[r['clientId'] as String]),
    ];
    list.sort(_order);
    items = list;
  }

  static int _order(TaskComment a, TaskComment b) {
    if (a.pending != b.pending) return a.pending ? 1 : -1;
    final x = a.when, y = b.when;
    if (x == null) return y == null ? 0 : 1;
    if (y == null) return -1;
    return x.compareTo(y);
  }

  Future<void> _refresh() async {
    final fetched = await api.fetchTaskComments(taskId);
    final orphans = await db.comments.replaceComments(taskId, fetched);
    await _deleteFiles(orphans);
    await loadLocal();
  }

  /// Написать — см. [ConversationController.enqueueAndSend].
  Future<void> send(String text, {String? photoPath}) =>
      enqueueAndSend(
          text,
          photoPath,
          (clientId, text, photoPath) => db.comments.enqueueComment(
              clientId, taskId,
              text: text,
              photoPath: photoPath,
              createdAtIso: DateTime.now().toIso8601String()));

  // --- что общей основе нужно от ленты ---

  @override
  Future<Directory> outgoingDirectory() => photoDirectory(db.userKey);

  @override
  Future<List<Map<String, Object?>>> outbox() =>
      db.comments.getCommentOutbox(taskId);

  @override
  Future<void> dequeue(String clientId) => db.comments.dequeueComment(clientId);

  @override
  Future<void> deleteFiles(List<String> paths) => _deleteFiles(paths);

  @override
  Map<String, dynamic> bodyHead(Map<String, Object?> row) => {'id': taskId};

  @override
  Future<void> post(Map<String, dynamic> body) => api.addTaskComment(body);

  /// Ушло — перечитать ленту: у сообщения теперь серверное время и id.
  @override
  Future<void> refreshAfterSend() => _refresh();

  // --- прочитано ---

  /// Лента показана — прочитано до последнего СЕРВЕРНОГО сообщения на экране. Его
  /// время — серверное, поэтому отметка не зависит от часов устройства; без единого
  /// серверного сообщения отмечать нечего (свои неотправленные непрочитанными не
  /// бывают). Пишется локально (бейдж гаснет в этом же кадре) и уходит на сервер —
  /// сейчас или дренажем, когда появится сеть.
  Future<void> markRead() async {
    String? upTo;
    for (final c in items) {
      if (!c.pending && c.dateTime != null) upTo = c.dateTime;
    }
    if (upTo == null) return;
    await db.comments.markCommentsRead(taskId, wireTime(upTo));
    await sendReadMarks();
  }

  /// Серверное время в провод так же, как #36838: `yyyy-MM-ddTHH:mm:ss`.
  static String wireTime(String serverDateTime) =>
      wireAt(serverDateTime.replaceFirst(' ', 'T'));

  @override
  Future<void> sendReadMarks() async {
    final mine = [
      for (final r in await db.comments.getPendingCommentReads())
        if (r['taskId'] == taskId) r
    ];
    await drain.each(mine, (r) async {
      final upTo = r['upTo'] as String;
      try {
        await api.markTaskCommentsRead(taskId, upTo);
      } on ApiException catch (e) {
        // доступа к задаче больше нет (403) или её нет (404) — отметке висеть в
        // очереди вечно незачем; прочий отказ (5xx) временный: ждёт следующего прохода
        if (e.status != 403 && e.status != 404) rethrow;
      }
      await db.comments.markCommentReadSent(taskId, upTo);
    });
  }

  // --- вложения: дисковый кэш + ленивое скачивание ---

  /// Кэш вложений — общий с карточкой задачи (#36842): на сервере это один класс
  /// TaskFile, одна ручка и одно право, а на устройстве — один каталог, который
  /// стирается целиком при выходе.
  late final TaskFileCache _files =
      TaskFileCache(userKey: db.userKey, api: api);

  /// Файл вложения: с диска, если уже скачан, иначе из сети (и на диск). null — ни
  /// файла, ни сети: плитка показывает «недоступно офлайн».
  Future<File?> photoFile(String fileId, {required bool thumb}) =>
      _files.file(fileId, thumb: thumb);

  /// Стереть вложение из кэша — байты не декодируются; следующий заход
  /// перекачает (см. TaskFileCache.evict).
  Future<void> evictPhoto(String fileId) => _files.evict(fileId);

  /// Каталог фото переписки: и исходящие снимки до отправки, и скачанные вложения.
  static Future<Directory> photoDirectory(String userKey) =>
      TaskFileCache.directory(userKey);

  static Future<void> _deleteFiles(List<String> paths) =>
      TaskFileCache.deleteFiles(paths);

  /// Удалить фото переписки одного пользователя — файловая половина «выйти и удалить
  /// данные»; строки кэша и очереди уходят вместе с самой базой.
  static Future<void> deletePhotos(String userKey) =>
      TaskFileCache.deleteAll(userKey);

  // --- для репозитория: дренаж и префетч без экрана ---

  /// Дожать очереди всех задач и отложенные отметки прочтения — при синхронизации, не
  /// дожидаясь, пока ленту откроют снова: «при возврате связи уходит» обязано
  /// случиться и у телефона в кармане. [skip] — задачи, чьё создание ещё в очереди:
  /// сообщение к задаче, которой сервер не знает, ехать не может (#36716 — создание
  /// барьер для всего остального по задаче).
  static Future<void> drainAll(LocalDb db, ApiClient api,
      {Set<String> skip = const {}}) async {
    final ids = <String>{
      for (final r in await db.comments.getAllCommentOutbox()) r['taskId'] as String,
      for (final r in await db.comments.getPendingCommentReads()) r['taskId'] as String,
    };
    for (final id in ids) {
      if (skip.contains(id)) continue;
      final c = TaskCommentsController(db: db, api: api, taskId: id);
      try {
        await c.syncAll();
      } catch (_) {
        // база закрылась под дренажем (выход из аккаунта) — очередь цела, дожмётся
        break;
      } finally {
        c.dispose();
      }
    }
  }

  /// Забрать ленту задачи в кэш без экрана — чтобы переписку можно было прочесть в
  /// подвале без сети. Тихий: ошибка оставляет прежний кэш.
  static Future<void> prefetch(LocalDb db, ApiClient api, String taskId) async {
    try {
      final fetched = await api.fetchTaskComments(taskId);
      final orphans = await db.comments.replaceComments(taskId, fetched);
      await _deleteFiles(orphans);
    } catch (_) {}
  }
}
