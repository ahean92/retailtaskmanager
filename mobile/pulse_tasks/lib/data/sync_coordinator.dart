import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import 'account_controller.dart';
import 'api_client.dart';
import 'comment_controller.dart';
import 'fill_controller.dart';
import 'home_controller.dart';
import 'local_db.dart';
import 'location_controller.dart';
import 'notifications_controller.dart';
import 'past_fill_controller.dart';
import 'session.dart';
import 'settings.dart';
import 'simple_controller.dart';
import 'task_file_cache.dart';
import 'task_file_controller.dart';
import 'task_repository.dart';
import 'user_base.dart';

/// Когда и в каком порядке телефон разговаривает с сервером: полный цикл «толкнуть
/// очереди — забрать свежее» ([syncAndRefresh]), дренаж очередей, которыми владеют
/// другие контроллеры (бланки, поручения, переписка, снимки), префетчи в кэш,
/// автоповтор с нарастающей паузой (#36916), слушатель сети и таймеры. Сами очереди
/// живут у своих хозяев; здесь — только их порядок и повод проснуться.
///
/// Единственный, кто знает всех остальных: реакции на их события — новое место, вход,
/// выбранный объект, легшая в очередь задача — подписываются в конструкторе.
class SyncCoordinator extends ChangeNotifier {
  final ApiClient api;
  final Session session;
  final Settings settings;
  final UserBase base;
  final TaskRepository repo;
  final LocationController location;
  final HomeController home;
  final NotificationsController notifications;
  final AccountController account;

  /// Бренд заказчика — единственное, что тянется без входа; как его применить, знает
  /// AppearanceController в слое экранов, сюда он приходит функцией.
  final Future<void> Function() refreshBrand;

  SyncCoordinator(
      {required this.api,
      required this.session,
      required this.settings,
      required this.base,
      required this.repo,
      required this.location,
      required this.home,
      required this.notifications,
      required this.account,
      required this.refreshBrand}) {
    repo.pushLocalTasks = drainLocalTasks;
    // новое место — новый список: из кэша сейчас, с сервера — следом, не задерживая
    // дверь (locate) и выбор соседа
    location.onPlaceChanged = () async {
      await repo.reloadLocal();
      unawaited(syncAndRefresh());
    };
    home.onObjectSelected = prefetchPastChecks;
    account.onSignedIn = () async {
      unawaited(refreshBrand());
      unawaited(syncAndRefresh());
    };
  }

  Timer? _notifTimer;

  /// Автоповтор очереди (#36916): тик каждые полминуты, попытка — по расписанию
  /// нарастающих пауз. Состояние здесь, решения — в [_retryTick].
  Timer? _retryTimer;

  DateTime? _nextRetryAt;

  int _retryStep = 0;

  /// Последняя ошибка дренажа локально-созданных задач — то, что сервер ОТВЕРГ, а не
  /// «нет связи». Показывается баннером главной: у поручения нет другого экрана, где
  /// человек узнал бы, что его задача не уезжает. Чистый дрейн сбрасывает в null.
  String? syncError;

  StreamSubscription<List<ConnectivityResult>>? _connSub;

  /// Приложение поднято, база вошедшего открыта и список из неё прочитан: включить
  /// слушатель сети, забрать то, что дёшево, и запустить таймеры.
  Future<void> start() async {
    try {
      // connectivity_plus 6.x emits a list of active transports; empty or
      // [none] means offline.
      _connSub = Connectivity().onConnectivityChanged.listen((results) {
        final nowOnline =
            results.any((r) => r != ConnectivityResult.none);
        final wasOffline = !repo.online;
        repo.online = nowOnline; // notifies
        if (nowOnline && wasOffline) {
          unawaited(syncAndRefresh());
        }
      });
    } catch (_) {
      // connectivity_plus unavailable (e.g. desktop/test) — ignore, offline
      // detection then falls back to failed network calls.
    }
    // the brand is answered without authentication, so it can already dress the login
    // screen; everything else waits until somebody is actually signed in
    if (settings.isConfigured) {
      unawaited(refreshBrand());
      if (session.isActive) {
        unawaited(home.refreshHome());
        // уведомления не ждут геогейта: лента — не про «где я стою»
        unawaited(notifications.refresh());
        // и регистрация телефона тоже: токен FCM ротируется сам (переустановка,
        // очистка данных, восстановление из бэкапа), и реестр на сервере должен
        // догонять его на каждом запуске, а не хранить позавчерашний
        unawaited(account.registerDevice());
        // For an account that works by location the gate pulls the list, because only it
        // knows which object to pull it for — asking here as well would be two fetches
        // racing to cache the same tasks. What the screen opens with meanwhile is what
        // reloadLocal() has already taken out of this person's base.
        if (location.geoReady) unawaited(syncAndRefresh());
      }
    }
    // «появляется само, без ручного обновления»: лента перечитывается раз в минуту,
    // пока приложение открыто, — уведомление, доехавшее за минуту, на демо от пуша
    // неотличимо. Гварды внутри notifications.refresh: без адреса или входа тик пустой.
    _notifTimer = Timer.periodic(
        const Duration(seconds: 60), (_) => unawaited(notifications.refresh()));
    // повтор с паузой, а не молчание (#36916): непустая очередь пробуется сама,
    // с нарастающей паузой — сервер, отвечавший 500 при живой сети, иначе держал бы
    // очередь до ручного жеста. Гварды и расписание — в _retryTick.
    _retryTimer = Timer.periodic(
        const Duration(seconds: 30), (_) => unawaited(_retryTick()));
  }

