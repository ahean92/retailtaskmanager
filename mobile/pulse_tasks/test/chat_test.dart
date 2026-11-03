import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/chat_controller.dart';
import 'package:pulse_tasks/data/local_db.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/data/unsent.dart';
import 'package:pulse_tasks/data/user_base.dart';
import 'package:pulse_tasks/models/chat.dart';
import 'support/fake_server.dart';
import 'support/test_env.dart';

/// Чаты (#37369): сообщение пишут без связи — пузырь «не отправлено» сразу,
/// очередь уходит по одному разу с тем же ключом; диалог, начатый по userId,
/// сливается с серверным; непрочитанное гаснет локально раньше сервера;
/// синхронизация, принёсшая новое, отмечает «доставлено». Настоящий sqlite (ffi):
/// кэш, очередь и отметка живут в схеме, и мокать их — значит не проверить ничего.

int _seq = 0;

/// Сервер, который отвечает на чат как настоящий: список, страница переписки,
/// 200 без тела на мутации, и умеет «пропадать» — целиком или только на POST.
class _Server {
  final calls = <String>[]; // все запросы, включая оборвавшиеся
  final bodies = <(String, Map<String, dynamic>)>[]; // (действие, тело POST)
  bool down = false;
  bool postDown = false; // чтение живо, запись рвётся
  final failWith = <String, int>{}; // действие → HTTP-статус отказа

  /// Чаты apiChats — как их собрал сервер (внутренние id, today).
  List<Map<String, Object?>> chats = [];

  /// Сообщения по чату, новые сверху — как отдаёт apiChatMessages.
  final messages = <int, List<Map<String, Object?>>>{};

  late final Session session;
  late final ApiClient api;

  _Server(Settings settings) {
    session = Session(
      // логин уникален и в прогоне, и между прогонами: имя базы содержит его, а
      // файл ffi-sqlite переживает запуск — прошлый кэш иначе пережил бы тест
      login: 'smirnov${DateTime.now().microsecondsSinceEpoch}_${_seq++}',
      name: 'Смирнов А.А.',
      token: 'token',
      signedIn: true,
      performerId: 'p1',
    );
    api = ApiClient(settings, session, client: MockClient((request) async {
      final action = actionOf(request);
      calls.add(action);
      if (request.method == 'POST') {
        if (down || postDown) throw const SocketException('нет сети');
        final fail = failWith[action];
        if (fail != null) {
          // тело — байтами UTF-8, как у настоящего сервера (okJson): Response
          // из строки кодирует latin1 и кириллица превратила бы отказ в
          // «обрыв связи» ещё внутри мока
          return http.Response.bytes(
              utf8.encode(jsonEncode(
                  {'error': 'forbidden', 'message': 'Нет доступа к чату'})),
              fail,
              headers: {'content-type': 'application/json; charset=utf-8'});
        }
        bodies.add((action,
            (jsonDecode(request.body) as Map).cast<String, dynamic>()));
        return http.Response('', 200); // мутации отвечают пустым телом
      }
      if (down) throw const SocketException('нет сети');
      final q = request.url.queryParameters;
      switch (action) {
        case 'apiChatInfo':
          return okJson(jsonEncode([{'enabled': true}]));
        case 'apiChats':
          return okJson(jsonEncode(chats));
        case 'apiChatMessages':
          return okJson(jsonEncode(messages[int.parse(q['id']!)] ?? const []));
        case 'apiChatContacts':
          return okJson(jsonEncode([
                {'id': 42, 'name': 'Иванов И.И.', 'hint': 'Директор · Магазин 12'},
              ]));
        default:
          return okJson('[]');
      }
    }));
  }

  List<Map<String, dynamic>> sent(String action) =>
      [for (final b in bodies) if (b.$1 == action) b.$2];
}

/// Диалог из выдачи apiChats.
Map<String, Object?> _chatRow(int id, String name, int peer,
    {int unread = 0, bool muted = false, bool readonly = false}) {
  return {
    'id': id,
    'kind': 'dialog',
    'name': name,
    'peerId': peer,
    'members': 2,
    if (readonly) 'readonly': true,
    if (muted) 'muted': true,
    if (unread > 0) 'unread': unread,
    'today': '2026-11-02',
  };
}

