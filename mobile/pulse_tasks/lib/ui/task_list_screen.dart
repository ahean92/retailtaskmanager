import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/task_repository.dart';
import 'settings_screen.dart';
import 'task_detail_screen.dart';
import 'theme.dart';
import 'widgets/account_menu.dart';
import 'widgets/task_card.dart';

/// The task list, optionally narrowed to one of the home screen's summary figures.
///
/// The filter is a parameter rather than screen state so a tile on the dashboard can open
/// exactly the list it stands for: a number the worker cannot open is a dead end.
class TaskListScreen extends StatefulWidget {
  final TaskFilter filter;
  const TaskListScreen({super.key, this.filter = TaskFilter.all});

  @override
  State<TaskListScreen> createState() => _TaskListScreenState();
}

class _TaskListScreenState extends State<TaskListScreen> {
  late TaskFilter _filter = widget.filter;

  @override
  Widget build(BuildContext context) {
    return Consumer<TaskRepository>(
      builder: (context, repo, _) {
        final shown = repo.tasks.where(_filter.matches).toList();
        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_filter == TaskFilter.all ? 'Мои задачи' : _filter.title),
                // who these tasks belong to. The counts live on the filter chips below,
                // and the answer to «под кем я работаю» has nowhere else to be shown.
                Text(
                  [repo.session.name, repo.session.login]
                      .where((s) => s.isNotEmpty)
                      .join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w400,
                      color: Colors.white70),
                ),
              ],
            ),
            actions: [
              if (repo.pendingCount > 0)
                IconButton(
                  tooltip: 'Синхронизировать (${repo.pendingCount})',
                  icon: Badge(
                    label: Text('${repo.pendingCount}'),
                    child: Icon(repo.syncing ? Icons.sync : Icons.sync_problem),
                  ),
                  onPressed: repo.syncing ? null : repo.syncAndRefresh,
                ),
              IconButton(
                tooltip: 'Подключение',
                icon: const Icon(Icons.settings),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SettingsScreen()),
                ),
              ),
              AccountMenu(repo: repo),
            ],
          ),
          body: Column(
            children: [
              if (!repo.online) const _OfflineBanner(),
              _FilterBar(
                current: _filter,
                counts: {
                  for (final f in TaskFilter.values)
                    f: repo.tasks.where(f.matches).length,
                },
                onChanged: (f) => setState(() => _filter = f),
              ),
              Expanded(child: _body(context, repo, shown)),
            ],
          ),
        );
      },
    );
  }

  Widget _body(BuildContext context, TaskRepository repo, List<TaskView> shown) {
    if (shown.isEmpty) {
      return RefreshIndicator(
        onRefresh: repo.syncAndRefresh,
        child: ListView(
          children: [
            SizedBox(height: MediaQuery.of(context).size.height * 0.25),
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  repo.loading
                      ? 'Загрузка…'
                      : (_filter == TaskFilter.all
                          ? 'Задач нет.\nПотяните вниз, чтобы обновить.'
                          : 'Здесь пусто — под фильтр «${_filter.title}» ничего не попало.'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Theme.of(context).colorScheme.outline),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: repo.syncAndRefresh,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 6),
        itemCount: shown.length,
        itemBuilder: (context, i) {
          final view = shown[i];
          return TaskCard(
            view: view,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => TaskDetailScreen(taskId: view.id),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Chips over a dropdown: with four options the whole choice fits on screen, and the
/// counts turn the bar into a summary of its own.
class _FilterBar extends StatelessWidget {
  final TaskFilter current;
  final Map<TaskFilter, int> counts;
  final ValueChanged<TaskFilter> onChanged;

  const _FilterBar(
      {required this.current, required this.counts, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        children: [
          for (final f in TaskFilter.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                selected: f == current,
                onSelected: (_) => onChanged(f),
                label: Text('${f.title} · ${counts[f] ?? 0}'),
                labelStyle: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: f == current
                      ? Wms.primary
                      : (f == TaskFilter.overdue && (counts[f] ?? 0) > 0
                          ? Wms.warn
                          : Wms.muted),
                ),
                selectedColor: Wms.active,
                backgroundColor: Wms.card,
                side: BorderSide(color: f == current ? Wms.primary : Wms.line),
                showCheckmark: false,
              ),
            ),
        ],
      ),
    );
  }
}

class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner();

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Wms.warn.withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(Icons.cloud_off, size: 18, color: Wms.warn),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Офлайн — показаны сохранённые данные',
                style: TextStyle(color: Wms.warn),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