  @override
  void dispose() {
    _connSub?.cancel();
    _notifTimer?.cancel();
    _retryTimer?.cancel();
    super.dispose();
  }

  /// Push pending changes, then pull fresh data. The home screen rides along: its numbers
  /// are as perishable as the task list, and a pull-to-refresh that updates one but not
  /// the other would leave the two halves of the same screen disagreeing.
  /// Пресеты создания едут этим же циклом: их смысл — оказаться на телефоне заранее,
  /// и «заранее» — это каждая синхронизация, а не отдельная кнопка. Каталог объектов
  /// (#37047) — тоже, но фоном и только при смене версии: он нужен не главной, а
  /// выбору объекта на ней без сети.
  ///
  /// Рождённые на телефоне задачи дожимаются первыми (#36716): их создание — барьер и
  /// для их статусов в syncOutbox, и для честного refresh — сервер, уже принявший
  /// задачу, вернёт её в fetched, и локальная строка схлопнется с серверной.
  /// Взятия уезжают до refresh: fetch, пришедший позже ответа взятия, уже несёт его
  /// результат, и группировка не мигает.
  Future<void> syncAndRefresh() async {
    // ручной жест обнуляет расписание автоповтора: «отправить сейчас» — это сейчас,
    // а не «когда истечёт пауза», и после него отсчёт пауз начинается заново
    _nextRetryAt = null;
    _retryStep = 0;
    await pushPending();
    await repo.refresh();
    await home.refreshHome();
    await home.refreshQuickCreate();
    await home.refreshExternalApps();
    await home.refreshAi();
    await notifications.refresh();
    // не awaited: спиннер pull-to-refresh не должен ждать догрузку истории, лент,
    // миниатюр и каталога объектов
    unawaited(prefetchPastChecks());
    unawaited(prefetchComments());
    unawaited(prefetchTaskPhotos());
    unawaited(home.refreshCatalog());
  }

  /// Толкнуть все очереди без перечитывания серверных данных — «отправить» без
  /// «обновить». Порядок тот же, что в [syncAndRefresh], и по той же причине:
  /// создание — барьер для всего по задаче, взятия должны обгонять fetch.
  Future<void> pushPending() async {
    await drainLocalTasks();
    // переписка — после задач: сообщение к задаче, чьё создание ещё едет, ждёт его
    await drainComments();
    await repo.syncTakes();
    await repo.syncOutbox();
  }

  /// Паузы автоповтора (#36916), секунды: очередь, не ушедшая с попытки, пробуется
  /// реже и реже — до потолка в пять минут. Появление сети и ручной жест вне
  /// расписания: первое толкает очередь само (listener в [start]), второй обнуляет
  /// отсчёт ([syncAndRefresh]).
  static const _retryPauses = [30, 60, 120, 300];

  Future<void> _retryTick() async {
    if (!session.isActive || base.db == null || repo.syncing || repo.loading) return;
    if (repo.unsentOps.isEmpty) {
      // очередь ушла (этим повтором или любым другим путём) — отсчёт пауз заново
      _nextRetryAt = null;
      _retryStep = 0;
      return;
    }
    final now = DateTime.now();
    if (_nextRetryAt != null && now.isBefore(_nextRetryAt!)) return;
    final before = repo.unsentOps.length;
    await pushPending();
    if (repo.unsentOps.isEmpty) {
      _nextRetryAt = null;
      _retryStep = 0;
      return;
    }
    // продвинулись — паузы с начала (сервер ожил, дожмём скоро); повторная неудача
    // подряд — пауза растёт. Первая неудача после сброса — короткая пауза целиком.
    if (repo.unsentOps.length < before) {
      _retryStep = 0;
    } else if (_nextRetryAt != null && _retryStep < _retryPauses.length - 1) {
      _retryStep++;
    }
    _nextRetryAt = now.add(Duration(seconds: _retryPauses[_retryStep]));
  }

