import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/geo.dart';
import '../data/task_repository.dart';
import '../models/place.dart';
import 'geo_gate_screen.dart';
import 'settings_screen.dart';
import 'task_detail_screen.dart';
import 'theme.dart';
import 'widgets/account_menu.dart';
import 'widgets/task_card.dart';
import 'widgets/warn_bar.dart';

/// The task list, optionally narrowed to one of the home screen's summary figures.
///
/// The filter is a parameter rather than screen state so a tile on the dashboard can open
/// exactly the list it stands for: a number the worker cannot open is a dead end.
///
/// The list is also narrowed to one object — the shop the person is standing in — and the
/// header says which and how far away it is. That is not decoration: a list of tasks is
/// only answerable at one place at a time, and somebody who sees the wrong tasks has to be
/// able to see *why* without leaving the screen.
class TaskListScreen extends StatefulWidget {
  final TaskFilter filter;

  /// Narrow the list to one shop. A tile of the dashboard's summary counts a single
  /// object, and the list it opens must count the same one — «1 здесь» opening six rows
  /// would teach the worker to trust neither the tile nor the list.
  final String? objectId;

  const TaskListScreen(
      {super.key, this.filter = TaskFilter.all, this.objectId});

  @override
  State<TaskListScreen> createState() => _TaskListScreenState();
}

class _TaskListScreenState extends State<TaskListScreen> {
  late TaskFilter _filter = widget.filter;

  /// «Взяты коллегами» по умолчанию свёрнуты: это ответ на «куда делась задача», а не
  /// рабочий план. Но группа не исчезает — задача, пропавшая из списка без
  /// объяснения, читается как потеря данных.
  bool _colleaguesOpen = false;

