import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'api_client.dart';
import 'fill_controller.dart';
import 'geo.dart';
import 'local_db.dart';
import 'unsent.dart';

/// Простое выполнение одной задачи (#36872): снимки, комментарий, «Выполнено».
///
/// Тот же рисунок, что у бланка (FillController) и переписки (TaskCommentsController):
/// офлайн-первым — всё, что человек сделал, ложится в очереди и показывается на экране
/// в том же кадре, а уезжает, когда есть сеть, отсюда же или дренажем репозитория.
/// Порядок отправки задан здесь и не зависит от везения: создание задачи (общий барьер
/// обоих видов выполнения) → старт → снимки → комментарий → завершение. Завершение
/// строго последним и только по пустым очередям: сервер проверяет отчёт целиком, и
/// «Выполнено», обогнавшее свой снимок, закрыло бы задачу без фотографии.
class SimpleExecutionController extends ChangeNotifier {
  final LocalDb db;
  final ApiClient api;
  final String taskId;

  /// Откуда взять координаты момента действия (#36838) — как у бланка: null означает
  /// «у контроллера нет экрана» (дренаж переподключения), и мерить на дожиме нельзя —
  /// записалось бы место появления сети, а не место работы.
  final Geo? geo;

  /// Требование фото, как его знает СПИСОК задач (apiTasks). Нужно до первого ответа
  /// сервера: задача, созданная в подвале, к серверу не ходила ни разу, а гасить
  /// «Выполнено» до снимка надо уже там — ловить отказ постфактум нельзя, человек к
  /// тому моменту ушёл с точки. Ответ apiSimpleInfo, когда он приходит, эту подсказку
  /// заменяет: сервер главнее кэша.
  final bool requirePhotoHint;

  SimpleExecutionController(
      {required this.db,
      required this.api,
      required this.taskId,
      this.geo,
      this.requirePhotoHint = false})
      : requirePhoto = requirePhotoHint;

  /// Снимки, лежащие файлами на этом устройстве, в порядке их индексов очереди.
  List<String> photoPaths = [];

  /// Снимки, о которых знает только сервер (сделаны на другом устройстве или на этом
  /// же до переустановки). Индексы — как есть: после удаления они НЕ уплотняются, и
  /// проход «от 1 до photoCount» промахнулся бы мимо снимков за дырой.
  List<int> serverPhotoIndexes = [];
  int serverPhotoCount = 0;

  String? comment;
  String? object;
  String? name;
  String? executor;
  bool requirePhoto;
  bool finished = false;

  bool loading = true;
  bool syncing = false;
  bool online = true;
  int pendingCount = 0;
  String? error;
  String? lastSyncError;
  bool _disposed = false;
  bool _resyncRequested = false;

  /// Очередь одной задачи дренится из одного места за раз, кто бы ни просил: открытый
  /// экран и дренаж репозитория — два контроллера над одними очередями, и снимок,
  /// который толкнут оба, сервер припишет дважды (он дописывает в конец).
  static final Map<String, Future<void>> _drains = {};
  Completer<void>? _syncDone;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// Снимок есть хоть где-нибудь — на устройстве или уже на сервере.
  bool get hasPhoto => photoPaths.isNotEmpty || serverPhotoCount > 0;

  /// Кнопка «Выполнено» доступна. Требование фото проверяется ЗДЕСЬ, до отправки:
  /// ловить отказ сервера постфактум нельзя — человек к тому моменту ушёл с точки.
  bool get canFinish => !finished && (!requirePhoto || hasPhoto);

