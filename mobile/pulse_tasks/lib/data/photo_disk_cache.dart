import 'dart:io';

import 'package:path/path.dart' as p;

/// Строка — кусок имени файла: код пункта, номер задачи, id файла с сервера. Всё,
/// кроме букв, цифр, точки, дефиса и подчёркивания, — в «_»: код пункта приходит из
/// шаблона, и разделитель пути в нём увёл бы файл в чужой каталог.
String fileSafe(String s) => s.replaceAll(RegExp(r'[^\w.-]'), '_');

/// Скачанные снимки на диске — одна механика на все экраны: файлы задачи и ленты,
/// вложения чата, прошлые проверки, отчёт результата, серверные кадры бланка и
/// поручения. Каждый экран называет свой каталог и имя файла, а как качать, класть на
/// диск и сбрасывать — решается здесь.
///
/// Запись идёт во временный файл и переименованием в итоговый: оборванная запись
/// (приложение закрыли, кончилось место) не оставляет под итоговым именем полфайла,
/// которому кэш поверил бы навсегда. Файл, скачанный целиком, но не ставший картинкой
/// (испорчен на сервере), снимает [evict]: экран зовёт его, когда картинка не
/// декодировалась, и следующий показ скачает заново.
///
/// Скачивания в полёте общие: галерея из пяти миниатюр при перерисовках не тянет одно
/// и то же пятью запросами. Неудача не запоминается — следующий заход попробует снова.
class PhotoDiskCache {
  /// Каталог файлов — свой у каждого кэша и свой на пользователя; стирается при
  /// «выйти и удалить данные» тем, кто его называет.
  final Future<Directory> Function() directory;

  PhotoDiskCache(this.directory);

  final Map<String, Future<File?>> _downloads = {};

  /// Файл [name] из [directory]: с диска, если уже лежит, иначе [fetch] — и на диск.
  /// null — ни файла, ни сети: плитка показывает «недоступно офлайн».
  ///
  /// [reuseDisk] = false — лежащий на диске файл не берётся, первый запрос этого кэша
  /// качает заново. Так — у кадров, которые ещё правят (бланк, поручение): индекс
  /// освобождается вместе с удалённым снимком и достаётся следующему, и файл,
  /// оставшийся с прошлого раза, показал бы чужой кадр.
  Future<File?> file(String name, Future<List<int>> Function() fetch,
      {bool reuseDisk = true}) {
    return _downloads.putIfAbsent(name, () async {
      final target = File(p.join((await directory()).path, name));
      if (reuseDisk && await target.exists()) return target;
      try {
        final bytes = await fetch();
        await target.parent.create(recursive: true);
        final part = File(
            '${target.path}.${DateTime.now().microsecondsSinceEpoch}.part');
        await part.writeAsBytes(bytes, flush: true);
        return await part.rename(target.path);
      } catch (_) {
        // неудача не должна запомниться до конца экрана
        _downloads.remove(name);
        return null;
      }
    });
  }

  /// Стереть файлы: байты не декодировались или снимка больше нет. Идемпотентен —
  /// отсутствующий файл и пустой полёт не ошибка, а «уже чисто».
  Future<void> evict(Iterable<String> names) async {
    final dir = await directory();
    for (final name in names) {
      _downloads.remove(name);
      try {
        await File(p.join(dir.path, name)).delete();
      } catch (_) {}
    }
  }
}