  /// «Обновить местоположение»: переехал в соседний магазин — нажал, список перестроился.
  ///
  /// Nothing is navigated away from and nothing is asked: the answer arrives in the
  /// header, which is where the question was. A failure is a snackbar rather than a full
  /// screen — the person is inside the app with a working list, not at the door.
  Future<void> _relocate() async {
    final repo = context.read<TaskRepository>();
    final outcome = await repo.locate();
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (outcome is GeoUnavailable) {
      final (_, title, _) = explainGeoFailure(outcome.reason);
      messenger.showSnackBar(SnackBar(
        content: Text(title),
        action: SnackBarAction(
          label: 'Настройки',
          onPressed: () => repo.geo.openSettings(outcome.reason),
        ),
      ));
      return;
    }
    // A press that changes nothing has to say so too, otherwise the only way to tell
    // «список тот же, потому что вы там же» from «кнопка не сработала» is to guess.
    final object = repo.place.object;
    messenger.showSnackBar(SnackBar(
      content: Text(object == null
          ? 'Рядом объектов не нашлось'
          : 'Вы на объекте «${object.name}»'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<TaskRepository>(
      builder: (context, repo, _) {
        final tasks = widget.objectId == null
            ? repo.tasks
            : repo.tasks
                .where((v) => v.task.objectId == widget.objectId)
                .toList();
        final shown = tasks.where(_filter.matches).toList();
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
              // проигранная гонка за задачу — заметным сообщением до явного
              // закрытия, а не тихой перестановкой строки (#36836)
              if (repo.takeNotice != null)
                NoticeBar(Icons.front_hand_outlined, repo.takeNotice!,
                    onClose: repo.dismissTakeNotice),
              // Only for accounts that work by location: a role excused from geolocation
              // gets its whole list, and a header about an object it is not standing at
              // would be a question nobody asked.
              if (repo.session.geoRequired)
                _PlaceBar(repo: repo, onRefresh: _relocate),
              _FilterBar(
                current: _filter,
                counts: {
                  for (final f in TaskFilter.values)
                    f: tasks.where(f.matches).length,
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
            SizedBox(height: MediaQuery.of(context).size.height * 0.12),
            _Empty(state: _emptyState(repo), onRelocate: _relocate),
          ],
        ),
      );
    }

    // Три группы, порядок фиксирован: «мои» сверху — ради них человек и открыл
    // приложение. Пустая группа не показывается вовсе: ни заголовка, ни «нет задач».
    final groups = {for (final g in TaskGroup.values) g: <TaskView>[]};
    for (final v in shown) {
      groups[v.group]!.add(v);
    }
    final visible =
        TaskGroup.values.where((g) => groups[g]!.isNotEmpty).toList();

    final rows = <Widget>[];
    for (final g in visible) {
      final items = groups[g]!;
      final collapsible = g == TaskGroup.taken;
      // единственной группе заголовок не нужен — деления нет; исключение — «взяты
      // коллегами»: её заголовок и есть та строка-объяснение, за которой группа
      // сворачивается
      if (visible.length > 1 || collapsible) {
        rows.add(_GroupHeader(
          group: g,
          count: items.length,
          open: collapsible ? _colleaguesOpen : null,
          onTap: collapsible
              ? () => setState(() => _colleaguesOpen = !_colleaguesOpen)
              : null,
        ));
      }
      if (collapsible && !_colleaguesOpen) continue;
      for (final view in items) {
        rows.add(TaskCard(
          view: view,
          onTake: view.canTake ? () => _take(view) : null,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => TaskDetailScreen(taskId: view.id),
            ),
          ),
        ));
      }
    }

    return RefreshIndicator(
      onRefresh: repo.syncAndRefresh,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 6),
        children: rows,
      ),
    );
  }

  /// Взять задачу из строки списка. Мгновенно и офлайн: намерение уже в очереди, а
  /// снекбар честно говорит, подтверждено оно или ещё поедет.
  Future<void> _take(TaskView view) async {
    final repo = context.read<TaskRepository>();
    final messenger = ScaffoldMessenger.of(context);
    await repo.takeTask(view.id);
    messenger.showSnackBar(SnackBar(
      content: Text(repo.online
          ? 'Задача перенесена в «Мои»'
          : 'Взятие сохранено офлайн — ожидает подтверждения'),
      duration: const Duration(seconds: 2),
    ));
  }

  /// Почему список пуст. «Задач нет» — только один из ответов, и схлопывать в него
  /// остальные нельзя: человек, который стоит в двенадцати километрах от ближайшего
  /// объекта, и человек, у которого на объекте всё сделано, должны сделать разное.
  _EmptyState _emptyState(TaskRepository repo) {
    if (repo.loading || repo.locating) {
      return const _EmptyState(Icons.hourglass_empty, 'Загрузка…', '');
    }
    if (repo.session.geoRequired) {
      final place = repo.place;
      switch (place.state) {
        case PlaceState.unknown:
          return const _EmptyState(
            Icons.location_searching,
            'Неизвестно, где вы',
            'Пока приложение не знает, на каком объекте вы стоите, отбирать задачи не '
                'из чего. Нажмите «Обновить местоположение».',
            relocate: true,
          );
        case PlaceState.noObjects:
          return const _EmptyState(
            Icons.wrong_location_outlined,
            'Рядом нет объектов с координатами',
            'Ни одному объекту проверки не проставлены координаты, поэтому определить, '
                'где вы, не по чему. Это чинится не на телефоне — сообщите '
                'администратору.',
            relocate: true,
          );
        case PlaceState.far:
          final nearest = place.nearest;
          return _EmptyState(
            Icons.near_me_disabled_outlined,
            'Рядом нет объектов',
            'Ближайший — «${nearest?.name ?? 'объект'}», до него '
                '${nearest?.distanceText ?? 'далеко'}. Задачи показываются по объекту, '
                'на котором вы стоите: подойдите ближе и обновите местоположение.',
            relocate: true,
          );
        case PlaceState.located:
          // the shop the list is narrowed to, when it was opened from a tile — the
          // person asked about that one, and an answer about the one they stand at
          // would name the wrong shop
          final name = _objectName(repo) ?? place.object!.name;
          return _EmptyState(
            Icons.task_alt,
            _filter == TaskFilter.all
                ? 'На объекте «$name» задач нет'
                : 'Под фильтр «${_filter.title}» ничего не попало',
            _filter == TaskFilter.all
                ? 'Потяните вниз, чтобы обновить. Если вы не на этом объекте — обновите '
                    'местоположение или выберите другой в шапке.'
                : 'На объекте «$name» такие задачи не нашлись.',
          );
      }
    }
    // Список, суженный до магазина, пустеет по-магазинному: «задач нет» человеку, у
    // которого плитка только что показала «6 всего», обязано говорить, ГДЕ их нет.
    final objectName = _objectName(repo);
    return _EmptyState(
      Icons.task_alt,
      _filter == TaskFilter.all
          ? (objectName == null
              ? 'Задач нет'
              : 'На объекте «$objectName» задач нет')
          : 'Под фильтр «${_filter.title}» ничего не попало',
      _filter == TaskFilter.all ? 'Потяните вниз, чтобы обновить.' : '',
    );
  }

  /// Название магазина, которым сужен список, — из справочника главной страницы.
  String? _objectName(TaskRepository repo) {
    final id = widget.objectId;
    if (id == null) return null;
    for (final o in repo.home.objects) {
      if (o.id == id) return o.name;
    }
    return null;
  }
}

