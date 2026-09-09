import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/notifications_controller.dart';
import '../data/task_file_cache.dart';
import '../data/task_repository.dart';
import '../models/notification.dart';
import '../models/notification_feed.dart';
import 'task_detail_screen.dart';
import 'theme.dart';
import 'widgets/task_photo.dart';

/// Лента уведомлений (#36717): что приходило этому человеку за последние 30 дней,
/// с переходом на задачу.
///
/// Пузыри и заголовки по датам — #37125. Запись рисуется пузырём, а не строкой с
/// разделителем; непрочитанное отличается заливкой пузыря (точку ищут, заливку видят);
/// «Сегодня», «Вчера» и дальше считаются от СЕРВЕРНОЙ даты (`notificationSections`) —
/// своих часов у экрана нет вовсе.
///
/// Прочитанным делает ТАП, а не открытие ленты. Сначала (#36717) было наоборот — вошёл,
/// значит прочитал всё; с пузырями это перестало годиться: непрочитанное теперь заливка
/// всей записи, главный признак экрана, и терялся он после первого же взгляда — зашёл,
/// глянул, вышел, и «что я ещё не разобрал» больше не видно. Событиям, которые
/// открывать незачем («просрочена», «проверка завершена»), — «Отметить все
/// прочитанными» в шапке.
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  /// Кэш вложений (#37125) — тот же, что у карточки задачи: миниатюра качается один
  /// раз и остаётся на диске, поэтому вернувшийся в ленту человек и человек без сети
  /// видят одно и то же. null — базы нет (сессия умерла под открытым экраном): тогда
  /// миниатюры не рисуются, а лента живёт.
  TaskFileCache? _photos;

  @override
  void initState() {
    super.initState();
    final feed = context.read<NotificationsController>();
    final repo = context.read<TaskRepository>();
    final db = repo.localDb;
    if (db != null) {
      _photos = TaskFileCache(userKey: db.userKey, api: repo.api);
    }
    unawaited(feed.refresh());
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<NotificationsController>(
      builder: (context, feed, _) {
        final items = feed.items;
        // Календарь ленты — серверный: заголовки не должны зависеть ни от часового
        // пояса телефона, ни от руками сдвинутой даты (#37125).
        final today = feedToday(items);
        // Плоский список из заголовков (String) и записей: секции нужны глазу, а
        // ListView.builder — длинной ленте, и ради второго первое разворачивается.
        final rows = <Object>[
          for (final s in notificationSections(items, today)) ...[
            s.title,
            ...s.items,
          ],
        ];
        return Scaffold(
          appBar: AppBar(
            title: const Text('Уведомления'),
            actions: [
              // кнопка есть, только пока есть что гасить: у разобранной ленты ей
              // нечего делать в шапке
              if (feed.unreadCount > 0)
                IconButton(
                  tooltip: 'Отметить все прочитанными',
                  icon: const Icon(Icons.done_all),
                  onPressed: () => unawaited(feed.markAllViewed()),
                ),
            ],
          ),
          body: RefreshIndicator(
            onRefresh: feed.refresh,
            child: rows.isEmpty
                ? ListView(
                    // ListView, а не Text по центру: RefreshIndicator тянется
                    // только за скроллируемым
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          context.watch<TaskRepository>().online
                              ? 'Уведомлений за последние 30 дней нет.'
                              : 'Нет связи с сервером — лента недоступна.',
                          style: TextStyle(color: Wms.muted),
                        ),
                      ),
                    ],
                  )
                : ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                    itemCount: rows.length,
                    itemBuilder: (context, i) {
                      final row = rows[i];
                      return row is String
                          ? _header(row, first: i == 0)
                          : _bubble(context, row as NotificationItem, today);
                    },
                  ),
          ),
        );
      },
    );
  }

  Widget _header(String title, {required bool first}) => Padding(
        padding: EdgeInsets.only(top: first ? 8 : 20, bottom: 8, left: 4),
        child: Text(title,
            style: TextStyle(
                fontSize: 13, fontWeight: FontWeight.w700, color: Wms.muted)),
      );

  /// Пузырь записи. Непрочитанное — заливкой и рамкой самого пузыря, а не точкой
  /// справа: точку ищут глазами, заливку видят сразу (#37125).
  Widget _bubble(BuildContext context, NotificationItem n, DateTime today) {
    final unread = !n.viewed;
    final overdue = n.event == 'overdue';
    final tint = overdue ? Wms.warn : Wms.primary;
    final radius = BorderRadius.circular(14);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: unread ? Wms.active : Wms.card,
        borderRadius: radius,
        border: Border.all(color: unread ? Wms.primary : Wms.line),
        boxShadow: Wms.cardShadow,
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          borderRadius: radius,
          onTap: () => _openTask(context, n),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // значок события — внутри пузыря, а не отдельной колонкой списка
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: tint.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(_icon(n.event), size: 18, color: tint),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        n.title ?? '(без заголовка)',
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight:
                                unread ? FontWeight.w700 : FontWeight.w500,
                            color: Wms.text),
                      ),
                      if (n.body != null && n.body!.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(n.body!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 13, color: Wms.muted)),
                      ],
                      const SizedBox(height: 4),
                      Text(notificationWhen(n, today),
                          style: TextStyle(fontSize: 12, color: Wms.muted)),
                    ],
                  ),
                ),
                // миниатюра вложения, из-за которого уведомление и пришло (#37125):
                // тем же виджетом и кэшем, что снимки задачи и вложения переписки
                if (n.imageId != null && _photos != null) ...[
                  const SizedBox(width: 10),
                  TaskPhotoThumb(
                    loader: _photos!.loaderFor(n.imageId!),
                    size: 56,
                    caption: n.title,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Тап — прочтение и переход на задачу (#37125). Прочтение первым и безусловно:
  /// человек эту запись открыл, и разобранной она считается независимо от того, доступна
  /// ли задача и есть ли она вообще — событие без задачи иначе не погасить ничем, кроме
  /// «отметить все».
  ///
  /// Деталка живёт над repo.tasks (задачи «здесь» и открытые) — про закрытую или чужого
  /// объекта честно говорим, а не открываем пустой экран. Уведомление о комментарии
  /// открывает карточку сразу на переписке: человека позвали именно туда.
  void _openTask(BuildContext context, NotificationItem n) {
    unawaited(context.read<NotificationsController>().markViewed(n));
    final id = n.taskId;
    if (id == null) return;
    final known = context
        .read<TaskRepository>()
        .tasks
        .any((t) => t.id == id || t.task.clientId == id);
    if (!known) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Задача недоступна: закрыта или относится '
            'к другому объекту'),
        duration: Duration(seconds: 2),
      ));
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TaskDetailScreen(
            taskId: id, showComments: n.event == 'taskComment'),
      ),
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
      case 'taskComment':
        return Icons.chat_bubble_outline;
      default:
        return Icons.notifications_outlined;
    }
  }
}
