import 'dart:async';
import 'dart:io';

import 'api_client.dart';
import 'local_db.dart';

/// Очередь отправки, показанная человеку (#36916): что именно ждёт сети, по-людски.
///
/// «Операция» здесь — не строка очереди, а то, что человек сделал: заполненный бланк —
/// одна операция, сколько бы ответов и фото в нём ни лежало. Экран «Не отправлено» и
/// счётчик в шапке считают одни и те же операции — числа обязаны сходиться.
///
/// Причины неудач пишутся контроллерами дренажа под ключом `вид:задача`
/// ([noteSyncFailure]) и подбираются сюда при сборке; причины уехавших операций
/// вычищаются здесь же ([LocalDb.pruneSyncErrors]) — успешный дожим никакого
/// «успеха» не пишет, он просто опустошает очередь.

/// Виды операций — они же префиксы ключей sync_errors.
class UnsentKind {
  static const create = 'create'; // создание задачи (task_outbox)
  static const fill = 'fill'; // бланк: ответы, фото, итог, старт/финиш
  static const simple = 'simple'; // выполнение поручения: фото, комментарий, финиш
  static const status = 'status'; // смена статуса (outbox)
  static const take = 'take'; // взятие/возврат (take_outbox)
  static const comment = 'comment'; // сообщения ленты (comment_outbox)
  static const file = 'file'; // фото к задаче (task_file_outbox)
}

/// Одна ожидающая операция — строка экрана «Не отправлено».
class UnsentOp {
  final String kind; // из [UnsentKind]
  final String taskId;
  final String title; // имя задачи — якорь, по которому человек её узнаёт
  final String detail; // что именно ждёт: «Бланк: 12 ответов, 3 фото»
  final DateTime? queuedAt; // самая ранняя постановка в очередь
  final String? error; // причина последней неудачи, если была
  const UnsentOp({
    required this.kind,
    required this.taskId,
    required this.title,
    required this.detail,
    this.queuedAt,
    this.error,
  });

  String get key => '$kind:$taskId';
}

/// Человеческий текст причины — то, что видит человек в поле, а не код HTTP.
/// ApiException — сервер ОТВЕТИЛ отказом, и его текст важен; таймаут и обрыв
/// связи различаются, потому что зовут к разным действиям (ждать сервер / искать
/// сеть). Всё прочее показывается как есть — лучше сырой текст, чем «ошибка».
String syncFailureText(Object e) {
  if (e is ApiException) return 'Отклонено сервером: ${e.message}';
  if (e is TimeoutException) return 'Сервер не ответил';
  if (e is SocketException) return 'Нет сети';
  if (e is FileSystemException) return 'Файл недоступен на устройстве';
  final s = '$e';
  // http.ClientException и обёртки платформ не импортируются сюда типом, но обрыв
  // связи в них читается по тексту — «Connection …», «Network is unreachable»
  if (s.contains('SocketException') ||
      s.contains('ClientException') ||
      s.contains('Connection')) {
    return 'Нет сети';
  }
  // сервер за прокси ответил не-JSON (страница ошибки) — парсер падает FormatException
  if (s.contains('FormatException')) return 'Непонятный ответ сервера';
  return s;
}

/// Записать причину неудачи операции. Молчит про ошибки записи: база могла
/// закрыться под дренажем (выход из аккаунта), и причину честнее потерять, чем
/// уронить unawaited-цепочку.
Future<void> noteSyncFailure(
    LocalDb db, String kind, String taskId, Object error) async {
  try {
    await db.saveSyncError('$kind:$taskId', syncFailureText(error),
        DateTime.now().toIso8601String());
  } catch (_) {}
}

