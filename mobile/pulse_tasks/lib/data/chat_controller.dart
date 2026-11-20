import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';

import '../models/chat.dart';
import 'api_client.dart';
import 'chat_file_cache.dart';
import 'conversation_controller.dart';
import 'local_db.dart';
import 'quiet_after_dispose.dart';
import 'session.dart';
import 'settings.dart';
import 'sync/outbox_drain.dart';
import 'unsent.dart';
import 'user_base.dart';

/// Чаты (#37369): список с непрочитанными, переписка, отправка без связи. Тот же
/// рисунок, что у переписки по задаче (comment_controller.dart): экран всегда читает
/// из кэша, отправка ложится строкой в очередь с ключом идемпотентности и уезжает
/// под drainLocked, отметка прочтения ставится локально сразу и уходит на сервер
/// монотонно.

/// Подпись числа непрочитанного для бейджа иконки «Чаты»: счётчик капится «99+»
/// по гайдлайну Material — плашка с шестью цифрами (на стенде чаты-замеры
/// принесли 100003) не влезает в кнопку у края экрана. Точное число остаётся
/// в подзаголовке списка чатов и в счётчиках строк.
String chatBadgeLabel(int n) => n > 99 ? '99+' : '$n';

/// Отказ, который повтором не лечится: доступа к чату нет (403) или нет самого
/// чата либо пакета чата на сервере (404). Прочие отказы, 5xx, — временные: отметка
/// ждёт следующего прохода, опрос продолжается.
bool _refusedForGood(Object e) =>
    e is ApiException && (e.status == 403 || e.status == 404);

/// Диалог, начатый с телефона и ещё не приехавший с сервера: строки очереди с
/// адресом-`userId`, собранные в одну строку списка. Серверный чат для него
/// создастся отправкой первого сообщения (createDialogChat идемпотентен), и
/// следующая синхронизация сдаст его в кэш — слиянием в ChatsDao.replaceChats.
class LocalChatDialog {
  final int userId;
  final String name;
  final List<Map<String, Object?>> pending;

  const LocalChatDialog(this.userId, this.name, this.pending);

  DateTime? get lastAt {
    DateTime? min;
    for (final r in pending) {
      final t = DateTime.tryParse((r['createdAt'] as String?) ?? '');
      if (t != null && (min == null || t.isAfter(min))) min = t;
    }
    return min;
  }

  /// Превью последнего неотправленного: «Вы: …» — так же, как сервер подписывает
  /// свои сообщения в списке.
  String get lastPreview {
    final r = pending.isEmpty ? null : pending.last;
    if (r == null) return '';
    final text = ((r['text'] as String?) ?? '').trim();
    return 'Вы: ${text.isEmpty ? 'Фотография' : text}';
  }
}

/// Сообщение из пуша для плашки поверх экрана (#37370): заголовок пуша (имя чата,
/// у диалога — собеседник) и тело («Иван: …» / «3 новых · Иван: …»).
class ChatLiveMessage {
  final int chatId;
  final String title;
  final String body;

  const ChatLiveMessage(
      {required this.chatId, required this.title, required this.body});
}

/// Живая (открытая) переписка для пуша (#37370): экран регистрирует себя при
/// построении и снимает при закрытии. Пуш спрашивает [isCurrent] — «этот ли чат
/// сейчас на экране» (верх маршрута, а не «где-то в стеке»: переписка, закрытая
/// другим экраном, — уже «другой экран», и ей положена плашка) — и [nudge], чтобы
/// открытая переписка обновилась сразу, не дожидаясь своего десятисекундного тика.
/// Экранов одного чата в стеке может быть больше одного — поэтому список, а не флаг.
class OpenChatEntry {
  static final List<OpenChatEntry> _open = [];

  final int chatId;
  final Route<dynamic> _route;
  final VoidCallback _refresh;

  OpenChatEntry(this.chatId, this._route, this._refresh) {
    _open.add(this);
  }

  /// Снять себя: экран закрыли — пуш больше не должен считать переписку открытой.
  void remove() => _open.remove(this);

  /// Верхний ли сейчас экран этого чата: по нему пуш не открывает вторую копию
  /// переписки и не показывает плашку.
  static bool isCurrent(int chatId) =>
      _open.any((e) => e.chatId == chatId && e._route.isCurrent);

