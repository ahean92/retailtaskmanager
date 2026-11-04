import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:pulse_tasks/app_controllers.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/geo.dart';
import 'package:pulse_tasks/data/push_service.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/main.dart' as app_main;
import 'package:pulse_tasks/ui/chat_list_screen.dart';
import 'package:pulse_tasks/ui/chat_push_banner.dart';
import 'package:pulse_tasks/ui/chat_screen.dart';
import 'support/fake_server.dart';
import 'support/test_env.dart';

/// Пуш чата (#37370): разбор event=chatMessage, плашка поверх чужого экрана,
/// немедленное обновление открытой переписки и переход по тапу — с одной
/// синхронизацией, если чат телефону ещё неизвестен. Контроллеры кэша и очередей
/// проверены в chat_test.dart, экраны — в chat_screens_test.dart.

int _seq = 0;

class _Server {
  List<Map<String, Object?>> chats = [];
  final messages = <int, List<Map<String, Object?>>>{};

  /// Имена ручек всех запросов — по ним тесты считают «сколько раз синхронизировались».
  final asked = <String>[];

  late final Session session;
  late final ApiClient api;

  _Server(Settings settings) {
    session = Session(
      login: 'push${DateTime.now().microsecondsSinceEpoch}_${_seq++}',
      name: 'Кузнецов К.К.',
      token: 'token',
      signedIn: true,
      performerId: 'p1',
    );
    api = ApiClient(settings, session, client: MockClient((request) async {
      final action = actionOf(request);
      asked.add(action);
      if (request.method == 'POST') return http.Response('', 200);
      switch (action) {
        case 'apiChats':
          return okJson(jsonEncode(chats));
        case 'apiChatMessages':
          final id = int.parse(request.url.queryParameters['id']!);
          return okJson(jsonEncode(messages[id] ?? const []));
        default:
          return okJson('[]');
      }
    }));
  }

  int countOf(String action) => asked.where((a) => a == action).length;
}

Future<AppControllers> _app(Settings settings, _Server server) async {
  final app = AppControllers(
      api: server.api, settings: settings, session: server.session);
  await app.account.updateSettings(settings); // открывает базу этого логина
  return app;
}

Map<String, Object?> _chat() => {
      'id': 7,
      'kind': 'dialog',
      'name': 'Иванов И.И.',
      'peerId': 42,
      'members': 2,
      'unread': 1,
      'today': '2026-11-02',
      'last': [
        {'id': 50, 'author': 'Иванов И.И.', 'text': 'примите накладную'}
      ],
    };