  /// Дожать неотправленные сообщения и отметки прочтения всех задач (#36844) — см.
  /// TaskCommentsController.drainAll. Задачи с ещё не уехавшим созданием пропускаются:
  /// их сообщения пойдут следующим заходом, когда drainLocalTasks дожмёт создание.
  Future<void> drainComments() async {
    final db = base.db;
    if (!session.isActive || db == null) return;
    try {
      await TaskCommentsController.drainAll(db, api,
          skip: await db.queues.getCreateTaskIds());
    } catch (_) {
      // база закрылась под дренажем (выход из аккаунта) — очередь цела в sqlite
    }
    await repo.reloadLocal();
  }

  /// Миниатюры снимков задач — в кэш заранее (#36842): «карточка открывается и в
  /// самолётном режиме» означает и фотографию проблемы, а её из подвала не скачать.
  /// Только миниатюры (256 по длинной стороне) и только те, которых на диске ещё нет;
  /// полный размер по-прежнему едет по явному тапу.
  ///
  /// Потолок на проход — чтобы синхронизация после недели офлайна не превратилась в
  /// мегабайты по мобильной сети. Недокачанное не теряется: остаток заберёт следующая
  /// синхронизация, а открытая карточка и так качает своё по требованию. Тихий, как
  /// prefetchComments: ошибка оставляет прежний кэш.
  Future<void> prefetchTaskPhotos({int limit = 40}) async {
    try {
      final db = base.db;
      if (!session.isActive || db == null) return;
      final cache = TaskFileCache(userKey: db.userKey, api: api);
      var budget = limit;
      for (final v in repo.tasks) {
        final t = v.task;
        for (final id in [
          for (final f in t.files)
            if (f.image) f.id,
          for (final e in t.executions)
            if (e.photoId != null) e.photoId!,
        ]) {
          if (budget <= 0) return;
          if (await TaskFileCache.hasThumb(db.userKey, id)) continue;
          budget--;
          // null — сеть пропала посреди догрузки: продолжать бессмысленно, остальные
          // ответят тем же, а следующая синхронизация начнёт с того же места
          if (await cache.file(id, thumb: true) == null) return;
        }
      }
    } catch (_) {
      // база закрылась под префетчем (выход из аккаунта) — очередной вход догонит
    }
  }

  /// Ленты задач — в кэш заранее (#36844): переписку читают там же, где заполняют
  /// бланк, часто без сети, и лента, доступная только онлайн, бесполезна именно там.
  /// Сеть трогается лишь там, где серверный счётчик разошёлся с кэшем (новое
  /// сообщение, удалённое на десктопе, ленту ещё не забирали) — одна ручка на такую
  /// задачу и ноль на остальные. Тихий, как prefetchPastChecks.
  Future<void> prefetchComments() async {
    try {
      final db = base.db;
      if (!session.isActive || db == null) return;
      final stats = await db.comments.commentStats();
      var changed = false;
      for (final v in repo.tasks) {
        final t = v.task;
        // рождённая на телефоне задача всю жизнь адресуется своим UUID — как бланк
        final key = t.clientId ?? t.id;
        final cached = stats[key] ?? stats[t.id];
        final serverCount = t.commentCount ?? 0;
        if (cached == null && serverCount == 0) continue;
        if (cached != null && cached.total == serverCount) continue;
        await TaskCommentsController.prefetch(db, api, key);
        changed = true;
      }
      if (changed) await repo.reloadLocal();
    } catch (_) {
      // база закрылась под префетчем (выход из аккаунта) — очередной вход догонит
    }
  }

  /// Прошлые проверки кэшируются вместе с задачами (#36778): человек в поле бывает
  /// без сети, и история, доступная только онлайн, бесполезна именно там, где
  /// нужна. Пять ручек на задачу — не бесплатно, поэтому сеть трогается только для
  /// задач с открывавшимся бланком (без fill_cache офлайн-бланк всё равно не
  /// открыть, и просмотр из него — тоже), у которых прошлая проверка есть и стала
  /// новее кэша просмотра. Ошибки тихие: дрейн общий с выходом из аккаунта, и
  /// закрывшаяся под ним база не должна ронять unawaited-цепочку.
  Future<void> prefetchPastChecks() async {
    try {
      final db = base.db;
      if (!session.isActive || db == null) return;
      for (final v in repo.tasks) {
        final t = v.task;
        if (!t.opensFill) continue;
        // задача, рождённая на телефоне, всю жизнь адресуется своим UUID — как её
        // бланк и очереди (см. TaskDetailScreen)
        final key = t.clientId ?? t.id;
        if (await _pastCacheStale(db, key)) {
          await PastFillController.prefetch(db, api, taskId: key);
        }
      }
      final obj = home.objectId;
      if (obj != null) {
        await PastFillController.prefetch(db, api, objectId: obj);
      }
      await home.refreshObjectPastLine(); // notifies
    } catch (_) {
      // база закрылась под префетчем (выход из аккаунта) — очередной вход догонит
    }
  }

