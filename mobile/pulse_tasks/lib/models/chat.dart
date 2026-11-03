import 'json.dart';
import 'notification.dart';

/// Вложенная «форма» ответа (last, replyTo, file): lsFusion экспортирует её
/// СПИСКОМ строк даже тогда, когда строка одна, — как и сам ответ ручки. Телефон
/// принимает обе формы: список с одним объектом и сам объект.
Map<String, dynamic>? chatForm(Object? v) {
  if (v is Map) return v.cast<String, dynamic>();
  if (v is List && v.isNotEmpty && v.first is Map) {
    return (v.first as Map).cast<String, dynamic>();
  }
  return null;
}

/// Статус своего сообщения чата — код с сервера (apiChatMessages.status), не
/// локализованная подпись платформы. Чужие телефон галками не помечает: статус
/// приходит только у своих.
class ChatMessageStatus {
  static const sent = 'sent'; // ✓ — отправлено
  static const delivered = 'delivered'; // ✓✓ — доставлено
  static const seen = 'seen'; // ✓✓ цветом — прочитано
}

/// Вид чата — рисует сервер (apiChats.kind), клиент решает по нему только значок.
class ChatKind {
  static const dialog = 'dialog';
  static const group = 'group';
  static const role = 'role';
}

/// Последнее сообщение чата из строки списка (apiChats.last). Пустое (нет id) —
/// чат есть, а последнего сообщения сервер не назвал; список рисует строку без
/// превью, а не разваливается.
class ChatLastMessage {
  final int id;
  final String? author;
  final bool mine;
  final String? dateTime;
  final String? text;
  final bool photo;

  const ChatLastMessage({
    required this.id,
    this.author,
    this.mine = false,
    this.dateTime,
    this.text,
    this.photo = false,
  });

  factory ChatLastMessage.fromJson(Map<String, dynamic> j) => ChatLastMessage(
        id: jsonInt(j['id']) ?? 0,
        author: jsonText(j['author']),
        mine: jsonFlag(j['mine']),
        dateTime: jsonText(j['dateTime']),
        text: jsonText(j['text']),
        photo: jsonFlag(j['photo']),
      );

  /// «Вы: …»/«Иван: …» — превью в списке чатов; сообщение только с фото —
  /// «Фотография», как его называет пуш (дизайн §6.4).
  String get preview {
    final who = mine ? 'Вы' : (author ?? '');
    final body = photo && (text ?? '').isEmpty
        ? 'Фотография'
        : (text ?? '').trim();
    return who.isEmpty ? body : '$who: $body';
  }

  DateTime? get when =>
      dateTime == null ? null : DateTime.tryParse(dateTime!);
}

/// Одна строка списка чатов (apiChats). Всё, кроме [last], — свойства чата для
/// вызывающего: имя (у диалога — собеседник), «только чтение», «без звука» и
/// непрочитанное. Правил видимости в клиенте нет — клиент рисует то, что пришло
/// (#37369 «Универсально»).
class ChatSummary {
  final int id;
  final String kind;
  final String? name;
  final int? peerId;
  final int? members;
  final bool readonly;
  final bool muted;
  final int unread;
  final ChatLastMessage? last;

  /// Серверная дата ответа — для подписей «сегодня»/«вчера» списка: телефон в
  /// чужом часовом поясе не должен раскладывать чужие «вчера» (тот же приём, что
  /// #37125). Хранится в каждой строке одинаковым — берётся из первой непустой.
  final String? today;

  const ChatSummary({
    required this.id,
    required this.kind,
    this.name,
    this.peerId,
    this.members,
    this.readonly = false,
    this.muted = false,
    this.unread = 0,
    this.last,
    this.today,
  });

  factory ChatSummary.fromJson(Map<String, dynamic> j) {
    final last = chatForm(j['last']);
    return ChatSummary(
      id: jsonInt(j['id']) ?? 0,
      kind: jsonStr(j['kind']) ?? ChatKind.group,
      name: jsonStr(j['name']),
      peerId: jsonInt(j['peerId']),
      members: jsonInt(j['members']),
      readonly: jsonFlag(j['readonly']),
      muted: jsonFlag(j['muted']),
      unread: jsonInt(j['unread']) ?? 0,
      last: last == null ? null : ChatLastMessage.fromJson(last),
      today: jsonStr(j['today']),
    );
  }

  /// Строка кэша `chat_cache`.
  Map<String, Object?> toMap() => {
        'id': id,
        'kind': kind,
        'name': name,
        'peerId': peerId,
        'members': members,
        'readonly': readonly ? 1 : 0,
        'muted': muted ? 1 : 0,
        'unread': unread,
        'lastId': last?.id,
        'lastAuthor': last?.author,
        'lastMine': last?.mine == true ? 1 : 0,
        'lastAt': last?.dateTime,
        'lastText': last?.text,
        'lastPhoto': last?.photo == true ? 1 : 0,
        'today': today,
      };

  factory ChatSummary.fromMap(Map<String, Object?> m) => ChatSummary(
        id: m['id'] as int,
        kind: m['kind'] as String,
        name: m['name'] as String?,
        peerId: m['peerId'] as int?,
        members: m['members'] as int?,
        readonly: m['readonly'] == 1,
        muted: m['muted'] == 1,
        unread: (m['unread'] as int?) ?? 0,
        last: m['lastId'] == null
            ? null
            : ChatLastMessage(
                id: m['lastId'] as int,
                author: m['lastAuthor'] as String?,
                mine: m['lastMine'] == 1,
                dateTime: m['lastAt'] as String?,
                text: m['lastText'] as String?,
                photo: m['lastPhoto'] == 1,
              ),
        today: m['today'] as String?,
      );