  /// Обновить живые экраны этого чата немедленно.
  static void nudge(int chatId) {
    for (final e in _open) {
      if (e.chatId == chatId) e._refresh();
    }
  }
}

/// Список чатов и число непрочитанных — уровень приложения: иконка в шапке главной
/// и список читают одно состояние, чтобы число на иконке и в списке не расходились.
/// Обновляется при синхронизации (вход, появление связи, pull-to-refresh) и по пушу
/// чата (#37370): refresh + плашка [liveMessage] поверх чужого экрана.
class ChatListController extends ChangeNotifier with QuietAfterDispose {
  final ApiClient api;
  final Session session;
  final Settings settings;
  final UserBase base;

  ChatListController({
    required this.api,
    required this.session,
    required this.settings,
    required this.base,
  }) {
    base.onChange(_onBase);
  }

  List<ChatSummary> chats = const [];
  List<LocalChatDialog> localDialogs = const [];

  /// Число на иконке «Чаты»: непрочитанное всех чатов, кроме «без звука» (в число
  /// не входят — дизайн §8). Считается в [loadLocal]: при висящей локальной отметке
  /// прочтения счётчик каждого чата пересчитывается из кэша сообщений, а не берётся
  /// у сервера — сервер ещё не знает о прочитанном офлайн и зажигал бы бейдж своим
  /// же «прочитано».
  int unreadBadge = 0;

  bool loading = false;

  /// Сообщение из пуша для плашки поверх экрана (#37370); null — плашки нет.
  ChatLiveMessage? liveMessage;

  /// Сколько плашка живёт, прежде чем уйти сама. Поле, а не константа, ради теста.
  Duration liveHideAfter = const Duration(seconds: 5);

  Timer? _liveHide;

  Future<void> _onBase(LocalDb? db) async {
    chats = const [];
    localDialogs = const [];
    unreadBadge = 0;
    _deliveredOwed = 0;
    if (db == null) {
      // вышли из учётки — плашка о чужом сообщении над логином не нужна
      liveMessage = null;
      _liveHide?.cancel();
      _liveHide = null;
      notifyListeners();
      return;
    }
    await loadLocal();
  }

  /// Перечитать список и бейдж из кэша вошедшего: серверные строки, локальные
  /// диалоги из очереди и эффективное непрочитанное.
  Future<void> loadLocal() async {
    final db = base.db;
    if (db == null) return;
    try {
      final cached = await db.chats.getChats();
      final byUser = <int, List<Map<String, Object?>>>{};
      final names = <int, String>{};
      for (final r in await db.chats.getAllOutbox()) {
        final userId = r['userId'] as int?;
        if (userId == null || r['chatId'] != null) continue;
        byUser.putIfAbsent(userId, () => []).add(r);
        names[userId] ??= (await db.chats.getContact(userId))?.name ??
            'Диалог';
      }
      chats = cached;
      localDialogs = [
        for (final e in byUser.entries)
          LocalChatDialog(e.key, names[e.key] ?? 'Диалог', e.value),
      ];
      var badge = 0;
      for (final c in cached) {
        if (c.muted) continue;
        badge += await _effectiveUnread(db, c);
      }
      unreadBadge = badge;
      notifyListeners();
    } catch (_) {
      // база закрылась под чтением (выход из аккаунта) — список уже пуст
    }
  }

  /// Непрочитанное чата: пока отметка «прочитано до» не доехала до сервера,
  /// серверное число врёт в большую сторону, и честный счёт — чужие сообщения
  /// в кэше новее отметки. Отметка доехала (pending = 0) — серверу виднее:
  /// кэш мог не доехать до последней страницы.
  Future<int> _effectiveUnread(LocalDb db, ChatSummary c) async {
    final mark = await db.chats.getReadMark(c.id);
    if (mark == null || mark['pending'] != 1) return c.unread;
    return db.chats.newSince(c.id, mark['upTo'] as int);
  }

  /// «Доставлено», которое не доехало до сервера: кэш списка уже знает новое, и
  /// сравнение с ним следующего раза не увидело бы, что отметка должна. 0 — долга нет.
  int _deliveredOwed = 0;

