import 'package:flutter/material.dart';

import '../../data/task_repository.dart';
import '../theme.dart';

/// A task as a WMS-style list row (mirrors the ARM `.arm-row`): a rounded white
/// card with a type icon tile, the object as a bold caption, a status badge and
/// meta line, and a chevron. A "pending sync" marker shows when the local status
/// change has not yet reached the server.
class TaskCard extends StatelessWidget {
  final TaskView view;
  final VoidCallback onTap;
  const TaskCard({super.key, required this.view, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = view.task;
    final metaParts = <String>[
      if (t.type != null) t.type!,
      if (t.subtitle != null) t.subtitle!,
    ];

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: Wms.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Wms.line),
        boxShadow: Wms.cardShadow,
      ),
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
                        style: const TextStyle(
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
                            style: const TextStyle(
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
                          if (t.deadline != null)
                            _Meta(icon: Icons.event, text: t.deadline!),
                          if (t.priority != null)
                            _Meta(icon: Icons.flag_outlined, text: t.priority!),
                          if (view.pending) const _PendingMark(),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                const Icon(Icons.chevron_right, color: Wms.muted, size: 26),
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
  const _Meta({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: Wms.muted),
        const SizedBox(width: 3),
        Text(text, style: const TextStyle(fontSize: 12, color: Wms.muted)),
      ],
    );
  }
}

class _PendingMark extends StatelessWidget {
  const _PendingMark();

  @override
  Widget build(BuildContext context) {
    return const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.sync_problem, size: 15, color: Wms.warn),
        SizedBox(width: 3),
        Text('ожидает синхронизации',
            style: TextStyle(fontSize: 12, color: Wms.warn)),
      ],
    );
  }
}
