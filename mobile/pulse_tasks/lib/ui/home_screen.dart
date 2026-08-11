import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/task_repository.dart';
import '../models/home.dart';
import 'settings_screen.dart';
import 'task_detail_screen.dart';
import 'task_list_screen.dart';
import 'theme.dart';
import 'widgets/account_menu.dart';
import 'widgets/home_blocks.dart';
import 'widgets/task_card.dart';

/// The app's start page, assembled from whatever blocks the server sends for this user.
///
/// A store manager opens it for the shop's numbers, an inspector for the regulation and
/// what changed — so the screen owns no layout of its own beyond "blocks, in order". The
/// only thing decided here is how each *type* of block is drawn.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  /// A server that has no home screen configured (or an old one without the endpoint)
  /// still has tasks — falling back to the task block keeps the app usable instead of
  /// opening on a blank page.
  static const _fallback = HomeBlock(
    code: 'myTasks',
    type: 'tasks',
    title: 'Мои задачи',
    icon: '📋',
  );

  @override
  Widget build(BuildContext context) {
    return Consumer<TaskRepository>(
      builder: (context, repo, _) {
        final blocks =
            repo.home.isEmpty ? const [_fallback] : repo.home.blocks;
        return Scaffold(
          appBar: AppBar(
            title: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (Wms.brand.logoBytes != null) ...[
                  Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Image.memory(
                      Wms.brand.logoBytes!,
                      height: 22,
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                    ),
                  ),
                  const SizedBox(width: 10),
                ],
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(Wms.brand.name),
                    if (Wms.brand.tagline.isNotEmpty)
                      Text(
                        Wms.brand.tagline,
                        style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w400,
                            color: Colors.white70),
                      ),
                  ],
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
              // the start page is where a shift ends — leaving from here must not require
              // walking into the task list first
              AccountMenu(repo: repo),
            ],
          ),
          body: Column(
            children: [
              if (!repo.online) const _OfflineBanner(),
              // The selector is shown only when it can change anything: one shop, or no
              // block broken down by shop, and it would be decoration.
              if (repo.home.hasObjectBlocks && repo.home.objects.length > 1)
                _ObjectBar(repo: repo),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: repo.syncAndRefresh,
                  child: ListView(
                    padding: const EdgeInsets.only(bottom: 24),
                    children: [
                      for (final b in blocks) ..._block(context, repo, b),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// An unknown type yields nothing: a newer server may configure a block this build
  /// cannot draw, and skipping it is better than failing the whole screen.
  List<Widget> _block(BuildContext context, TaskRepository repo, HomeBlock b) {
    switch (b.type) {
      case 'tasks':
        return _tasks(context, repo, b);
      case 'metrics':
        return [
          HomeSectionHeader(block: b),
          HomeMetricsBlock(
            block: b,
            objectId: b.byObject ? repo.objectId : null,
            onTapMetric: (m) => _openTasks(context, TaskFilter.parse(m.filter)),
          ),
        ];
      case 'text':
        return [HomeSectionHeader(block: b), HomeTextBlock(block: b)];
      case 'news':
        return [HomeSectionHeader(block: b), HomeNewsBlock(block: b)];
      default:
        return const [];
    }
  }

  void _openTasks(BuildContext context, TaskFilter filter) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => TaskListScreen(filter: filter)),
    );
  }

  /// The task block shows the few tasks the worker is most likely to open next and a way
  /// into the full list — the home screen is a starting point, not a second task list.
  /// Overdue ones come first: they are the reason to open the app at all.
  List<Widget> _tasks(
      BuildContext context, TaskRepository repo, HomeBlock b) {
    final all = [...repo.tasks]..sort((x, y) {
        if (x.overdue != y.overdue) return x.overdue ? -1 : 1;
        final dx = x.task.deadlineDate, dy = y.task.deadlineDate;
        if (dx == null) return dy == null ? 0 : 1;
        if (dy == null) return -1;
        return dx.compareTo(dy);
      });
    final preview = all.take(3).toList();
    final overdue = all.where((t) => t.overdue).length;

    return [
      HomeSectionHeader(
        block: b,
        trailing: TextButton(
          onPressed: () => _openTasks(context, TaskFilter.all),
          child: Text(all.isEmpty ? 'Открыть' : 'Все (${all.length})'),
        ),
      ),
      if (overdue > 0)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: InkWell(
            onTap: () => _openTasks(context, TaskFilter.overdue),
            child: Row(
              children: [
                Icon(Icons.error_outline, size: 16, color: Wms.warn),
                const SizedBox(width: 6),
                Text(
                  'Просрочено: $overdue',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Wms.warn),
                ),
              ],
            ),
          ),
        ),
      if (preview.isEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Text(
            repo.loading ? 'Загрузка…' : 'Открытых задач нет.',
            style: TextStyle(color: Wms.muted),
          ),
        ),
      for (final v in preview)
        TaskCard(
          view: v,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => TaskDetailScreen(taskId: v.id),
            ),
          ),
        ),
      if (all.length > preview.length)
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
          child: OutlinedButton(
            onPressed: () => _openTasks(context, TaskFilter.all),
            child: Text('Ещё ${all.length - preview.length}'),
          ),
        ),
    ];
  }
}

/// Which shop the numbers below belong to. A strip rather than a dropdown in the app bar:
/// on a dashboard the answer to «чьи это цифры» has to be visible without a tap.
class _ObjectBar extends StatelessWidget {
  final TaskRepository repo;
  const _ObjectBar({required this.repo});

  @override
  Widget build(BuildContext context) {
    final current = repo.currentObject;
    return Material(
      color: Wms.active,
      child: InkWell(
        onTap: () => _pick(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Icon(Icons.storefront_outlined, size: 18, color: Wms.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      current?.name ?? 'Объект не выбран',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Wms.text),
                    ),
                    if (current?.address != null)
                      Text(
                        current!.address!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: Wms.muted),
                      ),
                  ],
                ),
              ),
              Icon(Icons.unfold_more, size: 18, color: Wms.primary),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pick(BuildContext context) async {
    final selected = repo.objectId;
    final chosen = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Wms.card,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('Объект',
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: Wms.text)),
            ),
            for (final o in repo.home.objects)
              ListTile(
                title: Text(o.name),
                subtitle: o.address == null ? null : Text(o.address!),
                trailing: o.id == selected
                    ? Icon(Icons.check, color: Wms.primary)
                    : null,
                onTap: () => Navigator.of(context).pop(o.id),
              ),
          ],
        ),
      ),
    );
    if (chosen != null) await repo.selectObject(chosen);
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