  /// Забрать список с сервера (синхронизация): заменить кэш, слить локальные
  /// диалоги с серверными и, если принесённое новее всего виденного, отметить
  /// «доставлено» — у авторов в вебе свои сообщения получат второй крючок.
  /// Коллеги для поиска обновляются тем же заходом: они нужны офлайн. Тихая, как
  /// refreshHome: офлайн и отказ оставляют кэш.
  Future<void> refresh() async {
    final db = base.db;
    if (!settings.isConfigured || !session.isActive || db == null) return;
    try {
      final prevMax = await db.chats.maxLastId();
      final fetched = await api.fetchChats();
      await db.chats.replaceChats(fetched);
      final newMax = [
        for (final c in fetched)
          if (c.last != null) c.last!.id,
      ].fold<int>(0, (a, b) => a > b ? a : b);
      final upTo = newMax > prevMax ? newMax : _deliveredOwed;
      if (upTo > 0) {
        try {
          await api.markChatDelivered(upTo);
          _deliveredOwed = 0;
        } catch (e) {
          // не дошло — догонит следующая синхронизация; отказ навсегда — нет
          _deliveredOwed = _refusedForGood(e) ? 0 : upTo;
        }
      }
      await loadLocal();
    } catch (_) {
      // офлайн или отказ — остаётся то, что лежит в кэше
    }
    unawaited(refreshContacts());
  }

  /// Коллеги (apiChatContacts без запроса) — в кэш для офлайн-поиска собеседника.
  Future<void> refreshContacts() async {
    final db = base.db;
    if (!settings.isConfigured || !session.isActive || db == null) return;
    try {
      final contacts = await api.fetchChatContacts();
      await db.chats.replaceContacts(contacts,
          fetchedAtIso: DateTime.now().toIso8601String());
    } catch (_) {
      // офлайн — остаётся то, что лежит в кэше
    }
  }

  /// Диалог этого собеседника, если он уже есть в кэше, — id для открытия
  /// переписки: существующий диалог открывают, а не заводят новый.
  Future<int?> dialogWith(int userId) async {
    final db = base.db;
    if (db == null) return null;
    return (await db.chats.findDialogWith(userId))?.id;
  }

  /// Показать плашку о новом сообщении (#37370): новое заменяет висящее (свежее
  /// важнее) и заводит таймер авто-скрытия заново. Сама плашка не ходит ни по
  /// экранам, ни по сети — переход по её кнопке делает main.dart, список и бейдж
  /// к этому моменту уже обновил refresh, который вызвал показать её.
  void showLive(int chatId, {required String title, required String body}) {
    liveMessage = ChatLiveMessage(chatId: chatId, title: title, body: body);
    _liveHide?.cancel();
    _liveHide = Timer(liveHideAfter, hideLive);
    notifyListeners();
  }

  /// Убрать плашку: время вышло, по ней открыли переписку или ушли в неё с пуша.
  void hideLive() {
    if (liveMessage == null) return;
    liveMessage = null;
    _liveHide?.cancel();
    _liveHide = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _liveHide?.cancel();
    super.dispose();
  }

  /// Файловая половина «выйти и удалить данные»: строки кэша и очередей уходят
  /// вместе с базой пользователя, вложения — с её каталогом.
  static Future<void> deleteFiles(String userKey) =>
      ChatFileCache.deleteAll(userKey);
}

/// Переписка одного чата — экран всегда читает из кэша; отправка, опрос последней
/// страницы, отметка прочтения и «без звука». Адрес — серверный чат [chatId] или
/// собеседник [userId] (диалог, начатый без связи): когда синхронизация привозит
/// серверный диалог, очередь этого userId сцепляется с ним (ChatsDao.replaceChats)
/// и переписка переходит на серверный ключ — неотправленное остаётся на месте.
///
/// Очередь, отправка и подписи отказов — общие с лентой задачи, в
/// [ConversationController]; здесь адрес, страницы, опрос, отметка и звук.
class ChatConversationController extends ConversationController {
  /// Серверный чат; null, пока диалог существует только локально.
  int? chatId;

  /// Собеседник локального диалога (адрес отправки, пока [chatId] пуст).
  final int? userId;

  ChatConversationController(
      {required super.db, required super.api, this.chatId, this.userId})
      : assert(chatId != null || userId != null);

  /// Очередь отправки и вердикт о сети — общая политика, см. [OutboxDrain];
  /// причины ложатся под `chat:<ключ>` (ключ — id чата или «u<userId>»).
  @override
  late final OutboxDrain drain = OutboxDrain(() => db,
      kind: UnsentKind.chat, taskId: chatOutboxKey(chatId, userId ?? 0));

