import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/notifications_controller.dart';
import '../data/task_file_cache.dart';
import '../data/task_repository.dart';
import '../models/notification.dart';
import '../models/notification_feed.dart';
import 'task_detail_screen.dart';
import 'task_result_screen.dart';
import 'theme.dart';
import 'widgets/ds.dart';
import 'widgets/task_photo.dart';

/// Лента уведомлений (#36717): что приходило этому человеку за последние 30 дней,
/// с переходом на задачу.
///
/// Записи — строки-карточки, сгруппированные по дням (#37125): «Сегодня», «Вчера»,
/// дальше — дата; считаются от СЕРВЕРНОЙ даты (`notificationSections`) — своих
/// часов у экрана нет вовсе. Непрочитанное — жирным заголовком и точкой справа;
/// фильтры «Все» и «Непрочитанные» — клиентские (#37411, п. 11).
///
/// Прочитанным делает ТАП, а не открытие ленты. Сначала (#36717) было наоборот — вошёл,
/// значит прочитал всё; с этим перестало годиться: признак «что я ещё не разобрал»
/// терялся после первого же взгляда — зашёл, глянул, вышел. Событиям, которые
/// открывать незачем («просрочена», «проверка завершена»), — «Отметить все
/// прочитанными» рядом с заголовком.
class NotificationsScreen extends StatefulWidget {
  /// Вкладка нижней панели (#37411): без AppBar, крупный заголовок «Лента» и
  /// «Отметить все прочитанными» строкой под ним. Открытая из карточки лента —
  /// прежним стеком с шапкой.
  final bool asTab;

