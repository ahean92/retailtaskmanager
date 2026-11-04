import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

import '../models/chat.dart';
import 'api_client.dart';
import 'chat_file_cache.dart';
import 'client_id.dart';
import 'local_db.dart';
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
class ChatListController extends ChangeNotifier {
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
      if (newMax > prevMax) {
        try {
          await api.markChatDelivered(newMax);
        } catch (_) {
          // «доставлено» догонит следующая синхронизация — сообщение не теряется
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
class ChatConversationController extends ChangeNotifier {
  final LocalDb db;
  final ApiClient api;

  /// Серверный чат; null, пока диалог существует только локально.
  int? chatId;

  /// Собеседник локального диалога (адрес отправки, пока [chatId] пуст).
  final int? userId;

  ChatConversationController(
      {required this.db, required this.api, this.chatId, this.userId})
      : assert(chatId != null || userId != null);

  /// Очередь отправки и вердикт о сети — общая политика, см. [OutboxDrain];
  /// причины ложатся под `chat:<ключ>` (ключ — id чата или «u<userId>»).
  late final OutboxDrain _sync = OutboxDrain(() => db,
      kind: UnsentKind.chat, taskId: chatOutboxKey(chatId, userId ?? 0));

  bool get online => _sync.online;
  String? get lastSyncError => _sync.lastError;

  ChatSummary? chat;
  List<ChatMessage> items = const [];
  bool loading = true;
  bool syncing = false;
  String? error;
  bool _disposed = false;

  /// Отказ сервера по конкретному сообщению — подпись под его пузырём.
  final Map<String, String> _sendErrors = {};

  /// Строки кэша чатов и очередей поменялись (отправка, дожим, отметка) — списку
  /// и бейджу пора перечитаться; подключает экран, у которого есть список.
  VoidCallback? onQueueChanged;

  /// Ключ этой переписки в очередях: id серверного чата, пока его нет — «u<peer>».
  String get outboxKey => chatOutboxKey(chatId, userId ?? 0);

  /// Кэш вложений этого пользователя.
  late final ChatFileCache _files =
      ChatFileCache(userKey: db.userKey, api: api);

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    super.dispose();
  }

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
      await _loadLocal();
    } catch (_) {
      // база закрылась, пока переписка поднималась (выход из аккаунта)
      loading = false;
      return;
    }
    final failure = await _sync.attempt(() async {
      // своё — первым, чтобы ответ сервера ниже уже содержал его
      await syncAll();
      await _fetchPage(limit: 200); // кэш последних 200 — потолок хранения
      error = null;
    });
    if (failure != null && items.isEmpty) {
      error = failure is ApiException
          ? '$failure'
          : 'Нет связи — переписка ещё не загружалась';
      if (failure is ApiException) _poll?.cancel();
    }
    loading = false;
    if (!_disposed) notifyListeners();
  }

