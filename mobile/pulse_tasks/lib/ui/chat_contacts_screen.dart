import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/chat_controller.dart';
import '../data/task_repository.dart';
import 'chat_screen.dart';
import 'theme.dart';
import 'widgets/ds.dart';

/// Поиск собеседника для нового диалога (#37369): коллеги из кэша (работают без
/// сети) и поиск на сервере по имени и логину. Начать диалог можно только с тем,
/// кто есть в apiChatContacts; свой id сервер отвергнет — потому своих в списке
/// нет. Первый экран поиска — без запроса: то, что искали в прошлый раз, чаще
/// всего и нужно сейчас.
class ChatContactsScreen extends StatefulWidget {
  const ChatContactsScreen({super.key});

  @override
  State<ChatContactsScreen> createState() => _ChatContactsScreenState();
}

class _ChatContactsScreenState extends State<ChatContactsScreen> {
  ChatContactsController? _controller;
  final TextEditingController _query = TextEditingController();
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    final repo = context.read<TaskRepository>();
    final db = repo.localDb;
    if (db == null) return;
    _controller = ChatContactsController(db: db, api: repo.api);
    _controller!.load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller?.dispose();
    _query.dispose();
    super.dispose();
  }

  void _onQuery(String q) {
    _debounce?.cancel();
    _debounce = Timer(
        const Duration(milliseconds: 400), () => _controller?.search(q));
  }

  @override
  Widget build(BuildContext context) {
    if (_controller == null) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: _controller!,
      builder: (context, _) {
        final c = _controller!;
        return Scaffold(
          appBar: AppBar(
            // заголовок — крупным в теле; здесь только путь назад
            leading: const BackButton(),
          ),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DsScreenTitle('Новый диалог',
                  subtitle: 'Кому можно написать — решает сервер'),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: TextField(
                  controller: _query,
                  onChanged: _onQuery,
                  decoration: InputDecoration(
                    hintText: 'Имя или логин',
                    prefixIcon: const Icon(Icons.search),
                    isDense: true,
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              if (c.error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(c.error!,
                      style: TextStyle(fontSize: 13, color: Wms.muted)),
                ),
              Expanded(
                child: c.loading && c.items.isEmpty
                    ? const Center(child: CircularProgressIndicator())
                    : c.items.isEmpty
                        ? Center(
                            child: Text(
                              c.error == null ? 'Никого не нашли' : '',
                              style: TextStyle(
                                  fontSize: 13, color: Wms.muted),
                            ),
                          )
                        : SingleChildScrollView(
                            physics:
                                const AlwaysScrollableScrollPhysics(),
                            child: DsCard(
                              margin: const EdgeInsets.fromLTRB(
                                  16, 12, 16, 16),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 4),
                              children: [
                                for (final p in c.items) ...[
                                  _row(context, p),
                                  if (p != c.items.last)
                                    const Divider(height: 1, thickness: 1),
                                ],
                              ],
                            ),
                          ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _row(BuildContext context, contact) {
    final c = contact;
    final chats = context.read<ChatListController>();
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        backgroundColor: Wms.chipBg,
        child: Icon(Icons.person_outline, size: 20, color: Wms.primary),
      ),
      title: Text(c.name ?? 'Без имени',
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: c.hint == null
          ? null
          : Text(c.hint!,
              maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: () async {
        // диалог с этим человеком мог уже существовать — открываем его, а не
        // заводим новый: двойного чата сервер не создаст, но и локальной строки
        // «нового диалога» рядом с серверным быть не должно
        final existing = await chats.dialogWith(c.userId);
        if (!context.mounted) return;
        Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => existing != null
                ? ChatScreen(chatId: existing)
                : ChatScreen(userId: c.userId)));
      },
    );
  }
}
