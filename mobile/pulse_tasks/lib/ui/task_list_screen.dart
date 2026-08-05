import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/task_repository.dart';
import 'settings_screen.dart';
import 'task_detail_screen.dart';
import 'theme.dart';
import 'widgets/task_card.dart';

class TaskListScreen extends StatelessWidget {
  const TaskListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<TaskRepository>(
      builder: (context, repo, _) {
        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Мои задачи'),
                Text(
                  'Открытых задач: ${repo.tasks.length}',
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
            ],
          ),
          body: Column(
            children: [
              if (!repo.online) const _OfflineBanner(),
              Expanded(child: _body(context, repo)),
            ],
          ),
        );
      },
    );
  }

  Widget _body(BuildContext context, TaskRepository repo) {
    if (repo.tasks.isEmpty) {
      return RefreshIndicator(
        onRefresh: repo.syncAndRefresh,
        child: ListView(
          children: [
            SizedBox(height: MediaQuery.of(context).size.height * 0.3),
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  repo.loading
                      ? 'Загрузка…'
                      : 'Задач нет.\nПотяните вниз, чтобы обновить.',
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
        itemCount: repo.tasks.length,
        itemBuilder: (context, i) {
          final view = repo.tasks[i];
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
