import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/geo.dart';
import '../data/home_controller.dart';
import '../data/location_controller.dart';
import '../data/sync_coordinator.dart';
import '../data/task_repository.dart';
import '../models/place.dart';
import '../models/task_view.dart';
import 'geo_gate_screen.dart';
import 'task_detail_screen.dart';
import 'theme.dart';
import 'widgets/ds.dart';
import 'widgets/task_card.dart';
import 'widgets/task_list_empty.dart';
import 'widgets/warn_bar.dart';

/// The task list, optionally narrowed to one of the home screen's summary figures.
///
/// The filter is a parameter rather than screen state so a tile on the dashboard can open
/// exactly the list it stands for: a number the worker cannot open is a dead end.
///
/// Показывается ВСЁ назначенное, включая задачи других объектов (#36837): задачи
/// магазина, где человек стоит, — сверху и рабочие, остальные — ниже по расстоянию и
/// только для чтения. Шапка по-прежнему говорит, где человек, — теперь это объясняет
/// не «почему список такой короткий», а «почему эти строки только для просмотра».
///
/// Редизайн #37411 (п. 3): сверху чип текущего объекта с расстоянием (замена прежней
/// полосы-«шапки» объекта), крупный заголовок «Задачи», группы [TaskGroup] —
/// горизонтальные чипы-фильтры со счётчиками вместо секций с заголовками. Как вкладка
/// ([asTab]) экран живёт без AppBar; открытие с плитки главной — обычным стеком.
class TaskListScreen extends StatefulWidget {
  final TaskFilter filter;

  /// Narrow the list to one shop. A tile of the dashboard's summary counts a single
  /// object, and the list it opens must count the same one — «1 здесь» opening six rows
  /// would teach the worker to trust neither the tile nor the list.
  final String? objectId;

  /// Вкладка нижней панели: без AppBar, заголовок в теле, без отступа под назад.
  final bool asTab;

  const TaskListScreen(
      {super.key,
      this.filter = TaskFilter.all,
      this.objectId,
      this.asTab = false});

  @override
  State<TaskListScreen> createState() => _TaskListScreenState();
}

class _TaskListScreenState extends State<TaskListScreen> {
  late TaskFilter _filter = widget.filter;

  /// Выбранная человеком группа-чип; null — «авто»: первая непустая в порядке
  /// [TaskGroup] (то есть «Мои», когда они есть). Сворачиваемой «взяты коллегами»
  /// больше нет: группа выбирается чипом, и прятать за свёрнутостью то, что
  /// человек пришёл посмотреть, незачем.
  TaskGroup? _chosen;

  // --- разбор списка: поиск, сортировка, фильтры (#36915) ---

  late final TextEditingController _search;

  /// Строка поиска спрятана за значком-лупой у чипа объекта (стр. 2 макета) и
  /// появляется только по тапу: в покое экран выглядит как в макете, находить
  /// задачи от этого не сложнее.
  bool _searchOpen = false;
  TaskSort _sort = TaskSort.route;
  final Set<String> _statusIds = {};
  final Set<String> _priorityKeys = {};

  /// «Мои задачи», открытые сами по себе, помнят свой разбор между запусками. Список,
  /// открытый с плитки главной, — ответ на её вопрос: он приходит со своим фильтром,
  /// стартует чистым и сохранённый разбор не трогает — иначе плитка «Просроченные»
  /// перекраивала бы то, как человек разложил основной список.
  bool get _remembers =>
      widget.filter == TaskFilter.all && widget.objectId == null;