/// Собрать текущую очередь отправки списком операций, старейшие первыми, с
/// причинами последних неудач. Попутно вычищает причины уехавших операций.
Future<List<UnsentOp>> loadUnsentOps(LocalDb db) async {
  final tasks = await db.getTasks();
  final names = <String, String>{};
  for (final t in tasks) {
    final label = t.name ?? t.object ?? t.id;
    names[t.id] = label;
    final cid = t.clientId;
    if (cid != null) names[cid] = label;
  }
  String titleOf(String taskId) => names[taskId] ?? 'Задача $taskId';

  DateTime? at(Object? iso) =>
      iso == null ? null : DateTime.tryParse(iso as String);
  DateTime? earliest(Iterable<DateTime?> times) {
    DateTime? min;
    for (final t in times) {
      if (t != null && (min == null || t.isBefore(min))) min = t;
    }
    return min;
  }

  final ops = <UnsentOp>[];

  // создания задач — своей строкой: «создать задачу» человек делал отдельным жестом
  final creating = await db.getCreateTaskIds();
  for (final id in creating) {
    final entry = await db.getCreateEntry(id);
    ops.add(UnsentOp(
      kind: UnsentKind.create,
      taskId: id,
      title: titleOf(id),
      detail: 'Создание задачи',
      queuedAt: at(entry?['createdAt']),
    ));
  }

  // бланки: ответы + ячейки + фото + итог + отложенные старт/финиш одной строкой
  final lifecycle = await db.getLifecycleTaskIds();
  for (final id in lifecycle) {
    final fields = await db.getFieldOutbox(id);
    final cells = await db.getCellOutbox(id);
    final rowOps = await db.getRowOutbox(id);
    final photos = await db.getPendingFillPhotos(id);
    final photoDeletes = await db.getPhotoDeletes(id);
    final resolution = await db.getResolutionEntry(id);
    final start = await db.getStartEntry(id);
    final finish = await db.getFinishEntry(id);
    final answers = fields.length + cells.length;
    if (answers == 0 &&
        rowOps.isEmpty &&
        photos.isEmpty &&
        photoDeletes.isEmpty &&
        resolution == null &&
        start == null &&
        finish == null) {
      continue; // в жизненном цикле только создание — строка уже добавлена выше
    }
    final parts = <String>[
      if (answers > 0) _count(answers, 'ответ', 'ответа', 'ответов'),
      // состав строк таблицы (#36943) — не «ответ», а правка самой таблицы: человек
      // добавил позицию, которой в бланке не было, и это отдельное неотправленное дело
      if (rowOps.isNotEmpty)
        _count(rowOps.length, 'строка', 'строки', 'строк'),
      if (photos.isNotEmpty) '${photos.length} фото',
      // удаление кадра — такая же неотправленная правка, как и сам кадр (#36946)
      if (photoDeletes.isNotEmpty)
        '${_count(photoDeletes.length, 'удаление', 'удаления', 'удалений')} фото',
      if (resolution != null) 'итог',
      if (start != null) 'начало работы',
      if (finish != null) 'завершение',
    ];
    ops.add(UnsentOp(
      kind: UnsentKind.fill,
      taskId: id,
      title: titleOf(id),
      detail: 'Бланк: ${parts.join(', ')}',
      queuedAt: earliest([
        for (final r in [
          ...fields,
          ...rowOps,
          ...cells,
          ...photos,
          ...photoDeletes
        ])
          at(r['createdAt']),
        at(resolution?['createdAt']),
        at(start?['createdAt']),
        at(finish?['createdAt']),
      ]),
    ));
  }

  // выполнение поручения: фото + комментарий + отложенные старт/финиш одной строкой
  for (final id in await db.getSimpleQueueTaskIds()) {
    final photos = await db.getPendingSimplePhotos(id);
    final comment = await db.getSimpleComment(id);
    final start = await db.getSimpleStartEntry(id);
    final finish = await db.getSimpleFinishEntry(id);
    final parts = <String>[
      if (photos.isNotEmpty) '${photos.length} фото',
      if (comment != null) 'комментарий',
      if (start != null) 'начало работы',
      if (finish != null) 'завершение',
    ];
    if (parts.isEmpty) continue;
    ops.add(UnsentOp(
      kind: UnsentKind.simple,
      taskId: id,
      title: titleOf(id),
      detail: 'Выполнение: ${parts.join(', ')}',
      queuedAt: earliest([
        for (final r in photos) at(r['createdAt']),
        at(comment?['createdAt']),
        at(start?['createdAt']),
        at(finish?['createdAt']),
      ]),
    ));
  }

  // смены статуса
  for (final e in (await db.getOutbox()).values) {
    ops.add(UnsentOp(
      kind: UnsentKind.status,
      taskId: e.taskId,
      title: titleOf(e.taskId),
      detail: e.statusName == null
          ? 'Смена статуса'
          : 'Статус → «${e.statusName}»',
      queuedAt: at(e.createdAt),
    ));
  }

  // взятия и возвраты
  for (final r in await db.getTakeOutbox()) {
    final id = r['taskId'] as String;
    ops.add(UnsentOp(
      kind: UnsentKind.take,
      taskId: id,
      title: titleOf(id),
      detail: r['action'] == 'take' ? 'Взять на себя' : 'Вернуть в пул',
      queuedAt: at(r['createdAt']),
    ));
  }

  // сообщения ленты — по задаче, сколько бы их ни было
  final commentRows = await db.getAllCommentOutbox();
  final byTask = <String, List<Map<String, Object?>>>{};
  for (final r in commentRows) {
    byTask.putIfAbsent(r['taskId'] as String, () => []).add(r);
  }
  for (final e in byTask.entries) {
    ops.add(UnsentOp(
      kind: UnsentKind.comment,
      taskId: e.key,
      title: titleOf(e.key),
      detail: _count(e.value.length, 'сообщение', 'сообщения', 'сообщений'),
      queuedAt: earliest([for (final r in e.value) at(r['createdAt'])]),
    ));
  }

  // снимки, досланные к задаче
  final fileRows = await db.getAllTaskFileOutbox();
  final filesByTask = <String, List<Map<String, Object?>>>{};
  for (final r in fileRows) {
    filesByTask.putIfAbsent(r['taskId'] as String, () => []).add(r);
  }
  for (final e in filesByTask.entries) {
    ops.add(UnsentOp(
      kind: UnsentKind.file,
      taskId: e.key,
      title: titleOf(e.key),
      detail: '${e.value.length} фото к задаче',
      queuedAt: earliest([for (final r in e.value) at(r['createdAt'])]),
    ));
  }

  // причины последних неудач — к своим операциям; причины уехавших вычищаются
  final errors = await db.getSyncErrors();
  await db.pruneSyncErrors({for (final o in ops) o.key});
  final result = [
    for (final o in ops)
      errors.containsKey(o.key)
          ? UnsentOp(
              kind: o.kind,
              taskId: o.taskId,
              title: o.title,
              detail: o.detail,
              queuedAt: o.queuedAt,
              error: errors[o.key]!.message,
            )
          : o
  ];

  // старейшие первыми — это очередь, и читается она как очередь; без времени — в конец
  result.sort((a, b) {
    final x = a.queuedAt, y = b.queuedAt;
    if (x == null) return y == null ? 0 : 1;
    if (y == null) return -1;
    return x.compareTo(y);
  });
  return result;
}

/// «1 ответ, 2 ответа, 5 ответов» — счётные формы русского.
String _count(int n, String one, String few, String many) {
  final mod100 = n % 100, mod10 = n % 10;
  final String form;
  if (mod100 >= 11 && mod100 <= 14) {
    form = many;
  } else if (mod10 == 1) {
    form = one;
  } else if (mod10 >= 2 && mod10 <= 4) {
    form = few;
  } else {
    form = many;
  }
  return '$n $form';
}
