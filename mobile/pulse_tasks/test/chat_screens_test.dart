import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:pulse_tasks/app_controllers.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/ui/chat_list_screen.dart';
import 'package:pulse_tasks/ui/chat_screen.dart';
import 'package:pulse_tasks/models/home.dart';
import 'package:pulse_tasks/models/quick_create.dart';
import 'support/fake_server.dart';
import 'support/test_env.dart';

/// Экраны чатов (#37369): правила видимости решает сервер — «только чтение»
/// вместо поля ввода, обычный диалог с полем, список с превью «Вы: …» и серым
/// непрочитанным у «без звука». Контроллеры проверены в chat_test.dart — здесь
/// только то, что рисуют экраны.

int _seq = 0;

class _Server {
  List<Map<String, Object?>> chats = [];
  final messages = <int, List<Map<String, Object?>>>{};

  late final Session session;
  late final ApiClient api;

  _Server(Settings settings) {
    session = Session(
      login: 'kuznetsov${DateTime.now().microsecondsSinceEpoch}_${_seq++}',
      name: 'Кузнецов К.К.',
      token: 'token',
      signedIn: true,
      performerId: 'p1',
    );
    api = ApiClient(settings, session, client: MockClient((request) async {
      final action = actionOf(request);
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
}

Future<AppControllers> _app(Settings settings, _Server server) async {
  final app = AppControllers(
      api: server.api, settings: settings, session: server.session);
  await app.account.updateSettings(settings); // открывает базу этого логина
  return app;
}

/// Долгое нажатие внутри runAsync (#37441): таймер распознавателя — настоящий,
/// и фейковые часы pump'а его не тикают — палец держим реальное время, лист
/// докручиваем уже часами теста.
Future<void> _longPressReal(WidgetTester tester, Finder finder) async {
  final gesture = await tester.startGesture(tester.getCenter(finder));
  await Future<void>.delayed(const Duration(milliseconds: 600));
  await tester.pump();
  await gesture.up();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  initTestEnv();

  late Settings settings;
  late _Server server;
  late Directory docs;

  setUp(() {
    resetMockStores();
    docs = Directory.systemTemp.createTempSync('pulse_chat_ui');
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

  testWidgets('чата «только чтение»: строки «Только чтение», поля ввода нет',
      (tester) async {
    // runAsync — как у карточки задачи: ffi-sqlite под капотом контроллеров
    // живёт настоящим временем, и без него загрузка переписки не доезжает
    await tester.runAsync(() async {
      server.chats = [
        {
          'id': 7,
          'kind': 'role',
          'name': 'Роль: Продавец',
          'members': 200,
          'readonly': true,
          'today': '2026-11-02',
          'last': [ {'id': 5, 'author': 'Иванов И.И.', 'text': 'смена закрыта'}],
        },
      ];
      server.messages[7] = [
        {
          'id': 5,
          'authorId': 42,
          'author': 'Иванов И.И.',
          'dateTime': '2026-11-02 09:00:00',
          'text': 'смена закрыта',
        },
      ];
      final app = await _app(settings, server);
      await app.chat.refresh(); // список уже на телефоне — метаданные чата в кэше
      await tester.pumpWidget(MultiProvider(
        providers: app.providers,
        child: const MaterialApp(home: ChatScreen(chatId: 7)),
      ));
      // pumpAndSettle внутри runAsync не селится (см. task_elsewhere_test), а
      // данные идут настоящим временем — пауза даёт загрузке доехать, кадр —
      // отрисоваться
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();

      expect(find.text('Роль: Продавец'), findsOneWidget);
      expect(find.text('смена закрыта'), findsOneWidget);
      expect(find.text('Только чтение'), findsOneWidget);
      expect(find.byType(TextField), findsNothing,
          reason: 'в ролевой чат писать нельзя (#37369)');
      app.dispose();
    });
  });

  testWidgets('диалог: пузыри с именем автора в группе и без него в диалоге, '
      'поле ввода на месте', (tester) async {
    await tester.runAsync(() async {
      server.chats = [
        {
          'id': 9,
          'kind': 'group',
          'name': 'Магазин 12',
          'members': 6,
          'today': '2026-11-02',
          'last': [ {'id': 20, 'mine': true, 'text': 'принято'}],
        },
      ];
      server.messages[9] = [
        {
          'id': 20,
          'authorId': 7,
          'author': 'Кузнецов К.К.',
          'mine': true,
          'dateTime': '2026-11-02 10:00:00',
          'text': 'принято',
          'status': 'seen',
        },
        {
          'id': 19,
          'authorId': 42,
          'author': 'Иванов И.И.',
          'dateTime': '2026-11-02 09:58:00',
          'text': 'примите накладную',
        },
      ];
      final app = await _app(settings, server);
      await app.chat.refresh(); // вид и имя чата переписка берёт из кэша списка
      await tester.pumpWidget(MultiProvider(
        providers: app.providers,
        child: const MaterialApp(home: ChatScreen(chatId: 9)),
      ));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();

      expect(find.text('примите накладную'), findsOneWidget);
      expect(find.text('Иванов И.И.'), findsOneWidget,
          reason: 'в группе чужое — с именем автора');
      expect(find.text('Кузнецов К.К.'), findsNothing,
          reason: 'своё в группе — без имени');
      expect(find.byType(TextField), findsOneWidget);
      expect(find.byIcon(Icons.done_all), findsOneWidget,
          reason: 'прочитанное — ✓✓ цветом');
      app.dispose();
    });
  });

  testWidgets('список: превью «Вы: …», серое непрочитанное у «без звука»',
      (tester) async {
    await tester.runAsync(() async {
      server.chats = [
        {
          'id': 7,
          'kind': 'dialog',
          'name': 'Иванов И.И.',
          'peerId': 42,
          'members': 2,
          'unread': 2,
          'today': '2026-11-02',
          'last': [ {'id': 50, 'author': 'Иванов И.И.', 'text': 'примите накладную'}],
        },
        {
          'id': 8,
          'kind': 'group',
          'name': 'Смена закрыта',
          'members': 5,
          'muted': true,
          'unread': 5,
          'today': '2026-11-02',
          'last': [ {'id': 51, 'mine': true, 'text': 'вышло'}],
        },
      ];
      final app = await _app(settings, server);
      await app.chat.refresh();
      await tester.pumpWidget(MultiProvider(
        providers: app.providers,
        child: const MaterialApp(home: ChatListScreen()),
      ));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();

      expect(find.text('Иванов И.И.'), findsOneWidget);
      expect(find.text('Иванов И.И.: примите накладную'), findsOneWidget);
      expect(find.text('Вы: вышло'), findsOneWidget);
      expect(find.text('2'), findsOneWidget,
          reason: 'непрочитанное обычного чата');
      expect(find.text('5'), findsOneWidget,
          reason: 'у «без звука» счётчик серым');
      expect(find.byIcon(Icons.notifications_off_outlined), findsOneWidget);
      expect(app.chat.unreadBadge, 2,
          reason: 'число на иконке «без звука» не считает');
      app.dispose();
    });
  });

  // Мост «сообщение → задача» (#37441, дизайн-док этап 2): долгое нажатие теперь
  // открывает меню — действий у сообщения стало два.

  testWidgets('меню сообщения: «Ответить» и «Создать задачу»', (tester) async {
    await tester.runAsync(() async {
      server.chats = [
        {
          'id': 9,
          'kind': 'group',
          'name': 'Магазин 12',
          'members': 6,
          'today': '2026-11-02',
          'last': [ {'id': 19, 'author': 'Иванов И.И.', 'text': 'примите накладную'}],
        },
      ];
      server.messages[9] = [
        {
          'id': 19,
          'authorId': 42,
          'author': 'Иванов И.И.',
          'dateTime': '2026-11-02 09:58:00',
          'text': 'примите накладную',
        },
      ];
      final app = await _app(settings, server);
      await app.chat.refresh();
      await tester.pumpWidget(MultiProvider(
        providers: app.providers,
        child: const MaterialApp(home: ChatScreen(chatId: 9)),
      ));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();

      await _longPressReal(tester, find.text('примите накладную'));

      expect(find.text('Ответить'), findsOneWidget);
      expect(find.text('Создать задачу'), findsOneWidget);

      // прежний сценарий не сломан: ответ из меню ставит цитату над полем ввода
      await tester.tap(find.text('Ответить'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Иванов И.И.: примите накладную'), findsOneWidget,
          reason: '«Ответить» из меню — тот же путь, что long-press в #37369');
      app.dispose();
    });
  });

  testWidgets('ролевой чат «только чтение»: в меню только «Создать задачу»',
      (tester) async {
    await tester.runAsync(() async {
      server.chats = [
        {
          'id': 7,
          'kind': 'role',
          'name': 'Роль: Продавец',
          'members': 200,
          'readonly': true,
          'today': '2026-11-02',
          'last': [ {'id': 5, 'author': 'Иванов И.И.', 'text': 'смена закрыта'}],
        },
      ];
      server.messages[7] = [
        {
          'id': 5,
          'authorId': 42,
          'author': 'Иванов И.И.',
          'dateTime': '2026-11-02 09:00:00',
          'text': 'смена закрыта',
        },
      ];
      final app = await _app(settings, server);
      await app.chat.refresh();
      await tester.pumpWidget(MultiProvider(
        providers: app.providers,
        child: const MaterialApp(home: ChatScreen(chatId: 7)),
      ));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();

      await _longPressReal(tester, find.text('смена закрыта'));
      // писать в ролевой нельзя (#37369), но превратить сообщение в задачу —
      // можно: создание — не письмо в чат, ответ туда сервер не поставит
      expect(find.text('Создать задачу'), findsOneWidget);
      expect(find.text('Ответить'), findsNothing);
      app.dispose();
    });
  });

  testWidgets('мост: «Создать задачу» открывает экран создания с текстом сообщения',
      (tester) async {
    await tester.runAsync(() async {
      server.chats = [
        {
          'id': 9,
          'kind': 'dialog',
          'name': 'Иванов И.И.',
          'peerId': 42,
          'members': 2,
          'today': '2026-11-02',
          'last': [ {'id': 19, 'author': 'Иванов И.И.', 'text': 'примите накладную'}],
        },
      ];
      server.messages[9] = [
        {
          'id': 19,
          'authorId': 42,
          'author': 'Иванов И.И.',
          'dateTime': '2026-11-02 09:58:00',
          'text': 'примите накладную',
        },
      ];
      final app = await _app(settings, server);
      await app.chat.refresh();
      // один пресет — выбор без листа, прямо экран создания (как у «+» на главной)
      app.home.layout = HomeLayout.fromJson({
        'objects': [
          {'id': 'A', 'name': 'Объект A'},
        ],
      });
      app.home.quickCreate = const QuickCreateData(actions: [
        QuickPreset(code: 'errand', title: 'Поручение', typeId: 'issue'),
      ]);
      await tester.pumpWidget(MultiProvider(
        providers: app.providers,
        child: const MaterialApp(home: ChatScreen(chatId: 9)),
      ));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();

      await _longPressReal(tester, find.text('примите накладную'));
      await tester.tap(find.text('Создать задачу'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // карточка-цитата источника и предзаполненное описание — человек видит,
      // что уедет в задачу, и правит на месте
      expect(find.text('Текст сообщения переносится в описание задачи'),
          findsOneWidget);
      expect(find.widgetWithText(TextField, 'примите накладную'), findsOneWidget,
          reason: 'описание предзаполнено текстом сообщения (#37441)');
      app.dispose();
    });
  });

  testWidgets('мост: вложение не-фото названо в карточке источника', (tester) async {
    await tester.runAsync(() async {
      server.chats = [
        {
          'id': 9,
          'kind': 'dialog',
          'name': 'Иванов И.И.',
          'peerId': 42,
          'members': 2,
          'today': '2026-11-02',
          'last': [ {'id': 19, 'author': 'Иванов И.И.', 'text': 'накладная'}],
        },
      ];
      server.messages[9] = [
        {
          'id': 19,
          'authorId': 42,
          'author': 'Иванов И.И.',
          'dateTime': '2026-11-02 09:58:00',
          'text': 'накладная',
          'file': {'name': 'накладная.pdf', 'image': false},
        },
      ];
      final app = await _app(settings, server);
      await app.chat.refresh();
      app.home.layout = HomeLayout.fromJson({
        'objects': [
          {'id': 'A', 'name': 'Объект A'},
        ],
      });
      app.home.quickCreate = const QuickCreateData(actions: [
        QuickPreset(code: 'errand', title: 'Поручение', typeId: 'issue'),
      ]);
      await tester.pumpWidget(MultiProvider(
        providers: app.providers,
        child: const MaterialApp(home: ChatScreen(chatId: 9)),
      ));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();

      await _longPressReal(tester, find.text('накладная'));
      await tester.tap(find.text('Создать задачу'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Текст и вложение сообщения переносятся в задачу'),
          findsOneWidget);
      app.dispose();
    });
  });
}
