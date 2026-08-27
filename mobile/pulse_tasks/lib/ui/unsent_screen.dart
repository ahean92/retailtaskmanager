import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/task_repository.dart';
import '../data/unsent.dart';
import 'theme.dart';

/// Экран «Не отправлено» (#36916): что накопилось в очередях офлайна, по-людски —
/// «Задача „Проверить ценники“ — создание», «Бланк: 12 ответов, 3 фото» — со
/// временем постановки и причиной последней неудачи. И кнопка «Отправить сейчас»
/// с видимым результатом: человек в поле должен сам ответить себе на вопрос
/// «я заполнил — оно ушло или нет?», не гадая по спиннерам.
///
/// Чистый рендер repo.unsentOps: список собирает репозиторий при каждом _reload,
/// поэтому строки тают на глазах по мере дожима — и ровно те же операции считает
/// бейдж шапки, с которого сюда пришли.
class UnsentScreen extends StatefulWidget {
  const UnsentScreen({super.key});

  @override
  State<UnsentScreen> createState() => _UnsentScreenState();
}

class _UnsentScreenState extends State<UnsentScreen> {
  bool _sending = false;

  Future<void> _sendNow(TaskRepository repo) async {
    setState(() => _sending = true);
    final before = repo.pendingCount;
    try {
      await repo.syncAndRefresh();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
    if (!mounted) return;
    // видимый результат: сколько ушло и что осталось — не молчание и не спиннер
    final left = repo.pendingCount;
    final String text;
    if (left == 0) {
      text = 'Всё отправлено';
    } else if (left < before) {
      text = 'Отправлено ${before - left} из $before — '
          'остальное не прошло, причины в списке';
    } else {
      text = 'Отправить не удалось — причины в списке';
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 3)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<TaskRepository>(
      builder: (context, repo, _) {
        final ops = repo.unsentOps;
        return Scaffold(
          appBar: AppBar(title: const Text('Не отправлено')),
          body: ops.isEmpty ? _empty() : _list(ops),
          bottomNavigationBar: ops.isEmpty
              ? null
              : SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    child: FilledButton.icon(
                      onPressed: _sending ? null : () => _sendNow(repo),
                      icon: _sending
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.cloud_upload_outlined),
                      label: Text(
                          _sending ? 'Отправка…' : 'Отправить сейчас'),
                    ),
                  ),
                ),
        );
      },
    );
  }

  Widget _empty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_done_outlined, size: 48, color: Wms.muted),
          const SizedBox(height: 12),
          Text('Всё отправлено',
              style: TextStyle(fontSize: 16, color: Wms.muted)),
        ],
      ),
    );
  }

  Widget _list(List<UnsentOp> ops) {
    return ListView.separated(
      itemCount: ops.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) => _tile(ops[i]),
    );
  }

  Widget _tile(UnsentOp op) {
    return ListTile(
      leading: Icon(_icon(op.kind), color: Wms.primary),
      title: Text(
        op.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
            fontSize: 14, fontWeight: FontWeight.w600, color: Wms.text),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(op.detail, style: TextStyle(fontSize: 13, color: Wms.muted)),
          if (op.queuedAt != null)
            Text('В очереди с ${_fmtWhen(op.queuedAt!)}',
                style: TextStyle(fontSize: 12, color: Wms.muted)),
          if (op.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(op.error!,
                  style: TextStyle(fontSize: 12, color: Wms.warn)),
            ),
        ],
      ),
    );
  }

  IconData _icon(String kind) {
    switch (kind) {
      case UnsentKind.create:
        return Icons.add_task;
      case UnsentKind.fill:
        return Icons.checklist_outlined;
      case UnsentKind.simple:
        return Icons.task_alt;
      case UnsentKind.status:
        return Icons.swap_horiz;
      case UnsentKind.take:
        return Icons.front_hand_outlined;
      case UnsentKind.comment:
        return Icons.chat_bubble_outline;
      case UnsentKind.file:
        return Icons.photo_outlined;
      default:
        return Icons.cloud_upload_outlined;
    }
  }

  /// «сегодня 10:42», «вчера 18:03», «21.08 09:15» — как в ленте уведомлений.
  String _fmtWhen(DateTime t) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(t.year, t.month, t.day);
    String two(int v) => v.toString().padLeft(2, '0');
    final hm = '${two(t.hour)}:${two(t.minute)}';
    if (day == today) return 'сегодня $hm';
    if (day == today.subtract(const Duration(days: 1))) return 'вчера $hm';
    return '${two(t.day)}.${two(t.month)} $hm';
  }
}
