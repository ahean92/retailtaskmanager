import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'local_db.dart';
import 'past_fill_controller.dart';
import 'photo_disk_cache.dart';
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

  /// Каталог — тот же, что у прошлых проверок: свой на пользователя и стирается при
  /// «выйти и удалить данные» (PastFillController.deletePhotos).
  late final PhotoDiskCache _photos =
      PhotoDiskCache(() => PastFillController.photoDirectory(db.userKey));

  /// Снимок отчёта: с диска, если уже скачан, иначе из сети (и на диск). null — ни
  /// файла, ни сети: плитка скажет «недоступно офлайн».
  Future<File?> photo(int index, {required bool thumb}) => _photos.file(
      _photoName(index, thumb),
      () => api.fetchSimplePhoto(taskId, index, thumb: thumb));

  /// Снимок не декодировался — стереть оба размера, следующий показ перекачает.
  Future<void> evictPhoto(int index) =>
      _photos.evict([_photoName(index, true), _photoName(index, false)]);

  /// В имени — момент выполнения: снимок №1 прежнего раунда и №1 нового — разные кадры.
  String _photoName(int index, bool thumb) {
    final round = (date ?? '').replaceAll(RegExp(r'[^\w]'), '');
    return '${PastFillController.photoPrefix('result', taskId)}'
        '${round}_$index${thumb ? '_t' : ''}.jpg';
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