  /// Кэш сообщений плюс своя очередь: неотправленные — в конце, они новее всего,
  /// что сервер успел вернуть, каким бы ни было расхождение часов.
  Future<void> _loadLocal() async {
    await _resolveAddress();
    chat = chatId != null ? await db.chats.getChat(chatId!) : null;
    title = await _resolveTitle();
    final cached =
        chatId != null ? await db.chats.getMessages(chatId!) : const <ChatMessage>[];
    final queued = await db.chats.getOutbox(chatId: chatId, userId: userId);
    items = [
      ...cached,
      for (final r in queued)
        ChatMessage.pendingFrom(r, sendError: _sendErrors[r['clientId'] as String]),
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
    await _loadLocal();
  }

  /// Дозагрузка истории, когда человек доскроллил до верха. Загруженные старые
  /// страницы ложатся в кэш тем же диапазонным replace, но потолок хранения —
  /// 200, так что глубину каждый визит листают заново. Когда сервер не вернул ни
  /// одного сообщения старее запрошенной границы — история в этом чате кончилась.
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
      await _sync.attempt(() async {
        final id = chatId;
        if (id == null) return;
        final page =
            await api.fetchChatMessages(id, before: oldest, limit: 50);
        if (page.every((m) => m.id >= oldest)) {
          _noOlder = true; // старее границы не существует
          return;
        }
        final evict = await db.chats.replaceMessageRange(id, page);
        for (final messageId in evict) {
          await _files.evict(messageId);
        }
        await _loadLocal();
      });
    } finally {
      _loadingOlder = false;
      if (!_disposed) notifyListeners();
    }
  }

  bool _loadingOlder = false;
  bool _noOlder = false;
  bool get loadingOlder => _loadingOlder;

  // --- опрос открытой переписки ---

  Timer? _poll;

  /// Открытая переписка опрашивает последнюю страницу каждые 10 секунд — без
  /// действий человека (#37369). Тихий: обрыв связи — только офлайн-баннер.
  void startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(
        const Duration(seconds: 10), (_) => unawaited(refreshNow()));
  }

  void stopPolling() {
    _poll?.cancel();
    _poll = null;
  }

  /// Немедленный опросный тик: и тик таймера, и «переписка просто обновляется» по
  /// пушу (#37370) — новое сообщение видно сразу, не дожидаясь своего десятка.
  Future<void> refreshNow() async {
    if (_disposed || syncing) return;
    await _sync.attempt(() async {
      await syncAll();
      await _fetchPage(limit: 50);
    });
    if (!_disposed) notifyListeners();
  }

  // --- отправка ---

  /// Написать: строка в очередь (мгновенно и офлайн-безопасно), пузырь в том же
  /// кадре, отправка — следом. Фото копируется в каталог этого пользователя и
  /// уходит внутри того же POST: одно сообщение — один ретрай. Ответ адресуется
  /// серверным id сообщения ([replyTo]) — ответить можно только на серверное.
  Future<void> send(String text, {String? photoPath, int? replyTo}) async {
    final clientId = newClientId();
    final trimmed = text.trim();
    String? stored;
    if (photoPath != null) {
      final dir = await photoDirectory(db.userKey);
      if (!await dir.exists()) await dir.create(recursive: true);
      stored = p.join(dir.path, 'out_$clientId.jpg');
      await File(photoPath).copy(stored);
    }
    await db.chats.enqueueMessage(clientId,
        chatId: chatId,
        userId: chatId == null ? userId : null,
        text: trimmed.isEmpty ? null : trimmed,
        photoPath: stored,
        replyTo: replyTo,
        createdAtIso: DateTime.now().toIso8601String());
    await _loadLocal();
    notifyListeners();
    onQueueChanged?.call();
    unawaited(_sendAndRefresh());
  }

  Future<void> _sendAndRefresh() async {
    final sent = await syncAll();
    if (!sent || _disposed) return;
    try {
      // ушло — у сообщений теперь серверные id; диалог без связи мог стать серверным
      await _fetchPage(limit: 50);
      _sync.online = true;
    } catch (_) {}
    if (!_disposed) notifyListeners();
  }

  /// Убрать из очереди сообщение, которое сервер отверг: ретраить бесполезно, а
  /// висеть «не отправленным» вечно оно не должно (тот же жест, что у ленты).
  Future<void> discard(String clientId) async {
    for (final r in await db.chats.getOutbox(chatId: chatId, userId: userId)) {
      if (r['clientId'] != clientId) continue;
      final path = r['photoPath'] as String?;
      if (path != null) await ChatFileCache.deleteFiles([path]);
    }
    await db.chats.dequeue(clientId);
    _sendErrors.remove(clientId);
    await _loadLocal();
    notifyListeners();
    onQueueChanged?.call();
  }

  /// Дожать очередь этой переписки (и её отметку прочтения). Возвращает, ушло ли
  /// хоть одно сообщение. Открытая переписка и дренаж репозитория толкают одну
  /// очередь по очереди — [drainLocked].
  Future<bool> syncAll() =>
      drainLocked('${UnsentKind.chat}:$outboxKey', _drainOutbox);

  Future<bool> _drainOutbox() async {
    syncing = true;
    if (!_disposed) notifyListeners();
    var sent = false;
    try {
      final key = outboxKey;
      await _sync.each(
        await db.chats.getOutbox(chatId: chatId, userId: userId),
        (e) async {
          final cid = e['clientId'] as String;
          await api.addChatMessage(await _body(e));
          await db.chats.dequeue(cid);
          _sendErrors.remove(cid);
          final path = e['photoPath'] as String?;
          if (path != null) await ChatFileCache.deleteFiles([path]);
          sent = true;
        },
        kind: UnsentKind.chat,
        taskOf: (_) => key,
        onRefused: (e, ex) {
          // сервер ответил отказом (сеть жива): сообщение остаётся с подписью,
          // следующее пробуем — отказ по одному не блокирует остальные
          _sendErrors[e['clientId'] as String] = '$ex';
        },
      );
      await _sendReadMarks();
    } finally {
      syncing = false;
      if (!_disposed) {
        await _loadLocal();
        notifyListeners();
      }
    }
    if (sent) onQueueChanged?.call();
    return sent;
  }

  /// Тело apiAddChatMessage из строки очереди: адрес — серверный чат, а пока его
  /// нет — собеседник (сервер найдёт диалог или создаст). Файл, честно пропавший с
  /// диска (очищенное хранилище), текст не останавливает: сообщение едет без него,
  /// а сообщение из одного пропавшего фото сервер отвергнет — и оно покажется с
  /// подписью, откуда его можно убрать.
  Future<Map<String, dynamic>> _body(Map<String, Object?> e) async {
    final body = <String, dynamic>{'clientId': e['clientId']};
    if (chatId != null) {
      body['chatId'] = chatId;
    } else if (userId != null) {
      body['userId'] = userId;
    }
    final text = e['text'] as String?;
    if (text != null && text.isNotEmpty) body['text'] = text;
    final replyTo = e['replyTo'] as int?;
    if (replyTo != null) body['replyTo'] = replyTo;
    final path = e['photoPath'] as String?;
    if (path != null) {
      try {
        body['photo'] = base64Encode(await File(path).readAsBytes());
      } on PathNotFoundException {
        // см. выше
      }
    }
    return body;
  }

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
    await db.chats.markRead(id, upTo);
    await _sendReadMarks();
    onQueueChanged?.call();
  }

  Future<void> _sendReadMarks() async {
    final id = chatId;
    if (id == null) return;
    final mine = [
      for (final r in await db.chats.getPendingReads())
        if (r['chatId'] == id) r
    ];
    await _sync.each(mine, (r) async {
      final upTo = r['upTo'] as int;
      try {
        await api.markChatRead(id, upTo);
      } on ApiException {
        // сервер отверг (доступ к чату пропал): отметка не настолько важна, чтобы
        // висеть в очереди вечно
      }
      await db.chats.markReadSent(id, upTo);
    }, kind: UnsentKind.chat, taskOf: (_) => outboxKey);
    onQueueChanged?.call();
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
    await _loadLocal();
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