/// Сообщение из выдачи apiChatMessages (свежие сверху — сервер так и отдаёт).
Map<String, Object?> _msgRow(int id, String text,
    {bool mine = false, String? clientId, String? status}) {
  return {
    'id': id,
    if (clientId != null) 'clientId': clientId,
    'authorId': mine ? 7 : 42,
    'author': mine ? 'Смирнов А.А.' : 'Иванов И.И.',
    if (mine) 'mine': true,
    'dateTime': '2026-11-02 10:0${id % 10}:00',
    'text': text,
    if (status != null) 'status': status,
  };
}

void main() {
  initTestEnv();

  test('подпись бейджа иконки: до 99 — число, дальше «99+»', () {
    expect(chatBadgeLabel(0), '0');
    expect(chatBadgeLabel(7), '7');
    expect(chatBadgeLabel(99), '99');
    expect(chatBadgeLabel(100), '99+',
        reason: 'шесть цифр стенда не влезали в кнопку у края экрана');
    expect(chatBadgeLabel(100003), '99+');
  });

  late Settings settings;
  late _Server server;
  late UserBase base;
  late Directory docs;

  setUp(() {
    resetMockStores();
    // каталог вложений чата — файлами в каталоге приложения; на настольной машине
    // его никто не подставляет, поэтому подставляем сами (как у карточки задачи)
    docs = Directory.systemTemp.createTempSync('pulse_chat_docs');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => docs.path);
    settings = Settings(baseUrl: 'http://test.local:9080');
    server = _Server(settings);
    base = UserBase(settings: settings, session: server.session);
  });

  tearDown(() async {
    await base.close();
    if (docs.existsSync()) docs.deleteSync(recursive: true);
  });

  Future<LocalDb> openDb() async {
    await base.rebind();
    return base.db!;
  }

  test('модель: id числом и строкой, статус только у своих, NULL не выгружается',
      () {
    final m = ChatMessage.fromJson({
      'id': '101', // lsFusion шлёт LONG как попало
      'authorId': 42,
      'author': 'Иванов И.И.',
      'mine': true,
      'dateTime': '2026-11-02 10:00:00',
      'text': 'примите накладную',
      'replyTo': [ {'id': 99, 'author': 'Смирнов А.А.', 'text': 'вопрос'}],
      'file': [ {'name': 'Фото.jpg', 'image': true}],
      'status': 'delivered',
    });
    expect(m.id, 101);
    expect(m.mine, isTrue);
    expect(m.edited, isFalse, reason: 'нет ключа — не редактировалось');
    expect(m.replyId, 99);
    expect(m.replyAuthor, 'Смирнов А.А.');
    expect(m.fileName, 'Фото.jpg');
    expect(m.fileImage, isTrue);
    expect(m.status, ChatMessageStatus.delivered);

    // чужое: статуса нет вовсе, вложения нет — и полей нет, а не пустышки
    final other =
        ChatMessage.fromJson({'id': 102, 'author': 'И.И.', 'text': 'ок'});
    expect(other.status, isNull);
    expect(other.fileImage, isFalse);
    expect(other.hasPhoto, isFalse);

    // превью списка: «Иван: …», «Вы: …» и «Фотография»
    final row = ChatSummary.fromJson(_chatRow(7, 'Иванов И.И.', 42));
    expect(row.kind, ChatKind.dialog);
    expect(row.serverToday, DateTime(2026, 11, 2));
    expect(
        ChatLastMessage.fromJson(
                {'id': 5, 'author': 'Иванов И.И.', 'text': 'заказ собран'})
            .preview,
        'Иванов И.И.: заказ собран');
    expect(
        ChatLastMessage.fromJson({'id': 6, 'mine': true, 'photo': true})
            .preview,
        'Вы: Фотография');

    // кэш туда-обратно
    final cached = ChatMessage.fromMap(m.toMap(7));
    expect(cached.id, m.id);
    expect(cached.replyText, m.replyText);
    expect(cached.status, m.status);
  });

  test('dao: страница заменяет кэш на своём диапазоне — правки доезжают, '
      'удалённые уходят, потолок 200', () async {
    final db = await openDb();
    await db.chats.replaceMessageRange(7,
        [for (var i = 1; i <= 300; i++) ChatMessage.fromJson(_msgRow(i, 'т$i'))]);
    expect(await db.chats.getMessages(7), hasLength(200),
        reason: 'потолок кэша — последние 200');
    expect(await db.chats.maxMessageId(7), 300);

    // страница 290..300: сообщение 295 отредактировано, 297 удалено на сервере
    final page = [
      for (var i = 300; i >= 290; i--)
        if (i != 297)
          ChatMessage.fromJson(
              i == 295 ? {..._msgRow(i, 'правка')} : _msgRow(i, 'т$i')),
    ];
    final evict = await db.chats.replaceMessageRange(7, page);
    expect(evict, isEmpty, reason: 'картинок в этих строках не было');
    final cached = await db.chats.getMessages(7);
    expect(cached.any((m) => m.id == 297), isFalse,
        reason: 'удалённое из веба ушло из кэша');
    expect(cached.firstWhere((m) => m.id == 295).text, 'правка',
        reason: 'правка из веба доехала');
    expect(cached, hasLength(199));
  });

  test('dao: отметка «прочитано до» монотонна, диапазон с картинкой отдаётся на '
      'вычистку файлов', () async {
    final db = await openDb();
    expect(await db.chats.markRead(7, 50), isTrue);
    expect(await db.chats.markRead(7, 30), isFalse, reason: 'назад не катится');
    expect(await db.chats.markRead(7, 80), isTrue);
    expect((await db.chats.getReadMark(7))!['upTo'], 80);

    // сообщение с картинкой исчезло из диапазона страницы — файл больше ничей:
    // страница 49..51 не вернула 50, который лежал в кэше с вложением
    await db.chats.replaceMessageRange(
        7, [ChatMessage.fromJson({..._msgRow(50, 'вот'), 'file': {'name': 'ф.jpg', 'image': true}})]);
    final evict = await db.chats.replaceMessageRange(7, [
      ChatMessage.fromJson(_msgRow(51, 'новее')),
      ChatMessage.fromJson(_msgRow(49, 'старее')),
    ]);
    expect(evict, {50});
    expect((await db.chats.getMessages(7)).map((m) => m.id), [49, 51]);
  });

  test('авиарежим: три сообщения сразу пузырями «не отправлено», со связью '
      'уходят по одному разу с тем же ключом', () async {
    final db = await openDb();
    server.chats = [
      {..._chatRow(7, 'Иванов И.И.', 42)},
    ];
    final list = ChatListController(
        api: server.api,
        session: server.session,
        settings: settings,
        base: base);
    await list.refresh(); // список уже на телефоне — так и попадают в авиарежим
    server.down = true;
    final c = ChatConversationController(db: db, api: server.api, chatId: 7);
    await c.load();
    expect(c.online, isFalse);

    await c.send('первое');
    await c.send('второе');
    await c.send('третье');
    await c.syncAll(); // присоединиться к отправкам, упёршимся в «нет сети»

    expect(c.items, hasLength(3));
    expect(c.items.every((m) => m.pending), isTrue);
    expect(c.pendingCount, 3);
    expect(await db.queues.pendingChanges(), 3,
        reason: 'предупреждение при выходе считает и очередь чата');
    final ops = await loadUnsentOps(db);
    expect(ops.where((o) => o.kind == UnsentKind.chat), hasLength(1));
    final op = ops.firstWhere((o) => o.kind == UnsentKind.chat);
    expect(op.title, 'Иванов И.И.', reason: 'якорь операции — имя чата');
    expect(op.detail, contains('3 сообщ'));

    // связь вернулась: дренаж без открытой переписки
    server.down = false;
    final texts = ['первое', 'второе', 'третье'];
    final keys = c.items.map((m) => m.clientId!).toList();
    server.messages[7] = [
      for (var i = 0; i < 3; i++)
        _msgRow(900 + i, texts[i], mine: true, clientId: keys[i]),
    ];
    await ChatConversationController.drainAll(db, server.api);

    final sent = server.sent('apiAddChatMessage');
    expect(sent, hasLength(3), reason: 'по одному разу на сообщение');
    expect({for (final b in sent) b['clientId']}, keys.toSet(),
        reason: 'ключи рождаются с сообщением и не меняются');
    expect(await db.chats.getAllOutbox(), isEmpty);
    expect(
        (await loadUnsentOps(db)).where((o) => o.kind == UnsentKind.chat),
        isEmpty,
        reason: 'уехавшая операция исчезает из «Не отправлено»');

    await c.load();
    expect(c.items, hasLength(3));
    expect(c.items.every((m) => !m.pending), isTrue);
    c.dispose();
  });

  test('фото уходит внутри того же POST и не переживает отправку', () async {
    final db = await openDb();
    final photo = File('${docs.path}${Platform.pathSeparator}shot.jpg')
      ..writeAsBytesSync([1, 2, 3]);
    final c = ChatConversationController(db: db, api: server.api, chatId: 7);
    server.down = true;
    await c.send('', photoPath: photo.path);
    await c.syncAll(); // офлайн-попытка: строка в очереди, файл на диске
    final stored = (await db.chats.getAllOutbox()).single['photoPath'] as String;
    expect(stored, isNot(photo.path), reason: 'копия в каталоге чата');
    expect(File(stored).existsSync(), isTrue);

    server.down = false;
    await c.syncAll();
    final body = server.sent('apiAddChatMessage').single;
    expect(body['chatId'], 7);
    expect(body['photo'], base64Encode([1, 2, 3]));
    expect(File(stored).existsSync(), isFalse,
        reason: 'ушло — единственная копия больше не нужна');
    c.dispose();
  });

  test('прочтение: бейдж гаснет локально без сети, на сервер уходит монотонно '
      'и один раз', () async {
    final db = await openDb();
    server.chats = [
      {
        ..._chatRow(7, 'Иванов И.И.', 42),
        'last': [_msgRow(50, 'примите накладную')],
        'unread': 2,
      },
      {
        ..._chatRow(8, 'Смена закрыта', 0),
        'kind': 'group',
        'muted': true,
        'unread': 5,
        'last': [_msgRow(51, 'смена 3 закрыта')],
      },
    ];
    server.messages[7] = [_msgRow(50, 'примите накладную'), _msgRow(49, 'собрано')];
    final list = ChatListController(
        api: server.api, session: server.session, settings: settings, base: base);
    await list.refresh();
    expect(list.unreadBadge, 2, reason: '«без звука» в число на иконке не входит');

    final c = ChatConversationController(db: db, api: server.api, chatId: 7);
    await c.load();

    // запись рвётся, чтение живо: отметка легла локально и осталась ждать
    server.postDown = true;
    await c.markRead();
    await list.loadLocal();
    expect(list.unreadBadge, 0,
        reason: 'отметка локальная — счётчик гаснет в этом же кадре, без сети');
    expect(server.sent('apiMarkChatRead'), isEmpty);

    // сервер продолжает считать непрочитанным — телефон знает своё «прочитано»
    await list.refresh();
    expect(list.unreadBadge, 0,
        reason: 'висящая отметка пересчитывает непрочитанное из кэша сообщений');

    // связь вернулась: отметка уезжает один раз, повторный показ молчит
    server.postDown = false;
    await ChatConversationController.drainAll(db, server.api);
    final marks = server.sent('apiMarkChatRead');
    expect(marks, hasLength(1));
    expect(marks.single['upTo'], 50, reason: 'upTo — id последнего показанного');
    await c.markRead();
    expect(server.sent('apiMarkChatRead'), hasLength(1));
    c.dispose();
  });

  test('синхронизация, принёсшая новое, отмечает «доставлено»', () async {
    await openDb();
    final list = ChatListController(
        api: server.api, session: server.session, settings: settings, base: base);
    server.chats = [
      {..._chatRow(7, 'Иванов И.И.', 42), 'last': _msgRow(10, 'привет')},
    ];
    await list.refresh(); // пустой кэш — первое же «новое»
    var delivered = server.sent('apiMarkChatDelivered');
    expect(delivered, hasLength(1));
    expect(delivered.single['upTo'], 10);

    server.chats[0]['last'] = _msgRow(12, 'и ещё');
    await list.refresh();
    delivered = server.sent('apiMarkChatDelivered');
    expect(delivered, hasLength(2));
    expect(delivered.last['upTo'], 12);

    // без нового — новой отметки нет
    await list.refresh();
    expect(server.sent('apiMarkChatDelivered'), hasLength(2));
  });

  test('диалог без связи: очередь адресована userId и сливается с серверным чатом',
      () async {
    final db = await openDb();
    final list = ChatListController(
        api: server.api, session: server.session, settings: settings, base: base);
    await list.refreshContacts(); // коллеги в кэше — офлайн-поиск работает

    server.down = true;
    final c = ChatConversationController(db: db, api: server.api, userId: 42);
    await c.load();
    expect(c.chatId, isNull);
    await c.send('начало диалога');
    await c.syncAll();
    expect(c.items.single.pending, isTrue);
    expect(await db.chats.getOutbox(userId: 42), hasLength(1));
    expect(c.title, 'Иванов И.И.', reason: 'имя — из кэша коллег');

    await list.loadLocal();
    expect(list.localDialogs, hasLength(1), reason: 'в списке — локальная строка');
    expect(list.localDialogs.single.name, 'Иванов И.И.');
    expect(list.localDialogs.single.lastPreview, 'Вы: начало диалога');

    // связь и синхронизация: сообщение ушло, серверный диалог приехал
    server.down = false;
    await ChatConversationController.drainAll(db, server.api);
    server.chats = [
      {
        ..._chatRow(7, 'Иванов И.И.', 42),
        'last': [_msgRow(30, 'начало диалога', mine: true)],
      },
    ];
    await list.refresh();

    // СЛИЯНИЕ — риск тикета: локальной строки рядом с серверной нет
    expect(await db.chats.getAllOutbox(), isEmpty,
        reason: 'сообщение уже уехало');
    expect(list.localDialogs, isEmpty);
    expect(list.chats.single.id, 7);

    // открытая по userId переписка переходит на серверный ключ
    await c.load();
    expect(c.chatId, 7, reason: 'переписка не теряется и не двоится');
    expect(c.title, 'Иванов И.И.');
    c.dispose();
  });

  test('отказ сервера: подпись под пузырём, «Убрать из очереди» убирает строки '
      'и фото', () async {
    final db = await openDb();
    server.failWith['apiAddChatMessage'] = 403;
    final c = ChatConversationController(db: db, api: server.api, chatId: 7);
    final photo = File('${docs.path}${Platform.pathSeparator}gone.jpg')
      ..writeAsBytesSync([9]);
    await c.send('не приму', photoPath: photo.path);
    await c.syncAll();
    expect(c.items.single.pending, isTrue, reason: 'отказ — не «ушло»');
    expect(c.items.single.sendError, contains('Нет доступа'),
        reason: 'подпись под пузырём — словами сервера');

    final ops = await loadUnsentOps(db);
    final op = ops.singleWhere((o) => o.kind == UnsentKind.chat);
    expect(op.refused, isTrue, reason: 'отказ сервера предлагает «Убрать»');
    final stored = (await db.chats.getAllOutbox()).single['photoPath'] as String;
    await discardUnsentOp(db, op);
    expect(await db.chats.getAllOutbox(), isEmpty);
    expect(File(stored).existsSync(), isFalse);
    c.dispose();
  });

  test('контакты: пустой запрос обновляет кэш коллег, поиск идёт на сервер',
      () async {
    final db = await openDb();
    final c = ChatContactsController(db: db, api: server.api);
    await c.search('Ива');
    expect(c.items.single.name, 'Иванов И.И.');
    expect(c.items.single.hint, 'Директор · Магазин 12');
    expect(await db.chats.getContacts(), isEmpty,
        reason: 'поиск никого не кэширует — только коллеги без запроса');

    await c.search('');
    expect(await db.chats.getContacts(), hasLength(1));
    c.dispose();
  });
}
