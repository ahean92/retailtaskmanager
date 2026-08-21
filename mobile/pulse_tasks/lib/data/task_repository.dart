import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../ui/brand.dart';
import '../ui/theme.dart';

import '../models/fill.dart';
import '../models/home.dart';
import '../models/notification.dart';
import '../models/place.dart';
import '../models/quick_create.dart';
import '../models/task.dart';
import '../models/task_status.dart';
import 'api_client.dart';
import 'fill_controller.dart';
import 'geo.dart';
import 'local_db.dart';
import 'password_hash.dart';
import 'past_fill_controller.dart';
import 'push_service.dart';
import 'session.dart';
import 'settings.dart';

/// Группы списка задач (#36836). Порядок объявления — порядок на экране: сверху то,
/// ради чего человек открыл приложение; «взяты коллегами» сворачиваются, но не
/// исчезают — задача, пропавшая из списка без объяснения, читается как потеря данных.
enum TaskGroup {
  mine('Мои'),
  free('Свободные'),
  taken('Взяты коллегами');

  final String title;
  const TaskGroup(this.title);
}

/// A task as shown in the UI: the cached server snapshot plus the *effective*
/// status (an unsynced outbox change overrides the server status) and a flag
/// telling whether a change is still pending sync.
class TaskView {
  final Task task;
  final String? statusId; // effective
  final String? statusName; // effective
  final bool pending;

  /// Effective closedness — the outbox status wins here too, so a task the worker has
  /// just marked done stops counting as overdue before the server has heard about it.
  final bool closed;

  /// Завершена на телефоне, но finish ещё в очереди. Отдельно от [closed]: closed
  /// бывает и от смены статуса, которую человек вправе передумать, а по этой метке
  /// экран задачи гасит переключатель статусов — статус не должен обгонять финиш.
  final bool locallyFinished;

  /// Кто держит задачу — серверный ответ с наложенной очередью взятий: пока моё
  /// взятие не подтверждено, здесь уже я; пока не уехало снятие — уже никто.
  final String? takenById;
  final String? takenBy;
  final String? takenAt;

  /// Кнопка «Взять». Право считает только сервер (canTake из apiTasks) — здесь оно
  /// лишь гасится локальными оговорками: очередь по задаче, локально закрытая.
  final bool canTake;

  /// Взятие в очереди и сервером ещё не подтверждено — строка несёт явную пометку
  /// «ожидает подтверждения»: за эту задачу ещё могут поспорить.
  final bool takePending;

  /// «Снять с себя» имеет смысл: задача взята мной (или взятие ещё в очереди).
  final bool releasable;

  /// Задача другого объекта — видна, но только для чтения (#36837): исполнитель с
  /// обязательной геолокацией не может начать выполнение, заполнять бланк, завершать
  /// и менять статус, пока не стоит на объекте задачи. Всё, что работой не является
  /// (карточка, история, взятие на себя), остаётся доступным.
  ///
  /// Решает телефон, а не сервер, — сравнением объекта задачи с [Place.objectId]:
  /// положение меняется между синхронизациями, и серверный вердикт протух бы в
  /// кармане по дороге. Пока объект не определён, чужое всё: показать «можно всюду»
  /// значило бы снять гео-гейт первым же сбоем GPS.
  final bool elsewhere;

  final TaskGroup group;

  const TaskView(this.task, this.statusId, this.statusName, this.pending,
      {this.closed = false,
      this.locallyFinished = false,
      this.takenById,
      this.takenBy,
      this.takenAt,
      this.canTake = false,
      this.takePending = false,
      this.releasable = false,
      this.elsewhere = false,
      this.group = TaskGroup.mine});

  String get id => task.id;

  /// Past its deadline and still open. A closed task is never overdue — the deadline
  /// stopped mattering the moment the work was done.
  bool get overdue {
    final d = task.deadlineDate;
    if (closed || d == null) return false;
    final now = DateTime.now();
    return d.isBefore(DateTime(now.year, now.month, now.day));
  }

  bool get dueToday {
    final d = task.deadlineDate;
    if (closed || d == null) return false;
    final now = DateTime.now();
    return d == DateTime(now.year, now.month, now.day);
  }
}

/// The task lists the home screen can drill into. Mirrors HomeTaskFilter on the server;
/// an unknown value falls back to «all», because a newer server offering a filter this
/// build does not know is not a reason to show nothing.
/// «Выполненные» is deliberately absent: `apiTasks` only ever sends open tasks, so such
/// a filter would always show an empty list.
enum TaskFilter {
  all('Все задачи'),
  open('Открытые'),
  today('На сегодня'),
  overdue('Просроченные');

  final String title;
  const TaskFilter(this.title);

  static TaskFilter parse(String? code) => switch (code) {
        'open' => TaskFilter.open,
        'today' => TaskFilter.today,
        'overdue' => TaskFilter.overdue,
        _ => TaskFilter.all,
      };

  bool matches(TaskView v) => switch (this) {
        TaskFilter.all => true,
        TaskFilter.open => !v.closed,
        TaskFilter.today => v.dueToday,
        TaskFilter.overdue => v.overdue,
      };
}

/// Why a sign-in failed, in a sentence the person on shift can act on. Three causes get
/// three messages: a single «Ошибка: ...» with a stack trace in it tells them nothing about
/// whether to retype the password, walk towards the window, or call the office.
class LoginException implements Exception {
  final String message;
  LoginException(this.message);
  @override
  String toString() => message;
}

/// Offline-first repository. Reads always come from the local DB, so the app is
/// fully usable without connectivity. Writes (status changes) are recorded in an
/// outbox and pushed to the server opportunistically (immediately if online,
/// otherwise on the next reconnect / manual sync).
class TaskRepository extends ChangeNotifier {
  final ApiClient api;
  final Session session;
  final Geo geo;
  Settings settings;