/// Где человек находится, по мнению приложения, и почему он видит именно эти задачи.
///
/// Полоса под шапкой, а не значок в AppBar: «на каком я объекте» — первое, что надо
/// проверить, когда список выглядит не так, как ожидалось, и на проверку не должно
/// уходить нажатие. Нажатие есть у выбора соседа — но только когда сосед есть: если
/// объект один, спрашивать не о чем.
class _PlaceBar extends StatelessWidget {
  final TaskRepository repo;
  final Future<void> Function() onRefresh;
  const _PlaceBar({required this.repo, required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    final place = repo.place;
    final object = place.object;
    final choosable = place.nearby.length > 1;

    return Material(
      color: Wms.active,
      child: InkWell(
        onTap: choosable ? () => _pick(context) : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Row(
            children: [
              Icon(
                object == null
                    ? Icons.location_searching
                    : Icons.storefront_outlined,
                size: 18,
                color: Wms.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      object?.name ?? _title(place.state),
                      // Две строки, а не одна: объекты сплошь и рядом называются
                      // одинаково и различаются номером в самом конце —
                      // «MITE-T2 (термогигрометр) №470301». Многоточие съедает как раз
                      // его, и шапка перестаёт отвечать на вопрос, ради которого она
                      // здесь: на каком из трёх соседей человек стоит.
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Wms.text),
                    ),
                    Text(
                      _subtitle(place),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: Wms.muted),
                    ),
                  ],
                ),
              ),
              if (choosable)
                Icon(Icons.unfold_more, size: 18, color: Wms.primary),
              Tooltip(
                message: 'Обновить местоположение',
                child: TextButton.icon(
                  onPressed: repo.locating ? null : onRefresh,
                  icon: repo.locating
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.my_location, size: 18),
                  label: const Text('Обновить'),
                  style: TextButton.styleFrom(
                    foregroundColor: Wms.primary,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _title(PlaceState state) => switch (state) {
        PlaceState.unknown => 'Местоположение не определено',
        PlaceState.noObjects => 'Объектов с координатами нет',
        PlaceState.far => 'Вы не на объекте',
        PlaceState.located => '', // не встречается: тогда есть название объекта
      };

  /// Расстояние — то, ради чего шапка и заводилась: «120 м» отвечает на «то ли это
  /// здание», а время определения — на «а не полчаса ли назад это было».
  static String _subtitle(Place place) {
    final object = place.object;
    if (object == null) {
      final nearest = place.nearest;
      return nearest == null
          ? 'Нажмите «Обновить», чтобы определить'
          : 'Ближайший: ${nearest.name} · ${nearest.distanceText}';
    }
    final others = place.nearby.length - 1;
    return [
      object.distanceText,
      if (others > 0) 'ещё $others рядом',
      if (place.at != null) 'в ${_hhmm(place.at!)}',
    ].where((s) => s.isNotEmpty).join(' · ');
  }

  static String _hhmm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  /// Выбор объекта, когда рядом больше одного. По умолчанию выбран ближайший — лист
  /// открывается только по нажатию на шапку, и только если выбирать есть из чего:
  /// вопрос, у которого один ответ, задавать не надо.
  Future<void> _pick(BuildContext context) async {
    final selected = repo.place.objectId;
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
              child: Text('Вы на каком объекте?',
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: Wms.text)),
            ),
            for (final o in repo.place.nearby)
              ListTile(
                leading: Icon(Icons.storefront_outlined,
                    color: o.id == selected ? Wms.primary : Wms.muted),
                title: Text(o.name),
                subtitle: o.address == null ? null : Text(o.address!),
                // расстояние у каждого: между двумя магазинами в одном центре
                // выбирают именно по нему
                trailing: Text(
                  o.distanceText,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight:
                        o.id == selected ? FontWeight.w700 : FontWeight.w400,
                    color: o.id == selected ? Wms.primary : Wms.muted,
                  ),
                ),
                onTap: () => Navigator.of(context).pop(o.id),
              ),
          ],
        ),
      ),
    );
    if (chosen != null) await repo.selectNearby(chosen);
  }
}

/// Почему список пуст, одним экраном: значок, строка и что с этим делать.
class _EmptyState {
  final IconData icon;
  final String title;
  final String explanation;

  /// Показывать ли кнопку «Обновить местоположение» — она помогает не всегда, и там,
  /// где не помогает, её нет.
  final bool relocate;

  const _EmptyState(this.icon, this.title, this.explanation,
      {this.relocate = false});
}

class _Empty extends StatelessWidget {
  final _EmptyState state;
  final Future<void> Function() onRelocate;
  const _Empty({required this.state, required this.onRelocate});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        children: [
          Icon(state.icon, size: 48, color: Wms.muted),
          const SizedBox(height: 16),
          Text(
            state.title,
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 17, fontWeight: FontWeight.w700, color: Wms.text),
          ),
          if (state.explanation.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              state.explanation,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, height: 1.4, color: Wms.muted),
            ),
          ],
          if (state.relocate) ...[
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onRelocate,
              icon: const Icon(Icons.my_location, size: 18),
              label: const Text('Обновить местоположение'),
            ),
          ],
        ],
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

/// Заголовок группы списка (#36836). У «взяты коллегами» он же — переключатель
/// свёрнутости: счётчик виден всегда, состав — по нажатию.
class _GroupHeader extends StatelessWidget {
  final TaskGroup group;
  final int count;

  /// null — группа не сворачивается и рисуется без шеврона.
  final bool? open;
  final VoidCallback? onTap;

  const _GroupHeader(
      {required this.group, required this.count, this.open, this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
        child: Row(
          children: [
            Text(
              group.title,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                  color: Wms.muted),
            ),
            const SizedBox(width: 6),
            Text('$count',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Wms.primary)),
            if (open != null)
              Icon(open! ? Icons.expand_less : Icons.expand_more,
                  size: 18, color: Wms.muted),
          ],
        ),
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