  /// Кэш просмотра прошлой проверки задачи пора обновлять, когда шапка её бланка
  /// (fill_cache, обновляется каждым онлайн-открытием) называет прошлую проверку
  /// НОВЕЕ той, что лежит в кэше просмотра. Строго «новее», а не «не равна»: после
  /// перепроверки объекта кэш просмотра обновляется первым, и до переоткрытия
  /// бланка даты честно расходятся в другую сторону — «не равна» гоняла бы пять
  /// ручек каждую синхронизацию до скончания века.
  Future<bool> _pastCacheStale(LocalDb db, String key) async {
    final fill = await db.fill.getFillCache(key);
    if (fill == null) return false; // бланк не открывали — кэшировать нечего и незачем
    try {
      final prevDate = ((jsonDecode((fill['infoJson'] as String?) ?? '{}')
              as Map)['prevDate'])
          ?.toString();
      if (prevDate == null || prevDate.isEmpty) {
        return false; // по бланку прошлых нет — пустой кэш просмотра не нужен
      }
      final past = await db.cache.getPastFillCache('task', key);
      if (past == null) return true;
      final pastDate = ((jsonDecode((past['infoJson'] as String?) ?? '{}')
              as Map)['date'])
          ?.toString();
      return pastDate == null || prevDate.compareTo(pastDate) > 0;
    } catch (_) {
      return true;
    }
  }

  /// Дожать до сервера задачи, рождённые на телефоне, — не дожидаясь, пока их экран
  /// откроют снова: «после появления связи уезжает на сервер» обязано случиться и у
  /// телефона, лежащего в кармане. Каждая задача дренится своим контроллером — там
  /// написан порядок create → start → ответы → фото → finish и там же живёт замок,
  /// который не даёт открытому экрану и этому проходу толкать одну очередь вдвоём.
  Future<void> drainLocalTasks() async {
    final db = base.db;
    if (!session.isActive || db == null) return;
    final ids = await db.queues.getLifecycleTaskIds();
    // снимки задач (#36914) — своя очередь и свой повод проснуться: фото, досланное к
    // задаче, которая давно на сервере, никаких шагов жизненного цикла не заводит
    final photos = await db.queues.getAllTaskFileOutbox();
    if (ids.isEmpty && photos.isEmpty) return;
    String? firstError;
    for (final id in ids) {
      final c = FillController(db: db, api: api, taskId: id);
      try {
        await c.syncAll(refreshSummary: false);
        // интересен именно отказ сервера (online остался true): обрыв связи и так
        // виден офлайн-баннером, дублировать его текстом ошибки незачем
        if (firstError == null && c.online) firstError = c.lastSyncError;
      } catch (_) {
        // база могла закрыться прямо под дрейном (выход из аккаунта, смена сервера,
        // 401 → onSessionLost): очереди целы в sqlite и дожмутся следующим входом —
        // тихо прерваться лучше, чем уронить unawaited-цепочку unhandled-исключением
        break;
      } finally {
        c.dispose();
      }
    }
    // отчёты простого выполнения (#36872) — своими очередями и своим контроллером:
    // «уедет при связи» обещано и снимку поручения, а не только ответу бланка. После
    // цикла выше: создание задачи — общий барьер, и дренаж бланка его уже дожал.
    try {
      await SimpleExecutionController.drainAll(db, api);
    } catch (_) {
      // база закрылась под дренажем (выход из аккаунта) — очереди целы в sqlite
    }
    // снимки задач (#36914) — последними: создание им барьер (файл к задаче, которой
    // сервер не знает, ехать не может), а цикл выше его только что дожал
    try {
      final photoError =
          await TaskFilesController.drainAll(db, api, skip: await db.queues.getCreateTaskIds());
      firstError ??= photoError;
    } catch (_) {
      // база закрылась под дренажем — очередь цела в sqlite
    }
    // отказ сервера (например, отвергнутое создание) без этого не всплывал бы нигде:
    // у поручения нет экрана бланка, где виден lastSyncError
    syncError = firstError == null ? null : 'Не синхронизировано: $firstError';
    notifyListeners();
    await repo.reloadLocal();
  }
}
