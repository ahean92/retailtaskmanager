import 'package:flutter/foundation.dart';

import '../models/route.dart';
import 'api_client.dart';
import 'geo.dart';
import 'local_db.dart';
import 'quiet_after_dispose.dart';
import 'session.dart';
import 'settings.dart';
import 'task_repository.dart';
import 'user_base.dart';

class RouteController extends ChangeNotifier with QuietAfterDispose {
  final ApiClient api;
  final Settings settings;
  final Session session;
  final UserBase base;
  final TaskRepository repo;
  final Geo geo;

  RouteController(
      {required this.api,
      required this.settings,
      required this.session,
      required this.base,
      required this.repo,
      required this.geo}) {
    base.onChange(_onBase);
  }

  static const needsNetwork = 'Нужна связь';
  static const _noRoutes = '';

  RoutePlan? plan;
  bool supported = true;
  bool busy = false;
  String? error;
  DateTime? fetchedAt;

  bool get online => repo.online;

  bool get _ready =>
      settings.isConfigured && session.isActive && base.db != null;

  Future<void> _onBase(LocalDb? db) async {
    plan = null;
    supported = true;
    error = null;
    fetchedAt = null;
    if (db != null) {
      try {
        final cached = await db.cache.getRoute();
        supported = cached != _noRoutes;
        plan = RoutePlan.parse(cached);
      } catch (_) {
        plan = null;
      }
    }
    notifyListeners();
  }

  Future<void> refresh() async {
    if (!_ready) return;
    String? raw;
    final failure = await repo.drain.attempt(() async {
      raw = await api.fetchRouteRaw();
    });
    if (failure is ApiException &&
        (failure.status == 404 || failure.status == 403)) {
      supported = false;
      plan = null;
      await _store(_noRoutes);
      notifyListeners();
      return;
    }
    if (failure != null) {
      notifyListeners();
      return;
    }
    supported = true;
    await _accept(raw ?? '');
  }

  Future<bool> build() async {
    if (!_ready || busy) return false;
    if (!online) {
      error = needsNetwork;
      notifyListeners();
      return false;
    }
    busy = true;
    error = null;
    notifyListeners();
    double? lat;
    double? lon;
    try {
      final outcome = await geo.locate();
      if (outcome is GeoFix) {
        lat = outcome.latitude;
        lon = outcome.longitude;
      }
    } catch (_) {
      lat = null;
    }
    lat ??= session.latitude;
    lon = lat == null ? null : (lon ?? session.longitude);
    String? raw;
    final failure = await repo.drain.attempt(() async {
      raw = await api.buildRouteRaw(lat: lat, lon: lon);
    });
    busy = false;
    if (failure != null) {
      error = _say(failure);
      notifyListeners();
      return false;
    }
    await _accept(raw ?? '');
    return true;
  }

  Future<bool> reorder(int oldIndex, int newIndex) async {
    final current = plan;
    if (current == null || busy) return false;
    if (!online) {
      error = needsNetwork;
      notifyListeners();
      return false;
    }
    final stops = [...current.stops];
    if (oldIndex < 0 || oldIndex >= stops.length) return false;
    if (newIndex < 0 || newIndex >= stops.length) return false;
    if (newIndex == oldIndex) return true;
    stops.insert(newIndex, stops.removeAt(oldIndex));
    plan = current.reordered(stops);
    busy = true;
    error = null;
    notifyListeners();
    String? raw;
    final failure = await repo.drain.attempt(() async {
      raw = await api.orderRouteRaw(
          current.id, [for (final s in stops) s.objectId]);
    });
    busy = false;
    if (failure != null) {
      plan = current;
      error = _say(failure);
      notifyListeners();
      return false;
    }
    await _accept(raw ?? '');
    return true;
  }

  void clearError() {
    if (error == null) return;
    error = null;
    notifyListeners();
  }

  Future<void> _accept(String raw) async {
    plan = RoutePlan.parse(raw);
    fetchedAt = DateTime.now();
    await _store(raw.trim().isEmpty ? '{}' : raw);
    notifyListeners();
  }

  Future<void> _store(String raw) async {
    final db = base.db;
    if (db != null) {
      await db.cache.saveRoute(raw, DateTime.now().toIso8601String());
    }
  }

  String _say(Object failure) {
    if (failure is ApiException) return failure.message;
    if (failure is SessionExpiredException) return failure.toString();
    return '$needsNetwork: сервер не ответил';
  }
}
