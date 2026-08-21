import 'package:flutter/material.dart';

import '../../data/task_repository.dart';
import '../theme.dart';

/// A task as a WMS-style list row (mirrors the ARM `.arm-row`): a rounded white
/// card with a type icon tile, the object as a bold caption, a status badge and
/// meta line, and a chevron. A "pending sync" marker shows when the local status
/// change has not yet reached the server.
///
/// Взятие (#36836): у строки виден тот, кто её держит, взятая офлайн несёт явную
/// пометку «ожидает подтверждения», а по [onTake] рисуется кнопка «Взять» — она
/// приходит только вместе с серверным canTake, карточка права не вычисляет.
class TaskCard extends StatelessWidget {
  final TaskView view;
  final VoidCallback onTap;
  final VoidCallback? onTake;
  const TaskCard(
      {super.key, required this.view, required this.onTap, this.onTake});

  @override
  Widget build(BuildContext context) {
    final t = view.task;
    final overdue = view.overdue;
    final metaParts = <String>[
      if (t.type != null) t.type!,
      if (t.subtitle != null) t.subtitle!,
    ];

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: Wms.card,
        borderRadius: BorderRadius.circular(12),
        // An overdue row is marked by its border and a stripe down the left edge rather
        // than by a red fill: the card still has to be readable, and a wash of colour
        // behind the text makes the status louder than the task.
        border: Border.all(color: overdue ? Wms.warn : Wms.line),
        boxShadow: Wms.cardShadow,
      ),
      foregroundDecoration: overdue
          ? BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border(left: BorderSide(color: Wms.warn, width: 4)),
            )
          : null,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            child: Row(
              children: [
                _IconTile(typeId: t.typeId),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        t.object ?? t.name ?? t.id,
                        style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                            color: Wms.text),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (metaParts.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            metaParts.join(' · '),
                            style: TextStyle(
                                fontSize: 13, color: Wms.muted),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          _StatusBadge(
                            label: view.statusName ?? view.statusId ?? '—',
                            statusId: view.statusId,
                          ),
                          // задача другого объекта (#36837): пометка стоит сразу за
                          // статусом — «можно ли работать» человек читает раньше срока
                          if (view.elsewhere)
                            _ElsewhereMark(distanceText: t.distanceText),
                          if (t.deadline != null)
                            _Meta(
                              icon: overdue
                                  ? Icons.event_busy
                                  : Icons.event,
                              text: t.deadline!,
                              color: overdue ? Wms.warn : null,
                              bold: overdue,
                            ),
                          if (t.priority != null)
                            _Meta(icon: Icons.flag_outlined, text: t.priority!),
                          // кто держит задачу — «с чужим именем» и есть признак
                          // группы «взяты коллегами»; у своей — «вы», без имени
                          if (view.takenBy != null && !view.takePending)
                            _Meta(
                              icon: Icons.person_outline,
                              text: view.group == TaskGroup.mine
                                  ? 'взяли вы'
                                  : 'взял: ${view.takenBy}',
                            ),
                          if (view.takePending) const _TakeAwaitMark(),
                          if (view.pending) const _PendingMark(),
                          if (onTake != null && view.canTake)
                            _TakeButton(onTake: onTake!),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Icon(Icons.chevron_right, color: Wms.muted, size: 26),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _IconTile extends StatelessWidget {
  final String? typeId;
  const _IconTile({required this.typeId});

  IconData get _icon {
    switch (typeId) {
      case 'checklist':
        return Icons.fact_check_outlined;
      case 'recount':
        return Icons.inventory_2_outlined;
      case 'pricing':
        return Icons.sell_outlined;
      default:
        return Icons.assignment_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: Wms.bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(_icon, size: 22, color: Wms.primary),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final String label;
  final String? statusId;
  const _StatusBadge({required this.label, this.statusId});

  Color get _color {
    switch (statusId) {
      case 'done':
        return Wms.ok;
      case 'in progress':
        return Wms.primary;
      case 'canceled':
        return Wms.muted;
      default:
        return Wms.muted;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style:
            TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: c),
      ),
    );
  }
}

class _Meta extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color? color;
  final bool bold;
  const _Meta(
      {required this.icon, required this.text, this.color, this.bold = false});

  @override
  Widget build(BuildContext context) {
    final c = color ?? Wms.muted;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: c),
        const SizedBox(width: 3),
        Text(text,
            style: TextStyle(
                fontSize: 12,
                color: c,
                fontWeight: bold ? FontWeight.w700 : FontWeight.w400)),
      ],
    );
  }
}

/// «Только просмотр · 3,4 км» — задача другого объекта (#36837). Расстояние — часть
/// пометки: запрет без «сколько туда ехать» отвечает на полвопроса, ради которого
/// чужие задачи вообще показываются. Без расстояния (объект без координат или кэш
/// старой схемы) остаётся сам запрет.
class _ElsewhereMark extends StatelessWidget {
  final String? distanceText;
  const _ElsewhereMark({this.distanceText});

  @override
  Widget build(BuildContext context) {
    final d = distanceText;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.near_me_outlined, size: 15, color: Wms.primary),
        const SizedBox(width: 3),
        Text(
          d == null ? 'только просмотр' : 'только просмотр · $d',
          style: TextStyle(
              fontSize: 12, fontWeight: FontWeight.w600, color: Wms.primary),
        ),
      ],
    );
  }
}

class _PendingMark extends StatelessWidget {
  const _PendingMark();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.sync_problem, size: 15, color: Wms.warn),
        const SizedBox(width: 3),
        Text('ожидает синхронизации',
            style: TextStyle(fontSize: 12, color: Wms.warn)),
      ],
    );
  }
}

/// Взятие ещё не подтверждено сервером — не молча: за эту задачу могут поспорить,
/// и человек должен это понимать, глядя на строку.
class _TakeAwaitMark extends StatelessWidget {
  const _TakeAwaitMark();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.hourglass_top, size: 15, color: Wms.warn),
        const SizedBox(width: 3),
        Text('взята — ожидает подтверждения',
            style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w600, color: Wms.warn)),
      ],
    );
  }
}

/// Компактная «Взять» прямо в строке: работу берут из группы «Свободные», и делать
/// ради этого лишний переход в деталку — ставить дверь перед дверью.
class _TakeButton extends StatelessWidget {
  final VoidCallback onTake;
  const _TakeButton({required this.onTake});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 34,
      child: FilledButton.icon(
        onPressed: onTake,
        icon: const Icon(Icons.back_hand_outlined, size: 15),
        label: const Text('Взять'),
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 34),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          visualDensity: VisualDensity.compact,
          textStyle:
              const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}