  Future<void> load() async {
    loading = true;
    notifyListeners();
    final hadCache = await _loadFromCache();
    try {
      // Первое открытие (кэша ещё нет) — момент фактического начала работы: старт
      // создаёт выполнение, и координаты места должны уехать в нём (#36838). Сервер
      // пишет их только при создании, поэтому на повторных открытиях геопозицию не
      // меряем — жгла бы батарею ради значений, которые всё равно не запишутся.
      //
      // Задача, рождённая на этом телефоне и ещё не уехавшая, стартует только через
      // очередь: сервер такой задачи не знает, и прямой вызов ответил бы «not found».
      if (!finished && !await db.hasSimpleStart(taskId)) {
        final stamp = hadCache ? null : await _stamp();
        if (await db.simpleLifecyclePending(taskId)) {
          // задачи ещё нет у сервера — старт ждёт её в очереди, следом за созданием
          await db.enqueueSimpleStart(taskId, stamp!.at,
              lat: stamp.lat, lon: stamp.lon);
        } else {
          try {
            await api.startSimple(taskId,
                lat: stamp?.lat, lon: stamp?.lon, at: stamp?.at);
          } on ApiException {
            rethrow; // сервер отказал — это показывают, а не ретраят молча
          } catch (_) {
            // связи нет: работа всё равно началась — старт уходит в очередь с
            // точкой ЭТОГО момента, иначе выполнения не будет и снимку некуда лечь
            if (stamp != null) {
              await db.enqueueSimpleStart(taskId, stamp.at,
                  lat: stamp.lat, lon: stamp.lon);
            } else {
              await db.enqueueSimpleStart(
                  taskId, FillController.wireAt(DateTime.now().toIso8601String()));
            }
            rethrow;
          }
        }
      }
      // Своё — вперёд, чтобы ответ сервера ниже уже содержал его, а не догонял.
      await syncAll(refreshInfo: false);
      await _refreshInfo();
      online = true;
      error = null;
    } on ApiException catch (e) {
      // сервер ОТВЕТИЛ отказом — сеть жива, и «офлайн» было бы неправдой
      online = true;
      if (!hadCache) error = '$e';
    } catch (_) {
      online = false;
      if (!hadCache) error = 'Нет связи — выполнение ещё не загружалось';
    } finally {
      loading = false;
      await _overlayQueues();
      if (!_disposed) notifyListeners();
    }
  }

  /// Состояние с сервера + всё, что лежит в очередях этого устройства. Возвращает,
  /// был ли кэш: его отсутствие — это «экран открывают впервые», и только тогда
  /// снимается точка начала работы.
  Future<bool> _loadFromCache() async {
    final c = await db.getSimpleCache(taskId);
    if (c == null) {
      await _overlayQueues();
      return false;
    }
    _applyInfo(
        (jsonDecode(c['infoJson'] as String) as Map).cast<String, dynamic>());
    await _overlayQueues();
    return true;
  }

  Future<void> _refreshInfo() async {
    final info = await api.fetchSimpleInfo(taskId);
    if (_disposed || info == null) return;
    _applyInfo(info);
    await db.saveSimpleInfo(taskId, jsonEncode(info));
    await _overlayQueues();
  }

  void _applyInfo(Map<String, dynamic> j) {
    object = j['object']?.toString();
    name = j['name']?.toString();
    executor = j['executor']?.toString();
    requirePhoto = j['requirePhoto'] == true;
    finished = j['finished'] == true;
    comment = j['comment']?.toString();
    serverPhotoCount = _int(j['photoCount']) ?? 0;
    serverPhotoIndexes = _indexes(j['photoIndexes'], serverPhotoCount);
  }

  /// Очереди поверх серверного состояния: снимки этого устройства, ещё не уехавший
  /// комментарий и завершение, сделанное офлайн. Без последнего переоткрытый экран
  /// выглядел бы незавершённым и противоречил бы списку.
  Future<void> _overlayQueues() async {
    final rows = await db.getSimplePhotos(taskId);
    photoPaths = [
      for (final r in rows)
        if (r['path'] != null) r['path'] as String,
    ];
    final queued = await db.getSimpleComment(taskId);
    if (queued != null) comment = queued['text'] as String?;
    if (!finished && await db.hasSimpleFinish(taskId)) finished = true;
    await _refreshPending();
  }

  Future<void> _refreshPending() async {
    pendingCount = (await db.getPendingSimplePhotos(taskId)).length +
        (await db.getSimpleComment(taskId) != null ? 1 : 0) +
        (await db.hasSimpleStart(taskId) ? 1 : 0) +
        (await db.hasSimpleFinish(taskId) ? 1 : 0) +
        (await db.getCreateEntry(taskId) != null ? 1 : 0);
  }

  /// Координаты и время «прямо сейчас» — момент действия (#36838). Время устройства
  /// есть всегда; координат может не быть (подвал, склад, отказ в разрешении), и
  /// тогда их честно нет: отсутствие координат работу не останавливает.
  Future<({double? lat, double? lon, String at})> _stamp() async {
    final at = FillController.wireAt(DateTime.now().toIso8601String());
    final fix = geo == null ? null : await geo!.locate();
    return fix is GeoFix
        ? (lat: fix.latitude, lon: fix.longitude, at: at)
        : (lat: null, lon: null, at: at);
  }

