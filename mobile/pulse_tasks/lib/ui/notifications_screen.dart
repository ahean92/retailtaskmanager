import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/task_repository.dart';
import '../models/notification.dart';
import 'task_detail_screen.dart';
import 'theme.dart';

/// Лента уведомлений (#36717): что приходило этому человеку за последние 30 дней,
/// с переходом на задачу. Открытие ленты и есть прочтение — бейдж на главной гаснет,
/// но записи, непрочитанные на момент входа, остаются подсвеченными до конца визита:
/// пометка уходит на сервер сразу, а выделение должно её пережить.
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  final Set<String> _unreadAtEntry = {};

  @override
  void initState() {
    super.initState();
    final repo = context.read<TaskRepository>();
    _snapshotUnread(repo);
    unawaited(_syncViewed(repo));
  }

  void _snapshotUnread(TaskRepository repo) {
    for (final n in repo.notifications) {
      if (!n.viewed) _unreadAtEntry.add(n.key);
    }
  }

  /// Свежая лента, потом пометка: то, что доехало за время визита, тоже считается
  /// увиденным — человек смотрит на экран прямо сейчас.
  Future<void> _syncViewed(TaskRepository repo) async {
    await repo.refreshNotifications();
    if (!mounted) return;
    setState(() => _snapshotUnread(repo));
    await repo.markAllNotificationsViewed();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<TaskRepository>(
      builder: (context, repo, _) {
        final items = repo.notifications;
        return Scaffold(
          appBar: AppBar(title: const Text('Уведомления')),
          body: RefreshIndicator(
            onRefresh: () => _syncViewed(repo),
            child: items.isEmpty
                ? ListView(
                    // ListView, а не Text по центру: RefreshIndicator тянется
                    // только за скроллируемым
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          repo.online
                              ? 'Уведомлений за последние 30 дней нет.'
                              : 'Нет связи с сервером — лента недоступна.',
                          style: TextStyle(color: Wms.muted),
                        ),
                      ),
                    ],
                  )
                : ListView.separated(
                    itemCount: items.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, i) => _tile(context, repo, items[i]),
                  ),
          ),
        );
      },
    );
  }

  Widget _tile(BuildContext context, TaskRepository repo, NotificationItem n) {
    final unread = _unreadAtEntry.contains(n.key);
    final overdue = n.event == 'overdue';
    return ListTile(
      leading: Icon(_icon(n.event), color: overdue ? Wms.warn : Wms.primary),
      title: Text(
        n.title ?? '(без заголовка)',
        style: TextStyle(
            fontSize: 14,
            fontWeight: unread ? FontWeight.w700 : FontWeight.w500,
            color: Wms.text),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (n.body != null && n.body!.isNotEmpty)
            Text(n.body!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: Wms.muted)),
          Text(_fmtWhen(n.when),
              style: TextStyle(fontSize: 12, color: Wms.muted)),
        ],
      ),
      trailing: unread
          ? Icon(Icons.circle, size: 10, color: Wms.primary)
          : null,
      onTap: n.taskId == null ? null : () => _openTask(context, repo, n),
    );
  }

  /// Переход на задачу. Деталка живёт над repo.tasks (задачи «здесь» и открытые) —
  /// про закрытую или чужого объекта честно говорим, а не открываем пустой экран.
  void _openTask(BuildContext context, TaskRepository repo, NotificationItem n) {
    final id = n.taskId;
    if (id == null) return;
    final known =
        repo.tasks.any((t) => t.id == id || t.task.clientId == id);
    if (!known) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Задача недоступна: закрыта или относится '
            'к другому объекту'),
        duration: Duration(seconds: 2),
      ));
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => TaskDetailScreen(taskId: id)),
    );
  }

  IconData _icon(String? event) {
    switch (event) {
      case 'taskAssigned':
        return Icons.assignment_ind_outlined;
      case 'deadlineNear':
        return Icons.schedule_outlined;
      case 'overdue':
        return Icons.error_outline;
      case 'fillingFinished':
        return Icons.checklist_outlined;
      case 'correctiveCreated':
        return Icons.build_outlined;
      default:
        return Icons.notifications_outlined;
    }
  }

  String _fmtWhen(DateTime? t) {
    if (t == null) return '';
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
