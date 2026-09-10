import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../models/quick_create.dart';
import '../models/task.dart';
import '../models/task_status.dart';
import '../models/task_view.dart';
import 'api_client.dart';
import 'client_id.dart' as ids;
import 'geo.dart';
import 'local_db.dart';
import 'location_controller.dart';
import 'session.dart';
import 'settings.dart';
import 'sync/outbox_drain.dart';
import 'task_file_controller.dart';
import 'unsent.dart';
import 'user_base.dart';

/// Offline-first repository. Reads always come from the local DB, so the app is
/// fully usable without connectivity. Writes (status changes) are recorded in an
/// outbox and pushed to the server opportunistically (immediately if online,
/// otherwise on the next reconnect / manual sync).
///
/// Здесь — список задач и то, что ложится на него из очередей: статусы, взятия,
/// снимки, рождённые на телефоне задачи. Остальное живёт рядом и читает список отсюда:
/// вход и выход — AccountController, место — [LocationController], главная и
/// пресеты — HomeController, лента — NotificationsController, дренаж чужих очередей
/// и расписание синхронизации — SyncCoordinator. Собирает их вместе AppControllers.
class TaskRepository extends ChangeNotifier {
  final ApiClient api;
  final Session session;
  final Settings settings;
  final Geo geo;

  /// База вошедшего — одна на всех, кто в ней живёт: список читает из неё задачи и
  /// свои очереди, остальные — своё, по [UserBase.onChange].
  final UserBase base;

  /// Где человек стоит: задачи делятся на «здесь» и «не здесь» ([TaskView.elsewhere]),
  /// и у сервера список спрашивается под этот объект.
  final LocationController location;

  /// Отправка очередей статусов и взятий и вердикт о сети — общая политика, см.
  /// [OutboxDrain]; экземпляр общий с [LocationController]: «сервер не ответил, кто
  /// рядом» и «сервер не принял статус» зажигают один и тот же баннер.
  final OutboxDrain drain;

  /// Кого позвать, когда в очереди жизненного цикла легло новое — созданная задача,
  /// снимок к существующей: эти очереди дренит SyncCoordinator, здесь только просьба
  /// «толкни, если сеть есть».
  Future<void> Function()? pushLocalTasks;

  TaskRepository(
      {required this.api,
      required this.settings,
      required this.session,
      required this.base,
      required this.location,
      required this.drain,
      required this.geo}) {
    base.onChange(_onBase);
  }

  /// For the screens, which only exist under a signed-in user. Reading it with nobody
  /// signed in is a bug in the caller, not a state to handle.
  LocalDb get db =>
      base.db ?? (throw StateError('no local database: nobody is signed in'));

  /// То же, но без исключения — для виджетов, которые могут оказаться построенными,
  /// когда базы нет (сессия умерла под открытой карточкой): им честнее нарисовать
  /// пустое место, чем уронить экран.
  LocalDb? get localDb => base.db;

  /// Всё, что назначено этому человеку, — включая задачи других объектов (#36837).
  /// Задачи объекта, на котором он стоит, идут первыми, остальные — ниже по
  /// расстоянию и помечены [TaskView.elsewhere]: видеть можно всё, работать — на месте.
  List<TaskView> tasks = const [];

  List<TaskStatus> statuses = const [];

  /// Очередь отправки как список операций (#36916) — то, что рисует экран
  /// «Не отправлено», с человеческими названиями и причинами последних неудач.
  /// Пересобирается каждым [_reload], так что бейдж и экран всегда согласны.
  List<UnsentOp> unsentOps = const [];

  /// Число операций в очереди — оно же на бейдже шапки. Ровно [unsentOps.length]:
  /// человек, открывший экран по бейджу «3», должен увидеть три строки.
  int pendingCount = 0;

  bool loading = false;

  bool syncing = false;

  bool get online => drain.online;

  /// Вердикт о сети меняется и без похода в очередь — слушателем сети; экраны с
  /// баннером «офлайн» узнают об этом отсюда.
  set online(bool v) {
    drain.online = v;
    notifyListeners();
  }

  String? error; // last network error (for the offline banner / snackbar)

