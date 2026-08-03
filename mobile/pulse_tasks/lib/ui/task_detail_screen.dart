import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/task_repository.dart';
import '../models/task_status.dart';
import 'fill_screen.dart';

class TaskDetailScreen extends StatelessWidget {
  final String taskId;
  const TaskDetailScreen({super.key, required this.taskId});

  @override
  Widget build(BuildContext context) {
    return Consumer<TaskRepository>(
      builder: (context, repo, _) {
        TaskView? found;
        for (final candidate in repo.tasks) {
          if (candidate.id == taskId) {
            found = candidate;
            break;
          }
        }

        if (found == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('Задача')),
            body: const Center(child: Text('Задача больше не в списке')),
          );
        }

        final TaskView view = found;
        final t = view.task;
        return Scaffold(
          appBar: AppBar(title: Text('Задача ${t.id}')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                t.object ?? t.name ?? t.id,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              // checklist, procedure, recount and price check all run on the engine
              if (t.typeId == 'checklist' ||
                  t.typeId == 'form' ||
                  t.typeId == 'recount' ||
                  t.typeId == 'pricing') ...[
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => FillScreen(taskId: t.id),
                    ),
                  ),
                  icon: Icon(_fillIcon(t.typeId)),
                  label: Text(_fillLabel(t.typeId)),
                ),
              ],
              const SizedBox(height: 16),
              _Field(label: 'Тип', value: t.type),
              _Field(label: 'Детали', value: t.subtitle),
              _Field(label: 'Название', value: t.name),
              _Field(label: 'Адрес', value: t.address),
              _Field(label: 'Исполнитель', value: t.assignedTo),
              _Field(label: 'Приоритет', value: t.priority),
              _Field(label: 'Срок', value: t.deadline),
              _Field(
                  label: 'Прогресс',
                  value: t.progress == null ? null : '${t.progress}%'),
              const Divider(height: 32),
              Row(
                children: [
                  Text('Статус', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(width: 10),
                  if (view.pending)
                    const Chip(
                      visualDensity: VisualDensity.compact,
                      avatar: Icon(Icons.sync_problem, size: 16),
                      label: Text('не синхронизировано'),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                view.statusName ?? view.statusId ?? '—',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 16),
              if (repo.statuses.isEmpty)
                Text('Справочник статусов не загружен',
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.outline))
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: repo.statuses.map((s) {
                    final selected = s.id == view.statusId;
                    return ChoiceChip(
                      label: Text(s.name ?? s.id),
                      selected: selected,
                      onSelected: selected
                          ? null
                          : (_) => _change(context, repo, t.id, s),
                    );
                  }).toList(),
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _change(BuildContext context, TaskRepository repo, String id,
      TaskStatus status) async {
    final messenger = ScaffoldMessenger.of(context);
    await repo.setStatus(id, status);
    messenger.showSnackBar(
      SnackBar(
        content: Text(repo.online
            ? 'Статус изменён: ${status.name ?? status.id}'
            : 'Сохранено офлайн — синхронизируется при связи'),
        duration: const Duration(seconds: 2),
      ),
    );
  }
}

IconData _fillIcon(String? typeId) {
  switch (typeId) {
    case 'checklist':
      return Icons.checklist;
    case 'recount':
      return Icons.inventory_2_outlined;
    case 'pricing':
      return Icons.sell_outlined;
    default:
      return Icons.assignment_turned_in;
  }
}

String _fillLabel(String? typeId) {
  switch (typeId) {
    case 'checklist':
      return 'Заполнить чек-лист';
    case 'recount':
      return 'Пересчитать';
    case 'pricing':
      return 'Проверить ценники';
    default:
      return 'Заполнить';
  }
}

class _Field extends StatelessWidget {
  final String label;
  final String? value;
  const _Field({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    if (value == null || value!.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(label,
                style: TextStyle(color: Theme.of(context).colorScheme.outline)),
          ),
          Expanded(child: Text(value!)),
        ],
      ),
    );
  }
}