  /// Серверный день ответа, каким его прислали (или null — тогда подписи времени
  /// считает экран по часам устройства, как fallback ленты #37125).
  DateTime? get serverToday => parseServerDay(today);
}

/// Сообщение чата. С сервера (apiChatMessages) — с внутренним id; из очереди
/// телефона — с [pending] и ключом [clientId], по которому строка схлопнется с
/// серверной, когда ответ на POST потерялся по дороге, а само сообщение доехало.
class ChatMessage {
  /// Серверный id; 0 — сообщение ещё в очереди и серверного id не имеет.
  final int id;
  final String? clientId;
  final int? authorId;
  final String? author;
  final bool mine;
  final String? dateTime;

  /// Чистый текст — HTML сервера телефон не отрисовывает (plainFromHtml на сервере).
  final String? text;
  final bool edited;

  /// Цитата ответа, если сообщение отвечает на другое: автор и текст исходного.
  final int? replyId;
  final String? replyAuthor;
  final String? replyText;

  /// Вложение — ровно одно на сообщение: имя и признак картинки; байты отдаёт
  /// apiChatFile по id сообщения.
  final String? fileName;
  final bool fileImage;

  /// sent/delivered/seen — только у своих (см. [ChatMessageStatus]).
  final String? status;

  /// Ещё не доехало до сервера: показывается пузырём «не отправлено» из локального
  /// файла [photoPath]; [sendError] — отказ сервера при последней попытке.
  final bool pending;
  final String? photoPath;
  final String? sendError;

  const ChatMessage({
    required this.id,
    this.clientId,
    this.authorId,
    this.author,
    this.mine = false,
    this.dateTime,
    this.text,
    this.edited = false,
    this.replyId,
    this.replyAuthor,
    this.replyText,
    this.fileName,
    this.fileImage = false,
    this.status,
    this.pending = false,
    this.photoPath,
    this.sendError,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> j) {
    final reply = chatForm(j['replyTo']);
    final file = chatForm(j['file']);
    return ChatMessage(
      id: jsonInt(j['id']) ?? 0,
      clientId: jsonText(j['clientId']),
      authorId: jsonInt(j['authorId']),
      author: jsonText(j['author']),
      mine: jsonFlag(j['mine']),
      dateTime: jsonText(j['dateTime']),
      text: jsonText(j['text']),
      edited: jsonFlag(j['edited']),
      replyId: reply == null ? null : jsonInt(reply['id']),
      replyAuthor: reply == null ? null : jsonText(reply['author']),
      replyText: reply == null ? null : jsonText(reply['text']),
      fileName: file == null ? null : jsonText(file['name']),
      fileImage: file != null && jsonFlag(file['image']),
      status: jsonStr(j['status']),
    );
  }

  /// Строка кэша `chat_message_cache`.
  Map<String, Object?> toMap(int chatId) => {
        'chatId': chatId,
        'id': id,
        'clientId': clientId,
        'authorId': authorId,
        'author': author,
        'mine': mine ? 1 : 0,
        'dateTime': dateTime,
        'text': text,
        'edited': edited ? 1 : 0,
        'replyId': replyId,
        'replyAuthor': replyAuthor,
        'replyText': replyText,
        'fileName': fileName,
        'fileImage': fileImage ? 1 : 0,
        'status': status,
      };

  factory ChatMessage.fromMap(Map<String, Object?> m) => ChatMessage(
        id: m['id'] as int,
        clientId: m['clientId'] as String?,
        authorId: m['authorId'] as int?,
        author: m['author'] as String?,
        mine: m['mine'] == 1,
        dateTime: m['dateTime'] as String?,
        text: m['text'] as String?,
        edited: m['edited'] == 1,
        replyId: m['replyId'] as int?,
        replyAuthor: m['replyAuthor'] as String?,
        replyText: m['replyText'] as String?,
        fileName: m['fileName'] as String?,
        fileImage: m['fileImage'] == 1,
        status: m['status'] as String?,
      );

  /// Строка очереди `chat_outbox` — сообщение, которого сервер ещё не видел:
  /// адрес отправки (chatId или userId) остаётся в строке, а не в модели.
  factory ChatMessage.pendingFrom(Map<String, Object?> row,
      {String? sendError}) {
    final cid = row['clientId'] as String;
    return ChatMessage(
      id: 0,
      clientId: cid,
      author: 'Вы',
      mine: true,
      dateTime: row['createdAt'] as String?,
      text: row['text'] as String?,
      replyId: row['replyTo'] as int?,
      pending: true,
      photoPath: row['photoPath'] as String?,
      sendError: sendError,
    );
  }

  DateTime? get when =>
      dateTime == null ? null : DateTime.tryParse(dateTime!);

  bool get hasPhoto => fileImage || photoPath != null;
}

/// Кандидат диалога (apiChatContacts): активная учётка исполнителя, не своя.
/// [hint] — подсказка, кто это («Директор · Магазин 12»); хост может подставить
/// своё — клиент рисует как есть.
class ChatContact {
  final int userId;
  final String? name;
  final String? hint;

  const ChatContact({required this.userId, this.name, this.hint});

  factory ChatContact.fromJson(Map<String, dynamic> j) => ChatContact(
        userId: jsonInt(j['id']) ?? 0,
        name: jsonStr(j['name']),
        hint: jsonStr(j['hint']),
      );

  Map<String, Object?> toMap(String fetchedAtIso) => {
        'userId': userId,
        'name': name,
        'hint': hint,
        'fetchedAt': fetchedAtIso,
      };

  factory ChatContact.fromMap(Map<String, Object?> m) => ChatContact(
        userId: m['userId'] as int,
        name: m['name'] as String?,
        hint: m['hint'] as String?,
      );
}