  /// База сменилась (вход, выход, другой сервер): сообщение о проигранной гонке —
  /// про задачу ушедшего, следующему его не показывают. Сам список перечитывает не
  /// хук, а тот, кто базу сменил, — [reloadLocal] после того, как все прочитали своё.
  Future<void> _onBase(LocalDb? db) async {
    takeNotice = null;
  }

  TaskStatus? statusById(String? id) {
    if (id == null) return null;
    for (final s in statuses) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// Задача по любому из её адресов: ST-номер или UUID, которым рождённая на
  /// телефоне задача зовётся всю жизнь (бланк и очереди ключуются им и после того,
  /// как сервер выдал ей номер). Null — задачи в списке больше нет.
  TaskView? viewOf(String taskId) {
    for (final v in tasks) {
      if (v.id == taskId || v.task.clientId == taskId) return v;
    }
    return null;
  }

  /// Задача не того объекта, где человек стоит, — для аккаунта с обязательной
  /// геолокацией она видна, но только для чтения (#36837). Считается локально и
  /// мгновенно: смена объекта в шапке и отъезд перекрашивают список в том же кадре,
  /// без сервера — положение телефона меняется между синхронизациями, и серверному
  /// флагу здесь верить нельзя.
  ///
  /// A role excused from geolocation works from anywhere, and there is no object for
  /// them to be standing at — nothing is elsewhere for them.
  bool _elsewhere(Task t) => session.geoRequired && !location.place.holds(t);

  /// Rebuild the in-memory view from the local DB (tasks + statuses + outbox),
  /// applying the outbox status overlay. Nothing is filtered by assignee here: `apiTasks`
  /// only ever sends the signed-in user's tasks, so what is cached is already theirs.
  /// И по месту не фильтруется тоже (#36837): задачи чужих объектов остаются в списке
  /// с пометкой «только для чтения» — сортировка ниже ставит их после задач «здесь».
  ///
  /// Задачи, рождённые на телефоне, несут свои метки поверх той же строки кэша: пока
  /// создание в очереди — «не синхронизировано», пока в очереди финиш — «завершена, не
  /// отправлена» и closed, чтобы завершённая в подвале проверка не считалась просроченной.
  Future<void> _reload() async {
    final db = base.db;
    if (db == null) {
      // signed out: what is on the screen belongs to the person who has just left, and the
      // next one must not find it waiting for them
      tasks = const [];
      statuses = const [];
      unsentOps = const [];
      pendingCount = 0;
      notifyListeners();
      return;
    }
    final all = await db.tasks.getTasks();
    final outbox = await db.tasks.getOutbox();
    final creating = await db.queues.getCreateTaskIds();
    final starting = await db.queues.getStartTaskIds();
    final finishing = await db.queues.getFinishTaskIds();
    final takes = {
      for (final r in await db.tasks.getTakeOutbox())
        r['taskId'] as String: r['action'] as String
    };
    // переписка (#36844): сводка кэша лент и своя очередь — поверх серверных чисел
    final commentStats = await db.comments.commentStats();
    final commentQueue = <String, int>{};
    for (final r in await db.comments.getAllCommentOutbox()) {
      final id = r['taskId'] as String;
      commentQueue[id] = (commentQueue[id] ?? 0) + 1;
    }
    statuses = await db.tasks.getStatuses();

    tasks = all.map((t) {
      // очереди рождённой на телефоне задачи всю жизнь ключуются её UUID, а строка
      // кэша после первой синхронизации несёт уже ST-номер — метки ищутся по обоим,
      // иначе завершённая офлайн проверка «открывалась» бы обратно после refresh
      final cid = t.clientId;
      bool inQ(Set<String> q) =>
          q.contains(t.id) || (cid != null && q.contains(cid));
      final ob = outbox[t.id] ?? (cid == null ? null : outbox[cid]);
      final statusId = ob?.statusId ?? t.statusId;
      final done = inQ(finishing);
      final closed = done || (statusById(statusId)?.closed ?? false);

      // Группа — по серверным флагам, поверх которых кладётся только СВОЯ очередь
      // взятий: mine не пересобирается из takenById/assigneeId (#36751). Строка без
      // единого из новых ключей пришла со старого сервера или рождена на телефоне —
      // такая выдача вся назначена лично, то есть «мои».
      final takeAction = takes[t.id];
      final taking = takeAction == 'take';
      final releasing = takeAction == 'release';
      final legacy =
          t.mine == null && t.takenById == null && t.canTake == null;
      // авторская-и-только — отдельная группа (#36844): взять её нельзя (сервер не
      // шлёт canTake), «моей» она не бывает, а в «свободные» или «взяты коллегами»
      // ей нечего делать — это не пул моего подразделения
      final authoredOnly = t.authoredOnly;
      // наблюдаемая-и-только (#37135) — тоже своя группа, и проверяется ДО legacy:
      // серверных ключей взятия у такой строки нет (mine, canTake считаются от
      // назначения), и по legacy она уехала бы в «Мои», разойдясь с плиткой главной
      final watchedOnly = t.watchedOnly;
      final TaskGroup group;
      if (authoredOnly) {
        group = TaskGroup.authored;
      } else if (watchedOnly) {
        group = TaskGroup.watched;
      } else if (taking) {
        group = TaskGroup.mine;
      } else if (releasing) {
        group = TaskGroup.free;
      } else if (t.mine == true || legacy) {
        group = TaskGroup.mine;
      } else if (t.takenById != null) {
        group = TaskGroup.taken;
      } else {
        group = TaskGroup.free;
      }

      // кэш ленты и очередь рождённой на телефоне задачи ключуются её UUID — как
      // бланк; строка после синхронизации несёт ST-номер, ищем по обоим
      final cached = commentStats[t.id] ??
          (cid == null ? null : commentStats[cid]);
      final queued = (commentQueue[t.id] ?? 0) +
          (cid == null || cid == t.id ? 0 : (commentQueue[cid] ?? 0));
      final (commentCount, unreadComments) = _commentCounts(t, cached, queued);

      return TaskView(
        t,
        statusId,
        done
            ? 'Завершена — не отправлена'
            : (ob == null ? t.status : (ob.statusName ?? t.status)),
        ob != null || inQ(creating) || inQ(starting) || done || releasing,
        closed: closed,
        locallyFinished: done,
        takenById: taking
            ? session.performerId
            : (releasing ? null : t.takenById),
        takenBy: taking
            ? (session.name.isEmpty ? session.login : session.name)
            : (releasing ? null : t.takenBy),
        takenAt: taking || releasing ? null : t.takenAt,
        canTake: t.canTake == true && takeAction == null && !closed,
        takePending: taking,
        releasable: taking ||
            (takeAction == null &&
                t.takenById != null &&
                t.takenById == session.performerId &&
                !closed),
        elsewhere: _elsewhere(t),
        authoredOnly: authoredOnly,
        watchedOnly: watchedOnly,
        commentCount: commentCount,
        unreadComments: unreadComments,
        group: group,
      );
    }).toList();

    // Задачи объекта, где человек стоит, — сверху, остальные ниже по расстоянию:
    // список читается как маршрут, а не как алфавит (#36837). Внутри «здесь» и при
    // равных расстояниях порядок серверной выдачи сохраняется — sort() нестабилен,
    // поэтому исходный индекс дотягивается до компаратора явно.
    final order = {for (var i = 0; i < tasks.length; i++) tasks[i]: i};
    tasks.sort((a, b) {
      if (a.elsewhere != b.elsewhere) return a.elsewhere ? 1 : -1;
      if (a.elsewhere) {
        final da = a.task.distance, db = b.task.distance;
        if (da != db) {
          // без расстояния (объект без координат) — в самый конец: ехать «неизвестно
          // куда» предлагают после всех известных адресов
          if (da == null) return 1;
          if (db == null) return -1;
          final byDistance = da.compareTo(db);
          if (byDistance != 0) return byDistance;
        }
      }
      return order[a]!.compareTo(order[b]!);
    });

    // Все очереди, а не только видимые списку (#36916): ответ бланка и снимок,
    // ждущие в подвале, — такие же «не отправлено», как смена статуса. Считаются
    // операциями, а не строками таблиц: бейдж «3» обещает три строки на экране.
    unsentOps = await loadUnsentOps(db);
    pendingCount = unsentOps.length;
    notifyListeners();
  }

  /// Счётчики переписки для строки списка (#36844). Сервер сказал своё на момент
  /// fetch; телефон знает больше про «сейчас»: что прочитал (местная отметка, ещё не
  /// ушедшая) и что написал (очередь). Непрочитанное — меньшее из серверного и
  /// местного, пока кэш ленты не отстал от сервера (в кэше не меньше сообщений, чем
  /// сервер насчитал): прочитанное офлайн гасит бейдж сразу, прочитанное с другого
  /// телефона — тоже, а отставший кэш верит серверу — его число и зовёт префетч.
  static (int, int) _commentCounts(Task t, CommentStats? cached, int queued) {
    final serverCount = t.commentCount ?? 0;
    final serverUnread = t.unreadComments ?? 0;
    var count = serverCount;
    var unread = serverUnread;
    if (cached != null) {
      if (cached.total > count) count = cached.total;
      if (cached.total >= serverCount) unread = min(cached.unread, serverUnread);
    }
    return (count + queued, unread);
  }

  /// Перечитать локальное состояние без сети: лента комментариев сообщает сюда, что
  /// прочитала или отправила что-то, и бейджи на карточках должны сойтись с ней в том
  /// же кадре.
  Future<void> reloadLocal() => _reload();

  /// Pull the latest tasks + statuses from the server into the local cache.
  Future<void> refresh() async {
    if (!settings.isConfigured) {
      error = 'Не настроено подключение';
      notifyListeners();
      return;
    }
    final db = base.db;
    if (!session.isActive || db == null) return;
    loading = true;
    error = null;
    notifyListeners();
    final failure = await drain.attempt(() async {
      final fetched = await api.fetchTasks(
          lat: location.place.latitude, lon: location.place.longitude, objectId: location.place.objectId);
      final st = await api.fetchStatuses();
      // Сервер с #36837 отдаёт всё назначенное, где бы человек ни стоял, поэтому
      // спрашивать можно и «ниоткуда» — в дороге список нужнее всего. Единственное
      // исключение: старый сервер на «ниоткуда» отвечал пустым списком, и пустой
      // ответ без выбранного объекта кэш не затирает — у нового сервера он означал
      // бы «задач нет вообще», и почти пустой кэш переживёт это расхождение до
      // первого located-fetch.
      if (fetched.isNotEmpty ||
          !session.geoRequired ||
          location.place.objectId != null) {
        await db.tasks.replaceTasks(fetched);
      }
      if (st.isNotEmpty) await db.tasks.replaceStatuses(st);
    });
    if (failure is SessionExpiredException) {
      // the session is already cleared — the app root will show the login screen
      error = 'Сессия истекла — войдите заново';
    } else if (failure is ApiException) {
      error = 'Не удалось обновить список: $failure';
    } else if (failure != null) {
      error = 'Нет связи с сервером — показаны сохранённые данные';
    }
    loading = false;
    await _reload();
  }

  /// Change a task's status: record it locally (instant, offline-safe) and try
  /// to push right away.
  Future<void> setStatus(String taskId, TaskStatus status) async {
    final db = base.db;
    if (db == null) return;
    await db.tasks.enqueue(
        taskId, status.id, status.name, DateTime.now().toIso8601String());
    await _reload();
    unawaited(syncOutbox());
  }

  /// Drain the outbox to the server, oldest first. Stops on the first network
  /// failure and keeps the remaining entries for a later retry.
  ///
  /// Only ever the signed-in person's own queue: the base being drained is theirs, and
  /// nobody else's entries are reachable from it — which is what keeps one worker's change
  /// from reaching the server under another worker's account.
  Future<void> syncOutbox() async {
    final db = base.db;
    if (syncing || !session.isActive || db == null) return;
    syncing = true;
    notifyListeners();
    try {
      final outbox = await db.tasks.getOutbox();
      // барьер #36716: статус задачи, чьё создание ещё не уехало, не отправляется —
      // он ушёл бы к серверу, который такой задачи не знает. И статус задачи с
      // застрявшим finish тоже придерживается: иначе он обгонит завершение, и 'done'
      // финиша перезапишет его — хронология пользователя инвертируется. Записи
      // остаются в очереди и уйдут заходом после того, как drainLocalTasks дожмёт.
      final creating = await db.queues.getCreateTaskIds();
      final finishing = await db.queues.getFinishTaskIds();
      final ready = [
        for (final e in outbox.values)
          if (!creating.contains(e.taskId) && !finishing.contains(e.taskId)) e
      ];
      // отказ по статусу одной задачи её строку оставляет, а следующие едут; обрыв
      // связи оставляет в очереди всё до следующего захода
      final go = await drain.each(ready, (entry) async {
        await api.setStatus(entry.taskId, entry.statusId);
        await db.tasks.updateTaskStatus(
            entry.taskId, entry.statusId, entry.statusName);
        await db.tasks.dequeue(entry.taskId);
      },
          kind: UnsentKind.status,
          taskOf: (e) => e.taskId,
          onRefused: (_, e) => error = 'Не удалось синхронизировать: $e');
      if (!go) _noteStop();
    } finally {
      syncing = false;
      await _reload();
    }
  }

  /// Цепочка остановилась: обрыв связи — «не удалось синхронизировать» с причиной;
  /// потеря сессии свой текст уже поставила (onSessionLost), и очередь переживёт
  /// перевход.
  void _noteStop() {
    if (drain.lastFailure is SessionExpiredException) return;
    error = 'Не удалось синхронизировать: ${drain.lastError}';
  }

  // --- взятие задачи из пула подразделения (#36836) ---

  /// Проигранная гонка за задачу — с именем и временем того, кто успел. Показывается
  /// полосой на списке и главной до явного закрытия: перестановка строки в «взяты
  /// коллегами» не должна быть тихой. Хранится одно, последнее: конфликт — редкость,
  /// и очередь из них — уже не сообщение, а журнал.
  String? takeNotice;

  void dismissTakeNotice() {
    takeNotice = null;
    notifyListeners();
  }

  /// Взять задачу на себя: намерение — строкой в очередь (мгновенно и офлайн-безопасно,
  /// как смена статуса), список перестраивается в этом же кадре, отправка — следом.
  Future<void> takeTask(String taskId) async {
    final db = base.db;
    if (db == null) return;
    await db.tasks.enqueueTake(taskId, 'take', DateTime.now().toIso8601String());
    await _reload();
    unawaited(syncTakes());
  }

  /// Снять с себя — тем же путём. Поверх ещё не ушедшего взятия строка очереди просто
  /// заменяется: это и есть «откат снимает пометку и ничего больше» — ответы бланка не
  /// трогаются нигде, а снятие невзятой задачи сервер отвечает пустым 200.
  Future<void> releaseTask(String taskId) async {
    final db = base.db;
    if (db == null) return;
    await db.tasks.enqueueTake(taskId, 'release', DateTime.now().toIso8601String());
    await _reload();
    unawaited(syncTakes());
  }

  Future<void>? _takesRun;

  /// Дренаж очереди взятий — старейшая запись первой, с перечитыванием очереди после
  /// каждой: пока запись была в полёте, человек мог передумать (REPLACE строки на
  /// противоположное действие), и ответ обогнанного взятия не должен снести намерение,
  /// записанное позже него, — сверку по action делает dequeueTake.
  ///
  /// Возвращает именно ИДУЩИЙ проход, когда он есть: «await syncTakes() вернулся»
  /// всегда означает «попытка отправки состоялась» — запись, легшая в очередь до
  /// вызова, этим проходом уже видна (очередь перечитывается на каждом шаге).
  Future<void> syncTakes() {
    final running = _takesRun;
    if (running != null) return running;
    final run = _syncTakesBody().whenComplete(() => _takesRun = null);
    _takesRun = run;
    return run;
  }

  Future<void> _syncTakesBody() async {
    if (!session.isActive || base.db == null) return;
    try {
      // очередь перечитывается после каждой записи (eachNext): пока запись была в
      // полёте, человек мог передумать (REPLACE строки на противоположное
      // действие), и ответ обогнанного взятия не должен снести намерение,
      // записанное позже него, — сверку по action делает dequeueTake
      LocalDb? db;
      final go = await drain.eachNext(() async {
        db = base.db; // вышли из аккаунта прямо под дренажем — очередь кончилась
        final rows = await db?.tasks.getTakeOutbox();
        return rows == null || rows.isEmpty ? null : rows.first;
      }, (entry) async {
        final local = db!;
        final id = entry['taskId'] as String;
        final action = entry['action'] as String;
        final refusal = action == 'take'
            ? await api.takeTask(id)
            : await api.releaseTask(id);
        if (refusal == null) {
          // принято. Строка кэша приводится к подтверждённому состоянию до
          // dequeue — между ними её не успеет перезаписать параллельный fetch, и
          // задача не мигнёт прежней группой до следующего refresh
          if (action == 'take') {
            await local.tasks.updateTaskTake(id,
                takenById: session.performerId,
                takenBy: session.name.isEmpty ? session.login : session.name,
                takenAt: DateTime.now().toIso8601String(),
                mine: true,
                canTake: false);
          } else {
            // снятая мной вернулась в пул: раз сервер снятие принял, взять её
            // можно снова — это его же canTake, каким он был до взятия
            await local.tasks.updateTaskTake(id,
                takenById: null,
                takenBy: null,
                takenAt: null,
                mine: false,
                canTake: true);
          }
        } else {
          // задачу держит другой (409, а у снятия и 403 notOwner): строка
          // переезжает в «взяты коллегами» с именем и временем успевшего, человеку
          // — заметное сообщение. Ответы бланка не трогаются: «взял» на сервере —
          // координация, а не блокировка.
          if (refusal.takenById != null) {
            await local.tasks.updateTaskTake(id,
                takenById: refusal.takenById,
                takenBy: refusal.takenBy,
                takenAt: refusal.takenAt,
                mine: false,
                canTake: false);
          }
          _noteTakeRefusal(id, refusal);
        }
        await local.tasks.dequeueTake(id, action);
      }, kind: UnsentKind.take, taskOf: (e) => e['taskId'] as String);
      // отказ сервера без адресата (500 «Take failed» и т.п.) — запись остаётся,
      // повтор взятия безопасен и уйдёт следующим циклом
      if (!go) _noteStop();
    } catch (_) {
      // база закрылась прямо под дренажем (выход из аккаунта): очередь цела в
      // sqlite и дожмётся следующим входом — тихо прерваться лучше, чем уронить
      // unawaited-цепочку unhandled-исключением
    } finally {
      await _reload();
    }
  }

  /// «Задачу уже взял Иванов, 10:42» — а не «не получилось».
  void _noteTakeRefusal(String taskId, TakeRefusal refusal) {
    String? name;
    for (final v in tasks) {
      if (v.id == taskId) {
        name = v.task.name ?? v.task.object;
        break;
      }
    }
    final what = name == null ? 'Задачу' : 'Задачу «$name»';
    if (refusal.takenBy == null && refusal.takenById == null) {
      takeNotice = refusal.message ?? '$what взять не удалось';
      return;
    }
    final when = _takenAtText(refusal.takenAt);
    takeNotice = '$what уже взял ${refusal.takenBy ?? 'другой сотрудник'}'
        '${when == null ? '' : ', $when'}';
  }

  /// Время взятия для сообщения: сегодняшнее — часами, старше — с датой.
  static String? _takenAtText(String? iso) {
    if (iso == null) return null;
    final t = DateTime.tryParse(iso);
    if (t == null) return null;
    final now = DateTime.now();
    final hhmm = '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}';
    final sameDay =
        t.year == now.year && t.month == now.month && t.day == now.day;
    return sameDay
        ? hhmm
        : '${t.day.toString().padLeft(2, '0')}.'
            '${t.month.toString().padLeft(2, '0')} $hhmm';
  }

  // --- снимки задачи (#36914) ---

  /// Снимки этой задачи, ещё не уехавшие: карточка рисует их рядом с приехавшими,
  /// с пометкой «ожидает отправки». Пусто, если базы нет (сессия закрылась).
  Future<List<({String clientId, String path})>> pendingTaskPhotos(
      String taskId) async {
    final db = base.db;
    if (db == null) return const [];
    try {
      return [
        for (final r in await db.queues.getTaskFileOutbox(taskId))
          (clientId: r['clientId'] as String, path: r['path'] as String)
      ];
    } catch (_) {
      // база закрылась под чтением (выход из аккаунта, смена сервера) — карточке
      // это уже неинтересно, она сейчас исчезнет вместе с сессией
      return const [];
    }
  }

  /// Приложить снимок к существующей задаче — без комментария: строка в очередь
  /// (мгновенно и офлайн-безопасно), кадр виден на карточке в том же кадре, отправка —
  /// следом. Задача, ещё не уехавшая сама, кадру не помеха: очередь адресуется её
  /// UUID'ом, а дренаж держит порядок «создание → снимки».
  Future<void> attachTaskPhoto(String taskId, String photoPath) async {
    final db = base.db;
    if (db == null) return;
    await TaskFilesController.attach(db, taskId, photoPath);
    notifyListeners();
    unawaited(pushLocalTasks?.call());
  }

  /// Убрать снимок, который ещё не уехал (передумал до отправки): строка из очереди и
  /// файл с диска — на сервере он не появится и места в телефоне не займёт.
  Future<void> discardTaskPhoto(String clientId) async {
    final db = base.db;
    if (db == null) return;
    await TaskFilesController.discard(db, clientId);
    notifyListeners();
  }

  // --- задачи, рождённые на телефоне (#36716) ---

  /// UUID v4 — ключ клиента для задачи, создаваемой на месте (генератор общий с
  /// сообщениями ленты, см. data/client_id.dart).
  static String newClientId() => ids.newClientId();

  static String _isoDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// Родить задачу прямо в магазине — целиком локально, сети здесь нет и не ждут:
  /// строка в списке, тело apiCreateTask в очереди, а для бланочного пресета — ещё
  /// отложенный старт и бланк, посеянный из предзагруженного шаблона, чтобы экран
  /// заполнения открылся немедленно. Возвращает UUID задачи: им она адресуется всю
  /// жизнь, даже после того как сервер выдаст ей ST-номер.
  ///
  /// Кадры автора (#36914) копируются в каталог файлов этого пользователя и ложатся
  /// в очередь снимков той же транзакцией, что и сама задача; уезжают они СЛЕДОМ за
  /// apiCreateTask, своей ручкой и каждый со своим ключом идемпотентности. Исходные
  /// файлы из галереи/камеры не трогаем — они живут в кэше приложения.
  /// Параметры задачи, а не пресет: этим же путём создаётся задача, собранная AI
  /// (#AI-1), а у неё пресета нет и быть не может. Всё, что раньше бралось из пресета,
  /// вызывающий передаёт явно — типом, бланком, приоритетом и требованием фото.
  ///
  /// [clientId] задаётся только когда ключ уже родился раньше: у AI это ключ разговора,
  /// по которому сервер связывает созданную задачу с запросом. Обычное создание ключ
  /// минтит само.
  ///
  /// [startFilling] — открывать ли бланк сразу: внезапная проверка так и делается, а
  /// поручение, собранное AI, уходит в чужой список, и заполнять там нечего.
  ///
  /// [template] — шаблон под [templateCode] из предзагруженного кэша, если он там есть:
  /// им сеется форма, чтобы экран заполнения открылся офлайн. Его отсутствие не
  /// отменяет сам бланк у задачи: код всё равно уезжает на сервер, и с ближайшей
  /// синхронизацией форма приедет. Кэш пресетов держит HomeController, поэтому шаблон
  /// приходит параметром, а не ищется здесь.
  Future<String> createTask({
    required String typeId,
    required String objectId,
    required String name,
    String? templateCode,
    PresetTemplate? template,
    String? priorityId,
    bool requirePhoto = false,
    // вид выполнения — с сервера (#36872), и параметром, а не из пресета: у задачи,
    // собранной AI, пресета нет. Не задан — Task.opensFill падает на прежний список
    // типов, ровно то поведение, что было до #36872.
    String? executionKind,
    String? objectName,
    String? objectAddress,
    DateTime? deadline,
    String? description,
    List<String> photoPaths = const [],
    String? assigneeId,
    String? assigneeName,
    String? clientId,
    bool startFilling = true,
  }) async {
    final db = this.db;
    final uuid = clientId ?? newClientId();
    final now = DateTime.now();

    final payload = <String, dynamic>{
      'clientId': uuid,
      'typeId': typeId,
      'objectId': objectId,
      'name': name,
      // дата с телефона, не дата синхронизации: задача, созданная офлайн три дня
      // назад, должна выглядеть созданной три дня назад — от этого считается просрочка
      'created': _isoDate(now),
      if (templateCode != null) 'templateId': templateCode,
      if (assigneeId != null) 'assigneeId': assigneeId,
      if (deadline != null) 'deadline': _isoDate(deadline),
      if (priorityId != null) 'priorityId': priorityId,
      if (description != null && description.isNotEmpty)
        'description': description,
      if (requirePhoto) 'requirePhoto': true,
    };

    final photos = <String, String>{};
    for (final path in photoPaths) {
      final (clientId, stored) =
          await TaskFilesController.storePhoto(db.userKey, path);
      photos[clientId] = stored;
    }

    // Бланочная задача начинает выполняться этим же жестом — её очередь старта несёт
    // точку момента создания (#36838): человек рождает задачу, стоя у витрины, и это
    // и есть место начала работы, какой бы ни была сеть. Без фикса координаты честно
    // пусты — создание из-за GPS не задерживается дольше [Geo.fixTimeout] и не
    // блокируется вовсе.
    final fillNow = startFilling && template != null;
    GeoFix? startFix;
    if (fillNow) {
      final outcome = await geo.locate();
      if (outcome is GeoFix) startFix = outcome;
    }

    final task = Task(
      id: uuid,
      clientId: uuid,
      name: name,
      object: objectName,
      objectId: objectId,
      address: objectAddress,
      typeId: typeId,
      // вид выполнения — с сервера (#36872): без него задача, рождённая в подвале,
      // не открылась бы ничем до первой синхронизации, а именно её и надо выполнить
      // здесь и сейчас
      executionKind: executionKind,
      requirePhoto: requirePhoto ? true : null,
      status: 'Ожидает отправки',
      assignedTo: assigneeName ??
          (session.name.isEmpty ? session.login : session.name),
      assigneeId: assigneeId ?? session.performerId,
      // участие (#36844): рождённая мной задача — авторская; назначенная не мне
      // ложится в «Поставленные мной» сразу, не дожидаясь серверных флагов
      authored: true,
      assigned: assigneeId == null || assigneeId == session.performerId,
      deadline: deadline == null ? null : _isoDate(deadline),
      // dueToday/overdue сознательно пусты (#36944): серверной даты у телефона нет и
      // взяться ей неоткуда, поэтому до первой синхронизации срок рождённой здесь
      // задачи читается от даты устройства — тем же откатом, что и у старого сервера
    );

    await db.queues.createLocalTask(
      task,
      payloadJson: jsonEncode(payload),
      photos: photos,
      createdAtIso: now.toIso8601String(),
      queueStart: fillNow,
      startLat: startFix?.latitude,
      startLon: startFix?.longitude,
      seedFieldsJson: template == null ? null : jsonEncode(template.fieldsRaw),
      seedOptionsJson:
          template == null ? null : jsonEncode(template.optionsRaw),
      seedColumnsJson:
          template == null ? null : jsonEncode(template.columnsRaw),
      seedInfoJson: template == null
          ? null
          : jsonEncode({
              'object': objectName,
              'template': template.name ?? template.code,
              'resolutionRequired': template.resolutionRequired,
              'finished': false,
              'total': template.fields.length,
            }),
    );
    await _reload(); // карточка видна в том же кадре — это и есть «сразу в списке»
    unawaited(pushLocalTasks?.call()); // а если сеть есть — уезжает немедленно
    return uuid;
  }
}
