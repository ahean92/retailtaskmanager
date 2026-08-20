import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/task_repository.dart';
import '../models/fill.dart';
import '../models/task_status.dart';
import 'fill_screen.dart';

class TaskDetailScreen extends StatefulWidget {
  final String taskId;
  const TaskDetailScreen({super.key, required this.taskId});

  @override
  State<TaskDetailScreen> createState() => _TaskDetailScreenState();
}

class _TaskDetailScreenState extends State<TaskDetailScreen> {
  /// Set once the screen is on its way out, so a rebuild while the pop is pending cannot
  /// schedule a second one and take the task list down with it.
  bool _leaving = false;

  /// The task is gone from the list — completed on this very screen, or closed and
  /// confirmed by the server (`apiTasks` only ever sends open tasks). Details of a task
  /// that no longer exists are a dead end, so the screen steps back to the list rather
  /// than staying to announce its own emptiness.
  void _leave() {
    if (_leaving) return;
    _leaving = true;
    final navigator = Navigator.of(context);
    // during a build there is no popping — the frame this decision is made in has to be
    // finished first
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (navigator.mounted && navigator.canPop()) navigator.pop();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<TaskRepository>(
      builder: (context, repo, _) {
        // Совпадение и по clientId тоже: экран, открытый на задаче, рождённой на
        // телефоне, держит её UUID — а после синхронизации строку в кэше заменяет
        // серверная, с ST-номером в id и тем же UUID в clientId. Без второго сравнения
        // этот экран решил бы, что задача исчезла, и закрылся бы у человека под рукой.
        TaskView? found;
        for (final candidate in repo.tasks) {
          if (candidate.id == widget.taskId ||
              candidate.task.clientId == widget.taskId) {
            found = candidate;
            break;
          }
        }

        if (found == null) {
          _leave();
          // one frame with nothing on it, and it is the frame that is being replaced
          return const Scaffold(body: SizedBox.shrink());
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
              if (fillableTypeIds.contains(t.typeId)) ...[
                const SizedBox(height: 12),
                FilledButton.icon(
                  // задача, рождённая на телефоне, всю жизнь адресуется своим UUID:
                  // на нём её локальный кэш бланка и очереди, и сервер понимает оба
                  // адреса — поэтому clientId, а не ST-номер, когда он есть
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => FillScreen(taskId: t.clientId ?? t.id),
                    ),
                  ),
                  icon: Icon(_fillIcon(t.typeId)),
                  label: Text(_fillLabel(t.typeId)),
                ),
              ],
              // взятие из пула (#36836): право рисует серверный canTake, снятие —
              // взятость мной; оба уходят той же офлайн-очередью, что и в списке
              if (view.canTake) ...[
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: () => _take(context, repo, view.id),
                  icon: const Icon(Icons.back_hand_outlined),
                  label: const Text('Взять на себя'),
                ),
              ],
              if (view.releasable) ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () => _release(context, repo, view.id),
                  icon: const Icon(Icons.undo),
                  label: const Text('Снять с себя'),
                ),
              ],
              const SizedBox(height: 16),
              _Field(label: 'Тип', value: t.type),
              _Field(label: 'Детали', value: t.subtitle),
              _Field(label: 'Название', value: t.name),
              _Field(label: 'Адрес', value: t.address),
              _Field(label: 'Исполнитель', value: t.assignedTo),
              _Field(label: 'Взял на себя', value: _takenLine(view)),
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
                    // у завершённой на телефоне задачи статусы не переключаются:
                    // смена ушла бы на сервер раньше застрявшего finish, и его
                    // 'done' молча перезаписал бы её — хронология наоборот
                    return ChoiceChip(
                      label: Text(s.name ?? s.id),
                      selected: selected,
                      onSelected: selected || view.locallyFinished
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

  /// Кто держит задачу, для карточки: имя, время — и честная пометка, пока взятие
  /// не подтверждено сервером.
  String? _takenLine(TaskView view) {
    final who = view.takenBy;
    if (who == null) return null;
    if (view.takePending) return '$who — ожидает подтверждения';
    final at = DateTime.tryParse(view.takenAt ?? '');
    if (at == null) return who;
    final hhmm = '${at.hour.toString().padLeft(2, '0')}:'
        '${at.minute.toString().padLeft(2, '0')}';
    final now = DateTime.now();
    final sameDay =
        at.year == now.year && at.month == now.month && at.day == now.day;
    return sameDay
        ? '$who, в $hhmm'
        : '$who, ${at.day.toString().padLeft(2, '0')}.'
            '${at.month.toString().padLeft(2, '0')} $hhmm';
  }

  Future<void> _take(
      BuildContext context, TaskRepository repo, String id) async {
    final messenger = ScaffoldMessenger.of(context);
    await repo.takeTask(id);
    messenger.showSnackBar(SnackBar(
      content: Text(repo.online
          ? 'Задача перенесена в «Мои»'
          : 'Взятие сохранено офлайн — ожидает подтверждения'),
      duration: const Duration(seconds: 2),
    ));
  }

  Future<void> _release(
      BuildContext context, TaskRepository repo, String id) async {
    final messenger = ScaffoldMessenger.of(context);
    await repo.releaseTask(id);
    messenger.showSnackBar(SnackBar(
      content: Text(repo.online
          ? 'Задача возвращена в «Свободные»'
          : 'Снятие сохранено офлайн — синхронизируется при связи'),
      duration: const Duration(seconds: 2),
    ));
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
