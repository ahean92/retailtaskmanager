import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/comment.dart';
import 'api_client.dart';
import 'client_id.dart';
import 'fill_controller.dart';
import 'local_db.dart';
import 'task_file_cache.dart';
import 'unsent.dart';

/// Лента комментариев одной задачи (#36844): кэш-первым, очередь отправки с ретраем
/// и ключом идемпотентности, отметка прочтения, миниатюры вложений с дисковым кэшем.
///
/// Тот же рисунок, что у бланка (FillController): сообщение пишут там же, где
/// заполняют бланк, — часто без связи, — поэтому оно ложится строкой в очередь и
/// показывается в ленте сразу, с пометкой «не отправлено»; уезжает, когда есть сеть,
/// — отсюда же или дренажем репозитория при синхронизации. clientId (UUID) рождается
/// вместе с сообщением: сервер по нему узнаёт повтор, так что ретрай очереди не
/// задваивает сообщение, а переписка не читается как сбой.
class TaskCommentsController extends ChangeNotifier {
  final LocalDb db;
  final ApiClient api;
  final String taskId;

  TaskCommentsController(
      {required this.db, required this.api, required this.taskId});

  List<TaskComment> items = const [];
  bool loading = true;
  bool online = true;
  bool syncing = false;
  String? error;
  String? lastSyncError;
  bool _disposed = false;

  /// Сервер отверг конкретное сообщение (не обрыв сети) — подпись под его пузырём:
  /// без неё застрявшее «не отправлено» объяснить нечем, а человеку решать, ждать
  /// или убрать (см. [discard]).
  final Map<String, String> _sendErrors = {};

  /// Очередь одной задачи дренится из одного места за раз, кто бы ни просил: открытая
  /// лента и дренаж репозитория при синхронизации — два контроллера над одной очередью,
  /// и сообщение, которое толкнут оба, уедет дважды (сервер ответит повтором, но
  /// трафик и гонка за dequeue ни к чему). Цепочка futures на задачу — весь мьютекс.
  static final Map<String, Future<void>> _drains = {};

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  int get pendingCount => items.where((c) => c.pending).length;

