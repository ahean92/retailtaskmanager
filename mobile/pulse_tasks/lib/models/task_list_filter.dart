import 'task.dart';
import 'task_status.dart';
import 'task_view.dart';

/// Разбор списка задач (#36915): поиск, сортировка, фильтры по статусу и приоритету,
/// выбранная группа. Отдельно от экрана: что показать и в каком порядке, решается
/// здесь, а экран рисует чипы, полосы и шторку и хранит строку поиска.
class TaskListFilterState {
  /// Фильтр плитки главной, с которой открыт список; «Показать все» его снимает.
  TaskFilter filter;

  TaskSort sort = TaskSort.route;
  final Set<String> statusIds = {};
  final Set<String> priorityKeys = {};

  /// Выбранная человеком группа-чип; null — «авто»: первая непустая в порядке
  /// [TaskGroup] (то есть «Мои», когда они есть). Сворачиваемой «взяты коллегами»
  /// больше нет: группа выбирается чипом, и прятать за свёрнутостью то, что
  /// человек пришёл посмотреть, незачем.
  TaskGroup? chosen;

  TaskListFilterState(this.filter);

  /// Сохранённый разбор «Моих задач» (см. ListPrefs).
  void restore(ListPrefs prefs) {
    sort = prefs.sort;
    statusIds.addAll(prefs.statusIds);
    priorityKeys.addAll(prefs.priorityKeys);
  }

  /// Что записать между запусками. Текст поиска не пишется — поиск про сейчас, а не
  /// про завтра.
  ListPrefs get prefs => ListPrefs(
        sort: sort,
        statusIds: {...statusIds},
        priorityKeys: {...priorityKeys},
      );

  bool get filtersActive => statusIds.isNotEmpty || priorityKeys.isNotEmpty;

  /// Разбор отличается от исходного — значок шторки об этом говорит.
  bool get tuned => filtersActive || sort != TaskSort.route;

  void toggleStatus(String id) {
    if (!statusIds.remove(id)) statusIds.add(id);
  }

  void togglePriority(String key) {
    if (!priorityKeys.remove(key)) priorityKeys.add(key);
  }

  /// «Показать все» — сброс статусов, приоритетов и фильтра плитки (строку поиска
  /// чистит экран). Сортировка остаётся: она не прячет задачи, а лишь расставляет их.
  void showAll() {
    statusIds.clear();
    priorityKeys.clear();
    filter = TaskFilter.all;
  }

  /// Поиск по тому, чем человек задачу помнит: название, объект, исполнитель, номер.
  /// По подстроке и без регистра — «по части слова» из приёмки. Целиком локально,
  /// поэтому работает офлайн и без задержки. [q] — уже в нижнем регистре.
  static bool matchesQuery(TaskView v, String q) {
    if (q.isEmpty) return true;
    final t = v.task;
    for (final s in [t.name, t.object, t.assignedTo, t.id]) {
      if (s != null && s.toLowerCase().contains(q)) return true;
    }
    return false;
  }

  bool _matchesStatus(TaskView v) =>
      statusIds.isEmpty || statusIds.contains(v.statusId);

  bool _matchesPriority(TaskView v) =>
      priorityKeys.isEmpty || priorityKeys.contains(v.task.priorityId);

  /// Разобрать [tasks] (открытые вместе с архивом «Выполненных») по строке поиска
  /// [query]. Поиск и фильтры — до групп: счётчики на чипах обязаны сходиться с тем,
  /// что покажет нажатие, иначе «Свободные · 3» открывали бы пять строк.
  ///
  /// Группа разрешается здесь один раз — чипы и список смотрят на одно и то же
  /// значение, иначе счётчик чипа и число строк разъедутся на переходе. Выбранная,
  /// но опустевшая (решение по последней в «Решить») не держится: её чип уже скрыт,
  /// а пустой экран под ним объяснял бы место или фильтры.
  TaskListSlice apply(List<TaskView> tasks, String query) {
    final filtered = tasks
        .where((v) =>
            matchesQuery(v, query) && _matchesStatus(v) && _matchesPriority(v))
        .where(filter.matches)
        .toList();
    final counts = {for (final g in TaskGroup.values) g: 0};
    for (final v in filtered) {
      counts[v.group] = counts[v.group]! + 1;
    }
    final c = chosen;
    final group = c != null && counts[c]! > 0
        ? c
        : TaskGroup.values.where((g) => counts[g]! > 0).firstOrNull;
    return TaskListSlice(filtered, counts, group);
  }

