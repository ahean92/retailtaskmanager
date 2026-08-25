import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/task_repository.dart';
import '../models/fill.dart';
import '../models/home.dart';
import '../models/quick_create.dart';
import 'notifications_screen.dart';
import 'past_check_screen.dart';
import 'quick_create_screen.dart';
import 'settings_screen.dart';
import 'task_detail_screen.dart';
import 'task_list_screen.dart';
import 'theme.dart';
import 'widgets/account_menu.dart';
import 'widgets/home_blocks.dart';
import 'widgets/task_card.dart';
import 'widgets/warn_bar.dart';

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
                      // подложка остаётся белой и в тёмной теме: логотип заказчика
                      // рисуют под светлый фон, и тёмный на тёмном просто пропадёт.
                      // Это не «плашка на экране», а фон самого знака — с ним он
                      // выглядит одинаково в обеих темах
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
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w400,
                            color: Wms.onChrome.withValues(alpha: 0.75)),
                      ),
                  ],
                ),
              ],
            ),
            actions: [
              IconButton(
                tooltip: 'Уведомления',
                icon: Badge(
                  label: Text('${repo.unreadCount}'),
                  isLabelVisible: repo.unreadCount > 0,
                  child: const Icon(Icons.notifications_outlined),
                ),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                      builder: (_) => const NotificationsScreen()),
                ),
              ),
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
                tooltip: 'Настройки',
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
              if (!repo.online || repo.syncError != null)
                _OfflineBanner(text: repo.syncError),
              // проигранная гонка за задачу (#36836): фоновая синхронизация могла
              // случиться, пока человек был на главной, — сообщение ждёт его здесь
              if (repo.takeNotice != null)
                NoticeBar(Icons.front_hand_outlined, repo.takeNotice!,
                    onClose: repo.dismissTakeNotice),
              // The selector is shown only when it can change anything: one shop, or no
              // block broken down by shop, and it would be decoration.
              if (repo.home.hasObjectBlocks && repo.home.objects.length > 1)
                _ObjectBar(repo: repo),
              // «что было здесь в прошлый раз» с карточки объекта (#36778) — вход
              // не зависит от того, по какому шаблону идёт текущая задача
              if (repo.objectId != null) _PastCheckStrip(repo: repo),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: repo.syncAndRefresh,
                  child: ListView(
                    // запас под кнопку «+», чтобы она не ложилась на последний блок
                    padding: const EdgeInsets.only(bottom: 88),
                    children: [
                      for (final b in blocks) ..._block(context, repo, b),
                    ],
                  ),
                ),
              ),
            ],
          ),
          // Кнопка есть ровно тогда, когда бэк-офис настроил хоть один пресет для ролей
          // этого человека: список приезжает с сервера уже отфильтрованным, поэтому
          // «разным ролям — разные кнопки» здесь не логика, а данные.
          floatingActionButton: repo.quickCreate.isEmpty
              ? null
              : FloatingActionButton(
                  tooltip: 'Создать',
                  onPressed: () => _create(context, repo),
                  child: const Icon(Icons.add),
                ),
        );
      },
    );
  }

  /// Один пресет открывается сразу; из нескольких человек выбирает. Список — то, что
  /// лежит в кэше этого пользователя, экран работает и без сети.
  Future<void> _create(BuildContext context, TaskRepository repo) async {
    final actions = repo.quickCreate.actions;
    QuickPreset? preset = actions.length == 1 ? actions.first : null;
    preset ??= await showModalBottomSheet<QuickPreset>(
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
              child: Text('Создать',
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: Wms.text)),
            ),
            for (final a in actions)
              ListTile(
                leading: Text(a.icon ?? '➕',
                    style: const TextStyle(fontSize: 22)),
                title: Text(a.title),
                onTap: () => Navigator.of(context).pop(a),
              ),
          ],
        ),
      ),
    );
    if (preset == null || !context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => QuickCreateScreen(preset: preset!)),
    );
  }

  /// An unknown type yields nothing: a newer server may configure a block this build
  /// cannot draw, and skipping it is better than failing the whole screen.
  List<Widget> _block(BuildContext context, TaskRepository repo, HomeBlock b) {
    switch (b.type) {
      case 'tasks':
        return _tasks(context, repo, b);
      case 'metrics':
        // A per-object tile counts one shop, so the list under the tap is narrowed to
        // the same shop — the tile and the list must answer the same question, or the
        // worker who sees «1 здесь» and opens six rows stops trusting either number.
        final objectId = b.byObject ? repo.objectId : null;
        return [
          HomeSectionHeader(block: b),
          HomeMetricsBlock(
            block: b,
            objectId: objectId,
            onTapMetric: (m) => _openTasks(context, TaskFilter.parse(m.filter),
                objectId: objectId),
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

  void _openTasks(BuildContext context, TaskFilter filter, {String? objectId}) {
    Navigator.of(context).push(
      MaterialPageRoute(
          builder: (_) => TaskListScreen(filter: filter, objectId: objectId)),
    );
  }

  /// The task block shows the few tasks the worker is most likely to open next and a way
  /// into the full list — the home screen is a starting point, not a second task list.
  /// Overdue ones come first: they are the reason to open the app at all.
  ///
  /// Превью и «просрочено» — только «мои» (#36836): свободный пул и взятые коллегами
  /// не зовут человека с главной, а просрочка чужой взятой задачи — не его тревога.
  /// Считать сюда всё видимое — тот же дефект доверия, что #36751: числа главной
  /// разошлись бы с группой «Мои» в списке. Кнопки «Все»/«Ещё» ведут в полный
  /// список — их числа честно считают всё, что там будет показано группами.
  List<Widget> _tasks(
      BuildContext context, TaskRepository repo, HomeBlock b) {
    final all = [...repo.tasks]..sort((x, y) {
        if (x.overdue != y.overdue) return x.overdue ? -1 : 1;
        final dx = x.task.deadlineDate, dy = y.task.deadlineDate;
        if (dx == null) return dy == null ? 0 : 1;
        if (dy == null) return -1;
        return dx.compareTo(dy);
      });
    final my = all.where((v) => v.group == TaskGroup.mine).toList();
    final preview = my.take(3).toList();
    final overdue = my.where((t) => t.overdue).length;

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

/// Итог последней завершённой проверки текущего объекта — и вход в её просмотр.
/// Чистый рендер repo.objectPastCheck (репозиторий читает кэш при входе, смене
/// объекта и после каждого префетча), поэтому работает и в самолётном режиме и не
/// дёргает sqlite на каждый notifyListeners. Объект без единой завершённой
/// проверки строки не получает — «нет ни пометок, ни входа в просмотр» (#36778).
class _PastCheckStrip extends StatelessWidget {
  final TaskRepository repo;
  const _PastCheckStrip({required this.repo});

  @override
  Widget build(BuildContext context) {
    final obj = repo.objectId;
    final s = repo.objectPastCheck;
    final date = s?.date;
    if (obj == null || s == null || date == null) {
      return const SizedBox.shrink();
    }
    return Material(
      color: Wms.card,
      child: InkWell(
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => PastCheckScreen.forObject(obj))),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.history, size: 16, color: Wms.muted),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Прошлая проверка: '
                  '${FillSummary.pastLine(date, s.percent, s.remarks)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: Wms.muted),
                ),
              ),
              Icon(Icons.chevron_right, size: 16, color: Wms.muted),
            ],
          ),
        ),
      ),
    );
  }
}

class _OfflineBanner extends StatelessWidget {
  /// Текст поверх стандартного «офлайн»: отказ сервера при дожиме локально-созданных
  /// задач — у поручения нет своего экрана, где эту ошибку можно было бы увидеть.
  final String? text;
  const _OfflineBanner({this.text});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Wms.warnTint,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(text == null ? Icons.cloud_off : Icons.sync_problem,
                size: 18, color: Wms.warn),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text ?? 'Офлайн — показаны сохранённые данные',
                style: TextStyle(color: Wms.warn),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
