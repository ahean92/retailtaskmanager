import 'package:sqflite/sqflite.dart';

import '../../models/chat.dart';

/// Чаты (#37369): кэш списка и последних 200 сообщений каждого чата, очередь
/// отправки с ключом идемпотентности, отметки «прочитано до» и коллеги для поиска
/// собеседника. Тот же рисунок, что у [CommentsDao] переписки по задаче.

/// Потолок кэша сообщений одного чата: глубже человек листает с сервера.
const chatMessageCacheLimit = 200;

/// Ключ адреса чата в очередях и причинах: серверный чат — его id, диалог,
/// начатый без связи, — «u<userId>», пока серверного чата нет. Префикс разводит
/// пространства ключей: числовые id пользователя и чата могут совпасть, а ключ
/// обязан адресовать одно.
String chatOutboxKey(int? chatId, int userId) =>
    chatId != null ? '$chatId' : 'u$userId';

class ChatsDao {
  ChatsDao(this._db);

  final Database _db;

  // --- список чатов ---

  /// Заменить кэш списка ответом apiChats и слить локальные диалоги с серверными:
  /// строка очереди, адресованная `userId` (диалог начат без связи), получает
  /// chatId приехавшего диалога с тем же peerId — иначе переписка, начатая до
  /// синхронизации, осталась бы «новым диалогом» рядом со своим серверным двойником
  /// (риск #37369; двойного чата сервер не создаст — createDialogChat идемпотентен,
  /// слияние нужно только на клиенте). Возвращает пары «userId → chatId», которые
  /// слились: открытая переписка по userId должна перейти на новый ключ.
  Future<Map<int, int>> replaceChats(List<ChatSummary> chats) async {
    final merged = <int, int>{};
    await _db.transaction((txn) async {
      await txn.delete('chat_cache');
      final batch = txn.batch();
      for (final c in chats) {
        batch.insert('chat_cache', c.toMap(),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
      for (final c in chats) {
        if (c.kind != ChatKind.dialog || c.peerId == null) continue;
        await txn.update(
          'chat_outbox',
          {'chatId': c.id},
          where: 'userId = ? AND chatId IS NULL',
          whereArgs: [c.peerId],
        );
        merged[c.peerId!] = c.id;
      }
    });
    return merged;
  }

  /// Кэш списка, свежие сверху — тем же порядком, каким их отдал сервер
  /// (lastMessageDateTime DESC, id DESC): локальное сравнение строк серверных
  /// времён и есть этот порядок.
  Future<List<ChatSummary>> getChats() async {
    final rows = await _db.query('chat_cache',
        orderBy: 'lastAt DESC, id DESC');
    return rows.map(ChatSummary.fromMap).toList();
  }

  Future<ChatSummary?> getChat(int id) async {
    final rows = await _db
        .query('chat_cache', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : ChatSummary.fromMap(rows.first);
  }

  /// Самый большой id последнего сообщения по всему кэшу списка — «что телефон уже
  /// видел»: синхронизация, принёсшая более свежий id, отмечает «доставлено».
  Future<int> maxLastId() async {
    final rows = await _db.rawQuery('SELECT MAX(lastId) AS m FROM chat_cache');
    return (rows.first['m'] as int?) ?? 0;
  }

  /// Диалог с собеседником [userId], если он уже приехал с сервера, — им завершает
  /// поиск собеседника: найден диалог → открываем его, а не заводим новый.
  Future<ChatSummary?> findDialogWith(int userId) async {
    final rows = await _db.query('chat_cache',
        where: 'kind = ? AND peerId = ?',
        whereArgs: [ChatKind.dialog, userId],
        limit: 1);
    return rows.isEmpty ? null : ChatSummary.fromMap(rows.first);
  }

  /// Заменить «без звука» в строке кэша — человек переключил звук сейчас, а
  /// серверное значение приедет следующей синхронизацией списка.
  Future<void> setMuted(int chatId, bool muted) async {
    await _db.update('chat_cache', {'muted': muted ? 1 : 0},
        where: 'id = ?', whereArgs: [chatId]);
  }

  // --- сообщения ---

  /// Заменить кэш сообщений на диапазоне id страницы (свежие сверху, как отдал
  /// сервер): в диапазоне [min..max] удаляется всё и вставляется страница — так
  /// доезжают правки и удаления из веба, а не только новые. Возвращает id чужих
  /// сообщений с картинкой, которые удалены и не вернулись страницей: их
  /// скачанные файлы больше ничьи, вызывающий стирает их с диска.
  Future<Set<int>> replaceMessageRange(
      int chatId, List<ChatMessage> page) async {
    final evict = <int>{};
    await _db.transaction((txn) async {
      if (page.isNotEmpty) {
        final ids = page.map((m) => m.id).toList();
        final minId = ids.reduce((a, b) => a < b ? a : b);
        final maxId = ids.reduce((a, b) => a > b ? a : b);
        final kept = await txn.query('chat_message_cache',
            columns: ['id', 'fileImage'],
            where: 'chatId = ? AND id BETWEEN ? AND ?',
            whereArgs: [chatId, minId, maxId]);
        final returned = ids.toSet();
        for (final r in kept) {
          final id = r['id'] as int;
          if (!returned.contains(id) && r['fileImage'] == 1) evict.add(id);
        }
        await txn.delete('chat_message_cache',
            where: 'chatId = ? AND id BETWEEN ? AND ?',
            whereArgs: [chatId, minId, maxId]);
        final batch = txn.batch();
        for (final m in page) {
          batch.insert('chat_message_cache', m.toMap(chatId),
              conflictAlgorithm: ConflictAlgorithm.replace);
        }
        await batch.commit(noResult: true);
      }
      // потолок кэша — последние 200: всё, что старше, листается с сервера
      await txn.execute(
          'DELETE FROM chat_message_cache WHERE chatId = ? AND id NOT IN '
          '(SELECT id FROM chat_message_cache WHERE chatId = ? '
          'ORDER BY id DESC LIMIT ?)',
          [chatId, chatId, chatMessageCacheLimit]);
    });
    return evict;
  }

  /// Кэш сообщений чата, старые снизу (порядок ленты).
  Future<List<ChatMessage>> getMessages(int chatId) async {
    final rows = await _db.query('chat_message_cache',
        where: 'chatId = ?', whereArgs: [chatId], orderBy: 'id ASC');
    return rows.map(ChatMessage.fromMap).toList();
  }

  /// Самый большой id сообщения в кэше чата — граница «прочитано до» и «доставлено
  /// до»; null — серверных сообщений в кэше нет, отмечать нечего.
  Future<int?> maxMessageId(int chatId) async {
    final rows = await _db.rawQuery(
        'SELECT MAX(id) AS m FROM chat_message_cache WHERE chatId = ?',
        [chatId]);
    return rows.first['m'] as int?;
  }

  /// Чужие сообщения чата новее [upTo] — точный местный непрочитанный счётчик,
  /// когда отметка «прочитано до» ещё не доехала до сервера: apiChats продолжил бы
  /// считать непрочитанным и прочитанное офлайн, и бейдж зажигался бы своим же
  /// «прочитано» (сервер отметку монотонно примет — расхождение живёт один прогон).
  Future<int> newSince(int chatId, int upTo) async {
    final rows = await _db.rawQuery(
        'SELECT COUNT(*) AS n FROM chat_message_cache '
        'WHERE chatId = ? AND id > ? AND mine = 0',
        [chatId, upTo]);
    return (rows.first['n'] as int?) ?? 0;
  }

  /// id сообщений с картинкой в диапазоне — какие из них уже скачаны (для префетча
  /// миниатюр: качать только то, чего на диске нет).
  Future<Set<int>> imageMessageIds(int chatId) async {
    final rows = await _db.query('chat_message_cache',
        columns: ['id'],
        where: 'chatId = ? AND fileImage = 1',
        whereArgs: [chatId]);
    return {for (final r in rows) r['id'] as int};
  }

  // --- очередь отправки ---

  /// Поставить сообщение: адрес — чат [chatId] или собеседник [userId] (диалог без
  /// связи, серверный чат ещё не существует).
  Future<void> enqueueMessage(String clientId,
      {int? chatId,
      int? userId,
      String? text,
      String? photoPath,
      int? replyTo,
      required String createdAtIso}) async {
    await _db.insert(
      'chat_outbox',
      {
        'clientId': clientId,
        'chatId': chatId,
        'userId': userId,
        'text': text,
        'photoPath': photoPath,
        'replyTo': replyTo,
        'createdAt': createdAtIso,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Неотправленные строки одной переписки: по чату — его строки, по диалогу без
  /// связи — строки этого userId (включая уже сцепленные с серверным чатом: адресат
  /// один, а слияние могло случиться, пока переписка открыта).
  Future<List<Map<String, Object?>>> getOutbox({int? chatId, int? userId}) {
    final where = <String>[];
    final args = <Object?>[];
    if (chatId != null) {
      where.add('(chatId = ?');
      args.add(chatId);
      if (userId != null) {
        where.add('OR (chatId IS NULL AND userId = ?))');
        args.add(userId);
      } else {
        where.add(')');
      }
    } else if (userId != null) {
      where.add('userId = ?');
      args.add(userId);
    } else {
      throw ArgumentError('chatId or userId required');
    }
    return _db.query('chat_outbox',
        where: where.join(' '), whereArgs: args, orderBy: 'createdAt ASC');
  }

  /// Вся очередь сообщений — для дренажа при синхронизации, счётчика
  /// «Не отправлено» и локальных строк списка («диалог, начатый без связи»).
  Future<List<Map<String, Object?>>> getAllOutbox() {
    return _db.query('chat_outbox', orderBy: 'createdAt ASC');
  }

  Future<void> dequeue(String clientId) async {
    await _db
        .delete('chat_outbox', where: 'clientId = ?', whereArgs: [clientId]);
  }

  // --- прочитано ---

  /// Прочитано до [upTo] (серверный id последнего показанного сообщения) —
  /// монотонно: отметка, приехавшая из прошлого, назад ничего не откатывает.
  /// Локально — сразу (бейдж гаснет в этом же кадре); на сервер уезжает очередью.
  Future<bool> markRead(int chatId, int upTo) async {
    final rows = await _db
        .query('chat_read', where: 'chatId = ?', whereArgs: [chatId]);
    if (rows.isNotEmpty && (rows.first['upTo'] as int) >= upTo) return false;
    await _db.insert(
      'chat_read',
      {'chatId': chatId, 'upTo': upTo, 'pending': 1},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return true;
  }

  Future<Map<String, Object?>?> getReadMark(int chatId) async {
    final rows = await _db
        .query('chat_read', where: 'chatId = ?', whereArgs: [chatId]);
    return rows.isEmpty ? null : rows.first;
  }

  Future<List<Map<String, Object?>>> getPendingReads() {
    return _db.query('chat_read', where: 'pending = 1');
  }

  /// Отметка ушла на сервер — но только эта: если за время полёта легла более
  /// свежая, ей ещё ехать.
  Future<void> markReadSent(int chatId, int upTo) async {
    await _db.update('chat_read', {'pending': 0},
        where: 'chatId = ? AND upTo = ?', whereArgs: [chatId, upTo]);
  }

  // --- коллеги ---

  /// Заменить кэш коллег ответом apiChatContacts без запроса — те, с кем можно
  /// начать диалог, нужны и без сети.
  Future<void> replaceContacts(List<ChatContact> contacts,
      {required String fetchedAtIso}) async {
    await _db.transaction((txn) async {
      await txn.delete('chat_contacts');
      final batch = txn.batch();
      for (final c in contacts) {
        batch.insert('chat_contacts', c.toMap(fetchedAtIso),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
  }

  Future<List<ChatContact>> getContacts() async {
    final rows = await _db.query('chat_contacts', orderBy: 'name ASC');
    return rows.map(ChatContact.fromMap).toList();
  }

  Future<ChatContact?> getContact(int userId) async {
    final rows = await _db
        .query('chat_contacts', where: 'userId = ?', whereArgs: [userId]);
    return rows.isEmpty ? null : ChatContact.fromMap(rows.first);
  }

  /// Удалить строки очереди одной операции «Не отправлено» (#37349) — человек
  /// решил убрать отклонённое сервером. [key] — [chatOutboxKey]: для «u<userId>»
  /// берутся все строки этого собеседника (слияние могло уже проставить им chatId,
  /// а колонка userId остаётся), для серверного чата — его строки. Возвращает пути
  /// фото неснятых строк.
  Future<List<String>> discardOutboxRows(String key) async {
    final byUser = key.startsWith('u');
    final id = int.tryParse(byUser ? key.substring(1) : key);
    if (id == null) return const [];
    final where = byUser ? 'userId = ?' : 'chatId = ?';
    final rows = await _db.query('chat_outbox',
        where: '$where AND photoPath IS NOT NULL', whereArgs: [id]);
    await _db.delete('chat_outbox', where: where, whereArgs: [id]);
    return [
      for (final r in rows) r['photoPath']! as String,
    ];
  }
}
