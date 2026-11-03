import 'dart:typed_data';

import '../../models/chat.dart';
import '../api_client.dart';

/// Чаты (#37369). Контракт — таблица #37366 и шапка api/ChatApi.lsf: чтение — GET,
/// мутации — POST с JSON-телом и ответом `{}`; идентификаторы внутренние (LONG),
/// на «нет такого» и на «не твой» — один 403.
extension ChatApi on ApiClient {
  /// Включён ли чат на этом сервере (`chatEnabled`). Сервер без пакета чата
  /// ответит 404 — телефон прячет раздел, тот же приём, что apiAiInfo.
  Future<bool> fetchChatInfo() async {
    final r = await get(exec('apiChatInfo'), timeout: const Duration(seconds: 10));
    final list = decodeList(r.bodyBytes);
    if (list.isEmpty) return false;
    return list.first['enabled'] == true ||
        list.first['enabled'] == 1 ||
        list.first['enabled'] == 'true';
  }

  /// Все чаты вызывающего, которые показывает телефон, свежие сверху. `today` —
  /// серверная дата для подписей «сегодня»/«вчера» (#37125).
  Future<List<ChatSummary>> fetchChats() async {
    final r = await get(exec('apiChats'));
    return decodeList(r.bodyBytes).map(ChatSummary.fromJson).toList();
  }

  /// Страница переписки, свежие сверху. Без [before] — последние [limit]
  /// (по умолчанию 50, не больше 200), с [before] — более старые; граница и
  /// порядок — по id сообщения, не по времени.
  Future<List<ChatMessage>> fetchChatMessages(int chatId,
      {int? before, int? limit}) async {
    final r = await get(exec('apiChatMessages', {
      'id': '$chatId',
      if (before != null) 'before': '$before',
      if (limit != null) 'limit': '$limit',
    }));
    return decodeList(r.bodyBytes).map(ChatMessage.fromJson).toList();
  }

  /// Отправить сообщение: тело — строка очереди как есть (clientId — UUID, по
  /// которому сервер узнаёт повтор; chatId или userId — диалог, начатый без связи,
  /// сервер найдёт его или создаст; photo в base64). Повтор того же clientId —
  /// 200 без тела, поэтому ретраи безопасны. Телу с фото — время по размеру ноши,
  /// как у addTaskComment.
  Future<void> addChatMessage(Map<String, dynamic> body) =>
      postJson('apiAddChatMessage', body,
          timeout: body.containsKey('photo')
              ? const Duration(seconds: 120)
              : const Duration(seconds: 20));

  /// Прочитано до [upTo] — id последнего показанного сообщения чата. Монотонна и
  /// идемпотентна на сервере: повтор и отставшая отметка безвредны.
  Future<void> markChatRead(int chatId, int upTo) =>
      postJson('apiMarkChatRead', {'id': chatId, 'upTo': upTo});

  /// «Доставлено» до [upTo] по всем чатам вызывающего — телефон зовёт после
  /// синхронизации, которая принесла новые сообщения.
  Future<void> markChatDelivered(int upTo) =>
      postJson('apiMarkChatDelivered', {'upTo': upTo});

  /// Байты вложения сообщения; [thumb] — миниатюра через общий serveImage.
  Future<Uint8List> fetchChatFile(int messageId, {bool thumb = false}) async {
    final r = await get(
      exec('apiChatFile', {'id': '$messageId', if (thumb) 'thumb': '1'}),
      timeout: thumb ? const Duration(seconds: 20) : const Duration(seconds: 60),
    );
    return r.bodyBytes;
  }

  /// Контакты: без [q] — коллеги (кэшируются телефоном для работы без связи),
  /// с [q] — поиск по имени и логину, не больше 30 человек.
  Future<List<ChatContact>> fetchChatContacts({String? q}) async {
    final r = await get(exec('apiChatContacts', {if (q != null && q.isNotEmpty) 'q': q}));
    return decodeList(r.bodyBytes).map(ChatContact.fromJson).toList();
  }

  /// «Без звука» у чата: сообщения приходят и считаются непрочитанными, пуша по
  /// ним нет (пуш — стык уведомлений, #37367).
  Future<void> setChatMuted(int chatId, bool muted) =>
      postJson('apiSetChatMuted', {'id': chatId, 'muted': muted});
}
