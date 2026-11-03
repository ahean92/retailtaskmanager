import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'api_client.dart';

/// Дисковый кэш вложений чата (#37369): миниатюра качается один раз и остаётся на
/// устройстве, полный размер — по явному тапу. Ключ файла — id СООБЩЕНИЯ: у чата
/// вложение лежит в самом сообщении, а не в отдельном классе файлов, и отдельной
/// ручки на него нет (apiChatFile).
///
/// Свой каталог, а не общий с [TaskFileCache]: имена файлов там строятся из id, а
/// id сообщения чата и id TaskFile — числа из разных пространств, и одна папка
/// склеила бы чужие вложения. Каталог свой на пользователя, как база и фото
/// переписки, и стирается целиком при «выйти и удалить данные».
class ChatFileCache {
  final String userKey;
  final ApiClient api;

  ChatFileCache({required this.userKey, required this.api});

  /// Скачивания в полёте: пять миниатюр при перерисовках не должны тянуть одно и
  /// то же пятью параллельными запросами.
  final Map<(int, bool), Future<File?>> _downloads = {};

  /// Файл вложения: с диска, если уже скачан, иначе из сети (и на диск). null — ни
  /// файла, ни сети: плитка показывает «недоступно офлайн».
  Future<File?> file(int messageId, {required bool thumb}) {
    return _downloads.putIfAbsent((messageId, thumb), () async {
      final target = File(await _pathFor(userKey, messageId, thumb));
      if (await target.exists()) return target;
      try {
        final bytes = await api.fetchChatFile(messageId, thumb: thumb);
        await target.parent.create(recursive: true);
        await target.writeAsBytes(bytes);
        return target;
      } catch (_) {
        // неудача не должна запомниться до конца экрана
        _downloads.remove((messageId, thumb));
        return null;
      }
    });
  }

  /// Стереть файлы сообщения из кэша: сообщение удалено из диапазона страницы, и
  /// байты больше ничьи. Оба размера — половинка без целого не нужна.
  Future<void> evict(int messageId) async {
    _downloads.remove((messageId, true));
    _downloads.remove((messageId, false));
    await deleteFiles([
      await _pathFor(userKey, messageId, true),
      await _pathFor(userKey, messageId, false),
    ]);
  }

  /// Есть ли миниатюра уже на диске — без сети и без скачивания.
  static Future<bool> hasThumb(String userKey, int messageId) async =>
      File(await _pathFor(userKey, messageId, true)).exists();

  /// Каталог вложений чата: и исходящие снимки до отправки, и скачанные файлы.
  static Future<Directory> directory(String userKey) async {
    final dir = await getApplicationDocumentsDirectory();
    return Directory(p.join(dir.path, 'chat_photos', userKey));
  }

  static Future<String> _pathFor(
      String userKey, int messageId, bool thumb) async {
    final dir = await directory(userKey);
    return p.join(dir.path, 'm_$messageId${thumb ? '_t' : ''}.jpg');
  }

  static Future<void> deleteFiles(List<String> paths) async {
    for (final path in paths) {
      try {
        await File(path).delete();
      } catch (_) {}
    }
  }

  /// Файловая половина «выйти и удалить данные» — строки кэша и очереди уходят
  /// вместе с самой базой пользователя.
  static Future<void> deleteAll(String userKey) async {
    final dir = await directory(userKey);
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}