  @override
  void initState() {
    super.initState();
    _search = TextEditingController();
    if (_remembers) {
      final prefs = context.read<HomeController>().listPrefs;
      _sort = prefs.sort;
      _statusIds.addAll(prefs.statusIds);
      _priorityKeys.addAll(prefs.priorityKeys);
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Записать разбор в базу пользователя — после каждого изменения, а не при выходе с
  /// экрана: «переживает перезапуск» обязано выполняться и для убитого из шторки
  /// приложения. Текст поиска не пишется — поиск про сейчас, а не про завтра.
  void _persist() {
    if (!_remembers) return;
    unawaited(context.read<HomeController>().saveListPrefs(ListPrefs(
          chip: _filter,
          sort: _sort,
          statusIds: {..._statusIds},
          priorityKeys: {..._priorityKeys},
        )));
  }

  bool get _filtersActive => _statusIds.isNotEmpty || _priorityKeys.isNotEmpty;

  String get _query => _search.text.trim().toLowerCase();

  /// Поиск по тому, чем человек задачу помнит: название, объект, исполнитель, номер.
  /// По подстроке и без регистра — «по части слова» из приёмки. Целиком локально,
  /// поэтому работает офлайн и без задержки.
  static bool _matchesQuery(TaskView v, String q) {
    if (q.isEmpty) return true;
    final t = v.task;
    for (final s in [t.name, t.object, t.assignedTo, t.id]) {
      if (s != null && s.toLowerCase().contains(q)) return true;
    }
    return false;
  }

  bool _matchesStatus(TaskView v) =>
      _statusIds.isEmpty || _statusIds.contains(v.statusId);

  bool _matchesPriority(TaskView v) =>
      _priorityKeys.isEmpty || _priorityKeys.contains(v.task.priorityKey);

  /// «Показать все» — сброс в один тап: поиск, статусы, приоритеты. Сортировка
  /// остаётся: она не прячет задачи, а лишь расставляет их.
  void _showAll() {
    setState(() {
      _search.clear();
      _statusIds.clear();
      _priorityKeys.clear();
      _filter = TaskFilter.all;
    });
    _persist();
  }

  /// Шторка «Сортировка и фильтры». Варианты статусов и приоритетов — из того, что
  /// реально есть в списке, со счётчиками: фильтр, под который заведомо ничего не
  /// попадает, — это вопрос без ответа. Каждый тап применяется сразу — список за
  /// шторкой перестраивается тем же жестом — и сразу же записывается.
  Future<void> _tune(TaskRepository repo) async {
    final tasks = widget.objectId == null
        ? repo.tasks
        : repo.tasks
            .where((v) => v.task.objectId == widget.objectId)
            .toList();

    // статусы — эффективные (очередь поверх сервера), порядок — справочника
    final statusNames = <String, String>{};
    final statusCounts = <String, int>{};
    for (final v in tasks) {
      final id = v.statusId;
      if (id == null) continue;
      statusNames[id] = repo.statusById(id)?.name ?? v.statusName ?? id;
      statusCounts[id] = (statusCounts[id] ?? 0) + 1;
    }
    int statusOrder(String id) =>
        repo.statusById(id)?.sortingOrder ?? 1 << 20;
    final statusIds = [...statusNames.keys]..sort((a, b) {
        final c = statusOrder(a).compareTo(statusOrder(b));
        return c != 0 ? c : statusNames[a]!.compareTo(statusNames[b]!);
      });

    final prioNames = <String, String>{};
    final prioCounts = <String, int>{};
    final prioRanks = <String, int>{};
    for (final v in tasks) {
      final key = v.task.priorityKey;
      if (key == null) continue;
      prioNames[key] = v.task.priority ?? key;
      prioCounts[key] = (prioCounts[key] ?? 0) + 1;
      prioRanks[key] = v.task.priorityRank;
    }
    final prioKeys = [...prioNames.keys]..sort((a, b) {
        final c = prioRanks[a]!.compareTo(prioRanks[b]!);
        return c != 0 ? c : prioNames[a]!.compareTo(prioNames[b]!);
      });

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Wms.card,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheet) {
          // тап меняет оба мира одним жестом: список за шторкой и саму шторку
          void update(VoidCallback f) {
            setState(f);
            setSheet(() {});
            _persist();
          }

          Widget caption(String s) => Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
                child: Text(s,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.4,
                        color: Wms.muted)),
              );

          Widget chips(List<Widget> children) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Wrap(spacing: 8, runSpacing: 8, children: children),
              );

          Widget chip(String label, bool selected, VoidCallback onTap) =>
              DsOutlineChip(label, selected: selected, onTap: onTap);