  ChatSummary? chat;
  List<ChatMessage> items = const [];

  /// Строки кэша чатов и очередей поменялись (отправка, дожим, отметка) — списку
  /// и бейджу пора перечитаться; подключает экран, у которого есть список.
  VoidCallback? onQueueChanged;

  @override
  void queueChanged() => onQueueChanged?.call();

  /// Ключ этой переписки в очередях: id серверного чата, пока его нет — «u<peer>».
  String get outboxKey => chatOutboxKey(chatId, userId ?? 0);

  @override
  String get syncKey => '${UnsentKind.chat}:$outboxKey';

  @override
  String get unsentTask => outboxKey;

  /// Кэш вложений этого пользователя.
  late final ChatFileCache _files =
      ChatFileCache(userKey: db.userKey, api: api);

  @override
  void dispose() {
    _poll?.cancel();
    // вложения истории старше кэша скачаны только на время экрана: строк под
    // ними в кэше нет, и без уборки байты жили бы на диске до выхода из учётки
    final floor = _cacheFloor;
    for (final m in items) {
      if (floor != null && m.fileImage && !m.pending && m.id < floor) {
        unawaited(_files.evict(m.id));
      }
    }
    super.dispose();
  }

  @override
  int get pendingCount => items.where((m) => m.pending).length;

  /// Имя переписки: серверная строка чата или имя собеседника локального диалога.
  Future<String> _resolveTitle() async {
    if (chat != null) return chat!.name ?? 'Чат';
    if (userId != null) {
      return (await db.chats.getContact(userId!))?.name ?? 'Диалог';
    }
    return 'Чат';
  }

  /// Заголовок экрана (меняется, когда локальный диалог стал серверным).
  String title = 'Чат';

  Future<void> load() async {
    loading = true;
    notifyListeners();
    try {
      await loadLocal();
    } catch (_) {
      // база закрылась, пока переписка поднималась (выход из аккаунта)
      loading = false;
      return;
    }
    // кэш — на экран сразу, не дожидаясь сервера: без связи ответа ждать долго
    notifyListeners();
    final failure = await drain.attempt(() async {
      // своё — первым, чтобы ответ сервера ниже уже содержал его
      await syncAll();
      await _fetchPage(limit: 200); // кэш последних 200 — потолок хранения
      error = null;
    });
    if (failure != null && items.isEmpty) {
      error = loadFailureText(failure,
          offline: 'Нет связи — переписка ещё не загружалась');
    }
    // доступа к чату нет — опрашивать незачем, есть ли что показать из кэша или нет
    if (failure != null && _refusedForGood(failure)) _stopForGood();
    loading = false;
    notifyListeners();
  }

  /// id самого старого сообщения в кэше: всё, что старше, — история, подгруженная
  /// на время экрана. null — кэш этого чата пуст.
  int? _cacheFloor;

  /// Кэш сообщений плюс своя очередь: неотправленные — в конце, они новее всего,
  /// что сервер успел вернуть, каким бы ни было расхождение часов. Перед кэшем —
  /// история старше его потолка, уже показанная этим экраном: подгруженные
  /// страницы и сообщения, которые потолок вытолкнул, пока переписка открыта. Она
  /// живёт только в памяти — кэш хранит последние 200, а пропадать из-под глаз
  /// читающего ей незачем.
  @override
  Future<void> loadLocal() async {
    await _resolveAddress();
    chat = chatId != null ? await db.chats.getChat(chatId!) : null;
    title = await _resolveTitle();
    final cached =
        chatId != null ? await db.chats.getMessages(chatId!) : const <ChatMessage>[];
    final queued = await db.chats.getOutbox(chatId: chatId, userId: userId);
    final floor = cached.isEmpty ? null : cached.first.id;
    _cacheFloor = floor;
    items = [
      if (floor != null)
        for (final m in items)
          if (!m.pending && m.id < floor) m,
      ...cached,
      for (final r in queued)
        ChatMessage.pendingFrom(r, sendError: sendErrors[r['clientId'] as String]),
    ];
  }

  /// Диалог, начатый без связи, мог стать серверным, пока экран был открыт или до
  /// него: находим чат по peerId и переходим на его ключ.
  Future<void> _resolveAddress() async {
    if (chatId != null || userId == null) return;
    final dialog = await db.chats.findDialogWith(userId!);
    if (dialog != null) chatId = dialog.id;
  }

