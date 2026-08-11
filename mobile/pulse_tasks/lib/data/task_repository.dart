import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import '../ui/brand.dart';
import '../ui/theme.dart';

import '../models/home.dart';
import '../models/place.dart';
import '../models/task.dart';
import '../models/task_status.dart';
import 'api_client.dart';
import 'fill_controller.dart';
import 'geo.dart';
import 'local_db.dart';
import 'password_hash.dart';
import 'session.dart';
import 'settings.dart';

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

  const TaskView(this.task, this.statusId, this.statusName, this.pending,
      {this.closed = false});

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

  TaskRepository(
      {required this.api,
      required this.settings,
      required this.session,
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

  /// The tasks of the object this person is standing at — see [_here]. Not everything the
  /// base holds: an object is what makes a list of tasks answerable at all.
  List<TaskView> tasks = const [];
  List<TaskStatus> statuses = const [];
  HomeLayout home = const HomeLayout();

  /// Where the app thinks the person is, and who else is nearby. Loaded from their base
  /// on the way in, so an app reopened without a signal knows which object it is showing.
  Place place = const Place();

  int pendingCount = 0;
  bool loading = false;
  bool syncing = false;

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
        // For an account that works by location the gate pulls the list, because only it
        // knows which object to pull it for — asking here as well would be two fetches
        // racing to cache the same tasks. What the screen opens with meanwhile is what
        // _reload() has already taken out of this person's base.
        if (geoReady) unawaited(syncAndRefresh());
      }
    }
  }

  @override
  void dispose() {
    _connSub?.cancel();
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
    // and so is the shop somebody was standing in: whoever comes next is asked themselves
    place = const Place();
    await previous?.close();
    if (key != null) {
      _db = await LocalDb.open(key);
      await _loadHome();
      await _loadPlace();
    }
  }

  TaskStatus? statusById(String? id) {
    if (id == null) return null;
    for (final s in statuses) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// A task of the object this person is standing at. The server already sends only
  /// those, so online this filter changes nothing — it earns its place on the two
  /// occasions the cache outlives the answer: switching object in the header, where the
  /// list has to rebuild at once instead of after a round trip, and a shift without a
  /// signal, where there is no round trip to wait for.
  ///
  /// A role excused from geolocation sees everything: the server does not narrow their
  /// list either, and there is no object for them to be standing at.
  bool _here(Task t) => !session.geoRequired || place.holds(t);

  /// Rebuild the in-memory view from the local DB (tasks + statuses + outbox),
  /// applying the outbox status overlay. Nothing is filtered by assignee here: `apiTasks`
  /// only ever sends the signed-in user's tasks, so what is cached is already theirs.
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
    statuses = await db.getStatuses();

    tasks = all.where(_here).map((t) {
      final ob = outbox[t.id];
      final statusId = ob?.statusId ?? t.statusId;
      return TaskView(
        t,
        statusId,
        ob == null ? t.status : (ob.statusName ?? t.status),
        ob != null,
        closed: statusById(statusId)?.closed ?? false,
      );
    }).toList();

    pendingCount = outbox.length;
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
    // An account that works by location and does not know where it is stands nowhere, and
    // the server answers for nowhere with an empty list — which would then overwrite the
    // cache, the only thing such a person has. Nothing is asked until there is an object;
    // the screen meanwhile says which of the three reasons there is none.
    if (session.geoRequired && place.objectId == null) return;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final fetched = await api.fetchTasks(
          lat: place.latitude, lon: place.longitude, objectId: place.objectId);
      final st = await api.fetchStatuses();
      await db.replaceTasks(fetched);
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
      for (final entry in outbox.values) {
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

  /// Push pending changes, then pull fresh data. The home screen rides along: its numbers
  /// are as perishable as the task list, and a pull-to-refresh that updates one but not
  /// the other would leave the two halves of the same screen disagreeing.
  Future<void> syncAndRefresh() async {
    await syncOutbox();
    await refresh();
    await refreshHome();
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
  Future<GeoOutcome> locate() async {
    locating = true;
    notifyListeners();
    GeoOutcome outcome = const GeoUnavailable(GeoFailure.noFix);
    try {
      outcome = await geo.locate();
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
    await session.clear();
    error = null;
    await _bindDb(); // the base closes here — an open file must not be deleted under it
    await _reload();
    if (key == null) return;
    await LocalDb.deleteFor(key);
    await FillController.deletePhotos(key);
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

  /// The object whose numbers the home screen shows. Falls back to the first one the
  /// server sent, so a fresh install opens on a shop rather than on empty tiles.
  String? get objectId {
    final saved = settings.objectId;
    if (saved.isNotEmpty && home.objects.any((o) => o.id == saved)) return saved;
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