  /// Строки выбранной группы в порядке разбора (#36915): выбранный компаратор,
  /// добитый исходным индексом, — sort() нестабилен, а равные (обе без срока, один
  /// приоритет) должны стоять как стояли, то есть маршрутным порядком списка.
  /// «Выполненные»: «По умолчанию» — закрытиями сверху (архив читают как «что я
  /// сделал недавно»), ручная же сортировка применяется и к архиву — равные при ней
  /// добиваются датой закрытия.
  List<TaskView> rows(TaskListSlice slice) {
    final group = slice.group;
    if (group == null) return const [];
    final items = group.applyTo(slice.filtered);
    List<TaskView> apply(int Function(TaskView, TaskView) cmp) {
      final order = {for (var i = 0; i < items.length; i++) items[i]: i};
      return [...items]..sort((a, b) {
          final c = cmp(a, b);
          return c != 0 ? c : order[a]!.compareTo(order[b]!);
        });
    }

    final manual = sort.comparator;
    if (group != TaskGroup.done) {
      return manual == null ? items : apply(manual);
    }
    return manual == null
        ? apply(_closedFirst)
        : apply((a, b) {
            final c = manual(a, b);
            return c != 0 ? c : _closedFirst(a, b);
          });
  }

  /// Свежие закрытия сверху; без момента закрытия (старая строка) — в конец.
  static int _closedFirst(TaskView a, TaskView b) {
    final da = a.task.closedAtDate, db = b.task.closedAtDate;
    if (da == null && db == null) return 0;
    if (da == null) return 1;
    if (db == null) return -1;
    return db.compareTo(da);
  }

  /// Варианты шторки «Сортировка и фильтры» со счётчиками — по тому же отбору, что и
  /// «Найдено» ([apply]): фильтр плитки, поиск [query] и выбор в соседнем блоке
  /// (статусы считаются среди выбранных приоритетов, приоритеты — среди выбранных
  /// статусов). Тогда без выбранного статуса сумма по статусам равна «Найдено», а с
  /// выбранными «Найдено» — сумма выбранных.
  ///
  /// Варианта, под который ничего не попадает, нет — это вопрос без ответа, — кроме уже
  /// выбранного: его надо видеть, чтобы снять. Имена — из всех [tasks]: выбранный вариант
  /// мог выпасть из отбора. Статусы — эффективные (очередь поверх сервера), в порядке
  /// справочника [statusById]; приоритеты — по рангу.
  TaskListOptions options(List<TaskView> tasks, String query,
      TaskStatus? Function(String id) statusById) {
    final base = tasks
        .where((v) => matchesQuery(v, query) && filter.matches(v))
        .toList();

    final statusNames = <String, String>{};
    for (final v in tasks) {
      final id = v.statusId;
      if (id != null) statusNames[id] = statusById(id)?.name ?? v.statusName ?? id;
    }
    final statusCounts = {for (final id in statusIds) id: 0};
    for (final v in base.where(_matchesPriority)) {
      final id = v.statusId;
      if (id != null) statusCounts[id] = (statusCounts[id] ?? 0) + 1;
    }
    String statusName(String id) => statusNames[id] ?? statusById(id)?.name ?? id;
    int statusOrder(String id) => statusById(id)?.sortingOrder ?? 1 << 20;
    final statusKeys = [...statusCounts.keys]..sort((a, b) {
        final c = statusOrder(a).compareTo(statusOrder(b));
        return c != 0 ? c : statusName(a).compareTo(statusName(b));
      });

    final prioNames = <String, String>{};
    for (final v in tasks) {
      final key = v.task.priorityId;
      if (key != null) prioNames[key] = v.task.priority ?? key;
    }
    final prioCounts = {for (final key in priorityKeys) key: 0};
    for (final v in base.where(_matchesStatus)) {
      final key = v.task.priorityId;
      if (key != null) prioCounts[key] = (prioCounts[key] ?? 0) + 1;
    }
    int prioRank(String key) => Task(id: '', priorityId: key).priorityRank;
    final prioKeys = [...prioCounts.keys]..sort((a, b) {
        final c = prioRank(a).compareTo(prioRank(b));
        return c != 0 ? c : (prioNames[a] ?? a).compareTo(prioNames[b] ?? b);
      });
    return TaskListOptions(
      statuses: [
        for (final id in statusKeys)
          (key: id, label: '${statusName(id)} · ${statusCounts[id]}'),
      ],
      priorities: [
        for (final key in prioKeys)
          (key: key, label: '${prioNames[key] ?? key} · ${prioCounts[key]}'),
      ],
    );
  }
}

/// Итог разбора: отфильтрованные задачи всех групп, счётчики чипов и группа, которую
/// показывать (null — показывать нечего).
class TaskListSlice {
  final List<TaskView> filtered;
  final Map<TaskGroup, int> counts;
  final TaskGroup? group;
  const TaskListSlice(this.filtered, this.counts, this.group);
}

/// Варианты фильтров шторки: ключ и подпись «Название · число».
class TaskListOptions {
  final List<({String key, String label})> statuses;
  final List<({String key, String label})> priorities;
  const TaskListOptions({required this.statuses, required this.priorities});
}

extension TaskGroupFilter on TaskGroup {
  /// Задачи этой группы из уже отфильтрованного списка.
  List<TaskView> applyTo(List<TaskView> filtered) =>
      filtered.where((v) => v.group == this).toList();
}