  /// Страница с сервера заменяет кэш на своём диапазоне id — так доезжают правки
  /// и удаления из веба, а не только новые. Файлы чужих сообщений, которых страница
  /// не вернула, стираются: байты больше ничьи.
  Future<void> _fetchPage({int? before, int limit = 50}) async {
    final id = chatId;
    if (id == null) return; // локальный диалог: с сервера брать нечего
    final page = await api.fetchChatMessages(id, before: before, limit: limit);
    final evict = await db.chats.replaceMessageRange(id, page);
    for (final messageId in evict) {
      await _files.evict(messageId);
    }
    await loadLocal();
  }

  /// Страница истории при прокрутке к верху.
  static const olderPageSize = 50;

  /// Дозагрузка истории, когда человек доскроллил до верха. Старые страницы в
  /// кэш не пишутся — его потолок, 200 последних, тут же вытолкнул бы их, — а
  /// встают в начало [items] и живут, пока открыт экран (см. [loadLocal]). Сервер
  /// вернул старее границы меньше страницы — история в этом чате кончилась, и
  /// больше её не спрашивают.
  Future<void> loadOlder() async {
    if (_noOlder || _loadingOlder) return;
    final oldest = items
        .where((m) => !m.pending)
        .map((m) => m.id)
        .fold<int?>(null, (a, b) => a == null || b < a ? b : a);
    if (oldest == null) return;
    _loadingOlder = true;
    notifyListeners();
    try {
      await drain.attempt(() async {
        final id = chatId;
        if (id == null) return;
        final page = await api.fetchChatMessages(id,
            before: oldest, limit: olderPageSize);
        // сервер отдаёт свежие сверху, а удалённую границу понимает как «последние»
        // — в ленту идёт только то, что старше неё
        final older = [
          for (final m in page)
            if (m.id < oldest) m
        ]..sort((a, b) => a.id.compareTo(b.id));
        if (older.length < olderPageSize) _noOlder = true;
        if (older.isNotEmpty) items = [...older, ...items];
      });
    } finally {
      _loadingOlder = false;
      notifyListeners();
    }
  }

  bool _loadingOlder = false;
  bool _noOlder = false;
  bool get loadingOlder => _loadingOlder;

  // --- опрос открытой переписки ---

  Timer? _poll;

  /// Тик идёт: стенд отвечает и по 15–20 секунд, и следующий тик не накладывает
  /// второй запрос страницы на неотвеченный первый.
  bool _refreshing = false;

  /// Сервер отказал в этом чате навсегда (403 — доступа нет, 404 — чата нет):
  /// опрос остановлен и с возвратом приложения на экран не заводится.
  bool _denied = false;

  /// Открытая переписка опрашивает последнюю страницу каждые 10 секунд — без
  /// действий человека (#37369). Тихий: обрыв связи — только офлайн-баннер.
  void startPolling() {
    _poll?.cancel();
    if (_denied) return;
    _poll = Timer.periodic(
        const Duration(seconds: 10), (_) => unawaited(refreshNow()));
  }

  void stopPolling() {
    _poll?.cancel();
    _poll = null;
  }

  /// Опрос заведён.
  bool get polling => _poll?.isActive ?? false;

  void _stopForGood() {
    _denied = true;
    stopPolling();
  }

  /// Немедленный опросный тик: и тик таймера, и «переписка просто обновляется» по
  /// пушу (#37370) — новое сообщение видно сразу, не дожидаясь своего десятка.
  /// Экран будится, только если тик что-то поменял: раз в 10 секунд перерисовывать
  /// неизменную ленту незачем.
  Future<void> refreshNow() async {
    if (disposed || _denied || loading || syncing || _refreshing) return;
    _refreshing = true;
    final before = _shown();
    try {
      final failure = await drain.attempt(() async {
        await syncAll();
        await _fetchPage(limit: 50);
      });
      if (failure != null && _refusedForGood(failure)) _stopForGood();
    } finally {
      _refreshing = false;
    }
    if (_shown() != before) notifyListeners();
  }

  /// То, что рисует экран переписки: заголовок, сеть, звук и сообщения со
  /// статусами — для сравнения «до и после» тика.
  String _shown() => jsonEncode([
        title,
        online,
        chat?.muted,
        for (final m in items) [
          ...m.toMap(0).values,
          m.pending,
          m.photoPath,
          m.sendError,
        ],
      ]);

