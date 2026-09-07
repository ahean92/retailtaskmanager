import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/place.dart';
import 'api_client.dart';
import 'geo.dart';
import 'local_db.dart';
import 'session.dart';
import 'sync/outbox_drain.dart';
import 'user_base.dart';

/// Где человек стоит: гео-гейт на входе, «Обновить местоположение» в шапке списка и
/// выбор соседнего объекта (#36837). Координаты уходят в сессию, объекты вокруг — в
/// [place]; список задач делит по нему строки на «здесь» и «не здесь», главная берёт
/// из него объект по умолчанию.
class LocationController extends ChangeNotifier {
  final Session session;
  final Geo geo;
  final ApiClient api;
  final UserBase base;

  /// Вердикт о сети — общий с очередями ([OutboxDrain]): «сервер не ответил, кто
  /// рядом» и «сервер не принял ответ бланка» зажигают один и тот же баннер.
  final OutboxDrain drain;

  /// Место сменилось — по свежему фиксу или выбору соседа. The tasks are the server's
  /// answer to «на каком объекте я стою», so a new place is a new list — this is
  /// «Обновить местоположение честно перестраивает список»: список перестраивается
  /// из кэша в том же кадре, а сервер спрашивается следом, не задерживая дверь. Кто
  /// именно это делает, решает SyncCoordinator; здесь — только сообщение.
  Future<void> Function()? onPlaceChanged;

  LocationController(
      {required this.session,
      required this.geo,
      required this.api,
      required this.base,
      required this.drain}) {
    base.onChange(_onBase);
  }

  /// Where the app thinks the person is, and who else is nearby. Loaded from their base
  /// on the way in, so an app reopened without a signal knows which object it is showing.
  Place place = const Place();

  /// A location is being taken right now — the header's «Обновить» is spinning.
  bool locating = false;

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

  /// База сменилась: whoever is at the app now is somebody else than a moment ago (or
  /// nobody) — the location gate is theirs to pass, not one they inherit already open;
  /// and so is the shop somebody was standing in: whoever comes next is asked themselves.
  Future<void> _onBase(LocalDb? db) async {
    _located = false;
    place = const Place();
    if (db != null) await _loadPlace(db);
  }

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
        // by the new object now, not when the server gets round to answering — and the
        // server is asked after that, without holding the door (see [onPlaceChanged])
        await onPlaceChanged?.call();
      }
    } finally {
      locating = false;
      notifyListeners();
    }
    return outcome;
  }

  /// Who is around this fix, and which of them the person is at.
  ///
  /// A server that does not answer leaves the previous place standing rather than
  /// emptying it: offline the saved object is the only thing that makes the cached list
  /// mean anything, and «сервер молчит» must not be shown as «рядом никого нет».
  Future<void> _askNearby(GeoFix fix) async {
    final failure = await drain.attempt(() async {
      final objects = await api.fetchNearbyObjects(fix.latitude, fix.longitude);
      place = Place(
        objects: objects,
        objectId: Place.pick(objects, previous: place.objectId),
        latitude: fix.latitude,
        longitude: fix.longitude,
        at: fix.at,
        answered: true,
      );
    });
    if (failure is SessionExpiredException) {
      return; // the session is already cleared — the app root shows the login screen
    }
    if (failure != null) place = place.fixedAt(fix.latitude, fix.longitude);
    await _savePlace();
  }

  /// The person says which of the neighbouring objects they are actually at — two shops in
  /// one shopping centre are metres apart and nothing but the person knows which one they
  /// walked into.
  Future<void> selectNearby(String id) async {
    if (place.objectId == id) return;
    place = place.select(id);
    await _savePlace();
    notifyListeners(); // the header shows the choice now
    await onPlaceChanged?.call(); // and the list rebuilds now, not when the server gets round to it
  }

  Future<void> _savePlace() async {
    final db = base.db;
    if (db == null) return;
    await db.cache.savePlace(jsonEncode(place.toJson()),
        (place.at ?? DateTime.now()).toIso8601String());
  }

  /// Where this person was standing when they last closed the app. Read out of their own
  /// base, so a phone reopened in the aisle without a signal shows the shop it is in and
  /// filters the cached tasks by it, instead of asking the GPS all over again.
  Future<void> _loadPlace(LocalDb db) async {
    final json = await db.cache.getPlace();
    if (json == null || json.isEmpty) return;
    try {
      place = Place.fromJson((jsonDecode(json) as Map).cast<String, dynamic>());
    } catch (_) {
      // stored place unreadable — the gate will establish it again in a moment
    }
  }
}
