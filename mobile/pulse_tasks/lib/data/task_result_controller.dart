import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'api_client.dart';
import 'local_db.dart';
import 'past_fill_controller.dart';
import 'sync/outbox_drain.dart';

/// Сданный отчёт поручения или корректирующего действия — для экрана результата
/// (#37158): все снимки «стало» и комментарий исполнителя. Только чтение, без очередей.
///
/// Читает то же, что экран выполнения, — apiSimpleInfo и apiSimplePhoto последнего
/// выполнения задачи; принимающего сервер к ним пускает (ApiCommon.canView). В выдаче
/// задач у выполнения снимок один (первый), а принимают по всем.
///
/// Кэш-первым, как весь клиент: принимающий решает в зале, где связи может не быть, —
/// ответ сервера лежит в simple_cache (тот же, что у экрана выполнения: это один и тот
/// же ответ), миниатюры — на диске, и синхронизация забирает их заранее ([prefetch]).
class TaskResultController extends ChangeNotifier {
  final LocalDb db;
  final ApiClient api;
  final String taskId;

  TaskResultController(
      {required this.db, required this.api, required this.taskId});

  String? comment;
  String? executor;

  /// Когда заведено выполнение — им же различаются снимки разных раундов на диске:
  /// после возврата у нового выполнения индексы начинаются сначала.
  String? date;
  List<int> photoIndexes = const [];
  bool loading = true;
  String? error;

  /// Вердикт о сети — тот же, что у очередей ([OutboxDrain.attempt]).
  late final OutboxDrain _link = OutboxDrain(() => db);
  bool get online => _link.online;

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> load() async {
    loading = true;
    notifyListeners();
    await _loadFromCache();
    final failure = await _link.attempt(() async {
      await _refresh(db, api, taskId);
      await _loadFromCache();
      error = null;
    });
    if (failure != null && date == null && photoIndexes.isEmpty) {
      error = failure is ApiException
          ? '$failure'
          : 'Нет данных офлайн — результат ещё не загружался';
    }
    loading = false;
    if (!_disposed) notifyListeners();
  }

  Future<void> _loadFromCache() async {
    final c = await db.simple.getSimpleCache(taskId);
    if (c == null) return;
    try {
      final j = (jsonDecode(c['infoJson'] as String) as Map)
          .cast<String, dynamic>();
      comment = j['comment']?.toString();
      executor = j['executor']?.toString();
      date = j['date']?.toString();
      photoIndexes = _indexes(j['photoIndexes'], j['photoCount']);
    } catch (_) {
      // нечитаемый кэш — как его отсутствие
    }
  }

  static Future<void> _refresh(LocalDb db, ApiClient api, String taskId) async {
    final info = await api.fetchSimpleInfo(taskId);
    if (info == null) return;
    await db.simple.saveSimpleInfo(taskId, jsonEncode(info));
  }

  /// Тихий вариант для синхронизации: ответ и миниатюры — в кэш, чтобы экран
  /// результата открылся в самолётном режиме. Ошибки тихие, как у прочих префетчей.
  static Future<void> prefetch(LocalDb db, ApiClient api, String taskId,
      {int limit = 20}) async {
    final c = TaskResultController(db: db, api: api, taskId: taskId);
    try {
      await _refresh(db, api, taskId);
      await c._loadFromCache();
      var budget = limit;
      for (final i in c.photoIndexes) {
        if (budget-- <= 0) break;
        // null — сеть пропала посреди догрузки: остальные ответят тем же
        if (await c.photo(i, thumb: true) == null) break;
      }
    } catch (_) {
      // база закрылась под префетчем (выход из аккаунта) — следующий вход догонит
    } finally {
      c.dispose();
    }
  }

  /// Скачивания в полёте — галерея при перерисовках не тянет одно и то же дважды.
  final Map<(int, bool), Future<File?>> _downloads = {};

  /// Снимок отчёта: с диска, если уже скачан, иначе из сети (и на диск). null — ни
  /// файла, ни сети: плитка скажет «недоступно офлайн».
  Future<File?> photo(int index, {required bool thumb}) {
    return _downloads.putIfAbsent((index, thumb), () async {
      final target = File(await _photoPath(index, thumb));
      if (await target.exists()) return target;
      try {
        final bytes = await api.fetchSimplePhoto(taskId, index, thumb: thumb);
        await target.parent.create(recursive: true);
        await target.writeAsBytes(bytes);
        return target;
      } catch (_) {
        _downloads.remove((index, thumb)); // неудача не запоминается до конца экрана
        return null;
      }
    });
  }

  /// Каталог — тот же, что у прошлых проверок: свой на пользователя и стирается при
  /// «выйти и удалить данные» (PastFillController.deletePhotos). В имени — момент
  /// выполнения: снимок №1 прежнего раунда и №1 нового — разные кадры.
  Future<String> _photoPath(int index, bool thumb) async {
    final dir = await PastFillController.photoDirectory(db.userKey);
    final round = (date ?? '').replaceAll(RegExp(r'[^\w]'), '');
    final task = taskId.replaceAll(RegExp(r'[^\w.-]'), '_');
    return p.join(
        dir.path, 'result_${task}_${round}_$index${thumb ? '_t' : ''}.jpg');
  }

  /// «1,3» → [1, 3]; строки нет (старый сервер) — плотная нумерация по числу снимков.
  static List<int> _indexes(Object? raw, Object? count) {
    final parsed = [
      for (final part in (raw?.toString() ?? '').split(','))
        if (int.tryParse(part.trim()) != null) int.parse(part.trim()),
    ];
    if (parsed.isNotEmpty) return parsed;
    final n = count is num ? count.toInt() : int.tryParse('$count') ?? 0;
    return [for (var i = 1; i <= n; i++) i];
  }
}