void main() {
  initTestEnv();

  late Settings settings;
  late _Server server;
  late Directory docs;

  setUp(() {
    resetMockStores();
    docs = Directory.systemTemp.createTempSync('pulse_chat_push');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => docs.path);
    settings = Settings(baseUrl: 'http://test.local:9080');
    server = _Server(settings);
  });

  tearDown(() async {
    if (docs.existsSync()) docs.deleteSync(recursive: true);
  });

  group('разбор пуша (chatTargetOf)', () {
    test('чат: event=chatMessage, chatId строкой, taskId пуст', () {
      final m = RemoteMessage(data: {
        'event': 'chatMessage',
        'taskId': '',
        'date': '2026-11-02',
        'chatId': '81234567',
      });
      expect(PushService.chatTargetOf(m), 81234567);
    });

    test('задача: без event=chatMessage идёт прежним путём taskId', () {
      final m = RemoteMessage(data: {
        'event': 'taskAssigned',
        'taskId': 'ST000014',
        'date': '2026-11-02',
      });
      expect(PushService.chatTargetOf(m), isNull,
          reason: 'пуши задач открываются как раньше');
    });

    test('битый chatId — не открывать непонятно что', () {
      final m = RemoteMessage(
          data: {'event': 'chatMessage', 'taskId': '', 'chatId': 'семь'});
      expect(PushService.chatTargetOf(m), isNull);
    });
  });

  test('плашка: новое заменяет висящее и уходит таймером', () async {
    final app = await _app(settings, server);
    app.chat.liveHideAfter = const Duration(milliseconds: 150);
    app.chat.showLive(7, title: 'Иванов И.И.', body: 'примите накладную');
    expect(app.chat.liveMessage?.chatId, 7);

    app.chat.showLive(8, title: 'Смена', body: 'Иван: выходи');
    expect(app.chat.liveMessage?.chatId, 8,
        reason: 'свежее сообщение важнее висящего');

    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(app.chat.liveMessage, isNull, reason: 'ушла сама');

    app.chat.hideLive(); // уже скрыта — не падает и не шумит
    expect(app.chat.liveMessage, isNull);
    app.dispose();
  });

  testWidgets('чужой экран — плашка «Иван: …», кнопка «Открыть» ведёт в чат',
      (tester) async {
    await tester.runAsync(() async {
      server.chats = [_chat()];
      final app = await _app(settings, server);
      app.chat.liveHideAfter = const Duration(seconds: 30);
      await app.chat.refresh();
      final opened = <int>[];
      await tester.pumpWidget(MultiProvider(
        providers: app.providers,
        child: MaterialApp(
          navigatorKey: app_main.PulseApp.navigatorKey,
          builder: (context, child) => ChatPushBannerOverlay(
            onOpen: opened.add,
            child: child!,
          ),
          home: const ChatListScreen(),
        ),
      ));
      await tester.pump();

      app_main.chatPushArrived(app, 7, 'Иванов И.И.',
          '3 новых · Иванов И.И.: примите накладную');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(app.chat.liveMessage?.chatId, 7);
      // тело пуша уникально для плашки: список показывает своё превью «Иванов И.И.: …»
      expect(find.text('3 новых · Иванов И.И.: примите накладную'),
          findsOneWidget);
      expect(find.text('Открыть'), findsOneWidget);

      await tester.tap(find.text('Открыть'));
      expect(opened, [7], reason: 'кнопка плашки зовёт тот же переход, что пуш');
      app.dispose();
    });
  });

  testWidgets('открыта переписка этого чата — просто обновляется, без плашки',
      (tester) async {
    await tester.runAsync(() async {
      server.chats = [_chat()];
      server.messages[7] = [
        {
          'id': 50,
          'authorId': 42,
          'author': 'Иванов И.И.',
          'dateTime': '2026-11-02 09:00:00',
          'text': 'примите накладную',
        },
      ];
      final app = await _app(settings, server);
      app.chat.liveHideAfter = const Duration(seconds: 30);
      await app.chat.refresh(); // метаданные чата — в кэше
      await tester.pumpWidget(MultiProvider(
        providers: app.providers,
        child: MaterialApp(
          navigatorKey: app_main.PulseApp.navigatorKey,
          home: const ChatScreen(chatId: 7),
        ),
      ));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();

      final before = server.countOf('apiChatMessages');
      app_main.chatPushArrived(app, 7, 'Иванов И.И.', 'ещё сообщение');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();

      expect(app.chat.liveMessage, isNull,
          reason: 'переписка на экране — плашке здесь не место');
      expect(server.countOf('apiChatMessages'), greaterThan(before),
          reason: 'обновилась немедленно, не дожидаясь десятисекундного тика');
      app.dispose();
    });
  });

  testWidgets('тап по пушу: чат неизвестен — одна синхронизация, потом переписка',
      (tester) async {
    await tester.runAsync(() async {
      server.chats = [_chat()];
      final app = await _app(settings, server); // список НЕ refreshed — чата нет в кэше
      await tester.pumpWidget(MultiProvider(
        providers: app.providers,
        child: MaterialApp(
          navigatorKey: app_main.PulseApp.navigatorKey,
          home: const Scaffold(body: SizedBox()),
        ),
      ));
      await tester.pump();

      final chatsBefore = server.countOf('apiChats');
      await app_main.openChatFromPush(app, 7);
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();

      final nav = app_main.PulseApp.navigatorKey.currentState!;
      expect(nav.canPop(), true, reason: 'что-то открылось поверх корня');
      expect(find.byType(ChatScreen), findsOneWidget);
      expect(server.countOf('apiChats') - chatsBefore, 1,
          reason: 'ровно одна синхронизация списка');
      app.dispose();
    });
  });

  testWidgets('чат так и не приехал — список чатов с подсказкой, а не пустота',
      (tester) async {
    await tester.runAsync(() async {
      server.chats = const []; // сервер этот чат не отдаёт
      final app = await _app(settings, server);
      // корень без своего Scaffold: SnackBar рисуется на всех зарегистрированных
      // скаффолдах разом, и второй экземпляр под корнем путает подсчёт текстов
      await tester.pumpWidget(MultiProvider(
        providers: app.providers,
        child: MaterialApp(
          navigatorKey: app_main.PulseApp.navigatorKey,
          home: const SizedBox(),
        ),
      ));
      await tester.pump();

      await app_main.openChatFromPush(app, 7);
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(ChatListScreen), findsOneWidget,
          reason: 'честнее список со своими подсказками, чем пустая переписка');
      expect(find.text('Чат ещё не загрузился — проверьте связь'),
          findsOneWidget);
      app.dispose();
    });
  });

  testWidgets('переписка уже на экране — тап по пушу не наслаивает вторую копию',
      (tester) async {
    await tester.runAsync(() async {
      server.chats = [_chat()];
      server.messages[7] = [
        {
          'id': 50,
          'authorId': 42,
          'author': 'Иванов И.И.',
          'dateTime': '2026-11-02 09:00:00',
          'text': 'примите накладную',
        },
      ];
      final app = await _app(settings, server);
      await app.chat.refresh();
      await tester.pumpWidget(MultiProvider(
        providers: app.providers,
        child: MaterialApp(
          navigatorKey: app_main.PulseApp.navigatorKey,
          home: const ChatScreen(chatId: 7),
        ),
      ));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();

      final before = server.countOf('apiChatMessages');
      await app_main.openChatFromPush(app, 7);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();

      final nav = app_main.PulseApp.navigatorKey.currentState!;
      expect(nav.canPop(), false, reason: 'второго экрана не появилось');
      expect(find.byType(ChatScreen), findsOneWidget);
      expect(server.countOf('apiChatMessages'), greaterThan(before),
          reason: 'вместо копии — немедленное обновление открытой');
      app.dispose();
    });
  });

  testWidgets(
      'пуш, поднявший приложение, ждёт гео-гейт, а не гаснет в первом кадре',
      (tester) async {
    await tester.runAsync(() async {
      server.chats = [_chat()];
      // гейт действует, а место ещё не определено: фиксу «едет» через Completer
      server.session.geoRequired = true;
      final gate = Completer<GeoFix?>();
      final app = AppControllers(
          api: server.api,
          settings: settings,
          session: server.session,
          geo: Geo(platform: _GateGeoPlatform(gate)));
      await app.account.updateSettings(settings);
      await app.chat.refresh();
      await tester.pumpWidget(MultiProvider(
        providers: app.providers,
        child: MaterialApp(
          navigatorKey: app_main.PulseApp.navigatorKey,
          home: const SizedBox(),
        ),
      ));
      await tester.pump();

      final nav = app_main.PulseApp.navigatorKey.currentState!;
      final opening = app_main.openChatFromPush(app, 7);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(nav.canPop(), false,
          reason: 'гейт не прошёл — перехода ещё нет, но пуш и не ушёл');

      unawaited(app.location.locate()); // гейт заработал…
      await Future<void>.delayed(const Duration(milliseconds: 100));
      gate.complete(GeoFix(53.9, 27.56, DateTime.now())); // …и получил место
      await Future<void>.delayed(const Duration(milliseconds: 500));
      // sanity: гейт действительно прошёл, иначе тест врёт сам себе
      expect(app.location.geoReady, isTrue,
          reason: 'locate с фиксом обязан открыть гейт');
      await opening; // пуш дождался двери и открыл переписку
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(nav.canPop(), isTrue, reason: 'что-то открылось поверх корня');
      expect(find.byType(ChatListScreen), findsNothing,
          reason: 'фоллбэк в список значил бы, что чат не нашли в кэше');

      expect(find.byType(ChatScreen), findsOneWidget);
      app.dispose();
    });
  });
}

/// Гео платформа теста «пуш ждёт гейт»: всё разрешено, а запомненный фикс
/// появляется только когда тест отпускает защёлку.
class _GateGeoPlatform implements GeoPlatform {
  final Completer<GeoFix?> _gate;

  _GateGeoPlatform(this._gate);

  @override
  Future<bool> servicesEnabled() async => true;
  @override
  Future<GeoPermission> permission() async => GeoPermission.granted;
  @override
  Future<GeoPermission> requestPermission() async => GeoPermission.granted;
  @override
  Future<GeoFix?> lastKnown() => _gate.future;
  @override
  Future<GeoFix?> fix(Duration timeout) async => null;
  @override
  Future<void> openSettings({required bool locationServices}) async {}
}
