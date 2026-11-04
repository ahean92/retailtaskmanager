import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_controllers.dart';
import 'data/account_controller.dart';
import 'data/api_client.dart';
import 'data/chat_controller.dart';
import 'data/location_controller.dart';
import 'data/push_service.dart';
import 'data/session.dart';
import 'data/settings.dart';
import 'ui/brand.dart';
import 'ui/app_shell.dart';
import 'ui/chat_list_screen.dart';
import 'ui/chat_push_banner.dart';
import 'ui/chat_screen.dart';
import 'ui/geo_gate_screen.dart';
import 'ui/login_screen.dart';
import 'ui/notifications_screen.dart';
import 'ui/settings_screen.dart';
import 'ui/task_detail_screen.dart';
import 'ui/task_result_screen.dart';
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
  // the controllers that open it — at startup if the session survived, at the sign-in
  // otherwise — and close it again when they leave
  final api = ApiClient(settings, session);
  final push = PushService(api: api, session: session);
  final app = AppControllers(
      api: api, settings: settings, session: session, push: push);

  push.onForegroundMessage = () => unawaited(app.notifications.refresh());
  // Сообщение чата в открытом приложении (#37370): список и бейдж обновляются, а
  // дальше — переписка этого чата сама, любой другой экран — плашкой.
  push.onForegroundChat = (chatId, note) =>
      chatPushArrived(app, chatId, note?.title ?? '', note?.body ?? '');
  // Кадра ещё нет, а сообщение, которым приложение и открыли, придёт прямо внутри
  // push.init() ниже — навигатора в этот момент не существует. Поэтому переход
  // откладывается до первого кадра, а не выполняется на месте.
  push.onOpenTask = (taskId) => WidgetsBinding.instance
      .addPostFrameCallback((_) => unawaited(_openTaskFromPush(app, taskId)));
  push.onOpenChat = (chatId) => WidgetsBinding.instance
      .addPostFrameCallback((_) => unawaited(openChatFromPush(app, chatId)));

  // до app.init(): именно учётная запись регистрирует телефон, когда видит живую
  // сессию, и к этому моменту Firebase должен быть уже поднят
  await push.init();
  await app.init();

  runApp(PulseApp(app: app));
}

/// Открыть задачу, по уведомлению о которой нажали.
///
/// Гейт геолокации здесь не обходится намеренно: пуш — это способ позвать человека в
/// приложение, а не способ войти в него мимо двери. Пока гейт не пройден, уведомление
/// просто открывает приложение, и дальше человек идёт обычным путём.
///
/// Задачи может не оказаться в списке: её успели закрыть (отменить, выполнить),
/// человек в ней больше не участвует (отписался, переназначили) или список просто
/// ещё не синхронизирован. Один раз пробуем обновиться; закрытую после этого
/// стягиваем по id — уведомление о ней остаётся в ленте 30 дней, и открывать по
/// нажатию можно и отменённую, чтобы прочесть описание и переписку (15.10). Если и
/// после этого её нет — открываем ленту: там запись есть с заголовком и текстом, и
/// это честнее пустого экрана деталки.
///
/// Задача ждёт решения этого человека (#37158) — открывается её результат: пуш «ожидает
/// приёмки» зовёт решить, а решают по тому, что сдано.
Future<void> _openTaskFromPush(AppControllers app, String taskId) async {
  final nav = PulseApp.navigatorKey.currentState;
  if (nav == null || !app.session.isActive || !app.location.geoReady) return;

  if (app.repo.viewOf(taskId) == null) await app.sync.syncAndRefresh();

  var view = app.repo.viewOf(taskId);
  view ??= await app.repo.loadTaskById(taskId);
  if (view != null && view.awaitingDecision) {
    nav.push(taskResultRoute(view));
    return;
  }
  nav.push(MaterialPageRoute(
    builder: (_) => view != null
        ? TaskDetailScreen(taskId: taskId)
        : const NotificationsScreen(),
  ));
}

/// Пуш о сообщении чата пришёл в открытое приложение (#37370). Список чатов и
/// число на иконке обновляются всегда; дальше — по месту человека: открытая
/// переписка этого чата просто обновляется (без плашки и без второго экрана),
/// любой другой экран получает плашку «Иван: …» с кнопкой «Открыть».
void chatPushArrived(AppControllers app, int chatId, String title, String body) {
  unawaited(app.chat.refresh());
  // над логином или гео-гейтом плашки не показываем: пуш зовёт человека в
  // приложение, а не в переписку мимо двери
  if (!app.session.isActive || !app.location.geoReady) return;
  if (OpenChatEntry.isCurrent(chatId)) {
    OpenChatEntry.nudge(chatId);
    return;
  }
  app.chat.showLive(chatId, title: title, body: body);
}