  // --- снимки ---

  /// Добавить снимок: файл в каталог этого пользователя, строка в очередь, плитка на
  /// экране — в том же кадре. Каждый снимок получает свой индекс и свою строку, так
  /// что второй никогда не затирает первый ни на устройстве, ни на сервере.
  Future<void> addPhoto(String sourcePath) async {
    final idx = await db.nextSimplePhotoIndex(taskId);
    final saved = await _persistPhoto(sourcePath, idx);
    photoPaths = [...photoPaths, saved];
    await db.saveSimplePhoto(
        taskId, idx, saved, DateTime.now().toIso8601String());
    await _refreshPending();
    notifyListeners();
    unawaited(syncAll());
  }

  /// Убрать все снимки. Поштучно на сервере удаляется только то, чей серверный индекс
  /// это устройство знает; набор, снятый где-то ещё, честнее стереть целиком и снять
  /// заново, чем гадать об индексах (та же развилка, что у фото поля бланка).
  Future<void> clearPhotos() async {
    final old = [...photoPaths];
    final wasOnServer = serverPhotoCount > 0;
    photoPaths = [];
    serverPhotoCount = 0;
    serverPhotoIndexes = [];
    for (final r in await db.getSimplePhotos(taskId)) {
      await db.deleteSimplePhoto(taskId, r['idx'] as int);
    }
    if (wasOnServer) {
      // пустое фото — команда серверу стереть весь набор
      await db.saveSimplePhoto(
          taskId, 0, null, DateTime.now().toIso8601String());
    }
    for (final path in old) {
      try {
        await File(path).delete();
      } catch (_) {}
    }
    await _refreshPending();
    notifyListeners();
    unawaited(syncAll());
  }

  /// Снимки живут там же, где снимки бланка: один каталог на пользователя, который
  /// целиком стирается при выходе «с удалением данных» (FillController.photoDirectory).
  Future<String> _persistPhoto(String sourcePath, int idx) async {
    final dir = await FillController.photoDirectory(db.userKey);
    if (!await dir.exists()) await dir.create(recursive: true);
    final dest = p.join(dir.path, '${taskId}_simple_$idx.jpg');
    await File(sourcePath).copy(dest);
    return dest;
  }

  // --- комментарий ---

  /// Комментарий ложится в очередь (одной строкой на задачу — он один) и виден сразу.
  /// Пустой текст — это «стереть комментарий», а не «нечего отправлять».
  Future<void> setComment(String text) async {
    final trimmed = text.trim();
    if ((comment ?? '') == trimmed) return;
    comment = trimmed;
    await db.enqueueSimpleComment(
        taskId, trimmed, DateTime.now().toIso8601String());
    await _refreshPending();
    notifyListeners();
    unawaited(syncAll());
  }

  // --- синхронизация ---

  Future<void> syncAll({bool refreshInfo = true}) async {
    if (syncing) {
      // запрос складывается в идущий проход, но вызывающий ждёт его КОНЦА: finish()
      // судит об отказе сервера по очередям, и ранний возврат заставил бы его
      // отменить завершение, которое проход ещё только собирался отправить
      _resyncRequested = true;
      final done = _syncDone;
      if (done != null) await done.future;
      return;
    }
    syncing = true;
    final done = _syncDone = Completer<void>();
    notifyListeners();
    try {
      final prev = _drains[taskId] ?? Future<void>.value();
      final run = prev.catchError((_) {}).then((_) => _syncBody());
      _drains[taskId] = run;
      try {
        await run;
      } finally {
        if (identical(_drains[taskId], run)) _drains.remove(taskId);
      }
    } finally {
      syncing = false;
      if (!_disposed) {
        await _refreshPending();
        if (pendingCount == 0) lastSyncError = null;
        if (refreshInfo && pendingCount == 0 && online) {
          try {
            await _refreshInfo();
          } catch (_) {}
        }
        if (!_disposed) notifyListeners();
      }
      if (identical(_syncDone, done)) _syncDone = null;
      done.complete();
    }
  }

  /// Неудача одного шага дренажа: текст экрану (как раньше) и причина — в базу,
  /// под операцию «выполнение этой задачи» экрана «Не отправлено» (#36916).
  Future<void> _noteError(Object ex) async {
    lastSyncError = '$ex';
    await noteSyncFailure(db, UnsentKind.simple, taskId, ex);
  }