  Future<void> load() async {
    loading = true;
    notifyListeners();
    try {
      await _loadLocal();
    } catch (_) {
      // база закрылась, пока лента поднималась (выход из аккаунта, смена сервера):
      // показывать нечего и некому — экран уходит вместе с сессией
      loading = false;
      return;
    }
    try {
      // своё — первым, чтобы ответ сервера ниже уже содержал его, а не догонял
      await syncAll();
      await _refresh();
      online = true;
      error = null;
    } on ApiException catch (e) {
      // сервер ОТВЕТИЛ отказом — сеть жива, и «офлайн» было бы неправдой
      online = true;
      if (items.isEmpty) error = '$e';
    } catch (_) {
      online = false;
      if (items.isEmpty) error = 'Нет связи — переписка ещё не загружалась';
    } finally {
      loading = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// Кэш серверной ленты плюс своя очередь: неотправленные — в конце, они новее
  /// всего, что сервер успел вернуть, каким бы ни было расхождение часов.
  Future<void> _loadLocal() async {
    final cached = await db.getComments(taskId);
    final queued = await db.getCommentOutbox(taskId);
    final list = [
      ...cached,
      for (final r in queued)
        TaskComment.pendingFrom(r,
            sendError: _sendErrors[r['clientId'] as String]),
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
    final orphans = await db.replaceComments(taskId, fetched);
    await _deleteFiles(orphans);
    await _loadLocal();
  }

  /// Написать: строка в очередь (мгновенно и офлайн-безопасно), пузырь в ленте в том
  /// же кадре, отправка — следом. Фото копируется в каталог этого пользователя и
  /// уходит внутри того же POST, что и текст: одно сообщение — один ретрай.
  Future<void> send(String text, {String? photoPath}) async {
    final clientId = newClientId();
    final trimmed = text.trim();
    String? stored;
    if (photoPath != null) {
      final dir = await photoDirectory(db.userKey);
      if (!await dir.exists()) await dir.create(recursive: true);
      stored = p.join(dir.path, 'out_$clientId.jpg');
      await File(photoPath).copy(stored);
    }
    await db.enqueueComment(clientId, taskId,
        text: trimmed.isEmpty ? null : trimmed,
        photoPath: stored,
        createdAtIso: DateTime.now().toIso8601String());
    await _loadLocal();
    notifyListeners();
    unawaited(_sendAndRefresh());
  }

  Future<void> _sendAndRefresh() async {
    final sent = await syncAll();
    if (!sent || _disposed) return;
    // ушло — перечитать ленту: у сообщения теперь серверное время и id
    try {
      await _refresh();
      online = true;
    } catch (_) {}
    if (!_disposed) notifyListeners();
  }

  /// Убрать из очереди сообщение, которое сервер отверг: ретраить его бесполезно, а
  /// висеть «не отправленным» вечно оно не должно. Только своё и только из очереди —
  /// отправленное не редактируется и не удаляется (это лента, а не мессенджер).
  Future<void> discard(String clientId) async {
    for (final r in await db.getCommentOutbox(taskId)) {
      if (r['clientId'] != clientId) continue;
      final path = r['photoPath'] as String?;
      if (path != null) await _deleteFiles([path]);
    }
    await db.dequeueComment(clientId);
    _sendErrors.remove(clientId);
    await _loadLocal();
    notifyListeners();
  }

  /// Дожать очередь этой задачи (и её отметку прочтения). Возвращает, ушло ли хоть
  /// одно сообщение. Вызов встаёт в очередь за тем, кто дренит сейчас, — см. [_drains].
  Future<bool> syncAll() async {
    var sent = false;
    final prev = _drains[taskId] ?? Future<void>.value();
    final run = prev.catchError((_) {}).then((_) async {
      sent = await _drainOutbox();
    });
    _drains[taskId] = run;
    try {
      await run;
    } finally {
      if (identical(_drains[taskId], run)) _drains.remove(taskId);
    }
    return sent;
  }

  Future<bool> _drainOutbox() async {
    syncing = true;
    if (!_disposed) notifyListeners();
    var sent = false;
    try {
      for (final e in await db.getCommentOutbox(taskId)) {
        final cid = e['clientId'] as String;
        try {
          await api.addTaskComment(await _body(e));
          await db.dequeueComment(cid);
          _sendErrors.remove(cid);
          final path = e['photoPath'] as String?;
          if (path != null) await _deleteFiles([path]);
          sent = true;
          online = true;
        } on ApiException catch (ex) {
          // сервер ответил отказом (сеть жива): сообщение остаётся в очереди с
          // подписью, следующее пробуем — отказ по одному не блокирует остальные
          _sendErrors[cid] = '$ex';
          lastSyncError = '$ex';
          await noteSyncFailure(db, UnsentKind.comment, taskId, ex);
          online = true;
        } catch (ex) {
          lastSyncError = '$ex';
          await noteSyncFailure(db, UnsentKind.comment, taskId, ex);
          online = false;
          break;
        }
      }
      await _sendReadMark();
    } finally {
      syncing = false;
      if (!_disposed) {
        await _loadLocal();
        notifyListeners();
      }
    }
    return sent;
  }

  /// Тело apiAddTaskComment из строки очереди; фото — base64 внутри. Файл, честно
  /// пропавший с диска (очищенное хранилище), текст не останавливает: сообщение
  /// едет без него, а сообщение из одного пропавшего фото сервер отвергнет — и оно
  /// покажется с подписью, откуда его можно убрать.
  Future<Map<String, dynamic>> _body(Map<String, Object?> e) async {
    final body = <String, dynamic>{'id': taskId, 'clientId': e['clientId']};
    final text = e['text'] as String?;
    if (text != null && text.isNotEmpty) body['text'] = text;
    final path = e['photoPath'] as String?;
    if (path != null) {
      try {
        body['photo'] = base64Encode(await File(path).readAsBytes());
      } on PathNotFoundException {
        // см. выше
      }
    }
    return body;
  }

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
    await db.markCommentsRead(taskId, wireTime(upTo));
    await _sendReadMark();
  }

  /// Серверное время в провод так же, как #36838: `yyyy-MM-ddTHH:mm:ss`.
  static String wireTime(String serverDateTime) =>
      FillController.wireAt(serverDateTime.replaceFirst(' ', 'T'));

  Future<void> _sendReadMark() async {
    for (final r in await db.getPendingCommentReads()) {
      if (r['taskId'] != taskId) continue;
      final upTo = r['upTo'] as String;
      try {
        await api.markTaskCommentsRead(taskId, upTo);
        await db.markCommentReadSent(taskId, upTo);
        online = true;
      } on ApiException {
        // сервер отверг (доступ к задаче пропал): отметка не настолько важна, чтобы
        // висеть в очереди вечно
        await db.markCommentReadSent(taskId, upTo);
      } catch (_) {
        online = false;
      }
    }
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
      for (final r in await db.getAllCommentOutbox()) r['taskId'] as String,
      for (final r in await db.getPendingCommentReads()) r['taskId'] as String,
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
      final orphans = await db.replaceComments(taskId, fetched);
      await _deleteFiles(orphans);
    } catch (_) {}
  }
}