/// Открыть переписку чата, по уведомлению о которой нажали, — или по кнопке
/// «Открыть» плашки (#37370): путь один и тот же.
///
/// Гейт геолокации не обходится, по той же причине, что и у задачи выше, — но и
/// не разворачивается молча: пуш, поднявший приложение с нуля, приходит раньше,
/// чем первый фикс места, и проверка «гейт пройден» в первом же кадре гасила
/// переход, оставляя человека на главной. Пуш ждёт у двери, как человек: пока
/// гейт не прошёл — до 20 секунд; отвалившиеся GPS или умершая по пути сессия —
/// тихий уход, без обхода.
///
/// Чата может не быть в кэше: список ещё не синхронизирован, человека из чата
/// вывели или телефон офлайн. Один раз пробуем обновить список; если чат и после
/// этого не приехал — открываем список чатов с подсказкой: у списка есть свои
/// офлайн-подсказки, и это честнее пустой переписки о чужом разговоре.
Future<void> openChatFromPush(AppControllers app, int chatId) async {
  final nav = PulseApp.navigatorKey.currentState;
  if (nav == null || !app.session.isActive) return;
  if (!app.location.geoReady) {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (!app.location.geoReady &&
        app.session.isActive &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    if (!app.session.isActive || !app.location.geoReady) return;
  }

  app.chat.hideLive();

  // переписка этого чата уже на экране — вторую копию не наслаивать, просто обновить
  if (OpenChatEntry.isCurrent(chatId)) {
    OpenChatEntry.nudge(chatId);
    return;
  }

  final db = app.base.db;
  if (db != null && await db.chats.getChat(chatId) == null) {
    await app.chat.refresh();
  }
  final known = db != null && await db.chats.getChat(chatId) != null;
  if (known) {
    nav.push(MaterialPageRoute(builder: (_) => ChatScreen(chatId: chatId)));
    return;
  }
  nav.push(MaterialPageRoute(builder: (_) => const ChatListScreen()));
  WidgetsBinding.instance.addPostFrameCallback((_) {
    ScaffoldMessenger.of(nav.context).showSnackBar(
        const SnackBar(content: Text('Чат ещё не загрузился — проверьте связь')));
  });
}

class PulseApp extends StatefulWidget {
  final AppControllers app;
  const PulseApp({super.key, required this.app});

  /// Kept at the app level so a session that dies mid-work can take the screens above it
  /// down: swapping the root alone would leave the task somebody was in the middle of
  /// sitting on top of the login form.
  static final navigatorKey = GlobalKey<NavigatorState>();

  @override
  State<PulseApp> createState() => _PulseAppState();
}

class _PulseAppState extends State<PulseApp> with WidgetsBindingObserver {
  /// Была ли сессия жива на предыдущей сборке корня. Снести стек над логином
  /// надо только при реальном переходе «вошёл → вышел»: без этого флага any
  /// rebuild корня до входа (смена темы в настройках, приезжание бренда)
  /// захлопывал открытые с логина экраны — настройки закрывались сами.
  bool _wasActive = false;

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
    return MultiProvider(
      providers: widget.app.providers,
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
            // плашка нового сообщения чата (#37370) живёт поверх навигатора:
            // ей всё равно, какой экран открыт под ней, а кнопка «Открыть» идёт
            // тем же путём, что и тап по самому пушу
            builder: (context, child) => ChatPushBannerOverlay(
                  onOpen: (chatId) =>
                      unawaited(openChatFromPush(widget.app, chatId)),
                  child: child!,
                ),
            // корень слушает двоих: учётную запись (адрес настроен, вход, выход,
            // потеря сессии) и место (гейт пройден) — остальное экраны читают сами
            home: Builder(
              builder: (context) => _start(
                context.watch<AccountController>(),
                context.watch<LocationController>(),
              ),
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
  Widget _start(AccountController account, LocationController location) {
    if (!account.settings.isConfigured) {
      return const SettingsScreen(firstRun: true);
    }
    final active = account.session.isActive;
    if (active != _wasActive) {
      _wasActive = active;
      if (!active) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          PulseApp.navigatorKey.currentState?.popUntil((r) => r.isFirst);
        });
      }
    }
    if (!active) {
      return const LoginScreen();
    }
    if (!location.geoReady) return const GeoGateScreen();
    // редизайн #37411: корень — панель с вкладками, а не главная; вход с любой
    // вкладки в стек поверх неё
    return const AppShell();
  }
}
