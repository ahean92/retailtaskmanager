import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'api_client.dart';
import 'photo_disk_cache.dart';

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

  /// Скачивание и сброс — общей механикой ([PhotoDiskCache]), здесь — каталог и имена.
  late final PhotoDiskCache _disk = PhotoDiskCache(() => directory(userKey));

  /// Файл вложения: с диска, если уже скачан, иначе из сети (и на диск). null — ни
  /// файла, ни сети: плитка показывает «недоступно офлайн».
  Future<File?> file(int messageId, {required bool thumb}) =>
      _disk.file(_nameFor(messageId, thumb),
          () => api.fetchChatFile(messageId, thumb: thumb));

  /// Стереть файлы сообщения из кэша: сообщение удалено из диапазона страницы, и
  /// байты больше ничьи, или картинка не декодировалась. Оба размера — половинка без
  /// целого не нужна.
  Future<void> evict(int messageId) =>
      _disk.evict([_nameFor(messageId, true), _nameFor(messageId, false)]);

  /// Есть ли миниатюра уже на диске — без сети и без скачивания.
  static Future<bool> hasThumb(String userKey, int messageId) async =>
      File(await _pathFor(userKey, messageId, true)).exists();

  /// Каталог вложений чата: и исходящие снимки до отправки, и скачанные файлы.
  static Future<Directory> directory(String userKey) async {
    final dir = await getApplicationDocumentsDirectory();
    return Directory(p.join(dir.path, 'chat_photos', userKey));
  }

  static String _nameFor(int messageId, bool thumb) =>
      'm_$messageId${thumb ? '_t' : ''}.jpg';

  static Future<String> _pathFor(
      String userKey, int messageId, bool thumb) async {
    final dir = await directory(userKey);
    return p.join(dir.path, _nameFor(messageId, thumb));
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