          return SafeArea(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  caption('Сортировка'),
                  chips([
                    for (final s in TaskSort.values)
                      chip(s.title, s == _sort, () => update(() => _sort = s)),
                  ]),
                  if (statusIds.isNotEmpty) ...[
                    caption('Статус'),
                    chips([
                      for (final id in statusIds)
                        chip(
                          '${statusNames[id]} · ${statusCounts[id]}',
                          _statusIds.contains(id),
                          () => update(() {
                            if (!_statusIds.remove(id)) _statusIds.add(id);
                          }),
                        ),
                    ]),
                  ],
                  if (prioKeys.isNotEmpty) ...[
                    caption('Приоритет'),
                    chips([
                      for (final key in prioKeys)
                        chip(
                          '${prioNames[key]} · ${prioCounts[key]}',
                          _priorityKeys.contains(key),
                          () => update(() {
                            if (!_priorityKeys.remove(key)) {
                              _priorityKeys.add(key);
                            }
                          }),
                        ),
                    ]),
                  ],
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                    child: TextButton.icon(
                      onPressed: () {
                        Navigator.of(sheetContext).pop();
                        _showAll();
                      },
                      icon: const Icon(Icons.filter_alt_off_outlined, size: 18),
                      label: const Text('Показать все'),
                      style: TextButton.styleFrom(foregroundColor: Wms.primary),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// «Обновить местоположение»: переехал в соседний магазин — нажал, список перестроился.
  ///
  /// Nothing is navigated away from and nothing is asked: the answer arrives in the
  /// chip at the top, which is where the question was. A failure is a snackbar rather
  /// than a full screen — the person is inside the app with a working list.
  Future<void> _relocate() async {
    final location = context.read<LocationController>();
    // fresh: кнопку жмут, потому что переехали, — запомненная позиция здесь и есть
    // тот ответ, ради которого её жать не стали бы (#36837)
    final outcome = await location.locate(fresh: true);
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (outcome is GeoUnavailable) {
      final (_, title, _) = explainGeoFailure(outcome.reason);
      messenger.showSnackBar(SnackBar(
        content: Text(title),
        action: SnackBarAction(
          label: 'Настройки',
          onPressed: () => location.geo.openSettings(outcome.reason),
        ),
      ));
      return;
    }
    // A press that changes nothing has to say so too, otherwise the only way to tell
    // «список тот же, потому что вы там же» from «кнопка не сработала» is to guess.
    final object = location.place.object;
    messenger.showSnackBar(SnackBar(
      content: Text(object == null
          ? 'Рядом объектов не нашлось'
          : 'Вы на объекте «${object.name}»'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<TaskRepository>();
    final location = context.watch<LocationController>();
    final home = context.watch<HomeController>();
    final tasks = widget.objectId == null
        ? repo.tasks
        : repo.tasks
            .where((v) => v.task.objectId == widget.objectId)
            .toList();
    // поиск и фильтры — до групп: счётчики на чипах обязаны сходиться с тем, что
    // покажет нажатие, иначе «Свободные · 3» открывали бы пять строк
    final q = _query;
    final found = tasks
        .where((v) =>
            _matchesQuery(v, q) &&
            _matchesStatus(v) &&
            _matchesPriority(v))
        .toList();
    final filtered = found.where(_filter.matches).toList();
    final counts = _groupCounts(filtered);
    // группа разрешается один раз на build — чипы и список смотрят на одно и
    // то же значение, иначе счётчик чипа и число строк разъедутся на переходе
    final group = _chosen ??
        TaskGroup.values.where((g) => counts[g]! > 0).firstOrNull;

    final body = Column(
      children: [
        // проигранная гонка за задачу — заметным сообщением до явного
        // закрытия, а не тихой перестановкой строки (#36836)
        if (repo.takeNotice != null)
          NoticeBar(Icons.front_hand_outlined, repo.takeNotice!,
              onClose: repo.dismissTakeNotice),
        // чип объекта — всегда (стр. 2 макета): он отвечает «где я», и это
        // небезынтересно даже роли, которой гео не обязательно. Поиск —
        // значком рядом с ним: строка появляется только по тапу (#36915)
        _ObjectChip(
          location: location,
          onRefresh: _relocate,
          search: IconButton(
            tooltip: 'Поиск',
            onPressed: () => setState(() {
              _searchOpen = !_searchOpen;
              // закрыли строку — сбросили и разбор по ней, иначе фильтр остался
              // бы невидимым: значок не скажет, почему в списке одна задача
              if (!_searchOpen) _search.clear();
            }),
            icon: Icon(
              _searchOpen ? Icons.close : Icons.search,
              size: 20,
              color: _searchOpen ? Wms.primary : Wms.muted,
            ),
          ),
        ),
        DsScreenTitle(
          'Задачи',
          subtitle: widget.filter == TaskFilter.all
              ? null
              : widget.filter.title, // зашли с плитки главной — она и есть подзаголовок
        ),
        // «Сегодня сделано N из M» (стр. 2 макета) — пара чисел от сервера
        // (apiHome): закрытые задачи из выдачи исчезают, клиенту её не собрать.
        // Нет чисел (старый сервер) или план на день пуст — строки нет
        _TodayLine(
          done: home.layout.todayDone,
          total: home.layout.todayTotal,
        ),
        if (_searchOpen)
          _SearchField(controller: _search, onChanged: () => setState(() {})),
        _GroupBar(
          current: group,
          counts: counts,
          onChanged: (g) => setState(() => _chosen = g),
          tune: _TuneButton(
            active: _filtersActive || _sort != TaskSort.route,
            onTap: () => _tune(repo),
          ),
        ),
        // сколько нашлось — виден весь эффект разбора и выход из него: без
        // этой строки «куда делись задачи» решалось бы перебором фильтров
        if (q.isNotEmpty || _filtersActive)
          _FoundBar(count: filtered.length, onShowAll: _showAll),
        // офлайн-плашка — узкой полосой над самим списком (п. 3), под чипами групп
        if (!repo.online)
          DsBanner(
            Icons.cloud_off,
            repo.pendingCount > 0
                ? 'Нет связи · ${repo.pendingCount} ${_pendingWord(repo.pendingCount)} ждут отправки'
                : 'Офлайн — показаны сохранённые данные',
            tone: DsTone.caution,
            actionLabel: repo.pendingCount > 0 ? 'Отправить' : null,
            onAction: repo.pendingCount > 0
                ? () =>
                    unawaited(context.read<SyncCoordinator>().syncAndRefresh())
                : null,
          ),
        Expanded(child: _body(context, repo, location, filtered, group)),
      ],
    );

    if (widget.asTab) {
      return Scaffold(
        body: SafeArea(bottom: false, child: body),
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(widget.filter.title)),
      body: body,
    );
  }

  static String _pendingWord(int n) {
    final m = n % 100;
    if (m >= 11 && m <= 14) return 'действий';
    return switch (n % 10) {
      1 => 'действие',
      2 || 3 || 4 => 'действия',
      _ => 'действий',
    };
  }

  Map<TaskGroup, int> _groupCounts(List<TaskView> filtered) {
    final counts = {for (final g in TaskGroup.values) g: 0};
    for (final v in filtered) {
      counts[v.group] = counts[v.group]! + 1;
    }
    return counts;
  }

  /// Список выбранной группы. Группа выбирается чипом — счётчик чипа обязан
  /// совпасть с числом строк один к одному, поэтому здесь нет «показать всё
  /// сразу»: все группы видны по очереди, а не свалены в один список.
  Widget _body(BuildContext context, TaskRepository repo,
      LocationController location, List<TaskView> filtered, TaskGroup? group) {
    final shown =
        group == null ? const <TaskView>[] : _sorted(group.applyTo(filtered));
    if (shown.isEmpty) {
      return RefreshIndicator(
        onRefresh: context.read<SyncCoordinator>().syncAndRefresh,
        child: ListView(
          children: [
            SizedBox(height: MediaQuery.of(context).size.height * 0.12),
            EmptyListView(
                state: emptyListState(
                  loading: repo.loading,
                  locating: location.locating,
                  filtered: _query.isNotEmpty || _filtersActive,
                  geoRequired: repo.session.geoRequired,
                  place: location.place,
                  filter: _filter,
                  objectName: _objectName(),
                ),
                onRelocate: _relocate),
          ],
        ),
      );
    }

    // builder, а не children: элементы строятся по мере прокрутки, и на тысяче задач
    // ввод в строку поиска перестраивает экранную дюжину карточек, а не все (#36915)
    return RefreshIndicator(
      onRefresh: context.read<SyncCoordinator>().syncAndRefresh,
      child: ListView.builder(
        padding: const EdgeInsets.only(top: 6, bottom: 16),
        itemCount: shown.length + 1, // +1 — запас под нижнюю панель вкладки
        itemBuilder: (_, i) => i == shown.length
            ? const SizedBox(height: 72)
            : TaskCard(
                view: shown[i],
                onTake: shown[i].canTake ? () => _take(shown[i]) : null,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => TaskDetailScreen(taskId: shown[i].id),
                  ),
                ),
              ),
      ),
    );
  }

  /// Порядок внутри группы (#36915): выбранный компаратор, добитый исходным индексом,
  /// — sort() нестабилен, а равные (обе без срока, один приоритет) должны стоять как
  /// стояли, то есть маршрутным порядком _reload.
  List<TaskView> _sorted(List<TaskView> items) {
    final cmp = _sort.comparator;
    if (cmp == null) return items;
    final order = {for (var i = 0; i < items.length; i++) items[i]: i};
    return [...items]..sort((a, b) {
        final c = cmp(a, b);
        return c != 0 ? c : order[a]!.compareTo(order[b]!);
      });
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

  /// Название магазина, которым сужен список, — из ответа главной или каталога.
  String? _objectName() =>
      context.read<HomeController>().objectById(widget.objectId)?.name;
}

/// «Сегодня сделано N из M» с тонкой полосой (стр. 2 макета): прогресс дня над
/// списком. Пара чисел живёт в ответе apiHome и кэше главной — рисуется, только
/// когда сервер её прислал и план на день не пуст: выдумывать план телефон не
/// имеет права (п. 3 задачи #37411).
class _TodayLine extends StatelessWidget {
  final int? done;
  final int? total;
  const _TodayLine({required this.done, required this.total});

  @override
  Widget build(BuildContext context) {
    if (done == null || total == null || total! <= 0) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      // подпись слева, полоса от неё до края — одной строкой, как в макете
      child: Row(
        children: [
          Text('Сегодня сделано $done из $total',
              style: TextStyle(fontSize: 13, color: Wms.muted)),
          const SizedBox(width: 10),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: (done!.clamp(0, total!)) / total!,
                minHeight: 6,
                backgroundColor: Wms.chipBg,
                valueColor: AlwaysStoppedAnimation<Color>(Wms.primary),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Короткие названия групп для чипов: полные («Ждут моей приёмки», «Поставленные
/// мной») в горизонтальной полосе съедают место, ради которого чипы и заводились.
/// Полное название — в подсказке по долгому нажатию.
extension TaskGroupShort on TaskGroup {
  String get shortTitle => switch (this) {
        TaskGroup.mine => 'Мои',
        TaskGroup.awaiting => 'Решить',
        TaskGroup.free => 'Свободные',
        TaskGroup.taken => 'У коллег',
        TaskGroup.submitted => 'На приёмке',
        TaskGroup.rework => 'На доработке',
        TaskGroup.authored => 'Поставленные',
        TaskGroup.watched => 'Наблюдаю',
      };
}

extension TaskGroupFilter on TaskGroup {
  /// Задачи этой группы из уже отфильтрованного списка.
  List<TaskView> applyTo(List<TaskView> filtered) =>
      filtered.where((v) => v.group == this).toList();
}

/// Чип текущего объекта с расстоянием — замена прежней полосы-«шапки» (#37411,
/// п. 3). Тап открывает выбор соседнего объекта, когда соседей больше одного;
/// «обновить местоположение» — иконка рядом: переехал — нажал, чип перестроился.
class _ObjectChip extends StatelessWidget {
  final LocationController location;
  final Future<void> Function() onRefresh;

  /// Значок поиска рядом с чипом (стр. 2 макета): строка поиска живёт за ним.
  final Widget? search;
  const _ObjectChip(
      {required this.location, required this.onRefresh, this.search});

  @override
  Widget build(BuildContext context) {
    final place = location.place;
    final object = place.object;
    final choosable = place.nearby.length > 1;

    final label = object == null
        ? _title(place.state)
        : [
            object.name,
            object.distanceText,
          ].whereType<String>().where((s) => s.isNotEmpty).join(' · ');

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
      child: Row(
        children: [
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: InkWell(
                onTap: choosable ? () => _pick(context) : null,
                borderRadius: BorderRadius.circular(999),
                child: Container(
                  height: 36,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  // контурная пилюля с булавкой — как на стр. 2 макета:
                  // объект здесь не «метка», а ответ «где я»
                  decoration: BoxDecoration(
                    color: Colors.transparent,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: Wms.line),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        object == null
                            ? Icons.location_searching
                            : Icons.location_on_outlined,
                        size: 16,
                        color: Wms.primary,
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Wms.text),
                        ),
                      ),
                      if (choosable) ...[
                        const SizedBox(width: 4),
                        Icon(Icons.unfold_more,
                            size: 14, color: Wms.primary),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (search != null) search!,
          // обновление — всегда при чипе: без определённого объекта оно и есть
          // способ его определить (чип теперь виден каждой роли)
          Tooltip(
            message: 'Обновить местоположение',
            child: IconButton(
              onPressed: location.locating ? null : () => onRefresh(),
              icon: location.locating
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.my_location, size: 20),
            ),
          ),
        ],
      ),
    );
  }

  static String _title(PlaceState state) => switch (state) {
        PlaceState.unknown => 'Местоположение не определено',
        PlaceState.noObjects => 'Объектов с координатами нет',
        PlaceState.far => 'Вы не на объекте',
        PlaceState.located => '', // не встречается: тогда есть название объекта
      };

  /// Выбор объекта, когда рядом больше одного. По умолчанию выбран ближайший — лист
  /// открывается только по нажатию на чип, и только если выбирать есть из чего:
  /// вопрос, у которого один ответ, задавать не надо.
  Future<void> _pick(BuildContext context) async {
    final selected = location.place.objectId;
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
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: Wms.text)),
            ),
            for (final o in location.place.nearby)
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
    if (chosen != null) await location.selectNearby(chosen);
  }
}

/// Строка поиска (#36915). Всегда на экране, а не за лупой в шапке: поиск — первый
/// инструмент разбора длинного списка, и прятать его за тап значит учить человека
/// листать. Ищет по локальной базе, поэтому работает офлайн и без задержки.
class _SearchField extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onChanged;
  const _SearchField({required this.controller, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: TextField(
        controller: controller,
        // открывается по тапу в лупу — человек уже заявил, что хочет печатать
        autofocus: true,
        onChanged: (_) => onChanged(),
        textInputAction: TextInputAction.search,
        style: TextStyle(fontSize: 14, color: Wms.text),
        decoration: InputDecoration(
          hintText: 'Название, объект, исполнитель, номер',
          hintStyle: TextStyle(fontSize: 14, color: Wms.muted),
          prefixIcon: Icon(Icons.search, size: 20, color: Wms.muted),
          // крестик, как только есть что стирать: наискорейший из двух сбросов —
          // второй, полный, живёт в строке «Найдено»
          suffixIcon: controller.text.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Очистить',
                  icon: Icon(Icons.close, size: 18, color: Wms.muted),
                  onPressed: () {
                    controller.clear();
                    onChanged();
                  },
                ),
          isDense: true,
        ),
      ),
    );
  }
}

/// Вход в шторку сортировки и фильтров. Точка на значке — «разбор включён»: числа на
/// чипах об этом уже говорят, но напоминание обязано жить и у самого выключателя.
class _TuneButton extends StatelessWidget {
  final bool active;
  final VoidCallback onTap;
  const _TuneButton({required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      // правое поле — общее (16): кнопка стоит вровень с карточками списка,
      // а не впритык к краю экрана; зазор слева отделяет её от чипов групп
      padding: const EdgeInsets.fromLTRB(8, 0, 16, 0),
      child: IconButton(
        tooltip: 'Сортировка и фильтры',
        onPressed: onTap,
        icon: Badge(
          isLabelVisible: active,
          smallSize: 8,
          backgroundColor: Wms.primary,
          child: Icon(Icons.tune,
              size: 20, color: active ? Wms.primary : Wms.muted),
        ),
      ),
    );
  }
}

/// «Найдено: N · Показать все» — итог разбора и выход из него одним тапом (#36915).
class _FoundBar extends StatelessWidget {
  final int count;
  final VoidCallback onShowAll;
  const _FoundBar({required this.count, required this.onShowAll});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
      child: Row(
        children: [
          Expanded(
            child: Text('Найдено: $count',
                style: TextStyle(fontSize: 13, color: Wms.muted)),
          ),
          TextButton(
            onPressed: onShowAll,
            style: TextButton.styleFrom(
              foregroundColor: Wms.primary,
              visualDensity: VisualDensity.compact,
            ),
            child: const Text('Показать все'),
          ),
        ],
      ),
    );
  }
}

