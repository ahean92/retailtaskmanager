import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/chat_controller.dart';
import '../data/sync_coordinator.dart';
import '../models/chat.dart';
import 'chat_contacts_screen.dart';
import 'chat_screen.dart';
import 'theme.dart';
import 'widgets/ds.dart';

/// Список чатов (#37369): вид, имя, последнее сообщение «Иван: …»/«Вы: …», время
/// от серверного today, непрочитанные — у «без звука» серым. Чистый рендер
/// [ChatListController]: список обновляется при синхронизации, экран всегда читает
/// из кэша — и в подвале без сети открывается тем же списком.
class ChatListScreen extends StatelessWidget {
  const ChatListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ChatListController>();
    final sync = context.read<SyncCoordinator>();
    return Scaffold(
      appBar: AppBar(
        // заголовок — крупным в теле; здесь только путь назад и «новый диалог»
        leading: const BackButton(),
        actions: [
          IconButton(
            tooltip: 'Новый диалог',
            icon: const Icon(Icons.person_add_outlined),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const ChatContactsScreen())),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DsScreenTitle('Чаты',
              subtitle: chat.unreadBadge > 0
                  ? _unreadLine(chat.unreadBadge)
                  : null),
          Expanded(
            child: RefreshIndicator(
              onRefresh: sync.syncAndRefresh,
              child: chat.chats.isEmpty && chat.localDialogs.isEmpty
                  ? ListView(children: [
                      SizedBox(
                          height: MediaQuery.of(context).size.height * 0.12),
                      _empty(context),
                    ])
                  : _list(context, chat),
            ),
          ),
        ],
      ),
    );
  }

  static String _unreadLine(int n) {
    final m = n % 100;
    if (m >= 11 && m <= 14) return '$n непрочитанных сообщений';
    return switch (n % 10) {
      1 => '$n непрочитанное сообщение',
      2 || 3 || 4 => '$n непрочитанных сообщения',
      _ => '$n непрочитанных сообщений',
    };
  }

  Widget _empty(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.forum_outlined, size: 48, color: Wms.muted),
          const SizedBox(height: 12),
          Text('Чатов пока нет',
              style: TextStyle(fontSize: 16, color: Wms.muted)),
          const SizedBox(height: 4),
          Text('Начните диалог с коллегой — он появится здесь',
              style: TextStyle(fontSize: 13, color: Wms.muted)),
          const SizedBox(height: 16),
          FilledButton.tonalIcon(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const ChatContactsScreen())),
            icon: const Icon(Icons.person_add_outlined, size: 18),
            label: const Text('Новый диалог'),
          ),
        ],
      ),
    );
  }

  Widget _list(BuildContext context, ChatListController chat) {
    // «Какое сегодня» — серверное today из строк списка (#37125): телефон в чужом
    // часовом поясе не должен подписывать чужое «вчера». Нет ни у одной строки —
    // дата устройства, как fallback ленты.
    DateTime? serverToday;
    for (final c in chat.chats) {
      serverToday = c.serverToday;
      if (serverToday != null) break;
    }
    final today = serverToday ?? DateTime.now();

    // вместе и по свежести, как у мессенджера: только что начатый диалог —
    // самое свежее в списке, а не хвост под серверными строками. Серверное
    // время парсится (формат DATETIME не обязан совпадать с местным ISO),
    // локальное — уже ISO постановки в очередь.
    final rows = <(DateTime?, Widget)>[
      for (final c in chat.chats) (c.last?.when, _ChatRow(chat: c, today: today)),
      for (final d in chat.localDialogs) (d.lastAt, _LocalDialogRow(dialog: d)),
    ]..sort((a, b) {
        final x = a.$1, y = b.$1;
        if (x == null) return y == null ? 0 : 1;
        if (y == null) return -1;
        return y.compareTo(x);
      });
    final widgets = [for (final r in rows) r.$2];
    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      child: DsCard(
        margin: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        children: [
          for (final w in widgets) ...[
            w,
            if (w != widgets.last) const Divider(height: 1, thickness: 1),
          ],
        ],
      ),
    );
  }
}