  Future<void> _syncBody() async {
    do {
      _resyncRequested = false;

      // 0) сама задача (#36716) — общий барьер: пока сервер её не знает, ни снимок,
      // ни комментарий ехать не могут
      final create = await FillController.pushCreate(db, api, taskId);
      if (create.pushed) online = create.online;
      if (!create.sent) {
        lastSyncError = create.error ?? lastSyncError;
        break;
      }

      // 0b) старт — сразу за созданием и раньше снимков: они ложатся в выполнение,
      // которое он создаёт. lat/lon/createdAt берутся из строки очереди: они сняты в
      // момент начала работы, а не отправки (#36838)
      final startEntry = await db.getSimpleStartEntry(taskId);
      if (startEntry != null) {
        final ok = await _push(() async {
          await api.startSimple(taskId,
              lat: (startEntry['lat'] as num?)?.toDouble(),
              lon: (startEntry['lon'] as num?)?.toDouble(),
              at: FillController.wireAt(startEntry['createdAt'] as String));
          await db.dequeueSimpleStart(taskId);
        });
        if (!ok) break;
      }

      // 1) снимки
      var networkFailed = false;
      for (final e in await db.getPendingSimplePhotos(taskId)) {
        final idx = e['idx'] as int;
        final path = e['path'] as String?;
        try {
          String? b64;
          if (path != null) b64 = base64Encode(await File(path).readAsBytes());
          // сервер дописывает в конец, поэтому каждый снимок очереди становится там
          // своим; пустое фото (path = NULL) — команда стереть набор
          await api.setSimplePhoto(taskId, b64 ?? '');
          if (path == null) {
            await db.deleteSimplePhoto(taskId, idx);
          } else {
            await db.markSimplePhotoUploaded(taskId, idx);
          }
          online = true;
        } on ApiException catch (ex) {
          await _noteError(ex);
          online = true;
        } on FileSystemException catch (ex) {
          // файл честно пропал (очищенное хранилище) — держать строку вечно незачем
          lastSyncError = 'Файл фото недоступен: ${ex.message}';
          await db.deleteSimplePhoto(taskId, idx);
        } catch (ex) {
          await _noteError(ex);
          online = false;
          networkFailed = true;
          break;
        }
      }
      if (networkFailed) break;

      // 2) комментарий
      final queuedComment = await db.getSimpleComment(taskId);
      if (queuedComment != null) {
        final ok = await _push(() async {
          await api.setSimpleComment(
              taskId, (queuedComment['text'] as String?) ?? '');
          await db.dequeueSimpleComment(taskId);
        });
        if (!ok) break;
      }

      // 3) завершение — строго последним и только по пустым очередям: сервер
      // проверяет отчёт целиком, и «Выполнено», обогнавшее снимок, закрыло бы задачу
      // без фотографии. Отказ здесь цепочку не рвёт — это её последний шаг.
      final finishEntry = await db.getSimpleFinishEntry(taskId);
      if (finishEntry != null && await _bodyQueueCount() == 0) {
        await _push(() async {
          await api.finishSimple(taskId,
              lat: (finishEntry['lat'] as num?)?.toDouble(),
              lon: (finishEntry['lon'] as num?)?.toDouble(),
              at: FillController.wireAt(finishEntry['createdAt'] as String));
          await db.dequeueSimpleFinish(taskId);
          finished = true;
        });
      }
    } while (_resyncRequested);
  }

  /// Содержимое отчёта, ещё не ушедшее на сервер, — то, что держит завершение.
  Future<int> _bodyQueueCount() async =>
      (await db.getPendingSimplePhotos(taskId)).length +
      (await db.getSimpleComment(taskId) != null ? 1 : 0);

  /// Одна отправка: true — ушло; false — не ушло, и причина уже учтена. ApiException —
  /// сервер ответил отказом (сеть жива), всё прочее — обрыв связи.
  Future<bool> _push(Future<void> Function() send) async {
    try {
      await send();
      online = true;
      return true;
    } on ApiException catch (ex) {
      await _noteError(ex);
      online = true;
      return false;
    } catch (ex) {
      await _noteError(ex);
      online = false;
      return false;
    }
  }

