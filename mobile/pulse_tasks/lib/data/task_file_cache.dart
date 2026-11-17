import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'api_client.dart';
import 'photo_disk_cache.dart';

/// Дисковый кэш файлов задачи: миниатюра качается один раз и остаётся на устройстве,
/// полный размер — только по явному тапу. Механика скачивания и сброса — общая
/// ([PhotoDiskCache]), здесь — каталог и имена.
///
/// Один кэш на все вложения, потому что на сервере это один класс `TaskFile` и одна
/// ручка `apiTaskFile` с одним правом: снимок проблемы у самой задачи (#36842) и
/// вложение сообщения ленты (#36844) отличаются лишь тем, где их показывают. Файл на
/// диске переживает потерю сети — ради этого кэш и существует: карточка, однажды
/// открытая при связи, в подвале открывается с фотографиями.
///
/// Каталог — свой на пользователя, как база и фото-свидетельства
/// (`FillController.photoDirectory`); стирается целиком при «выйти и удалить данные».
/// Имя каталога осталось от задачи, в которой он появился (#36844): переименование
/// потеряло бы ещё не отправленные снимки переписки, лежащие там же, а они —
/// единственная копия.
class TaskFileCache {
  final String userKey;
  final ApiClient api;

  TaskFileCache({required this.userKey, required this.api});

  late final PhotoDiskCache _disk = PhotoDiskCache(() => directory(userKey));

  /// Файл вложения: с диска, если уже скачан, иначе из сети (и на диск). null — ни
  /// файла, ни сети: плитка показывает «недоступно офлайн».
  Future<File?> file(String fileId, {required bool thumb}) =>
      _disk.file(_nameFor(fileId, thumb),
          () => api.fetchTaskFile(fileId, thumb: thumb));

  /// Загрузчик для виджета: он не знает ни про кэш, ни про сеть — только про «дай
  /// файл, миниатюрой или целиком».
  Future<File?> Function({required bool thumb}) loaderFor(String fileId) =>
      ({required bool thumb}) => file(fileId, thumb: thumb);

  /// Стереть файл из кэша: байты не декодируются. Кэш верит диску слепо, и один
  /// битый файл (дозаписавшийся не до конца, испорченный на сервере) держал снимок
  /// заглушкой «офлайн» вечно — повторные заходы брали с диска то же самое. Здесь
  /// файл снимается, и следующий заход перекачает. Оба размера: если бит один,
  /// половинка не нужна. Идемпотентен: стирание отсутствующего и пустого полёта
  /// не ошибки, а «уже чисто».
  Future<void> evict(String fileId) =>
      _disk.evict([_nameFor(fileId, true), _nameFor(fileId, false)]);

  /// Есть ли миниатюра уже на диске — без сети и без скачивания. Префетчу нужно, чтобы
  /// не ходить на сервер за тем, что и так лежит.
  static Future<bool> hasThumb(String userKey, String fileId) async =>
      File(await _pathFor(userKey, fileId, true)).exists();

  static Future<Directory> directory(String userKey) async {
    final dir = await getApplicationDocumentsDirectory();
    return Directory(p.join(dir.path, 'comment_photos', userKey));
  }

  static String _fileSafe(String s) => s.replaceAll(RegExp(r'[^\w.-]'), '_');

  static String _nameFor(String fileId, bool thumb) =>
      'f_${_fileSafe(fileId)}${thumb ? '_t' : ''}.jpg';

  static Future<String> _pathFor(
      String userKey, String fileId, bool thumb) async {
    final dir = await directory(userKey);
    return p.join(dir.path, _nameFor(fileId, thumb));
  }

  /// Стереть скачанные файлы по id — оба размера — без экземпляра кэша: уборка
  /// задач, которых больше нет в списках (см. sweepGoneTasks).
  static Future<void> forgetFiles(String userKey, Iterable<String> fileIds) async {
    final dir = await directory(userKey);
    await deleteFiles([
      for (final id in fileIds) ...[
        p.join(dir.path, _nameFor(id, true)),
        p.join(dir.path, _nameFor(id, false)),
      ]
    ]);
  }

  static Future<void> deleteFiles(List<String> paths) async {
    for (final path in paths) {
      try {
        await File(path).delete();
      } catch (_) {}
    }
  }

  /// Файловая половина «выйти и удалить данные» — строки кэша и очередей уходят
  /// вместе с самой базой.
  static Future<void> deleteAll(String userKey) async {
    final dir = await directory(userKey);
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}
