import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/home_controller.dart';
import '../data/sync_coordinator.dart';
import '../data/task_repository.dart';
import '../models/fill.dart';
import '../models/home.dart';
import '../models/task_view.dart';
import 'past_check_screen.dart';
import 'task_detail_screen.dart';
import 'task_list_screen.dart';
import 'theme.dart';
import 'widgets/ds.dart';
import 'widgets/external_apps_section.dart';
import 'widgets/home/text.dart';
import 'widgets/home/tiles.dart';
import 'widgets/task_card.dart';
import 'widgets/warn_bar.dart';

/// The app's start page, assembled from whatever blocks the server sends for this user.
///
/// A store manager opens it for the shop's numbers, an inspector for the regulation and
/// what changed — so the screen owns no layout of its own beyond "blocks, in order". The
/// only thing decided here is how each *type* of block is drawn.
///
/// Редизайн #37411, п. 2: главная — вкладка нижней панели. Уведомления, «Не
/// отправлено» и настройки из шапки ушли (Лента, Профиль и панель), выбор объекта —
/// чипом в шапке, создание — «+» в панели. Состав и порядок блоков, как и раньше,
/// задаёт сервер.
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
    final repo = context.watch<TaskRepository>();
    final home = context.watch<HomeController>();
    final sync = context.watch<SyncCoordinator>();
    final blocks =
        home.layout.isEmpty ? const [_fallback] : home.layout.blocks;
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
                        color: Wms.muted),
                  ),
              ],
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          // «Сегодня» с датой (#37411, п. 10): крупный заголовок вкладки, как
          // «Задачи» и «Лента». Дата — устройства: других часов у клиента нет, а
          // серверные блоки своей даты не присылают.
          DsScreenTitle('Сегодня', subtitle: _todayLine()),
          // Чей это магазин — чипом строкой ниже заголовка, прижат к правому
          // краю (#37411, п. 10). Тянется на длину имени объекта, но не шире
          // контентного поля (экран − 16 − 16 — как у блока задач ниже); дальше
          // имя режется многоточием, полностью оно — в шторке выбора.
          // Показывается, только когда выбор есть: один объект — не вопрос.
          if (home.layout.hasObjectBlocks && home.selectableObjects.length > 1)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Align(
                alignment: Alignment.centerRight,
                child: _ObjectChip(home: home),
              ),
            ),
          if (!repo.online || sync.syncError != null)
            DsBanner(Icons.cloud_off, sync.syncError ?? 'Офлайн — показаны сохранённые данные'),
          // проигранная гонка за задачу (#36836): фоновая синхронизация могла
          // случиться, пока человек был на главной, — сообщение ждёт его здесь
          if (repo.takeNotice != null)
            NoticeBar(Icons.front_hand_outlined, repo.takeNotice!,
                onClose: repo.dismissTakeNotice),
          // «что было здесь в прошлый раз» с карточки объекта (#36778) — вход
          // не зависит от того, по какому шаблону идёт текущая задача
          if (home.objectId != null) _PastCheckStrip(home: home),
          Expanded(
            child: RefreshIndicator(
              onRefresh: sync.syncAndRefresh,
              child: ListView(
                // запас под нижнюю панель вкладки
                padding: const EdgeInsets.only(bottom: 96),
                children: [
                  for (final b in blocks) ..._block(context, repo, home, b),
                  // Внешние приложения (#36840) — после блоков: их состав и
                  // порядок настраиваются в своём справочнике, а не в блоках
                  // главной, поэтому вперемешку с ними секция не встаёт. Пустой
                  // список (модуль не подключён, роли не совпали) рисует ничего.
                  ExternalAppsSection(
                    apps: home.externalApps,
                    objectId: home.objectId,
                    login: home.session.login,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// An unknown type yields nothing: a newer server may configure a block this build
  /// cannot draw, and skipping it is better than failing the whole screen.
  List<Widget> _block(BuildContext context, TaskRepository repo,
      HomeController home, HomeBlock b) {
    switch (b.type) {
      case 'tasks':
        return _tasks(context, repo, b);
      case 'metrics':
        // A per-object tile counts one shop, so the list under the tap is narrowed to
        // the same shop — the tile and the list must answer the same question, or the
        // worker who sees «1 здесь» and opens six rows stops trusting either number.
        final objectId = b.byObject ? home.objectId : null;
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

  /// «вторник, 7 октября» — заголовок вкладки с датой по-русски, без года: дата
  /// здесь не справка, а ориентир «какой сегодня день».
  static String _todayLine() {
    const weekdays = [
      'понедельник',
      'вторник',
      'среда',
      'четверг',
      'пятница',
      'суббота',
      'воскресенье',
    ];
    const months = [
      'января',
      'февраля',
      'марта',
      'апреля',
      'мая',
      'июня',
      'июля',
      'августа',
      'сентября',
      'октября',
      'ноября',
      'декабря',
    ];
    final now = DateTime.now();
    return '${weekdays[now.weekday - 1]}, ${now.day} ${months[now.month - 1]}';
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
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: OutlinedButton(
            onPressed: () => _openTasks(context, TaskFilter.all),
            child: Text('Ещё ${all.length - preview.length}'),
          ),
        ),
    ];
  }
}

/// Чей магазин показывают числа ниже — чип на главной (#37411, п. 10).
///
/// Выбор — из каталога, скачанного фоном (#37047), поэтому работает и без сети и не
/// ограничен объектами рядом; числа выбранного объекта приезжают следующей
/// синхронизацией, а до неё плитки показывают сетевые.
class _ObjectChip extends StatelessWidget {
  final HomeController home;
  const _ObjectChip({required this.home});

  @override
  Widget build(BuildContext context) {
    final current = home.currentObject;
    return InkWell(
      onTap: () => _pick(context),
      borderRadius: BorderRadius.circular(999),
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: Wms.chipBg,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.storefront_outlined, size: 16, color: Wms.primary),
            const SizedBox(width: 6),
            // Flexible, а не просто Text: чип сжимается при споре с заголовком
            // за строку, и ellipsis срабатывает только у ограниченного текста
            Flexible(
              child: Text(
                current?.name ?? 'Объект не выбран',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Wms.text),
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.unfold_more, size: 14, color: Wms.primary),
          ],
        ),
      ),
    );
  }

  Future<void> _pick(BuildContext context) async {
    final selected = home.objectId;
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
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: Wms.text)),
            ),
            for (final o in home.selectableObjects)
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
    if (chosen != null) await home.selectObject(chosen);
  }
}

/// Итог последней завершённой проверки текущего объекта — и вход в её просмотр.
/// Чистый рендер home.objectPastCheck (контроллер главной читает кэш при входе, смене
/// объекта и после каждого префетча), поэтому работает и в самолётном режиме и не
/// дёргает sqlite на каждый notifyListeners. Объект без единой завершённой
/// проверки строки не получает — «нет ни пометок, ни входа в просмотр» (#36778).
class _PastCheckStrip extends StatelessWidget {
  final HomeController home;
  const _PastCheckStrip({required this.home});

  @override
  Widget build(BuildContext context) {
    final obj = home.objectId;
    final s = home.objectPastCheck;
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
