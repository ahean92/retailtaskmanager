import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/chat_controller.dart';

/// Плашка нового сообщения чата поверх любого экрана (#37370). Показывает её
/// [ChatListController.liveMessage] — туда её кладёт пуш, когда человек не в
/// переписке этого чата (в переписке сообщение просто приезжает в неё). Заголовок
/// — имя чата, тело — «Иван: …»; тап по плашке и кнопка «Открыть» ведут в
/// переписку тем же путём, что и тап по самому пушу (openChatFromPush).
///
/// Живёт в MaterialApp.builder поверх навигатора: плашке всё равно, какой экран
/// под ней, и она ему не мешает — перекрыта только верхняя полоса, остальное
/// продолжает принимать касания. Уходит сама таймером ChatListController, по
/// кнопке или по тапу. flutter_local_notifications здесь не нужен: приложение
/// открыто, и своё сообщение честнее показать внутри, а не в системной шторке.
class ChatPushBannerOverlay extends StatelessWidget {
  final void Function(int chatId) onOpen;
  final Widget child;

  const ChatPushBannerOverlay(
      {super.key, required this.onOpen, required this.child});

  @override
  Widget build(BuildContext context) {
    // select, а не watch: плашка меняется чаще списка, и списку незачем
    // перерисовываться под неё (и наоборот — бейдж не дёргает анимацию)
    final live = context
        .select<ChatListController, ChatLiveMessage?>((c) => c.liveMessage);
    return Stack(
      children: [
        child,
        Positioned(
          left: 0,
          top: 0,
          right: 0,
          child: SafeArea(
            bottom: false,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              transitionBuilder: (banner, animation) => SlideTransition(
                position: Tween<Offset>(
                        begin: const Offset(0, -1), end: Offset.zero)
                    .animate(animation),
                child: FadeTransition(opacity: animation, child: banner),
              ),
              child: live == null
                  ? const SizedBox.shrink()
                  : _BannerCard(live: live, onOpen: onOpen),
            ),
          ),
        ),
      ],
    );
  }
}

class _BannerCard extends StatelessWidget {
  final ChatLiveMessage live;
  final void Function(int chatId) onOpen;

  const _BannerCard({required this.live, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      // ключ — само сообщение: новое (пусть и в тот же чат) должно въехать заново,
      // а не тихо подменить текст под уже висящей плашкой
      key: ValueKey('${live.chatId}:${live.title}:${live.body}'),
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(12),
        color: scheme.surface,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => onOpen(live.chatId),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        live.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600),
                      ),
                      if (live.body.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          live.body,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 13, color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ],
                  ),
                ),
                TextButton(
                  onPressed: () => onOpen(live.chatId),
                  child: const Text('Открыть'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