  /// Пуш (#36720). Необязателен: тестам и сборке без конфигурации Firebase он не нужен,
  /// а вход и выход обязаны работать одинаково с ним и без него. Держится здесь, потому
  /// что регистрация телефона привязана к сессии, а сессией распоряжается репозиторий.
  final PushService? push;

  TaskRepository(
      {required this.api,
      required this.settings,
      required this.session,
      this.push,
      Geo? geo})
      : geo = geo ?? Geo();

  /// The local base of whoever is signed in, and nothing at all while nobody is: the file
  /// is named after the identity (see [LocalDb.keyFor]), so without one there is nothing
  /// to open — and, just as much to the point, nothing of the previous person's left open.
  LocalDb? _db;

  /// For the screens, which only exist under a signed-in user. Reading it with nobody
  /// signed in is a bug in the caller, not a state to handle.
  LocalDb get db =>
      _db ?? (throw StateError('no local database: nobody is signed in'));

  /// Всё, что назначено этому человеку, — включая задачи других объектов (#36837).
  /// Задачи объекта, на котором он стоит, идут первыми, остальные — ниже по
  /// расстоянию и помечены [TaskView.elsewhere]: видеть можно всё, работать — на месте.
  List<TaskView> tasks = const [];
  List<TaskStatus> statuses = const [];
  HomeLayout home = const HomeLayout();

  /// Лента уведомлений — последние 30 дней с сервера, новые сверху (#36717). Без
  /// локального кэша: журнал держит сервер, а офлайн экран честно показывает
  /// последнее полученное за этот запуск.
  List<NotificationItem> notifications = const [];

  /// Счётчик для бейджа считает клиент: полный список у него и так есть, отдельная
  /// ручка ради одного числа не нужна.
  int get unreadCount {
    var n = 0;
    for (final it in notifications) {
      if (!it.viewed) n++;
    }
    return n;
  }

  Timer? _notifTimer;

  /// Что этот человек может создать прямо в магазине, вместе со справочниками под это
  /// (шаблоны, исполнители). Пустое — кнопки «создать» нет; наполняется настройкой в
  /// бэк-офисе, без пересборки клиента.
  QuickCreateData quickCreate = const QuickCreateData();

  /// Where the app thinks the person is, and who else is nearby. Loaded from their base
  /// on the way in, so an app reopened without a signal knows which object it is showing.
  Place place = const Place();

  int pendingCount = 0;
  bool loading = false;
  bool syncing = false;

  /// Последняя ошибка дренажа локально-созданных задач — то, что сервер ОТВЕРГ, а не
  /// «нет связи». Показывается баннером главной: у поручения нет другого экрана, где
  /// человек узнал бы, что его задача не уезжает. Чистый дрейн сбрасывает в null.
  String? syncError;

  /// A location is being taken right now — the header's «Обновить» is spinning.
  bool locating = false;
  bool online = true;
  String? error; // last network error (for the offline banner / snackbar)

  StreamSubscription<List<ConnectivityResult>>? _connSub;