  const NotificationsScreen({super.key, this.asTab = false});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  /// «Только непрочитанные» (#37411, п. 11) — фильтр клиента: список уже на
  /// телефоне, второго захода на сервер ради него не нужно.
  bool _onlyUnread = false;

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
        final all = feed.items;
        final items = _onlyUnread
            ? all.where((n) => !n.viewed).toList()
            : all;
        // Календарь ленты — серверный: заголовки не должны зависеть ни от часового
        // пояса телефона, ни от руками сдвинутой даты (#37125).
        final today = feedToday(all);
        // Плоский список из заголовков (String) и записей: секции нужны глазу, а
        // ListView.builder — длинной ленте, и ради второго первое разворачивается.
        final rows = <Object>[
          for (final s in notificationSections(items, today)) ...[
            s.title,
            ...s.items,
          ],
        ];
        final feedBody = RefreshIndicator(
          onRefresh: feed.refresh,
          child: rows.isEmpty
              ? ListView(
                  // ListView, а не Text по центру: RefreshIndicator тянется
                  // только за скроллируемым
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        _onlyUnread
                            ? 'Непрочитанных нет.'
                            : (context.watch<TaskRepository>().online
                                ? 'Уведомлений за последние 30 дней нет.'
                                : 'Нет связи с сервером — лента недоступна.'),
                        style: TextStyle(color: Wms.muted),
                      ),
                    ),
                  ],
                )
              : ListView.builder(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding:
                      EdgeInsets.fromLTRB(16, widget.asTab ? 0 : 4, 16, 16),
                  itemCount: rows.length,
                  itemBuilder: (context, i) {
                    final row = rows[i];
                    return row is String
                        ? _header(row, first: i == 0)
                        : _row(context, row as NotificationItem, today);
                  },
                ),
        );

        if (widget.asTab) {
          return Scaffold(
            body: SafeArea(
              bottom: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 8, 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text('Лента',
                              style: TextStyle(
                                  fontSize: 30,
                                  fontWeight: FontWeight.w700,
                                  color: Wms.text)),
                        ),
                        if (feed.unreadCount > 0)
                          TextButton(
                            onPressed: () => unawaited(feed.markAllViewed()),
                            child: const Text('Отметить все прочитанными'),
                          ),
                      ],
                    ),
                  ),
                  _filterRow(feed),
                  Expanded(child: feedBody),
                ],
              ),
            ),
          );
        }
        return Scaffold(
          appBar: AppBar(
            title: const Text('Лента'),
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
          body: Column(
            children: [
              _filterRow(feed),
              Expanded(child: feedBody),
            ],
          ),
        );
      },
    );
  }

  /// Чипы «Все» и «Непрочитанные» со счётчиком (#37411, п. 11). Счётчик —
  /// залитой пилюлей в чипе (стр. 4 макета): число читается раньше текста.
  Widget _filterRow(NotificationsController feed) {
    final unread = feed.unreadCount;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Row(
        children: [
          DsOutlineChip(
            'Все',
            selected: !_onlyUnread,
            onTap: () => setState(() => _onlyUnread = false),
          ),
          const SizedBox(width: 8),
          DsOutlineChip(
            'Непрочитанные',
            counter: unread > 0 ? unread : null,
            selected: _onlyUnread,
            onTap: () => setState(() => _onlyUnread = !_onlyUnread),
          ),
        ],
      ),
    );
  }

  Widget _header(String title, {required bool first}) => Padding(
        padding: EdgeInsets.only(top: first ? 8 : 20, bottom: 8, left: 4),
        child: Text(title,
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Wms.muted)),
      );

  /// Строка-карточка записи. Непрочитанное — жирным заголовком и точкой справа
  /// (#37411, п. 11): точка на светлой карточке видна сразу и не раскрашивает всю
  /// запись — прочитанное и непрочитанное различаются одним взглядом.
  Widget _row(BuildContext context, NotificationItem n, DateTime today) {
    final unread = !n.viewed;
    final overdue = n.event == 'overdue';
    final tint = overdue ? Wms.danger : Wms.primary;
    final radius = BorderRadius.circular(16);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Wms.card,
        borderRadius: radius,
        border: Border.all(color: Wms.line),
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
                // значок события — внутри карточки, а не отдельной колонкой списка
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
                      // по подписке (#37136): почему это пришло — задача не моя,
                      // я за ней лишь наблюдаю. Причина, а не вид события: вида
                      // клиент по-прежнему не различает (#36717)
                      if (n.watching)
                        Row(
                          children: [
                            Icon(Icons.visibility_outlined,
                                size: 14, color: Wms.muted),
                            const SizedBox(width: 3),
                            Text('наблюдаю',
                                style:
                                    TextStyle(fontSize: 12, color: Wms.muted)),
                          ],
                        ),
                    ],
                  ),
                ),
                // правый край строки (стр. 4 макета): время на уровне
                // заголовка, точка непрочитанного — под ним у края
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(notificationWhen(n, today),
                          style:
                              TextStyle(fontSize: 12, color: Wms.muted)),
                      if (unread) ...[
                        const SizedBox(height: 6),
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                              color: Wms.primary, shape: BoxShape.circle),
                        ),
                      ],
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
  /// Деталка живёт над repo.tasks — открытыми задачами, в которых человек участвует, —
  /// поэтому про задачу не из списка честно говорим, а не открываем пустой экран. Таких
  /// две: закрытая (выдача отдаёт только открытые — «проверка завершена» по пройденной
  /// проверке приходит уже на закрытую) и та, в которой человек больше не участвует
  /// (отписался, переназначили). «Другой объект» причиной быть перестал с #36837.
  /// Уведомление о комментарии открывает карточку сразу на переписке: человека позвали
  /// именно туда.
  void _openTask(BuildContext context, NotificationItem n) {
    unawaited(context.read<NotificationsController>().markViewed(n));
    final id = n.taskId;
    if (id == null) return;
    final view = context.read<TaskRepository>().viewOf(id);
    if (view == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Задачи нет в вашем списке: она закрыта '
            'или вы в ней больше не участвуетесь'),
        duration: Duration(seconds: 3),
      ));
      return;
    }
    // принимающему — сразу результат (#37158): его позвали решить, а решают по тому,
    // что сдано; карточка — шагом назад
    if (view.awaitingDecision) {
      openTaskResult(context, view);
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
      // приёмка (#37158)
      case 'acceptancePending':
        return Icons.fact_check_outlined;
      case 'taskAccepted':
        return Icons.task_alt;
      case 'taskReturned':
        return Icons.undo;
      default:
        return Icons.notifications_outlined;
    }
  }
}