  // --- отправка ---

  /// Написать — см. [ConversationController.enqueueAndSend]. Ответ адресуется
  /// серверным id сообщения ([replyTo]) — ответить можно только на серверное.
  Future<void> send(String text, {String? photoPath, int? replyTo}) =>
      enqueueAndSend(
          text,
          photoPath,
          (clientId, text, photoPath) => db.chats.enqueueMessage(clientId,
              chatId: chatId,
              userId: chatId == null ? userId : null,
              text: text,
              photoPath: photoPath,
              replyTo: replyTo,
              createdAtIso: DateTime.now().toIso8601String()));

  // --- что общей основе нужно от чата ---

  @override
  Future<Directory> outgoingDirectory() => photoDirectory(db.userKey);

  @override
  Future<List<Map<String, Object?>>> outbox() =>
      db.chats.getOutbox(chatId: chatId, userId: userId);

  @override
  Future<void> dequeue(String clientId) => db.chats.dequeue(clientId);

  @override
  Future<void> deleteFiles(List<String> paths) =>
      ChatFileCache.deleteFiles(paths);

  /// Адрес — серверный чат, а пока его нет — собеседник (сервер найдёт диалог или
  /// создаст).
  @override
  Map<String, dynamic> bodyHead(Map<String, Object?> row) {
    final replyTo = row['replyTo'] as int?;
    return {
      if (chatId != null)
        'chatId': chatId
      else if (userId != null)
        'userId': userId,
      if (replyTo != null) 'replyTo': replyTo,
    };
  }

  @override
  Future<void> post(Map<String, dynamic> body) => api.addChatMessage(body);

  /// Ушло — у сообщений теперь серверные id; диалог без связи мог стать серверным.
  @override
  Future<void> refreshAfterSend() => _fetchPage(limit: 50);

  /// Слать нечего — ни индикатора, ни перерисовки: опрос заходит сюда каждые 10
  /// секунд.
  @override
  Future<bool> nothingToSend() async =>
      (await outbox()).isEmpty && (await _pendingReads()).isEmpty;

  // --- прочитано ---

  /// Переписка показана — прочитано до последнего СЕРВЕРНОГО сообщения на экране.
  /// upTo — его id, а не время: граница страницы у чата — id. Пишется локально
  /// (бейдж гаснет в этом же кадре) и уходит на сервер — сейчас или дренажем.
  /// Свои неотправленные непрочитанными не бывают.
  Future<void> markRead() async {
    final id = chatId;
    if (id == null) return;
    var upTo = 0;
    for (final m in items) {
      if (!m.pending && m.id > upTo) upTo = m.id;
    }
    if (upTo == 0) return;
    try {
      await db.chats.markRead(id, upTo);
      await sendReadMarks();
    } catch (_) {
      // база закрылась под отметкой (выход из аккаунта, конец работы приложения),
      // а экран звал без ожидания: записанная отметка уйдёт дренажем
      return;
    }
    queueChanged();
  }

  /// Отметки прочтения этого чата, ещё не доехавшие до сервера.
  Future<List<Map<String, Object?>>> _pendingReads() async {
    final id = chatId;
    if (id == null) return const [];
    return [
      for (final r in await db.chats.getPendingReads())
        if (r['chatId'] == id) r
    ];
  }

  @override
  Future<void> sendReadMarks() async {
    final id = chatId;
    if (id == null) return;
    await drain.each(await _pendingReads(), (r) async {
      final upTo = r['upTo'] as int;
      try {
        await api.markChatRead(id, upTo);
      } on ApiException catch (e) {
        // доступа к чату больше нет — отметке висеть в очереди вечно незачем;
        // прочий отказ (5xx) временный: отметка ждёт следующего прохода
        if (!_refusedForGood(e)) rethrow;
      }
      await db.chats.markReadSent(id, upTo);
    }, kind: UnsentKind.chat, taskOf: (_) => outboxKey);
    queueChanged();
  }

  // --- «без звука» ---

  /// Переключить звук чата. Очереди для звука нет (дизайн §8 — очередь у сообщений
  /// и отметок): вызов ждём, при отказе экран показывает причину, кэш списка
  /// вернёт серверное значение следующей синхронизацией.
  Future<void> setMuted(bool muted) async {
    final id = chatId;
    if (id == null) return;
    await api.setChatMuted(id, muted);
    await db.chats.setMuted(id, muted);
    await loadLocal();
    notifyListeners();
  }