/// Строка серверного чата: значок вида, имя, превью последнего сообщения, время и
/// непрочитанное (у «без звука» — серым), значок «без звука».
class _ChatRow extends StatelessWidget {
  final ChatSummary chat;
  final DateTime today;

  const _ChatRow({required this.chat, required this.today});

  @override
  Widget build(BuildContext context) {
    final unread = chat.unread;
    return InkWell(
      onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => ChatScreen(chatId: chat.id))),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            _kindIcon(context, chat.kind),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          chat.name ?? 'Чат',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: Wms.text),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _when(chat.last?.when, today),
                        style:
                            TextStyle(fontSize: 12, color: Wms.muted),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      if (chat.muted) ...[
                        Icon(Icons.notifications_off_outlined,
                            size: 14, color: Wms.muted),
                        const SizedBox(width: 4),
                      ],
                      Expanded(
                        child: Text(
                          chat.last == null ? '' : chat.last!.preview,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 13,
                              color: unread > 0 && !chat.muted
                                  ? Wms.text
                                  : Wms.muted),
                        ),
                      ),
                      if (unread > 0) ...[
                        const SizedBox(width: 8),
                        _UnreadBadge(count: unread, muted: chat.muted),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Widget _kindIcon(BuildContext context, String kind) {
    final (icon, label) = switch (kind) {
      ChatKind.dialog => (Icons.person_outline, 'Диалог'),
      ChatKind.role => (Icons.workspace_premium_outlined, 'Роль'),
      _ => (Icons.group_outlined, 'Группа'),
    };
    return Tooltip(
      message: label,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: Wms.chipBg,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Icon(icon, size: 20, color: Wms.primary),
      ),
    );
  }
}

/// Диалог, начатый с телефона и ещё не севший на серверный чат: имя собеседника,
/// превью неотправленного, значок «ждёт связи». После синхронизации сливается с
/// серверной строкой (ChatsDao.replaceChats) и строка списка становится обычной.
class _LocalDialogRow extends StatelessWidget {
  final LocalChatDialog dialog;

  const _LocalDialogRow({required this.dialog});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => ChatScreen(userId: dialog.userId))),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: Wms.chipBg,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Icon(Icons.person_outline, size: 20, color: Wms.primary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          dialog.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: Wms.text),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(Icons.schedule, size: 14, color: Wms.muted),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    dialog.lastPreview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: Wms.muted),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Счётчик непрочитанного в строке: обычный чат — фирменным цветом, «без звука» —
/// серым: сообщения приходят и считаются, но не зазывают.
class _UnreadBadge extends StatelessWidget {
  final int count;
  final bool muted;

  const _UnreadBadge({required this.count, required this.muted});

  @override
  Widget build(BuildContext context) {
    final bg = muted ? Wms.chipBg : Wms.primary;
    final fg = muted ? Wms.text2 : Colors.white;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$count',
        style: TextStyle(
            fontSize: 12, fontWeight: FontWeight.w700, color: fg),
      ),
    );
  }
}

/// «10:42» сегодня, «Вчера», «12.07» — время строки списка от серверного today
/// (часы — серверные, из самого сообщения). Пустое — сообщения в чате ещё нет.
String _when(DateTime? t, DateTime today) {
  if (t == null) return '';
  String two(int v) => v.toString().padLeft(2, '0');
  // счёт в UTC: разница двух местных полуночей в сутки перевода часов — 23 часа,
  // и «вчера» стало бы «сегодня» дважды в год (тот же приём, что лента #37125)
  final d = DateTime.utc(t.year, t.month, t.day);
  final now = DateTime.utc(today.year, today.month, today.day);
  final diff = now.difference(d).inDays;
  final hm = '${two(t.hour)}:${two(t.minute)}';
  if (diff <= 0) return hm;
  if (diff == 1) return 'Вчера';
  return '${two(t.day)}.${two(t.month)}';
}