  /// «Выполнено». Возвращает, можно ли считать задачу закрытой: true — сервер принял
  /// отчёт ИЛИ связи нет и завершение честно легло в очередь; false — сервер отказал,
  /// и тогда [error] несёт его причину. Сообщать об успехе, когда сервер отверг, —
  /// худший исход в поле: человек уходит с точки, а задача остаётся открытой.
  Future<bool> finish() async {
    error = null;
    if (requirePhoto && !hasPhoto) {
      error = 'Приложите фото выполненной работы';
      notifyListeners();
      return false;
    }
    // Момент нажатия — момент завершения работы: точка снимается здесь, до всякой
    // отправки, и дальше едет с завершением (#36838). После проверки фото: отказ
    // «приложите фото» GPS не трогает.
    final stamp = await _stamp();
    // Задача, чьё создание или старт ещё в очереди, завершается только через очередь:
    // сервер обязан увидеть create → start → снимки → finish в этом порядке, что бы
    // ни делала сеть. Завершение, уже лежащее в очереди (дренаж умер посередине),
    // идёт этой же веткой — прямой вызов отправил бы его вторым.
    if (await db.simpleLifecyclePending(taskId) ||
        await db.hasSimpleFinish(taskId) ||
        pendingCount > 0) {
      await db.enqueueSimpleFinish(taskId, stamp.at,
          lat: stamp.lat, lon: stamp.lon);
      await syncAll(refreshInfo: false);
      if (!await db.hasSimpleFinish(taskId)) {
        finished = true;
        online = true;
        try {
          await _refreshInfo();
        } catch (_) {}
        notifyListeners();
        return true;
      }
      if (!online) {
        // обещанное офлайн-поведение: закрыто на телефоне, уедет с сетью
        finished = true;
        notifyListeners();
        return true;
      }
      // связь есть, но что-то в цепочке отвергнуто — снять завершение из очереди и
      // сказать почему: оставить его значило бы противоречить «не удалось» на экране
      await db.dequeueSimpleFinish(taskId);
      await _refreshPending();
      error = lastSyncError != null
          ? 'Не удалось завершить: $lastSyncError'
          : 'Не удалось завершить';
      notifyListeners();
      return false;
    }
    try {
      await api.finishSimple(taskId,
          lat: stamp.lat, lon: stamp.lon, at: stamp.at);
      finished = true;
      online = true;
      try {
        await _refreshInfo();
      } catch (_) {}
      notifyListeners();
      return true;
    } on ApiException catch (e) {
      // сервер ответил отказом — показать его причину, а не «завершено»
      error = '$e';
      online = true;
      notifyListeners();
      return false;
    } catch (e) {
      // связи не стало на самом вызове — завершение уходит в очередь, как офлайн
      await db.enqueueSimpleFinish(taskId, stamp.at,
          lat: stamp.lat, lon: stamp.lon);
      finished = true;
      online = false;
      await _noteError(e);
      await _refreshPending();
      notifyListeners();
      return true;
    }
  }

  /// Снимок, который лежит только на сервере (сделан на другом устройстве): байты по
  /// требованию, миниатюрой. Офлайн вернёт null — плитка скажет «недоступно офлайн».
  Future<Uint8List?> serverPhoto(int index, {bool thumb = true}) async {
    try {
      return await api.fetchSimplePhoto(taskId, index, thumb: thumb);
    } catch (_) {
      return null;
    }
  }

  /// Дожать очереди всех задач простого выполнения — при синхронизации, не дожидаясь,
  /// пока экран откроют снова: «при возврате связи уходит» обязано случиться и у
  /// телефона в кармане.
  static Future<void> drainAll(LocalDb db, ApiClient api) async {
    for (final id in await db.getSimpleQueueTaskIds()) {
      final c = SimpleExecutionController(db: db, api: api, taskId: id);
      try {
        await c.syncAll(refreshInfo: false);
      } catch (_) {
        // база закрылась под дренажем (выход из аккаунта) — очереди целы, дожмутся
        break;
      } finally {
        c.dispose();
      }
    }
  }

  static int? _int(Object? v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse('$v');
  }

  /// «1,3» → [1, 3]. Пусто — падаем на 1..count: старый сервер строки индексов не
  /// шлёт, а без неё галерея должна хотя бы попробовать плотную нумерацию.
  static List<int> _indexes(Object? raw, int count) {
    final s = raw?.toString() ?? '';
    final parsed = [
      for (final part in s.split(','))
        if (int.tryParse(part.trim()) != null) int.parse(part.trim()),
    ];
    if (parsed.isNotEmpty) return parsed;
    return [for (var i = 1; i <= count; i++) i];
  }
}
