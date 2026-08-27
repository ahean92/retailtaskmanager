import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'api_client.dart';

/// Дисковый кэш файлов задачи: миниатюра качается один раз и остаётся на устройстве,
/// полный размер — только по явному тапу.
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

  /// Скачивания в полёте: галерея из пяти миниатюр при перерисовках не должна тянуть
  /// одно и то же пятью параллельными запросами.
  final Map<(String, bool), Future<File?>> _downloads = {};

  /// Файл вложения: с диска, если уже скачан, иначе из сети (и на диск). null — ни
  /// файла, ни сети: плитка показывает «недоступно офлайн».
  Future<File?> file(String fileId, {required bool thumb}) {
    return _downloads.putIfAbsent((fileId, thumb), () async {
      final target = File(await _pathFor(userKey, fileId, thumb));
      if (await target.exists()) return target;
      try {
        final bytes = await api.fetchTaskFile(fileId, thumb: thumb);
        await target.parent.create(recursive: true);
        await target.writeAsBytes(bytes);
        return target;
      } catch (_) {
        // неудача не должна запомниться до конца экрана
        _downloads.remove((fileId, thumb));
        return null;
      }
    });
  }

  /// Загрузчик для виджета: он не знает ни про кэш, ни про сеть — только про «дай
  /// файл, миниатюрой или целиком».
  Future<File?> Function({required bool thumb}) loaderFor(String fileId) =>
      ({required bool thumb}) => file(fileId, thumb: thumb);

  /// Есть ли миниатюра уже на диске — без сети и без скачивания. Префетчу нужно, чтобы
  /// не ходить на сервер за тем, что и так лежит.
  static Future<bool> hasThumb(String userKey, String fileId) async =>
      File(await _pathFor(userKey, fileId, true)).exists();

  static Future<Directory> directory(String userKey) async {
    final dir = await getApplicationDocumentsDirectory();
    return Directory(p.join(dir.path, 'comment_photos', userKey));
  }

  static String _fileSafe(String s) => s.replaceAll(RegExp(r'[^\w.-]'), '_');

  static Future<String> _pathFor(
      String userKey, String fileId, bool thumb) async {
    final dir = await directory(userKey);
    return p.join(dir.path, 'f_${_fileSafe(fileId)}${thumb ? '_t' : ''}.jpg');
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