  Future<void> init() async {
    api.onSessionLost = () {
      error = 'Сессия истекла — войдите заново';
      notifyListeners(); // the app root watches this and swaps in the login screen
      // A session dying mid-work is a way out of the app like any other, so the base closes
      // with it: whoever signs in at the form that comes up must not find the previous
      // person's tasks still cached behind it. The session itself is already gone —
      // `ApiClient` cleared it before calling this.
      unawaited(_bindDb().then((_) => _reload()));
    };
    await _bindDb(); // opens the signed-in person's base and their home screen with it
    await _reload();
    try {
      // connectivity_plus 6.x emits a list of active transports; empty or
      // [none] means offline.
      _connSub = Connectivity().onConnectivityChanged.listen((results) {
        final nowOnline =
            results.any((r) => r != ConnectivityResult.none);
        final wasOffline = !online;
        online = nowOnline;
        notifyListeners();
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
        unawaited(refreshHome());
        // уведомления не ждут геогейта: лента — не про «где я стою»
        unawaited(refreshNotifications());
        // и регистрация телефона тоже: токен FCM ротируется сам (переустановка,
        // очистка данных, восстановление из бэкапа), и реестр на сервере должен
        // догонять его на каждом запуске, а не хранить позавчерашний
        unawaited(push?.register() ?? Future.value());
        // For an account that works by location the gate pulls the list, because only it
        // knows which object to pull it for — asking here as well would be two fetches
        // racing to cache the same tasks. What the screen opens with meanwhile is what
        // _reload() has already taken out of this person's base.
        if (geoReady) unawaited(syncAndRefresh());
      }
    }
    // «появляется само, без ручного обновления»: лента перечитывается раз в минуту,
    // пока приложение открыто, — уведомление, доехавшее за минуту, на демо от пуша
    // неотличимо. Гварды внутри refreshNotifications: без адреса или входа тик пустой.
    _notifTimer = Timer.periodic(
        const Duration(seconds: 60), (_) => unawaited(refreshNotifications()));
  }

  @override
  void dispose() {
    _connSub?.cancel();
    _notifTimer?.cancel();
    push?.dispose();
    unawaited(_db?.close());
    super.dispose();
  }

  /// Point the repository at the base of whoever is signed in: open it on the way in, swap
  /// it when the identity changes (another person, or the same one against another server),
  /// close it on the way out. Everything the app knows offline hangs off this single file,
  /// so the swap *is* the isolation — no query can reach the other user's rows, because
  /// they are in a file this one does not have open.
  Future<void> _bindDb() async {
    final key = session.isActive
        ? LocalDb.keyFor(settings.baseUrl, session.login)
        : null;
    if (key == _db?.userKey) return;
    // whoever is at the app now is somebody else than a moment ago (or nobody): the
    // location gate is theirs to pass, not one they inherit already open
    _located = false;
    final previous = _db;
    _db = null; // nothing may reach the old base once it is on its way out
    // the dashboard is as personal as the tasks under it — it goes with the base
    home = const HomeLayout();
    // и лента уведомлений — она адресована ушедшему, следующему её не показывают
    notifications = const [];
    // и сообщение о проигранной гонке за задачу — оно про задачу ушедшего
    takeNotice = null;
    // and so is the shop somebody was standing in: whoever comes next is asked themselves
    place = const Place();
    // и набор «что мне разрешено создавать» — он отфильтрован по ролям ушедшего
    quickCreate = const QuickCreateData();
    await previous?.close();
    if (key != null) {
      _db = await LocalDb.open(key);
      await _loadHome();
      await _loadPlace();
      await _loadQuickCreate();
      // строка «прошлая проверка» на главном — из кэша этого же пользователя, чтобы
      // офлайн-запуск открывался с работающим входом в просмотр
      await refreshObjectPastLine();
    } else {
      objectPastCheck = null;
    }
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
  bool _elsewhere(Task t) => session.geoRequired && !place.holds(t);

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
    final db = _db;
    if (db == null) {
      // signed out: what is on the screen belongs to the person who has just left, and the
      // next one must not find it waiting for them
      tasks = const [];
      statuses = const [];
      pendingCount = 0;
      notifyListeners();
      return;
    }
    final all = await db.getTasks();
    final outbox = await db.getOutbox();
    final creating = await db.getCreateTaskIds();
    final starting = await db.getStartTaskIds();
    final finishing = await db.getFinishTaskIds();
    final takes = {
      for (final r in await db.getTakeOutbox())
        r['taskId'] as String: r['action'] as String
    };
    statuses = await db.getStatuses();

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
      final TaskGroup group;
      if (taking) {
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

    pendingCount = outbox.length +
        creating.length +
        starting.length +
        finishing.length +
        takes.length;
    notifyListeners();
  }

  /// Pull the latest tasks + statuses from the server into the local cache.
  Future<void> refresh() async {
    if (!settings.isConfigured) {
      error = 'Не настроено подключение';
      notifyListeners();
      return;
    }
    final db = _db;
    if (!session.isActive || db == null) return;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final fetched = await api.fetchTasks(
          lat: place.latitude, lon: place.longitude, objectId: place.objectId);
      final st = await api.fetchStatuses();
      // Сервер с #36837 отдаёт всё назначенное, где бы человек ни стоял, поэтому
      // спрашивать можно и «ниоткуда» — в дороге список нужнее всего. Единственное
      // исключение: старый сервер на «ниоткуда» отвечал пустым списком, и пустой
      // ответ без выбранного объекта кэш не затирает — у нового сервера он означал
      // бы «задач нет вообще», и почти пустой кэш переживёт это расхождение до
      // первого located-fetch.
      if (fetched.isNotEmpty ||
          !session.geoRequired ||
          place.objectId != null) {
        await db.replaceTasks(fetched);
      }
      if (st.isNotEmpty) await db.replaceStatuses(st);
      online = true;
    } on SessionExpiredException {
      // the session is already cleared — the app root will show the login screen
      error = 'Сессия истекла — войдите заново';
    } catch (e) {
      online = false;
      error = 'Нет связи с сервером — показаны сохранённые данные';
    } finally {
      loading = false;
      await _reload();
    }
  }

  /// Change a task's status: record it locally (instant, offline-safe) and try
  /// to push right away.
  Future<void> setStatus(String taskId, TaskStatus status) async {
    final db = _db;
    if (db == null) return;
    await db.enqueue(
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
    final db = _db;
    if (syncing || !session.isActive || db == null) return;
    syncing = true;
    notifyListeners();
    try {
      final outbox = await db.getOutbox();
      // барьер #36716: статус задачи, чьё создание ещё не уехало, не отправляется —
      // он ушёл бы к серверу, который такой задачи не знает. И статус задачи с
      // застрявшим finish тоже придерживается: иначе он обгонит завершение, и 'done'
      // финиша перезапишет его — хронология пользователя инвертируется. Записи
      // остаются в очереди и уйдут заходом после того, как drainLocalTasks дожмёт.
      final creating = await db.getCreateTaskIds();
      final finishing = await db.getFinishTaskIds();
      for (final entry in outbox.values) {
        if (creating.contains(entry.taskId) ||
            finishing.contains(entry.taskId)) {
          continue;
        }
        try {
          await api.setStatus(entry.taskId, entry.statusId);
          await db.updateTaskStatus(
              entry.taskId, entry.statusId, entry.statusName);
          await db.dequeue(entry.taskId);
          online = true;
        } on SessionExpiredException {
          error = 'Сессия истекла — войдите заново';
          break; // the queue survives the re-login
        } catch (e) {
          online = false;
          error = 'Не удалось синхронизировать: $e';
          break; // keep this and later entries queued
        }
      }
    } finally {
      syncing = false;
      await _reload();
    }
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
    final db = _db;
    if (db == null) return;
    await db.enqueueTake(taskId, 'take', DateTime.now().toIso8601String());
    await _reload();
    unawaited(syncTakes());
  }

  /// Снять с себя — тем же путём. Поверх ещё не ушедшего взятия строка очереди просто
  /// заменяется: это и есть «откат снимает пометку и ничего больше» — ответы бланка не
  /// трогаются нигде, а снятие невзятой задачи сервер отвечает пустым 200.
  Future<void> releaseTask(String taskId) async {
    final db = _db;
    if (db == null) return;
    await db.enqueueTake(taskId, 'release', DateTime.now().toIso8601String());
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
    if (!session.isActive || _db == null) return;
    try {
      while (true) {
        final db = _db;
        if (db == null) break; // вышли из аккаунта прямо под дренажем
        final rows = await db.getTakeOutbox();
        if (rows.isEmpty) break;
        final entry = rows.first;
        final id = entry['taskId'] as String;
        final action = entry['action'] as String;
        try {
          final refusal = action == 'take'
              ? await api.takeTask(id)
              : await api.releaseTask(id);
          online = true;
          if (refusal == null) {
            // принято. Строка кэша приводится к подтверждённому состоянию до
            // dequeue — между ними её не успеет перезаписать параллельный fetch, и
            // задача не мигнёт прежней группой до следующего refresh
            if (action == 'take') {
              await db.updateTaskTake(id,
                  takenById: session.performerId,
                  takenBy:
                      session.name.isEmpty ? session.login : session.name,
                  takenAt: DateTime.now().toIso8601String(),
                  mine: true,
                  canTake: false);
            } else {
              // снятая мной вернулась в пул: раз сервер снятие принял, взять её
              // можно снова — это его же canTake, каким он был до взятия
              await db.updateTaskTake(id,
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
              await db.updateTaskTake(id,
                  takenById: refusal.takenById,
                  takenBy: refusal.takenBy,
                  takenAt: refusal.takenAt,
                  mine: false,
                  canTake: false);
            }
            _noteTakeRefusal(id, refusal);
          }
          await db.dequeueTake(id, action);
        } on SessionExpiredException {
          error = 'Сессия истекла — войдите заново';
          break; // очередь переживает перевход
        } on ApiException catch (e) {
          // сервер ответил отказом без адресата (500 «Take failed» и т.п.) — запись
          // остаётся, повтор взятия безопасен и уйдёт следующим циклом
          error = 'Не удалось синхронизировать: $e';
          break;
        } catch (e) {
          online = false;
          error = 'Не удалось синхронизировать: $e';
          break;
        }
      }
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

  /// Push pending changes, then pull fresh data. The home screen rides along: its numbers
  /// are as perishable as the task list, and a pull-to-refresh that updates one but not
  /// the other would leave the two halves of the same screen disagreeing.
  /// Пресеты создания едут этим же циклом: их смысл — оказаться на телефоне заранее,
  /// и «заранее» — это каждая синхронизация, а не отдельная кнопка.
  ///
  /// Рождённые на телефоне задачи дожимаются первыми (#36716): их создание — барьер и
  /// для их статусов в syncOutbox, и для честного refresh — сервер, уже принявший
  /// задачу, вернёт её в fetched, и локальная строка схлопнется с серверной.
  /// Взятия уезжают до refresh: fetch, пришедший позже ответа взятия, уже несёт его
  /// результат, и группировка не мигает.
  Future<void> syncAndRefresh() async {
    await drainLocalTasks();
    await syncTakes();
    await syncOutbox();
    await refresh();
    await refreshHome();
    await refreshQuickCreate();
    await refreshNotifications();
    // не awaited: спиннер pull-to-refresh не должен ждать догрузку истории
    unawaited(prefetchPastChecks());
  }

  /// Итог последней завершённой проверки текущего объекта — то, что рисует строка
  /// «Прошлая проверка» на главном. Держится здесь, а не читается виджетом из
  /// sqlite на каждый rebuild: главная перерисовывается каждым notifyListeners
  /// (таймер уведомлений — раз в минуту), и строка не должна дёргать базу и мигать.
  FillSummary? objectPastCheck;

  /// Прошлые проверки кэшируются вместе с задачами (#36778): человек в поле бывает
  /// без сети, и история, доступная только онлайн, бесполезна именно там, где
  /// нужна. Пять ручек на задачу — не бесплатно, поэтому сеть трогается только для
  /// задач с открывавшимся бланком (без fill_cache офлайн-бланк всё равно не
  /// открыть, и просмотр из него — тоже), у которых прошлая проверка есть и стала
  /// новее кэша просмотра. Ошибки тихие: дрейн общий с выходом из аккаунта, и
  /// закрывшаяся под ним база не должна ронять unawaited-цепочку.
  Future<void> prefetchPastChecks() async {
    try {
      final db = _db;
      if (!session.isActive || db == null) return;
      for (final v in tasks) {
        final t = v.task;
        if (!fillableTypeIds.contains(t.typeId)) continue;
        // задача, рождённая на телефоне, всю жизнь адресуется своим UUID — как её
        // бланк и очереди (см. TaskDetailScreen)
        final key = t.clientId ?? t.id;
        if (await _pastCacheStale(db, key)) {
          await PastFillController.prefetch(db, api, taskId: key);
        }
      }
      final obj = objectId;
      if (obj != null) {
        await PastFillController.prefetch(db, api, objectId: obj);
      }
      await refreshObjectPastLine(); // notifies
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
    final fill = await db.getFillCache(key);
    if (fill == null) return false; // бланк не открывали — кэшировать нечего и незачем
    try {
      final prevDate = ((jsonDecode((fill['infoJson'] as String?) ?? '{}')
              as Map)['prevDate'])
          ?.toString();
      if (prevDate == null || prevDate.isEmpty) {
        return false; // по бланку прошлых нет — пустой кэш просмотра не нужен
      }
      final past = await db.getPastFillCache('task', key);
      if (past == null) return true;
      final pastDate = ((jsonDecode((past['infoJson'] as String?) ?? '{}')
              as Map)['date'])
          ?.toString();
      return pastDate == null || prevDate.compareTo(pastDate) > 0;
    } catch (_) {
      return true;
    }
  }

  /// Перечитать строку «прошлая проверка» текущего объекта из кэша — при смене
  /// объекта, после префетча и при входе (офлайн-старт живёт тем же кэшем).
  Future<void> refreshObjectPastLine() async {
    final db = _db;
    final obj = objectId;
    if (db == null || obj == null) {
      objectPastCheck = null;
      notifyListeners();
      return;
    }
    FillSummary? line;
    try {
      final row = await db.getPastFillCache('object', obj);
      if (row != null) {
        final info = (jsonDecode((row['infoJson'] as String?) ?? '{}') as Map)
            .cast<String, dynamic>();
        final s = FillSummary.fromJson(info);
        if (s.date != null) line = s;
      }
    } catch (_) {
      // нечитаемый кэш — строки просто нет до следующей синхронизации
    }
    objectPastCheck = line;
    notifyListeners();
  }

  /// Перечитать ленту уведомлений. Ошибка тихая: таймер попробует снова через
  /// минуту, а про офлайн и так говорит баннер.
  Future<void> refreshNotifications() async {
    if (!settings.isConfigured || !session.isActive) return;
    try {
      final list = await api.fetchNotifications();
      // новые сверху; нечитаемая дата не роняет ленту, а падает в конец
      list.sort((a, b) {
        final x = a.when, y = b.when;
        if (x == null) return y == null ? 0 : 1;
        if (y == null) return -1;
        return y.compareTo(x);
      });
      notifications = list;
      notifyListeners();
    } catch (_) {
      // офлайн или старый сервер без ручки — остаётся показанное ранее
    }
  }

  /// Открытая лента прочитана: каждая непрочитанная помечается на сервере своим
  /// адресом (событие, задача, дата). Обрыв на середине не страшен: локально
  /// прочитанными становятся только реально отправленные, остальные допометятся
  /// при следующем открытии — сама ручка идемпотентна.
  Future<void> markAllNotificationsViewed() async {
    final done = <String>{};
    for (final n in notifications) {
      if (n.viewed || n.event == null || n.date == null) continue;
      try {
        await api.markNotificationViewed(n.event!, n.taskId, n.date!);
        done.add(n.key);
      } catch (_) {
        break; // сеть пропала — остальные при следующем открытии
      }
    }
    if (done.isEmpty) return;
    notifications = [
      for (final n in notifications)
        done.contains(n.key) ? n.copyWith(viewed: true) : n
    ];
    notifyListeners();
  }

  /// Дожать до сервера задачи, рождённые на телефоне, — не дожидаясь, пока их экран
  /// откроют снова: «после появления связи уезжает на сервер» обязано случиться и у
  /// телефона, лежащего в кармане. Каждая задача дренится своим контроллером — там
  /// написан порядок create → start → ответы → фото → finish и там же живёт замок,
  /// который не даёт открытому экрану и этому проходу толкать одну очередь вдвоём.
  Future<void> drainLocalTasks() async {
    final db = _db;
    if (!session.isActive || db == null) return;
    final ids = await db.getLifecycleTaskIds();
    if (ids.isEmpty) return;
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
    // отказ сервера (например, отвергнутое создание) без этого не всплывал бы нигде:
    // у поручения нет экрана бланка, где виден lastSyncError
    syncError = firstError == null ? null : 'Не синхронизировано: $firstError';
    await _reload();
  }

  /// The address is half of the base's name, so pointing the app at another server points
  /// it at another base — the same person on the test server and on the live one keeps two
  /// caches, and neither of them shows the other's tasks.
  Future<void> updateSettings(Settings s) async {
    settings = s;
    api.settings = s;
    await _bindDb();
    await _reload(); // notifies
  }

  // --- задачи, рождённые на телефоне (#36716) ---

  /// UUID v4 из системного ГСЧ — ключ клиента для задачи, создаваемой на месте.
  /// Свой генератор на шестнадцати байтах вместо пакета uuid: формат на три строки,
  /// а зависимость — навсегда.
  static String newClientId() {
    final rnd = Random.secure();
    final b = List<int>.generate(16, (_) => rnd.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40; // version 4
    b[8] = (b[8] & 0x3f) | 0x80; // variant 10xx
    String hex(int from, int to) => [
          for (var i = from; i < to; i++)
            b[i].toRadixString(16).padLeft(2, '0')
        ].join();
    return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
  }

  static String _isoDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// Родить задачу прямо в магазине — целиком локально, сети здесь нет и не ждут:
  /// строка в списке, тело apiCreateTask в очереди, а для бланочного пресета — ещё
  /// отложенный старт и бланк, посеянный из предзагруженного шаблона, чтобы экран
  /// заполнения открылся немедленно. Возвращает UUID задачи: им она адресуется всю
  /// жизнь, даже после того как сервер выдаст ей ST-номер.
  ///
  /// Фото автора копируется в каталог фотографий этого пользователя и уходит внутри
  /// того же POST, что и задача; исходный файл из галереи/камеры не трогаем.
  Future<String> createTask({
    required QuickPreset preset,
    required String objectId,
    String? objectName,
    String? objectAddress,
    required String name,
    DateTime? deadline,
    String? description,
    String? photoPath,
    Performer? assignee,
  }) async {
    final db = this.db;
    final uuid = newClientId();
    final now = DateTime.now();

    final template = preset.templateCode == null
        ? null
        : quickCreate.templates[preset.templateCode];

    final payload = <String, dynamic>{
      'clientId': uuid,
      'typeId': preset.typeId,
      'objectId': objectId,
      'name': name,
      // дата с телефона, не дата синхронизации: задача, созданная офлайн три дня
      // назад, должна выглядеть созданной три дня назад — от этого считается просрочка
      'created': _isoDate(now),
      if (template != null) 'templateId': template.code,
      if (assignee != null) 'assigneeId': assignee.id,
      if (deadline != null) 'deadline': _isoDate(deadline),
      if (preset.priorityId != null) 'priorityId': preset.priorityId,
      if (description != null && description.isNotEmpty)
        'description': description,
      if (preset.requirePhoto) 'requirePhoto': true,
    };

    String? storedPhoto;
    if (photoPath != null) {
      final dir = await FillController.photoDirectory(db.userKey);
      if (!await dir.exists()) await dir.create(recursive: true);
      storedPhoto = p.join(dir.path, '${uuid}_task.jpg');
      await File(photoPath).copy(storedPhoto);
    }

    final task = Task(
      id: uuid,
      clientId: uuid,
      name: name,
      object: objectName,
      objectId: objectId,
      address: objectAddress,
      typeId: preset.typeId,
      status: 'Ожидает отправки',
      assignedTo: assignee?.name ??
          (session.name.isEmpty ? session.login : session.name),
      assigneeId: assignee?.id ?? session.performerId,
      deadline: deadline == null ? null : _isoDate(deadline),
    );

    await db.createLocalTask(
      task,
      payloadJson: jsonEncode(payload),
      photoPath: storedPhoto,
      createdAtIso: now.toIso8601String(),
      queueStart: template != null,
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
    unawaited(drainLocalTasks()); // а если сеть есть — уезжает немедленно
    return uuid;
  }

  // --- signing in ---

  /// A boolean as the server states it. lsFusion drops a NULL property from an export, so
  /// a flag arrives as `true` or does not arrive at all — and «not at all» is also what an
  /// older server that has never heard of the flag says.
  static bool _flag(Object? v) =>
      v == true || v == 1 || (v is String && v.toLowerCase() == 'true');

  /// Two steps: the platform issues a token for the credentials, then the profile says who
  /// that token belongs to. Only after both does the session exist — a token without a
  /// performer behind it would open an app with permanently empty lists.
  ///
  /// The profile also says whether this account works by location (`geoRequired`); if it
  /// does, the app root puts the gate in front of the home screen — see [geoReady].
  ///
  /// A server that does not answer at all is not a failure but the other route: see
  /// [_signInOffline]. A shop without a signal is the normal case this app was built for.
  Future<void> signIn(String login, String password) async {
    if (!settings.isConfigured) throw LoginException('Не указан адрес сервера');

    final String token;
    try {
      token = await api.fetchAuthToken(login, password);
    } on ApiException catch (e) {
      if (e.status == 401) throw LoginException('Неверный логин или пароль');
      throw LoginException('Сервер ответил ошибкой: ${e.message}');
    } catch (_) {
      // no answer at all: timeout, refused connection, no route
      await _signInOffline(login, password);
      return;
    }

    session
      ..login = login.trim()
      ..password = password
      ..passwordHash = await PasswordHash.create(password)
      ..token = token;

    final Map<String, dynamic>? profile;
    try {
      profile = await api.fetchCurrentUser();
    } on ApiException catch (e) {
      await session.clear();
      throw LoginException(switch (e.status) {
        401 => 'Неверный логин или пароль',
        403 => 'Нет доступа к задачам',
        _ => 'Сервер ответил ошибкой: ${e.message}',
      });
    } catch (_) {
      await session.clear();
      throw LoginException('Сервер недоступен');
    }
    // an empty answer means the same thing as the 403 — no performer behind the account
    if (profile == null || (profile['id']?.toString() ?? '').isEmpty) {
      await session.clear();
      throw LoginException('Нет доступа к задачам');
    }

    session
      ..name = profile['name']?.toString() ?? ''
      ..performerId = profile['id'].toString()
      ..geoRequired = _flag(profile['geoRequired'])
      ..signedIn = true;
    await session.save();

    // now that there is an identity there is a base to open — this person's own, and on
    // an installation updated from a build that had a single one, that single one becomes
    // theirs (see LocalDb._adoptLegacyDatabase)
    await _bindDb();
    await _reload();

    online = true;
    error = null;
    notifyListeners();
    unawaited(refreshBrand());
    unawaited(syncAndRefresh());
    // после входа, а не до: регистрация подписывает телефон за конкретным человеком, и
    // до появления сессии подписывать его не за кого
    unawaited(push?.register() ?? Future.value());
  }

  /// Sign in with no server to ask. The password is checked against the hash this device
  /// stored at the last successful sign-in, and only inside [Session.offlineWindow] — a
  /// phone that has been out of touch for longer has to prove itself to the server again.
  Future<void> _signInOffline(String login, String password) async {
    if (!await session.matches(login, password)) {
      // either this device has never seen the login, or the password does not match what
      // it remembers; without the server there is nothing else to check against
      throw LoginException(session.login.isEmpty
          ? 'Сервер недоступен'
          : 'Неверный логин или пароль');
    }
    if (!session.offlineWindowOpen) {
      throw LoginException('Сервер недоступен. Без сети войти можно в течение '
          'суток после последнего сеанса связи');
    }
    // the old token comes along as it is: it may be expired, and the 401 retry in
    // ApiClient will quietly swap it for a fresh one once there is a network again
    session.signedIn = true;
    await session.save();
    // an offline sign-in establishes the identity just as well, and the base it opens is
    // the whole point of signing in without a network: it is where the work is
    await _bindDb();
    await _reload();
    online = false;
    error = null;
    notifyListeners();
  }

  // --- the location gate ---

  /// Whether the coordinates have been taken since the app started. In memory on purpose:
  /// the position is asked for once per launch and once per sign-in, so a phone that was
  /// let in yesterday is asked again today — and a permission withdrawn in the meantime
  /// stops it at the door rather than at the next sign-in, whenever that happens to be.
  ///
  /// Cheap in practice: the fix a launch a minute later needs is the one the device still
  /// remembers (see [Geo.lastKnownWindow]), and that comes back instantly.
  bool _located = false;

  /// Whether the app may show anything beyond the gate. An account whose roles allow
  /// working without geolocation passes it without being asked anything.
  bool get geoReady => !session.geoRequired || _located;

  /// Ask the device where it is and, if it answers, find out what that place is: the
  /// coordinates go into the session, the objects around them into [place]. The screen
  /// gets the outcome back so it can say what went wrong; the app root gets a
  /// notification, which is what actually opens the way in.
  ///
  /// The same method behind the gate at the door and behind «Обновить местоположение» in
  /// the list header, because it is the same question — «где я сейчас» — and the second
  /// caller wants exactly what the first one does: a fresh fix, a fresh set of neighbours,
  /// and the task list rebuilt around them.
  ///
  /// The GPS is polled once per launch and once per press, and never on merely opening the
  /// list: what the list opens with is what the gate already established, or what the
  /// person's own base remembers from the last time.
  ///
  /// [fresh] прокидывается в [Geo.locate]: по кнопке «Обновить» позиция меряется заново,
  /// на входе — можно и запомненную (#36837).
  Future<GeoOutcome> locate({bool fresh = false}) async {
    locating = true;
    notifyListeners();
    GeoOutcome outcome = const GeoUnavailable(GeoFailure.noFix);
    try {
      outcome = await geo.locate(fresh: fresh);
      if (outcome is GeoFix) {
        session
          ..latitude = outcome.latitude
          ..longitude = outcome.longitude
          ..locatedAt = outcome.at;
        await session.save();
        _located = true;
        await _askNearby(outcome);
        // the header and the list have to agree in the same frame: the cache is refiltered
        // by the new object now, not when the server gets round to answering
        await _reload();
      }
    } finally {
      locating = false;
      notifyListeners();
    }
    // The tasks are the server's answer to «на каком объекте я стою», so a new place is a
    // new list — this is «Обновить местоположение честно перестраивает список». Not
    // awaited: the door must open on the fix, not on a task fetch that may time out.
    if (outcome is GeoFix) unawaited(syncAndRefresh());
    return outcome;
  }

  /// Who is around this fix, and which of them the person is at.
  ///
  /// A server that does not answer leaves the previous place standing rather than
  /// emptying it: offline the saved object is the only thing that makes the cached list
  /// mean anything, and «сервер молчит» must not be shown as «рядом никого нет».
  Future<void> _askNearby(GeoFix fix) async {
    try {
      final objects = await api.fetchNearbyObjects(fix.latitude, fix.longitude);
      place = Place(
        objects: objects,
        objectId: Place.pick(objects, previous: place.objectId),
        latitude: fix.latitude,
        longitude: fix.longitude,
        at: fix.at,
        answered: true,
      );
      online = true;
    } on SessionExpiredException {
      return; // the session is already cleared — the app root shows the login screen
    } catch (_) {
      online = false;
      place = place.fixedAt(fix.latitude, fix.longitude);
    }
    await _savePlace();
  }

  /// The person says which of the neighbouring objects they are actually at — two shops in
  /// one shopping centre are metres apart and nothing but the person knows which one they
  /// walked into.
  Future<void> selectNearby(String id) async {
    if (place.objectId == id) return;
    place = place.select(id);
    await _savePlace();
    await _reload(); // the list rebuilds now, not when the server gets round to it
    unawaited(syncAndRefresh());
  }

  Future<void> _savePlace() async {
    final db = _db;
    if (db == null) return;
    await db.savePlace(jsonEncode(place.toJson()),
        (place.at ?? DateTime.now()).toIso8601String());
  }

  /// Where this person was standing when they last closed the app. Read out of their own
  /// base, so a phone reopened in the aisle without a signal shows the shop it is in and
  /// filters the cached tasks by it, instead of asking the GPS all over again.
  Future<void> _loadPlace() async {
    final db = _db;
    if (db == null) return;
    final json = await db.getPlace();
    if (json == null || json.isEmpty) return;
    try {
      place = Place.fromJson((jsonDecode(json) as Map).cast<String, dynamic>());
    } catch (_) {
      // stored place unreadable — the gate will establish it again in a moment
    }
  }

  /// Sign out. Only the session goes: the address belongs to the installation, the cached
  /// tasks and their pending queue stay (the usual reason to sign out and back in is the
  /// same person on the same phone), and so do the credentials this device remembers —
  /// without them the way back in would require a network.
  ///
  /// What does go is the open base: it stays on the device under this person's name, and
  /// whoever signs in next gets their own instead. Their unsent queue waits for them here
  /// and can be pushed by nobody else.
  ///
  /// Somebody who finished a shift in a basement with no signal must find their queue
  /// waiting when the phone next sees the network — which is why erasing it is a separate
  /// door with a warning on it ([signOutAndWipe]) rather than part of this one.
  Future<void> signOut() async {
    // до session.signOut(), а не после: снятие регистрации — это запрос к серверу, и
    // делать его нечем, когда токен сессии уже стёрт. Ждём его, а не отпускаем в
    // unawaited: уведомления следующего сотрудника не должны уехать на этот телефон,
    // и лишняя секунда на выходе дешевле такой утечки
    await push?.unregister();
    await session.signOut();
    error = null; // the previous session's banner has nothing to tell the next person
    await _bindDb();
    await _reload(); // notifies, and clears the screen of the person who just left
  }

  /// Sign out and take this person's local data with them: the cached tasks, the queues
  /// that never reached the server, the evidence photos, and the credentials this device
  /// kept so they could get back in without a network.
  ///
  /// «Ровно этого пользователя»: everything erased here is named after the one identity —
  /// the base file and the photo directory are both keyed by [LocalDb.keyFor] — so a phone
  /// passed around a shift loses nothing of anybody else's. What does not go is what
  /// belongs to the installation rather than to the person: the server address, and the
  /// home screen's selected object — the shop this phone is standing in outlives whoever
  /// is holding it, and it cannot show anybody else's figures anyway (see [objectId]: a
  /// saved id is honoured only if it is in the newcomer's own list of objects). The
  /// located place is not that: it is where *this* person stood, it lives in their base,
  /// and it goes with it.
  ///
  /// The unsent queue dies with the base, which is the whole reason the screen asks first
  /// and says how many changes that is (see [unsentChanges]).
  Future<void> signOutAndWipe() async {
    // read while the session is still whole: it is the name of everything being erased
    final key = _db?.userKey ??
        (session.login.isEmpty
            ? null
            : LocalDb.keyFor(settings.baseUrl, session.login));
    // тоже до очистки сессии и по той же причине, что в signOut: «стереть всё своё» без
    // снятия регистрации оставило бы на телефоне ровно то, что человек хотел убрать
    await push?.unregister();
    await session.clear();
    error = null;
    await _bindDb(); // the base closes here — an open file must not be deleted under it
    await _reload();
    if (key == null) return;
    await LocalDb.deleteFor(key);
    await FillController.deletePhotos(key);
    await PastFillController.deletePhotos(key);
  }

  /// How many changes this person has made that the server has not taken yet — the status
  /// queue the sync badge counts plus the fill queues, which are drained by the task screen
  /// that owns them and are therefore invisible from here.
  ///
  /// Asked before signing out: a warning about what stays unsent is worth nothing unless it
  /// counts the photo taken in the aisle as well as the tick in the list.
  Future<int> unsentChanges() async => await _db?.pendingChanges() ?? 0;

  /// Pulls the customer's branding and applies it. Called as soon as the server address
  /// is known — a failure is silent by design: a wrong palette must never stand between
  /// the inspector and their tasks, the app simply keeps the look it already had.
  Future<void> refreshBrand() async {
    if (!settings.isConfigured) return;
    try {
      final j = await api.fetchBrand();
      if (j == null || j.isEmpty) return;
      settings.brandJson = jsonEncode(j);
      await settings.save();
      Wms.brand = Brand.fromJson(j);
    } catch (_) {
      // offline, older server without the endpoint, malformed palette — keep the current
    }
  }

  /// Pulls the home screen configured for this user. Silent on failure for the same
  /// reason as the brand: the cached layout is a fine answer, and an error banner about
  /// the dashboard must not push the tasks off the screen.
  Future<void> refreshHome() async {
    final db = _db;
    if (!settings.isConfigured || !session.isActive || db == null) return;
    try {
      final j = await api.fetchHome();
      if (j == null) return;
      final layout = HomeLayout.fromJson(j);
      // An empty answer means "not configured on this server" — keep whatever we had
      // rather than replacing a working home screen with a blank one.
      if (layout.isEmpty) return;
      home = layout;
      await db.saveHome(
          jsonEncode(layout.toJson()), DateTime.now().toIso8601String());
      notifyListeners();
    } catch (_) {
      // offline or an older server without the endpoint — the cached layout stands
    }
  }

  /// Забирает пресеты создания и справочники под них (шаблоны, исполнителей) — три
  /// ручки одним заходом, потому что порознь они бессмысленны: кнопка без бланка не
  /// нарисует форму, бланк без людей не даст выбрать исполнителя.
  ///
  /// Пустой ответ, в отличие от главной, ЗАПИСЫВАЕТСЯ: пресеты выключили в бэк-офисе —
  /// кнопка обязана пропасть при следующей синхронизации. Кэш переживает только ошибку
  /// (офлайн или старый сервер без ручек) — тогда телефон продолжает жить тем, что
  /// успел забрать.
  Future<void> refreshQuickCreate() async {
    final db = _db;
    if (!settings.isConfigured || !session.isActive || db == null) return;
    try {
      final actions = await api.fetchQuickActionsRaw();
      final templates = await api.fetchTemplatesRaw();
      final performers = await api.fetchPerformersRaw();
      quickCreate = QuickCreateData.parse(actions, templates, performers);
      await db.saveQuickCreate(
          actions, templates, performers, DateTime.now().toIso8601String());
      notifyListeners();
    } catch (_) {
      // офлайн или сервер без ручек — остаётся то, что лежит в кэше
    }
  }

  /// Пресеты, которые этот человек забрал в прошлый раз, — из его собственной базы.
  /// Именно этот путь делает «создать проверку в подвале без сети» возможным.
  Future<void> _loadQuickCreate() async {
    final db = _db;
    if (db == null) return;
    final cached = await db.getQuickCreate();
    if (cached == null) return;
    try {
      quickCreate = QuickCreateData.parse(cached.$1, cached.$2, cached.$3);
    } catch (_) {
      // нечитаемый кэш — кнопка появится после первой удачной синхронизации
    }
  }

  /// The object whose numbers the home screen shows: the person's own choice while it is
  /// still valid, else the shop they are standing at, else the first one the server sent —
  /// a fresh install opens on a shop rather than on empty tiles.
  ///
  /// The located shop outranks the alphabet on purpose: for an account that works by
  /// location the task list is that shop's, and a dashboard defaulting to whichever shop
  /// sorts first would disagree with the list under every tile.
  String? get objectId {
    final saved = settings.objectId;
    if (saved.isNotEmpty && home.objects.any((o) => o.id == saved)) return saved;
    final located = place.objectId;
    if (located != null && home.objects.any((o) => o.id == located)) {
      return located;
    }
    return home.objects.isEmpty ? null : home.objects.first.id;
  }

  HomeObject? get currentObject {
    final id = objectId;
    if (id == null) return null;
    for (final o in home.objects) {
      if (o.id == id) return o;
    }
    return null;
  }

  Future<void> selectObject(String id) async {
    settings.objectId = id;
    await settings.save();
    notifyListeners();
    // строка «прошлая проверка» — уже нового объекта: из кэша в этом же кадре, из
    // сети — как только префетч дотянется (иначе вход с карточки объекта появлялся
    // бы только после следующей полной синхронизации)
    await refreshObjectPastLine();
    unawaited(prefetchPastChecks());
  }

  /// The dashboard this person last saw, straight out of their own base — so a phone
  /// opened in the aisle without a signal shows yesterday's numbers rather than a spinner,
  /// and shows *theirs*.
  Future<void> _loadHome() async {
    final db = _db;
    if (db == null) return;
    var json = await db.getHome();
    // an installation updated from the build that kept one home screen for the whole
    // device: it belongs to whoever signs in first, same as the base itself
    if (json == null) {
      json = await Settings.takeLegacyHomeJson();
      if (json != null && json.isNotEmpty) {
        await db.saveHome(json, DateTime.now().toIso8601String());
      }
    }
    if (json == null || json.isEmpty) return;
    try {
      home =
          HomeLayout.fromJson((jsonDecode(json) as Map).cast<String, dynamic>());
    } catch (_) {
      // stored layout unreadable — the app falls back to the plain task list
    }
  }
}
