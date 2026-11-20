import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/fill.dart';
import 'api_client.dart';
import 'client_id.dart';
import 'execution_finish.dart';
import 'fill_controller.dart';
import 'geo.dart';
import 'local_db.dart';
import 'photo_disk_cache.dart';
import 'photo_shots.dart';
import 'sync/create_sync.dart';
import 'sync/outbox_drain.dart';
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
class SimpleExecutionController extends ChangeNotifier
    with SyncCoalescer, FinishCoalescer {
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

  /// Задача возвращена на доработку, и её последнее выполнение, по выдаче задач, —
  /// сданное (#37158): старт откроет новое (сервер — Execution.restartable). По выдаче, а
  /// не по кэшу этого экрана: кэш «выполнено» не помнит, если ответ на завершение
  /// потерялся и завершение дожал фоновый проход, — тогда старт звался бы без точки
  /// начала работы, а сданный отчёт так и выдавался бы за текущий.
  final bool restartHint;

  /// performerId вошедшего из apiCurrentUser — кем решается «этот отчёт веду не я», как
  /// у бланка (FillController.performerId): executorId выполнения сравнивается с ним, имена
  /// не уникальны. Пустой (дренаж без экрана) просмотр не включает — тому контроллеру UI нет.
  final String performerId;

  SimpleExecutionController(
      {required this.db,
      required this.api,
      required this.taskId,
      this.geo,
      this.requirePhotoHint = false,
      this.restartHint = false,
      this.performerId = ''})
      : requirePhoto = requirePhotoHint;

  /// Покадровая галерея отчёта: свои файлы и — миниатюрами с сервера — кадры, снятые
  /// на другом устройстве или до переустановки. У каждого кадра его серверный индекс,
  /// поэтому крестик удаляет ровно этот кадр. Собирает её общая с бланком сверка
  /// ([assembleShots]).
  List<FillShot> shots = [];

  /// Снимки, лежащие файлами на этом устройстве.
  List<String> get photoPaths =>
      [for (final s in shots) if (s.path != null) s.path!];

  /// Индексы снимков, которые называет сервер, без поставленных в очередь удалений.
  /// Индексы — как есть: после удаления они НЕ уплотняются, и проход «от 1 до
  /// photoCount» промахнулся бы мимо снимков за дырой.
  List<int> serverPhotoIndexes = [];
  int serverPhotoCount = 0;

  String? comment;
  String? object;
  String? name;
  String? executor;
  String? executorId;

  /// Когда заведено выполнение, о котором говорит ответ сервера, — по нему видно, что
  /// после возврата сервер завёл новое (#37158).
  String? date;
  bool requirePhoto;
  bool finished = false;

  bool loading = true;
  int pendingCount = 0;
  String? error;

  /// Отправка очередей и вердикт о сети — общая политика, см. [OutboxDrain]; причины
  /// ложатся под `simple:задача`. Замок «одна очередь дренится из одного места» и
  /// слияние повторных syncAll — [SyncCoalescer].
  late final OutboxDrain _sync =
      OutboxDrain(() => db, kind: UnsentKind.simple, taskId: taskId);

  bool get online => _sync.online;
  set online(bool v) => _sync.online = v;
  String? get lastSyncError => _sync.lastError;
  set lastSyncError(String? v) => _sync.lastError = v;

  @override
  String get syncKey => '${UnsentKind.simple}:$taskId';

  /// Снимок есть хоть где-нибудь — на устройстве или уже на сервере.
  bool get hasPhoto => shots.isNotEmpty || serverPhotoCount > 0;

  /// Отчёт ведёт другой сотрудник: задача на подразделение, и первым начал коллега. Сервер
  /// записям этого телефона отвечает 409, поэтому экран не предлагает правок, а показывает,
  /// кто ведёт отчёт, — как чужой бланк (FillController.filledByOther). По слову сервера
  /// (ответ или его кэш); пустой executorId (старый сервер) отчёт не запирает.
  bool get executedByOther =>
      executorId != null && performerId.isNotEmpty && executorId != performerId;

  /// Экран только показывает отчёт: он завершён или его ведёт другой.
  bool get viewOnly => finished || executedByOther;

  /// Кнопка «Выполнено» доступна. Требование фото проверяется ЗДЕСЬ, до отправки:
  /// ловить отказ сервера постфактум нельзя — человек к тому моменту ушёл с точки.
  /// Завершение в полёте тоже гасит кнопку: повторный тап не должен идти на сервер.
  bool get canFinish =>
      !finishing && !viewOnly && (!requirePhoto || hasPhoto);

  Future<void> load() async {
    loading = true;
    notifyListeners();
    final hadCache = await _loadFromCache();
    // Перевыполнение после возврата (#37158): старт зовётся, что бы ни помнил кэш, —
    // новое выполнение заведёт сервер (Execution.restartable), а если оно уже есть,
    // вызов пустой. Снимки прошлого раунда уйдут, когда ответ назовёт новое (_refreshInfo).
    final restart = restartHint;
    // Кэш с датой выполнения — ответ сервера, в котором выполнение уже было: старт
    // пропускается, как у бланка, — повторный вызов был бы гарантированным no-op.
    // Кэш без даты (ответ до первого старта) такого доказательства не даёт.
    final startedOnServer = date != null;
    final failure = await _sync.attempt(() async {
      // Блок достижим, когда выполнения на сервере, по кэшу, нет, или при перевыполнении:
      // этот вызов и создаёт выполнение, и координаты места должны уехать в нём (#36838).
      // Сервер пишет их только при создании, поэтому на открытиях с доказанным выполнением
      // геопозицию не меряем — жгла бы батарею ради значений, которые не запишутся.
      //
      // Без связи старт в очередь НЕ ложится: открыть экран — ещё не начать работу, и в
      // «Не отправлено» не должно появляться операции, которой человек не совершал. Точка
      // этого момента запоминается и уходит в очередь с первым действием (_queueStart).
      // Так же — задача, рождённая на этом телефоне и ещё не уехавшая: сервер её не знает,
      // прямой вызов ответил бы «not found», и старт поедет в очереди следом за созданием.
      if ((!finished || restart) &&
          (!startedOnServer || restart) &&
          !await db.simple.hasSimpleStart(taskId)) {
        final stamp = await stampNow(geo);
        if (await db.queues.simpleLifecyclePending(taskId)) {
          _pendingStart = stamp;
        } else {
          try {
            await api.startSimple(taskId,
                lat: stamp.lat, lon: stamp.lon, at: stamp.at);
          } on ApiException {
            rethrow; // сервер отказал — это показывают, а не ретраят молча
          } catch (_) {
            _pendingStart = stamp;
            // перевыполнение без связи: новый отчёт начинается здесь, а сданный
            // остаётся на сервере — старт с первым действием заведёт новое выполнение
            if (restart) await _startNewRound();
            rethrow;
          }
        }
      }
      // Своё — вперёд, чтобы ответ сервера ниже уже содержал его, а не догонял.
      await syncAll(refreshInfo: false);
      await _refreshInfo();
      error = null;
    });
    if (failure != null && !hadCache) {
      // отказ сервера — его словами (сеть жива); обрыв связи — про кэш, которого нет
      error = loadFailureText(failure,
          offline: 'Нет связи — выполнение ещё не загружалось');
    }
    loading = false;
    await _overlayQueues();
    if (!disposed) notifyListeners();
  }

  /// Состояние с сервера + всё, что лежит в очередях этого устройства. Возвращает,
  /// был ли кэш: его отсутствие — это «экран открывают впервые», и только тогда
  /// снимается точка начала работы.
  Future<bool> _loadFromCache() async {
    final c = await db.simple.getSimpleCache(taskId);
    if (c == null) {
      await _overlayQueues();
      return false;
    }
    _applyInfo(
        (jsonDecode(c['infoJson'] as String) as Map).cast<String, dynamic>());
    await _overlayQueues();
    return true;
  }

  /// Ответ сервера — в экран и кэш. Ответ назвал не то выполнение, что помнит кэш, —
  /// сервер завёл новое (перевыполнение после возврата, #37158): снимки прежнего, уехавшие
  /// с этого телефона, ему не принадлежат и уходят из очереди. Кэш без даты (ответ до
  /// первого старта) ни о каком выполнении не говорит — тогда уехавшее принадлежит
  /// нынешнему, и трогать его нельзя.
  Future<void> _refreshInfo() async {
    final info = await api.fetchSimpleInfo(taskId);
    if (disposed || info == null) return;
    final round = info['date']?.toString();
    if (date != null && round != null && round != date) await _dropSentPhotos();
    _applyInfo(info);
    await db.simple.saveSimpleInfo(taskId, jsonEncode(info));
    await _overlayQueues();
  }

  /// Перевыполнение, начатое без связи (#37158): старт уйдёт с первым действием, а экран
  /// показывает чистый отчёт. Сданный — с его снимками, комментарием и «выполнено» —
  /// остаётся на сервере историей.
  Future<void> _startNewRound() async {
    await _dropSentPhotos();
    await db.simple.deleteSimpleCache(taskId);
    finished = false;
    comment = null;
    date = null;
    serverPhotoCount = 0;
    serverPhotoIndexes = [];
  }

  /// Снимки прежнего отчёта, уже уехавшие с этого телефона: на сервере они лежат при
  /// сданном выполнении, а строки и файлы здесь больше ничего не держат. Неотправленные
  /// не трогаются — стереть их значило бы потерять работу.
  Future<void> _dropSentPhotos() async {
    for (final r in await db.simple.getSimplePhotos(taskId)) {
      if ((r['uploaded'] as int? ?? 0) == 0) continue;
      await db.simple.deleteSimplePhoto(taskId, r['idx'] as int);
      final path = r['path'] as String?;
      if (path == null) continue;
      try {
        await File(path).delete();
      } catch (_) {}
    }
  }

  void _applyInfo(Map<String, dynamic> j) {
    object = j['object']?.toString();
    name = j['name']?.toString();
    executor = j['executor']?.toString();
    executorId = j['executorId']?.toString();
    date = j['date']?.toString();
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
    await _rebuildShots();
    final queued = await db.simple.getSimpleComment(taskId);
    if (queued != null) comment = queued['text'] as String?;
    if (!finished && await db.simple.hasSimpleFinish(taskId)) finished = true;
    await _refreshPending();
  }

  /// Галерея из очереди снимков и серверных индексов — та же сверка, что у пункта
  /// бланка. Список сервера остаётся без очереди удалений: удаление, уже уехавшее, не
  /// должно вернуться плиткой до следующего ответа сервера.
  Future<void> _rebuildShots() async {
    final g = assembleShots(
        await db.simple.getSimplePhotos(taskId), serverPhotoIndexes, {
      for (final d in await db.simple.getSimplePhotoDeletes(taskId))
        d['serverIdx'] as int
    });
    for (final e in g.assigned.entries) {
      await db.simple.setSimplePhotoServerIdx(taskId, e.key, e.value);
    }
    shots = g.shots;
    serverPhotoIndexes = g.server;
    serverPhotoCount = g.server.length;
  }

  Future<void> _refreshPending() async {
    pendingCount = (await db.simple.getPendingSimplePhotos(taskId)).length +
        (await db.simple.getSimplePhotoDeletes(taskId)).length +
        (await db.simple.getSimpleComment(taskId) != null ? 1 : 0) +
        (await db.simple.hasSimpleStart(taskId) ? 1 : 0) +
        (await db.simple.hasSimpleFinish(taskId) ? 1 : 0) +
        (await db.queues.getCreateEntry(taskId) != null ? 1 : 0);
  }

  /// Старт, не ушедший при открытии (нет связи или задача ещё не создана на сервере). В
  /// очередь он ложится с первым действием человека — снимком, комментарием или
  /// «Выполнено» — и несёт точку и время ОТКРЫТИЯ, когда работа и началась (#36838).
  /// Экран, закрытый без действия, ничего не оставляет в «Не отправлено».
  ({double? lat, double? lon, String at})? _pendingStart;

  Future<void> _queueStart() async {
    final s = _pendingStart;
    if (s == null) return;
    _pendingStart = null;
    await db.simple.enqueueSimpleStart(taskId, s.at, lat: s.lat, lon: s.lon);
    await _refreshPending();
  }

  // --- снимки ---

  /// Добавить снимок: файл в каталог этого пользователя, строка в очередь, плитка на
  /// экране — в том же кадре. Каждый снимок получает свой индекс и свою строку, так
  /// что второй никогда не затирает первый ни на устройстве, ни на сервере, — и свой
  /// ключ клиента, по которому сервер узнаёт ретрай отправки (#37348).
  Future<void> addPhoto(String sourcePath) async {
    await _queueStart();
    final idx = await db.simple.nextSimplePhotoIndex(taskId);
    final clientId = newClientId();
    final saved = await _persistPhoto(sourcePath, clientId);
    await db.simple.saveSimplePhoto(taskId, idx, saved,
        DateTime.now().toIso8601String(),
        clientId: clientId);
    await _rebuildShots();
    await _refreshPending();
    notifyListeners();
    unawaited(syncAll());
  }

  /// Убрать ОДИН кадр отчёта — как кадр пункта бланка (FillController.deleteShot).
  /// Не уехавший уходит из очереди и с устройства — на сервере он не появится вовсе.
  /// Уехавший удаляется на сервере по своему индексу обычной офлайн-очередью: индексы
  /// там не уплотняются, соседние кадры остаются на своих местах.
  Future<void> deleteShot(FillShot shot) async {
    if (!shot.canDelete) return;
    final i = shot.serverIndex;
    if (i != null && (shot.uploaded || shot.path == null)) {
      await db.simple.enqueueSimplePhotoDelete(
          taskId, i, DateTime.now().toIso8601String());
      // скачанная миниатюра этого кадра больше ничего не показывает
      await evictServerPhoto(i);
    }
    if (shot.localIdx != null) {
      await db.simple.deleteSimplePhoto(taskId, shot.localIdx!);
      if (shot.path != null) {
        try {
          await File(shot.path!).delete();
        } catch (_) {}
      }
    }
    if (i != null) await _forgetPhotoInCache(i);
    await _rebuildShots();
    await _refreshPending();
    notifyListeners();
    unawaited(syncAll());
  }

  /// Убрать все снимки — одним пустым фото, а не N удалениями по индексам: сервер
  /// стирает набор целиком, и поштучные удаления после него уже не о чем.
  Future<void> clearPhotos() async {
    final rows = await db.simple.getSimplePhotos(taskId);
    // на сервере есть что стирать, если туда уехал хоть один кадр — в том числе только
    // что, фоновой отправкой: счётчик сервера про такой кадр ещё не знает
    final wasOnServer = serverPhotoCount > 0 ||
        rows.any((r) => (r['uploaded'] as int? ?? 0) != 0);
    // скачанные миниатюры набора больше ничего не показывают: нумерация на сервере
    // начнётся заново, и прежний файл по индексу 1 выдал бы себя за новый кадр
    for (final s in shots) {
      if (s.serverIndex != null) await evictServerPhoto(s.serverIndex!);
    }
    shots = [];
    serverPhotoCount = 0;
    serverPhotoIndexes = [];
    for (final r in rows) {
      await db.simple.deleteSimplePhoto(taskId, r['idx'] as int);
    }
    await db.simple.clearSimplePhotoDeletes(taskId);
    if (wasOnServer) {
      // пустое фото — команда серверу стереть весь набор
      await db.simple.saveSimplePhoto(
          taskId, 0, null, DateTime.now().toIso8601String());
      await _forgetPhotoInCache(null);
    }
    for (final r in rows) {
      final path = r['path'] as String?;
      if (path == null) continue;
      try {
        await File(path).delete();
      } catch (_) {}
    }
    await _refreshPending();
    notifyListeners();
    unawaited(syncAll());
  }

  /// Вычеркнуть удалённый кадр из кэша ответа сервера — как у бланка: очередь держит
  /// его вне галереи, пока удаление не уедет, а кэш снят до удаления, и офлайн-экран
  /// вернул бы кадр плиткой «недоступно офлайн». [index] = null — весь набор.
  Future<void> _forgetPhotoInCache(int? index) async {
    final c = await db.simple.getSimpleCache(taskId);
    if (c == null) return;
    try {
      final j = (jsonDecode(c['infoJson'] as String) as Map)
          .cast<String, dynamic>();
      final left = index == null
          ? const <int>[]
          : [
              for (final i
                  in _indexes(j['photoIndexes'], _int(j['photoCount']) ?? 0))
                if (i != index) i
            ];
      j['photoIndexes'] = left.join(',');
      j['photoCount'] = left.length;
      await db.simple.saveSimpleInfo(taskId, jsonEncode(j));
    } catch (_) {
      // кэш — оптимизация: испорченный он чинится следующим ответом сервера
    }
  }

  /// Индекс, который сервер даст только что отправленному кадру, — см.
  /// [nextServerIndex]. Что сервер называл в последний раз — по кэшу его ответа: так
  /// одинаково и у экрана, и у дренажа без экрана, который ответа не читал.
  Future<int> _nextServerIndex() async {
    var server = const <int>[];
    final c = await db.simple.getSimpleCache(taskId);
    if (c != null) {
      try {
        final j = (jsonDecode(c['infoJson'] as String) as Map)
            .cast<String, dynamic>();
        server = _indexes(j['photoIndexes'], _int(j['photoCount']) ?? 0);
      } catch (_) {}
    }
    return nextServerIndex(server, await db.simple.getSimplePhotos(taskId), [
      for (final d in await db.simple.getSimplePhotoDeletes(taskId))
        d['serverIdx'] as int
    ]);
  }

  /// Снимки живут там же, где снимки бланка: один каталог на пользователя, который
  /// целиком стирается при выходе «с удалением данных» (FillController.photoDirectory).
  /// Имя — по ключу кадра, а не по индексу очереди: индекс после удаления последнего
  /// кадра достаётся следующему, и картинка, закэшированная по тому же пути, показала
  /// бы удалённый снимок вместо нового.
  Future<String> _persistPhoto(String sourcePath, String clientId) async {
    final dir = await FillController.photoDirectory(db.userKey);
    if (!await dir.exists()) await dir.create(recursive: true);
    final dest = p.join(dir.path, '${taskId}_simple_$clientId.jpg');
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
    await _queueStart();
    await db.simple.enqueueSimpleComment(
        taskId, trimmed, DateTime.now().toIso8601String());
    await _refreshPending();
    notifyListeners();
    unawaited(syncAll());
  }

  // --- синхронизация ---

  /// Дожать очереди этой задачи. Слияние повторных вызовов и замок — в
  /// [SyncCoalescer]; [refreshInfo] — перечитать ли после чистого прохода
  /// состояние с сервера (load() делает это сам и не просит).
  Future<void> syncAll({bool refreshInfo = true}) =>
      runSync(refresh: refreshInfo);

  @override
  Future<void> afterSync(bool refresh) async {
    await _refreshPending();
    if (pendingCount == 0) lastSyncError = null;
    if (refresh && pendingCount == 0 && online) {
      try {
        await _refreshInfo();
      } catch (_) {}
    }
  }

  /// Один проход по очередям: порядок шагов — здесь; что делать с ответом
  /// сервера — в [OutboxDrain]. Барьеры — создание и старт; комментарий тоже
  /// держит цепочку: за ним только завершение, которому без принятого отчёта
  /// ехать нельзя.
  @override
  Future<void> drainPass() async {
    // 0) сама задача (#36716) — общий барьер: пока сервер её не знает, ни снимок,
    // ни комментарий ехать не могут
    if (!await TaskCreateSync.push(db, api, taskId, via: _sync)) return;

    // 0b) старт — сразу за созданием и раньше снимков: они ложатся в выполнение,
    // которое он создаёт. lat/lon/createdAt берутся из строки очереди: они сняты в
    // момент начала работы, а не отправки (#36838)
    final startEntry = await db.simple.getSimpleStartEntry(taskId);
    if (startEntry != null) {
      final started = await _sync.one(() async {
        await api.startSimple(taskId,
            lat: (startEntry['lat'] as num?)?.toDouble(),
            lon: (startEntry['lon'] as num?)?.toDouble(),
            at: wireAt(startEntry['createdAt'] as String));
        await db.simple.dequeueSimpleStart(taskId);
      });
      if (started != SendOutcome.sent) return;
    }

    // 1) снимки
    if (!await _sync.each(await db.simple.getPendingSimplePhotos(taskId), (e) async {
      final idx = e['idx'] as int;
      final path = e['path'] as String?;
      String? b64;
      if (path != null) b64 = base64Encode(await File(path).readAsBytes());
      // сервер дописывает в конец, поэтому каждый снимок очереди становится там
      // своим; повтор той же отправки сервер узнаёт по ключу клиента и вторым кадром
      // не пишет (#37348), строки старой очереди едут без ключа, как раньше; пустое
      // фото (path = NULL) — команда стереть набор
      await api.setSimplePhoto(taskId, b64 ?? '',
          clientId: e['clientId'] as String?);
      if (path == null) {
        await db.simple.deleteSimplePhoto(taskId, idx);
        // набор на сервере пуст — нумерация начнётся заново с единицы
        serverPhotoIndexes = [];
        serverPhotoCount = 0;
      } else {
        final serverIdx = await _nextServerIndex();
        if (await db.simple.markSimplePhotoUploaded(taskId, idx,
                serverIdx: serverIdx) ==
            0) {
          // Кадр убрали, пока он ехал: удаление сочло его неотправленным и стёрло
          // строку, а на сервере он уже лёг — удалить его там по индексу (шаг 1b)
          await db.simple.enqueueSimplePhotoDelete(
              taskId, serverIdx, DateTime.now().toIso8601String());
        }
        await _rebuildShots();
      }
    }, onFileError: (e, ex) async {
      // файл честно пропал (очищенное хранилище) — держать строку вечно незачем
      lastSyncError = 'Файл фото недоступен: ${ex.message}';
      await db.simple.deleteSimplePhoto(taskId, e['idx'] as int);
    })) {
      return;
    }

    // 1b) удаления отдельных кадров — ПОСЛЕ загрузок, как у бланка: сервер нумерует
    // новый снимок «максимум + 1», и удаление, обогнавшее отправку, освободило бы
    // номер, который отправитель уже посчитал своим. Повтор по уже удалённому индексу
    // сервер глотает.
    if (!await _sync.each(await db.simple.getSimplePhotoDeletes(taskId),
        (e) async {
      final serverIdx = e['serverIdx'] as int;
      await api.deleteSimplePhoto(taskId, serverIdx);
      await db.simple.dequeueSimplePhotoDelete(taskId, serverIdx);
    })) {
      return;
    }

    // 2) комментарий
    final queuedComment = await db.simple.getSimpleComment(taskId);
    if (queuedComment != null) {
      final sent = await _sync.one(() async {
        await api.setSimpleComment(
            taskId, (queuedComment['text'] as String?) ?? '');
        await db.simple.dequeueSimpleComment(taskId,
            createdAt: queuedComment['createdAt'] as String);
      });
      if (sent != SendOutcome.sent) return;
    }

    // 3) завершение — строго последним и только по пустым очередям: сервер
    // проверяет отчёт целиком, и «Выполнено», обогнавшее снимок, закрыло бы задачу
    // без фотографии. Отказ здесь цепочку не рвёт — это её последний шаг.
    final finishEntry = await db.simple.getSimpleFinishEntry(taskId);
    if (finishEntry != null && await _bodyQueueCount() == 0) {
      await _sync.one(() async {
        await api.finishSimple(taskId,
            lat: (finishEntry['lat'] as num?)?.toDouble(),
            lon: (finishEntry['lon'] as num?)?.toDouble(),
            at: wireAt(finishEntry['createdAt'] as String));
        await db.simple.dequeueSimpleFinish(taskId);
        finished = true;
      });
    }
  }

  /// Содержимое отчёта, ещё не ушедшее на сервер, — то, что держит завершение.
  Future<int> _bodyQueueCount() async =>
      (await db.simple.getPendingSimplePhotos(taskId)).length +
      (await db.simple.getSimplePhotoDeletes(taskId)).length +
      (await db.simple.getSimpleComment(taskId) != null ? 1 : 0);

  /// «Выполнено». Возвращает, можно ли считать задачу закрытой: true — сервер принял
  /// отчёт ИЛИ связи нет и завершение честно легло в очередь; false — сервер отказал,
  /// и тогда [error] несёт его причину. Сообщать об успехе, когда сервер отверг, —
  /// худший исход в поле: человек уходит с точки, а задача остаётся открытой.
  /// Повторные нажатия сливает [FinishCoalescer].
  @override
  Future<bool> finishOnce() async {
    error = null;
    if (requirePhoto && !hasPhoto) {
      error = 'Приложите фото выполненной работы';
      notifyListeners();
      return false;
    }
    // Момент нажатия — момент завершения работы: точка снимается здесь, до всякой
    // отправки, и дальше едет с завершением (#36838). После проверки фото: отказ
    // «приложите фото» GPS не трогает.
    final stamp = await stampNow(geo);
    // старт, отложенный при открытии без связи, ложится в очередь раньше завершения
    await _queueStart();
    // Задача, чьё создание или старт ещё в очереди, завершается только через очередь:
    // сервер обязан увидеть create → start → снимки → finish в этом порядке, что бы
    // ни делала сеть. Завершение, уже лежащее в очереди (дренаж умер посередине),
    // идёт этой же веткой — прямой вызов отправил бы его вторым.
    Future<void> enqueue() => db.simple
        .enqueueSimpleFinish(taskId, stamp.at, lat: stamp.lat, lon: stamp.lon);
    if (await db.queues.simpleLifecyclePending(taskId) ||
        await db.simple.hasSimpleFinish(taskId) ||
        pendingCount > 0) {
      switch (await finishViaQueue(
          drain: _sync,
          enqueue: enqueue,
          sync: () => syncAll(refreshInfo: false),
          stillQueued: () => db.simple.hasSimpleFinish(taskId),
          dequeue: () => db.simple.dequeueSimpleFinish(taskId))) {
        case FinishOutcome.accepted:
          finished = true;
          try {
            await _refreshInfo();
          } catch (_) {}
          notifyListeners();
          return true;
        case FinishOutcome.queuedOffline:
          finished = true;
          notifyListeners();
          return true;
        case FinishOutcome.refused:
          await _refreshPending();
          error = lastSyncError != null
              ? 'Не удалось завершить: $lastSyncError'
              : 'Не удалось завершить';
          notifyListeners();
          return false;
      }
    }
    final direct = await finishDirect(
        drain: _sync,
        call: () => api.finishSimple(taskId,
            lat: stamp.lat, lon: stamp.lon, at: stamp.at),
        enqueue: enqueue);
    switch (direct.outcome) {
      case FinishOutcome.refused:
        // сервер ответил отказом или сбоем — показать причину, а не «выполнено»
        error = failureReason(direct.refusal!);
        notifyListeners();
        return false;
      case FinishOutcome.queuedOffline:
        // связи не стало на самом вызове — завершение ушло в очередь, как офлайн
        finished = true;
        await _refreshPending();
        notifyListeners();
        return true;
      case FinishOutcome.accepted:
        finished = true;
        try {
          await _refreshInfo();
        } catch (_) {}
        notifyListeners();
        return true;
    }
  }

  /// Снимок, которого на этом устройстве нет (сделан на другом или до переустановки):
  /// миниатюра для галереи, полный размер по тапу. Качается один раз на экран, с диска
  /// прошлого раза не берётся — индекс освобождается вместе с удалённым кадром и
  /// достаётся следующему (как FillController.serverPhotoFile). Офлайн — null, плитка
  /// скажет «недоступно офлайн».
  late final PhotoDiskCache _serverPhotos =
      PhotoDiskCache(() => FillController.serverPhotoDirectory(db.userKey));

  Future<File?> serverPhotoFile(int index, {required bool thumb}) =>
      _serverPhotos.file(_serverPhotoName(index, thumb),
          () => api.fetchSimplePhoto(taskId, index, thumb: thumb),
          reuseDisk: false);

  /// Кадр удалён или его байты не декодировались — оба размера с диска долой.
  Future<void> evictServerPhoto(int index) => _serverPhotos.evict(
      [_serverPhotoName(index, true), _serverPhotoName(index, false)]);

  String _serverPhotoName(int index, bool thumb) =>
      'srv_${taskId}_simple_$index${thumb ? '_t' : ''}.jpg';

  /// Дожать очереди всех задач простого выполнения — при синхронизации, не дожидаясь,
  /// пока экран откроют снова: «при возврате связи уходит» обязано случиться и у
  /// телефона в кармане.
  static Future<void> drainAll(LocalDb db, ApiClient api) async {
    for (final id in await db.simple.getSimpleQueueTaskIds()) {
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
