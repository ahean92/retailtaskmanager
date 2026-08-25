import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'api_client.dart';
import 'client_id.dart';
import 'local_db.dart';
import 'task_file_cache.dart';

/// Снимки, приложенные к самой задаче (#36914): очередь отправки, ретрай с ключом
/// идемпотентности и уборка файлов.
///
/// Два места приложения — экран создания («вот бардак на витрине», три кадра подряд)
/// и карточка готовой задачи («вот ещё ценник крупно») — здесь сходятся в одно: и там,
/// и там кадр ложится строкой в `task_file_outbox` и уезжает ручкой apiAddTaskFile,
/// когда есть сеть. Это не комментарий: файл цепляется к задаче и виден на карточке и
/// в АРМ, а не прячется в ленту переписки.
///
/// Файл копируется в каталог этого пользователя РЯДОМ с кэшем вложений
/// (TaskFileCache.directory): пока строка очереди жива, копия в телефоне —
/// единственная, и стирается она вместе с базой при «выйти и удалить данные».
class TaskFilesController {
  /// Предел на задачу: десять кадров — та же цифра, что в приёмке #36914. Считается
  /// вместе с уже уехавшими: «десять фото на задачу» — свойство задачи, а не жеста.
  static const int maxPerTask = 10;

  /// Предел на кадр после сжатия. Собственная камера пишет пресетом (~0,3–0,8 МБ), а
  /// из галереи снимок приезжает сжатым image_picker'ом — три мегабайта перешагнёт
  /// разве что экзотика вроде панорамы, и её честнее отклонить с внятным текстом,
  /// чем полчаса гнать по мобильной сети.
  static const int maxPhotoBytes = 3 * 1024 * 1024;

  /// Человеческий текст отказа по размеру — один на все места, где кадр добавляют.
  static String tooLargeMessage(int bytes) =>
      'Снимок ${(bytes / (1024 * 1024)).toStringAsFixed(1)} МБ — предел '
      '${maxPhotoBytes ~/ (1024 * 1024)} МБ. Снимите ещё раз с меньшим качеством.';

  static String limitMessage(int limit) =>
      'Не больше $maxPerTask фото на задачу'
      '${limit <= 0 ? '' : ' — можно добавить ещё $limit'}.';

  /// Скопировать снимок в каталог пользователя под именем ключа отправки. Возвращает
  /// (clientId, путь копии): исходник из камеры/галереи не трогаем — он живёт в кэше
  /// приложения и убирается системой.
  static Future<(String, String)> storePhoto(
      String userKey, String sourcePath) async {
    final clientId = newClientId();
    final dir = await TaskFileCache.directory(userKey);
    if (!await dir.exists()) await dir.create(recursive: true);
    final stored = p.join(dir.path, 'task_$clientId.jpg');
    await File(sourcePath).copy(stored);
    return (clientId, stored);
  }

  /// Дослать кадр к задаче, которая уже существует (в том числе только в телефоне):
  /// строка в очередь, отправка — следом дренажем. Возвращает clientId записи.
  static Future<String> attach(
      LocalDb db, String taskId, String sourcePath) async {
    final (clientId, stored) = await storePhoto(db.userKey, sourcePath);
    await db.enqueueTaskFile(clientId, taskId,
        path: stored, createdAtIso: DateTime.now().toIso8601String());
    return clientId;
  }

  /// Убрать кадр, ещё не уехавший: строка из очереди и файл с диска. Это и есть
  /// «удалённый кадр не появляется на сервере и не занимает место на телефоне» —
  /// для снимка, который человек уже отправил в очередь, но передумал.
  static Future<void> discard(LocalDb db, String clientId) async {
    for (final r in await db.getAllTaskFileOutbox()) {
      if (r['clientId'] != clientId) continue;
      await deleteFile(r['path'] as String);
    }
    await db.dequeueTaskFile(clientId);
  }

  /// Удалить файл, не поднимая шума: снимок, которого уже нет, — не ошибка.
  static Future<void> deleteFile(String path) =>
      TaskFileCache.deleteFiles([path]);

  /// Дожать очередь снимков. [skip] — задачи, чьё СОЗДАНИЕ ещё в очереди: файл к
  /// задаче, которой сервер не знает, ехать не может (создание — барьер, #36716),
  /// и кадры уедут следующим заходом, сразу после того как создание дожмётся.
  ///
  /// Отказ сервера по одному кадру (сеть жива) не держит остальные: снимок остаётся
  /// в очереди и пробуется в следующий раз. Обрыв связи прекращает проход — по той же
  /// причине, что и в переписке: следующие кадры упрутся в тот же обрыв.
  static Future<String?> drainAll(LocalDb db, ApiClient api,
      {Set<String> skip = const {}}) async {
    String? firstError;
    for (final r in await db.getAllTaskFileOutbox()) {
      final taskId = r['taskId'] as String;
      if (skip.contains(taskId)) continue;
      final clientId = r['clientId'] as String;
      final path = r['path'] as String;
      final String photo;
      try {
        photo = base64Encode(await File(path).readAsBytes());
      } on PathNotFoundException {
        // файл честно пропал (очищенное хранилище) — отправлять нечего, и держать
        // запись вечно незачем
        await db.dequeueTaskFile(clientId);
        continue;
      } catch (e) {
        firstError ??= '$e';
        continue;
      }
      try {
        await api.addTaskFile(taskId, clientId, photo);
        await db.dequeueTaskFile(clientId);
        await deleteFile(path);
      } on ApiException catch (e) {
        // сервер ОТВЕТИЛ отказом: сеть жива, следующий кадр имеет смысл пробовать
        firstError ??= '$e';
      } catch (e) {
        firstError ??= '$e';
        break; // обрыв связи — остальные упрутся в него же
      }
    }
    return firstError;
  }
}
