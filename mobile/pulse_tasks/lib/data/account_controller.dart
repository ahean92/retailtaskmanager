import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'comment_controller.dart';
import 'fill_controller.dart';
import 'local_db.dart';
import 'password_hash.dart';
import 'past_fill_controller.dart';
import 'push_service.dart';
import 'session.dart';
import 'settings.dart';
import 'task_repository.dart';
import 'user_base.dart';

/// Why a sign-in failed, in a sentence the person on shift can act on. Three causes get
/// three messages: a single «Ошибка: ...» with a stack trace in it tells them nothing about
/// whether to retype the password, walk towards the window, or call the office.
class LoginException implements Exception {
  final String message;
  LoginException(this.message);
  @override
  String toString() => message;
}

/// Кто вошёл на этом телефоне: вход (онлайн и без сети), выход, выход со стиранием,
/// потеря сессии, адрес сервера. [Session] — данные; здесь — то, что с ними делают, и
/// то, что от них зависит: база вошедшего ([UserBase]) и регистрация телефона под пушем.
/// The app root watches this controller: каждый из этих переходов заканчивается
/// [notifyListeners], и корень подменяет экран — форму входа, гейт, главную.
class AccountController extends ChangeNotifier {
  final ApiClient api;
  final Session session;
  final Settings settings;
  final UserBase base;
  final TaskRepository repo;

  /// Пуш (#36720). Необязателен: тестам и сборке без конфигурации Firebase он не нужен,
  /// а вход и выход обязаны работать одинаково с ним и без него. Держится здесь, потому
  /// что регистрация телефона привязана к сессии, а сессией распоряжается этот контроллер.
  final PushService? push;

  /// Вход состоялся (онлайн): бренд и синхронизация — не дело входа, кто их запускает,
  /// решает SyncCoordinator.
  Future<void> Function()? onSignedIn;

  AccountController(
      {required this.api,
      required this.session,
      required this.settings,
      required this.base,
      required this.repo,
      this.push}) {
    api.onSessionLost = _sessionLost;
  }

  @override
  void dispose() {
    push?.dispose();
    super.dispose();
  }

  /// Сессия умерла посреди работы (401, который не вылечился перевходом).
  void _sessionLost() {
    repo.error = 'Сессия истекла — войдите заново';
    notifyListeners(); // the app root watches this and swaps in the login screen
    // A session dying mid-work is a way out of the app like any other, so the base closes
    // with it: whoever signs in at the form that comes up must not find the previous
    // person's tasks still cached behind it. The session itself is already gone —
    // `ApiClient` cleared it before calling this.
    unawaited(base.rebind().then((_) => repo.reloadLocal()));
  }

  /// Зарегистрировать телефон под этим человеком в реестре пуша. На каждом запуске, а
  /// не только при входе: токен FCM ротируется сам (переустановка, очистка данных,
  /// восстановление из бэкапа), и реестр на сервере должен догонять его, а не хранить
  /// позавчерашний.
  Future<void> registerDevice() => push?.register() ?? Future.value();

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
  /// does, the app root puts the gate in front of the home screen — see LocationController.geoReady.
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
    await base.rebind();
    await repo.reloadLocal();

    repo.online = true;
    repo.error = null;
    notifyListeners();
    unawaited(onSignedIn?.call());
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
    await base.rebind();
    await repo.reloadLocal();
    repo.online = false;
    repo.error = null;
    notifyListeners();
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
    repo.error = null; // the previous session's banner has nothing to tell the next person
    await base.rebind();
    await repo.reloadLocal(); // clears the screen of the person who just left
    notifyListeners(); // and the root swaps in the login form
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
  /// is holding it, and it cannot show anybody else's figures anyway (see HomeController.objectId: a
  /// saved id is honoured only if it is in the newcomer's own list of objects). The
  /// located place is not that: it is where *this* person stood, it lives in their base,
  /// and it goes with it.
  ///
  /// The unsent queue dies with the base, which is the whole reason the screen asks first
  /// and says how many changes that is (see [unsentChanges]).
  Future<void> signOutAndWipe() async {
    // read while the session is still whole: it is the name of everything being erased
    final key = base.userKey ??
        (session.login.isEmpty
            ? null
            : LocalDb.keyFor(settings.baseUrl, session.login));
    // тоже до очистки сессии и по той же причине, что в signOut: «стереть всё своё» без
    // снятия регистрации оставило бы на телефоне ровно то, что человек хотел убрать
    await push?.unregister();
    await session.clear();
    repo.error = null;
    await base.rebind(); // the base closes here — an open file must not be deleted under it
    await repo.reloadLocal();
    notifyListeners();
    if (key == null) return;
    await LocalDb.deleteFor(key);
    await FillController.deletePhotos(key);
    await PastFillController.deletePhotos(key);
    await TaskCommentsController.deletePhotos(key);
  }

  /// How many changes this person has made that the server has not taken yet — the status
  /// queue the sync badge counts plus the fill queues, which are drained by the task screen
  /// that owns them and are therefore invisible from here.
  ///
  /// Asked before signing out: a warning about what stays unsent is worth nothing unless it
  /// counts the photo taken in the aisle as well as the tick in the list.
  Future<int> unsentChanges() async => await base.db?.queues.pendingChanges() ?? 0;

  /// The address is half of the base's name, so pointing the app at another server points
  /// it at another base — the same person on the test server and on the live one keeps two
  /// caches, and neither of them shows the other's tasks.
  ///
  /// Объект настроек один на приложение — его держат и клиент API, и контроллеры, —
  /// поэтому значения переносятся в него, а не подменяется он сам.
  Future<void> updateSettings(Settings s) async {
    settings.copyFrom(s);
    await base.rebind();
    await repo.reloadLocal();
    notifyListeners(); // «настроено» — корень покажет форму входа
  }
}
