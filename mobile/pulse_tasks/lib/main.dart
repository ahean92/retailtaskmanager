import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'data/api_client.dart';
import 'data/push_service.dart';
import 'data/session.dart';
import 'data/settings.dart';
import 'data/task_repository.dart';
import 'ui/brand.dart';
import 'ui/geo_gate_screen.dart';
import 'ui/home_screen.dart';
import 'ui/login_screen.dart';
import 'ui/notifications_screen.dart';
import 'ui/settings_screen.dart';
import 'ui/task_detail_screen.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final settings = await Settings.load();
  final session = await Session.load();

  // Apply the brand kept from the last run BEFORE the first frame — otherwise the app
  // opens in its own colours and repaints into the customer's a moment later, which
  // reads as a glitch rather than as branding.
  if (settings.brandJson.isNotEmpty) {
    try {
      Wms.brand = Brand.fromJson(
          (jsonDecode(settings.brandJson) as Map).cast<String, dynamic>());
    } catch (_) {
      // stored brand unreadable — the default palette is a perfectly good fallback
    }
  }

  // и тема — тоже до первого кадра, и по той же причине: приложение, открывшееся
  // светлым и потемневшее через мгновение, выглядит сбоем, а не выбором человека
  await Wms.loadMode();

  // the local base is not opened here: it is named after whoever is signed in, so it is
  // the repository that opens it — at startup if the session survived, at the sign-in
  // otherwise — and closes it again when they leave
  final api = ApiClient(settings, session);
  final push = PushService(api: api, session: session);
  final repo =
      TaskRepository(api: api, settings: settings, session: session, push: push);

  push.onForegroundMessage = () => unawaited(repo.refreshNotifications());
  // Кадра ещё нет, а сообщение, которым приложение и открыли, придёт прямо внутри
  // push.init() ниже — навигатора в этот момент не существует. Поэтому переход
  // откладывается до первого кадра, а не выполняется на месте.
  push.onOpenTask = (taskId) => WidgetsBinding.instance
      .addPostFrameCallback((_) => unawaited(_openTaskFromPush(repo, taskId)));

  // до repo.init(): именно repo регистрирует телефон, когда видит живую сессию, и к
  // этому моменту Firebase должен быть уже поднят
  await push.init();
  await repo.init();

  runApp(PulseApp(repo: repo));
}

/// Открыть задачу, по уведомлению о которой нажали.
///
/// Гейт геолокации здесь не обходится намеренно: пуш — это способ позвать человека в
/// приложение, а не способ войти в него мимо двери. Пока гейт не пройден, уведомление
/// просто открывает приложение, и дальше человек идёт обычным путём.
///
/// Задачи может не оказаться в списке: он приезжает под объект, у которого человек
/// стоит, и уведомление могло прийти про другой магазин или про задачу, которую успели
/// закрыть. Один раз пробуем обновиться, а если и после этого её нет — открываем ленту:
/// там запись есть с заголовком и текстом, и это честнее пустого экрана деталки.
Future<void> _openTaskFromPush(TaskRepository repo, String taskId) async {
  final nav = PulseApp.navigatorKey.currentState;
  if (nav == null || !repo.session.isActive || !repo.geoReady) return;

  bool known() =>
      repo.tasks.any((t) => t.id == taskId || t.task.clientId == taskId);
  if (!known()) await repo.syncAndRefresh();

  nav.push(MaterialPageRoute(
    builder: (_) => known()
        ? TaskDetailScreen(taskId: taskId)
        : const NotificationsScreen(),
  ));
}

class PulseApp extends StatefulWidget {
  final TaskRepository repo;
  const PulseApp({super.key, required this.repo});

  /// Kept at the app level so a session that dies mid-work can take the screens above it
  /// down: swapping the root alone would leave the task somebody was in the middle of
  /// sitting on top of the login form.
  static final navigatorKey = GlobalKey<NavigatorState>();

  @override
  State<PulseApp> createState() => _PulseAppState();
}

class _PulseAppState extends State<PulseApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Телефон переключили на тёмное — руками или ночным режимом по расписанию. При
  /// выборе «как в системе» приложение обязано пойти следом на месте: человек в зале
  /// не станет его перезапускать, да и не должен.
  @override
  void didChangePlatformBrightness() => Wms.resolve();

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<TaskRepository>.value(
      value: widget.repo,
      // One binary for every customer: the name and the palette come from the brand the
      // server supplies once the address is known, so the whole app is rebuilt when it
      // arrives rather than being decided at build time.
      //
      // Второй слушатель — тема: MaterialApp'у нужны обе (светлая и тёмная) плюс режим,
      // а виджетам ниже — уже выбранная палитра, и приезжает она первым нотификатором.
      child: ValueListenableBuilder<Brand>(
        valueListenable: Wms.notifier,
        builder: (context, brand, _) => ValueListenableBuilder<ThemeMode>(
          valueListenable: Wms.mode,
          builder: (context, mode, __) => MaterialApp(
            navigatorKey: PulseApp.navigatorKey,
            title: brand.tagline.isEmpty
                ? brand.name
                : '${brand.name} — ${brand.tagline}',
            debugShowCheckedModeBanner: false,
            theme: buildAppTheme(Wms.base),
            darkTheme: buildAppTheme(Wms.darkPalette, dark: true),
            themeMode: mode,
            home: Consumer<TaskRepository>(
              builder: (context, repo, _) => _start(repo),
            ),
          ),
        ),
      ),
    );
  }

  /// Four states, in the order a device goes through them: an address has to be set up
  /// once, then somebody signs in, then — for everyone the server says works by location —
  /// the app finds out where that is, and from the next launch on the saved session takes
  /// them straight to the tasks.
  ///
  /// The gate is here rather than inside the sign-in so that it stands on every way in,
  /// including the one that skips the login form: a session restored at startup passes it
  /// too, and a permission withdrawn overnight therefore stops the app at the door.
  Widget _start(TaskRepository repo) {
    if (!repo.settings.isConfigured) return const SettingsScreen(firstRun: true);
    if (!repo.session.isActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        PulseApp.navigatorKey.currentState?.popUntil((r) => r.isFirst);
      });
      return const LoginScreen();
    }
    if (!repo.geoReady) return const GeoGateScreen();
    return const HomeScreen();
  }
}
