import 'dart:async';

import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';

import 'data/account_controller.dart';
import 'data/api_client.dart';
import 'data/geo.dart';
import 'data/home_controller.dart';
import 'data/location_controller.dart';
import 'data/notifications_controller.dart';
import 'data/push_service.dart';
import 'data/session.dart';
import 'data/settings.dart';
import 'data/sync/outbox_drain.dart';
import 'data/sync_coordinator.dart';
import 'data/task_repository.dart';
import 'data/user_base.dart';
import 'ui/appearance_controller.dart';

/// Контроллеры приложения, собранные и связанные в одном месте — то, что раньше было
/// одним TaskRepository. Каждый отвечает за свою область и уведомляет своих слушателей;
/// экраны берут из дерева ровно того, кого читают.
///
/// Порядок сборки — порядок зависимостей: база и вердикт о сети, потом место, потом
/// список (он делит задачи по месту), потом главная, лента и учётная запись (им нужен
/// список), последним — синхронизация, которая знает всех и подписывается на их события.
/// Порядок регистрации в базе ([UserBase.onChange]) — тот же, и он значим: строка
/// «прошлая проверка» на главной ищет объект по месту, которое к этому моменту уже
/// прочитано.
class AppControllers {
  final ApiClient api;
  final Settings settings;
  final Session session;
  final Geo geo;
  final UserBase base;
  final LocationController location;
  final TaskRepository repo;
  final HomeController home;
  final NotificationsController notifications;
  final AccountController account;
  final AppearanceController appearance;
  final SyncCoordinator sync;

  AppControllers._(
      {required this.api,
      required this.settings,
      required this.session,
      required this.geo,
      required this.base,
      required this.location,
      required this.repo,
      required this.home,
      required this.notifications,
      required this.account,
      required this.appearance,
      required this.sync});

  /// [push] и [geo] необязательны: тестам и сборке без Firebase пуш не нужен, а
  /// телефон подменяется фейком.
  factory AppControllers(
      {required ApiClient api,
      required Settings settings,
      required Session session,
      PushService? push,
      Geo? geo}) {
    final device = geo ?? Geo();
    final base = UserBase(settings: settings, session: session);
    final drain = OutboxDrain(() => base.db);
    final location = LocationController(
        session: session, geo: device, api: api, base: base, drain: drain);
    final repo = TaskRepository(
        api: api,
        settings: settings,
        session: session,
        base: base,
        location: location,
        drain: drain,
        geo: device);
    final home = HomeController(
        api: api,
        settings: settings,
        session: session,
        base: base,
        location: location,
        repo: repo);
    final notifications = NotificationsController(
        api: api, session: session, settings: settings, base: base);
    final account = AccountController(
        api: api,
        session: session,
        settings: settings,
        base: base,
        repo: repo,
        push: push);
    final appearance = AppearanceController(api: api, settings: settings);
    final sync = SyncCoordinator(
        api: api,
        session: session,
        settings: settings,
        base: base,
        repo: repo,
        location: location,
        home: home,
        notifications: notifications,
        account: account,
        refreshBrand: appearance.refreshBrand);
    return AppControllers._(
        api: api,
        settings: settings,
        session: session,
        geo: device,
        base: base,
        location: location,
        repo: repo,
        home: home,
        notifications: notifications,
        account: account,
        appearance: appearance,
        sync: sync);
  }

  /// Запуск: открыть базу того, кто вошёл (если сессия пережила перезапуск), поднять
  /// список из неё — и только потом фон: слушатель сети, первые запросы, таймеры.
  Future<void> init() async {
    await base.rebind();
    await repo.reloadLocal();
    await sync.start();
  }

  void dispose() {
    sync.dispose();
    account.dispose();
    home.dispose();
    notifications.dispose();
    location.dispose();
    repo.dispose();
    unawaited(base.close());
  }

  /// Что положить в дерево над экранами. Сам [AppControllers] тоже — для обвязки
  /// тестов, которой нужен доступ ко всем сразу; экраны берут контроллеры по одному.
  List<SingleChildWidget> get providers => [
        Provider<AppControllers>.value(value: this),
        ChangeNotifierProvider<TaskRepository>.value(value: repo),
        ChangeNotifierProvider<LocationController>.value(value: location),
        ChangeNotifierProvider<HomeController>.value(value: home),
        ChangeNotifierProvider<NotificationsController>.value(
            value: notifications),
        ChangeNotifierProvider<AccountController>.value(value: account),
        ChangeNotifierProvider<SyncCoordinator>.value(value: sync),
        Provider<AppearanceController>.value(value: appearance),
      ];
}