  // --- вложения ---

  /// Файл вложения: с диска, если уже скачан, иначе из сети (и на диск). null — ни
  /// файла, ни сети: плитка показывает «недоступно офлайн».
  Future<File?> photoFile(int messageId, {required bool thumb}) =>
      _files.file(messageId, thumb: thumb);

  /// Стереть вложение из кэша — байты не декодируются; следующий заход перекачает.
  Future<void> evictPhoto(int messageId) => _files.evict(messageId);

  /// Каталог фото переписки: и исходящие снимки до отправки, и скачанные вложения.
  static Future<Directory> photoDirectory(String userKey) =>
      ChatFileCache.directory(userKey);

  // --- для синхронизации: дожим и префетч без экрана ---

  /// Дожать очереди всех переписок и отложенные отметки прочтения — при
  /// синхронизации, не дожидаясь, пока чат откроют снова: «при возврате связи
  /// уходит» обязано случиться и у телефона в кармане.
  static Future<void> drainAll(LocalDb db, ApiClient api) async {
    final targets = <String>{};
    for (final r in await db.chats.getAllOutbox()) {
      targets.add('${r['chatId']}|${r['userId']}');
    }
    for (final r in await db.chats.getPendingReads()) {
      targets.add('${r['chatId']}|');
    }
    for (final t in targets) {
      final parts = t.split('|');
      final c = ChatConversationController(
          db: db,
          api: api,
          chatId: int.tryParse(parts.first),
          userId: int.tryParse(parts.last));
      try {
        await c.syncAll();
      } catch (_) {
        // база закрылась под дренажем (выход из аккаунта) — очередь цела, дожмётся
        break;
      } finally {
        c.dispose();
      }
    }
  }

  /// Забрать страницу переписки в кэш без экрана — чтобы чат читался в подвале без
  /// сети. Сеть трогается только там, где последнее сообщение чата разошлось с
  /// кэшем (сервер назвал более свежее) — по одной странице на такой чат.
  static Future<void> prefetch(LocalDb db, ApiClient api) async {
    for (final c in await db.chats.getChats()) {
      final lastId = c.last?.id;
      if (lastId == null) continue;
      final cachedMax = await db.chats.maxMessageId(c.id);
      if (cachedMax != null && cachedMax >= lastId) continue;
      final ctrl = ChatConversationController(db: db, api: api, chatId: c.id);
      try {
        await ctrl._fetchPage(limit: 50);
      } catch (_) {
        // офлайн или отказ — кэш остаётся прежним
      } finally {
        ctrl.dispose();
      }
    }
  }
}

/// Поиск собеседника: коллеги из кэша (работают без сети) и поиск на сервере по
/// имени и логину. Начать диалог можно только с тем, кто есть в apiChatContacts.
class ChatContactsController extends ChangeNotifier {
  final LocalDb db;
  final ApiClient api;

  ChatContactsController({required this.db, required this.api});

  List<ChatContact> items = const [];
  bool loading = false;
  String? error;
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// Коллеги из кэша, а если кэш пуст — попытка обновиться у сервера: список
  /// «с кем можно начать диалог» нужен прямо в подвале.
  Future<void> load() async {
    await _show(await db.chats.getContacts());
    if (items.isNotEmpty) return;
    await search('');
  }

  /// Пустой запрос — коллеги (кэш, мимо сети; пустой кэш обновляется у сервера и
  /// записывается), непустой — поиск на сервере по имени и логину.
  Future<void> search(String q) async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      if (q.trim().isEmpty) {
        final cached = await db.chats.getContacts();
        if (cached.isNotEmpty) {
          await _show(cached);
          return;
        }
        final fetched = await api.fetchChatContacts();
        await db.chats.replaceContacts(fetched,
            fetchedAtIso: DateTime.now().toIso8601String());
        await _show(fetched);
        return;
      }
      await _show(await api.fetchChatContacts(q: q.trim()));
    } catch (e) {
      error = e is ApiException ? '$e' : 'Нет связи';
    } finally {
      loading = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> _show(List<ChatContact> list) async {
    items = list;
    if (!_disposed) notifyListeners();
  }
}