/// Группы — горизонтальные чипы-фильтры со счётчиками (#37411, п. 3). Пустые группы
/// не показываем: чип с нулём — вопрос без ответа. Счётчик «Ждут моей приёмки»
/// («Решить») залит фирменным всегда: это единственная группа, где задача ждёт
/// решения самого человека, и пропускать её глазами дороже всего.
///
/// Полоса обрезается границей перед кнопкой «Сортировка и фильтры» — чипы не
/// наезжают под неё и не уезжают за край экрана, а скроллится полоса внутри
/// этой ширины. Выбранный чип докручивается в полосу целиком: тап по наполовину
/// спрятанному чипу не должен оставлять выбор спрятанным.
class _GroupBar extends StatefulWidget {
  final TaskGroup? current;
  final Map<TaskGroup, int> counts;
  final ValueChanged<TaskGroup> onChanged;
  final Widget tune;

  const _GroupBar({
    required this.current,
    required this.counts,
    required this.onChanged,
    required this.tune,
  });

  @override
  State<_GroupBar> createState() => _GroupBarState();
}

class _GroupBarState extends State<_GroupBar> {
  final _chipKeys = <TaskGroup, GlobalKey>{};

  /// Показать выбранный чип целиком — после кадра, когда выбор уже применён.
  void _reveal(TaskGroup g) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _chipKeys[g]?.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx,
            duration: const Duration(milliseconds: 200),
            alignment: 1.0,
            curve: Curves.easeOut);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final visible =
        TaskGroup.values.where((g) => widget.counts[g]! > 0).toList();
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          Expanded(
            // отступ снаружи скролла: полоса обрезается общим левым полем
            // экрана (16), как карточки списка ниже, — прокрученные чипы
            // скрываются за границей поля, а не за краем экрана
            child: Padding(
              padding: const EdgeInsets.only(left: 16),
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(0, 6, 8, 6),
                children: [
                  for (final g in visible)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: KeyedSubtree(
                        key: _chipKeys.putIfAbsent(g, () => GlobalKey()),
                        child: _groupChip(g),
                      ),
                    ),
                ],
              ),
            ),
          ),
          widget.tune,
        ],
      ),
    );
  }

  Widget _groupChip(TaskGroup g) {
    final selected = g == widget.current;
    final highlight = g == TaskGroup.awaiting; // «Решить» — см. доккласс

    // Выбранный чип: светлой темой — фирменная заливка, тёмной — светлая
    // плашка с тёмным текстом (зеркало, стр. 7 макета). Счётчик «Решить» залит
    // фирменным и на невыбранном чипе; на выбранном он переворачивается
    // контрастом самой заливки.
    final (chipBg, onChip, counterBg, onCounter) = selected
        ? _selectedColors(highlight)
        : _plainColors(highlight);

    final chip = Container(
      height: 36,
      padding: const EdgeInsets.only(left: 14, right: 8),
      decoration: BoxDecoration(
        color: chipBg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: selected ? chipBg : Wms.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            g.shortTitle,
            style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w600, color: onChip),
          ),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: counterBg == null
                ? null
                : BoxDecoration(
                    color: counterBg, borderRadius: BorderRadius.circular(999)),
            child: Text(
              '${widget.counts[g]}',
              style: TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w700, color: onCounter),
            ),
          ),
        ],
      ),
    );

    return Tooltip(
      message: g.title,
      child: InkWell(
        onTap: () {
        widget.onChanged(g);
        _reveal(g);
      },
        borderRadius: BorderRadius.circular(999),
        child: chip,
      ),
    );
  }

  /// (фон чипа, текст, фон счётчика, текст счётчика)
  (Color, Color, Color?, Color) _selectedColors(bool highlight) {
    if (!Wms.isDark) {
      final on = Wms.on(Wms.primary);
      return highlight
          ? (Wms.primary, on, on.withValues(alpha: 0.20), on)
          : (Wms.primary, on, null, on);
    }
    const chip = Color(0xFFE6EBF1);
    const onChip = Color(0xFF151B23);
    return highlight
        ? (chip, onChip, onChip.withValues(alpha: 0.12), onChip)
        : (chip, onChip, null, onChip);
  }

  (Color, Color, Color?, Color) _plainColors(bool highlight) {
    if (highlight) {
      return Wms.isDark
          ? (Colors.transparent, Wms.text2, Wms.brandTint, Wms.primary)
          : (Colors.transparent, Wms.text2, Wms.primary, Wms.on(Wms.primary));
    }
    return (Colors.transparent, Wms.text2, null, Wms.muted);
  }
}
