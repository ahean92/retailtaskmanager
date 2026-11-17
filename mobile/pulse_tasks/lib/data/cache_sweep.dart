import 'dart:io';

import 'package:path/path.dart' as p;

import 'fill_controller.dart';
import 'local_db.dart';
import 'past_fill_controller.dart';
import 'task_file_cache.dart';

/// Уборка того, что телефон держит по задачам, которых он больше не показывает:
/// закрытым больше 30 дней назад (окно архива «Выполненные» держит сервер) или
/// ставшим чужими. Бланк, отчёт поручения, лента, прошлая проверка и результат — их
/// кэши и файлы; уехавшие снимки — тоже: они уже на сервере. Задача, по которой
/// хоть что-то ждёт отправки, не трогается, открытые — тем более: они в списке.
///
/// Зовётся после того, как список задач заменён ответом сервера ([QueueDao]
/// судит по строкам задач). Ошибки не всплывают: уборка — не то, ради чего человек
/// открыл приложение, и база могла закрыться под ней (выход из аккаунта).
Future<void> sweepGoneTasks(LocalDb db) async {
  try {
    final key = db.userKey;
    final gone = await db.queues.forgetGoneTasks();
    await TaskFileCache.deleteFiles(gone.paths);
    await TaskFileCache.forgetFiles(key, gone.fileIds);
    final prefixes = [
      for (final id in gone.tasks) ...[
        PastFillController.photoPrefix('task', id),
        PastFillController.photoPrefix('result', id),
      ]
    ];
    if (prefixes.isNotEmpty) {
      await _deleteWhere(await PastFillController.photoDirectory(key),
          (name) => prefixes.any(name.startsWith));
    }
    // снимки с сервера, скачанные прежними версиями, лежали в постоянном каталоге
    // рядом со своими кадрами; их место теперь во временном — здесь они ничьи.
    // Один раз за запуск на пользователя: новые туда больше не пишутся
    if (_legacyServerPhotosGone.add(key)) {
      await _deleteWhere(await FillController.photoDirectory(key),
          (name) => name.startsWith('srv_'));
    }
  } catch (_) {
    // следующая синхронизация уберёт то, что не успела эта
  }
}

final _legacyServerPhotosGone = <String>{};

Future<void> _deleteWhere(Directory dir, bool Function(String name) test) async {
  if (!await dir.exists()) return;
  await for (final e in dir.list()) {
    if (e is File && test(p.basename(e.path))) {
      try {
        await e.delete();
      } catch (_) {}
    }
  }
}
