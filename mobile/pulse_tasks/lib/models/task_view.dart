// Как список задач выглядит с телефона: строка с наложенной очередью ([TaskView]),
// её группа, фильтры-двойники плиток главной, сортировка и сохранённый разбор списка.
// Только значения и правила над ними — без базы и сети; репозиторий их собирает,
// экраны рисуют.

import 'task.dart';

/// Группы списка задач (#36836). Порядок объявления — порядок на экране: сверху то,
/// ради чего человек открыл приложение; «взяты коллегами» сворачиваются, но не
/// исчезают — задача, пропавшая из списка без объяснения, читается как потеря данных.
/// «Поставленные мной» (#36844) — задачи, где я автор, но не исполнитель: они в
/// списке ради переписки с исполнителем и только для чтения, поэтому внизу.
/// «Наблюдаю» (#37135) — там же и по той же причине: подписка даёт читать переписку и
/// получать уведомления, а не работать. Своя группа, а не «Мои»: плитки главной считают
/// mine() на сервере, и наблюдаемая задача в «Моих» развела бы цифру со списком (#36751).
enum TaskGroup {
  mine('Мои'),
  free('Свободные'),
  taken('Взяты коллегами'),
  authored('Поставленные мной'),
  watched('Наблюдаю');

  final String title;
  const TaskGroup(this.title);
}

/// A task as shown in the UI: the cached server snapshot plus the *effective*
/// status (an unsynced outbox change overrides the server status) and a flag
/// telling whether a change is still pending sync.
class TaskView {
  final Task task;
  final String? statusId; // effective
  final String? statusName; // effective
  final bool pending;

  /// Effective closedness — the outbox status wins here too, so a task the worker has
  /// just marked done stops counting as overdue before the server has heard about it.
  final bool closed;

  /// Завершена на телефоне, но finish ещё в очереди. Отдельно от [closed]: closed
  /// бывает и от смены статуса, которую человек вправе передумать, а по этой метке
  /// экран задачи гасит переключатель статусов — статус не должен обгонять финиш.
  final bool locallyFinished;

  /// Кто держит задачу — серверный ответ с наложенной очередью взятий: пока моё
  /// взятие не подтверждено, здесь уже я; пока не уехало снятие — уже никто.
  final String? takenById;
  final String? takenBy;
  final String? takenAt;

  /// Кнопка «Взять». Право считает только сервер (canTake из apiTasks) — здесь оно
  /// лишь гасится локальными оговорками: очередь по задаче, локально закрытая.
  final bool canTake;

  /// Взятие в очереди и сервером ещё не подтверждено — строка несёт явную пометку
  /// «ожидает подтверждения»: за эту задачу ещё могут поспорить.
  final bool takePending;

  /// «Снять с себя» имеет смысл: задача взята мной (или взятие ещё в очереди).
  final bool releasable;

  /// Задача другого объекта — видна, но только для чтения (#36837): исполнитель с
  /// обязательной геолокацией не может начать выполнение, заполнять бланк, завершать
  /// и менять статус, пока не стоит на объекте задачи. Всё, что работой не является
  /// (карточка, история, взятие на себя), остаётся доступным.
  ///
  /// Решает телефон, а не сервер, — сравнением объекта задачи с [Place.objectId]:
  /// положение меняется между синхронизациями, и серверный вердикт протух бы в
  /// кармане по дороге. Пока объект не определён, чужое всё: показать «можно всюду»
  /// значило бы снять гео-гейт первым же сбоем GPS.
  final bool elsewhere;

  /// Я автор, но не исполнитель (#36844): задача приехала ради переписки, и работа по
  /// ней — заполнение, статус, взятие — на этом телефоне недоступна (сервер такие
  /// вызовы и так отвергает). См. Task.authoredOnly.
  final bool authoredOnly;

  /// Я только наблюдатель (#37135). См. Task.watchedOnly.
  final bool watchedOnly;

  /// Переписка (#36844): сколько сообщений в ленте и сколько не прочитано — бейдж на
  /// карточке. Серверные числа, поправленные тем, что знает телефон: прочитанным
  /// офлайн и написанным, но не отправленным (TaskRepository._commentCounts).
  final int commentCount;
  final int unreadComments;

  final TaskGroup group;

  const TaskView(this.task, this.statusId, this.statusName, this.pending,
      {this.closed = false,
      this.locallyFinished = false,
      this.takenById,
      this.takenBy,
      this.takenAt,
      this.canTake = false,
      this.takePending = false,
      this.releasable = false,
      this.elsewhere = false,
      this.authoredOnly = false,
      this.watchedOnly = false,
      this.commentCount = 0,
      this.unreadComments = 0,
      this.group = TaskGroup.mine});

  String get id => task.id;

  /// Задача приехала ради чтения, а не работы: автор (#36844) или наблюдатель (#37135).
  /// Экран задачи гасит по нему бланк, статус и взятие — причина разная, запрет один, и
  /// сервер обе эти попытки и так отвергает.
  bool get readOnly => authoredOnly || watchedOnly;

  /// Past its deadline and still open. A closed task is never overdue — the deadline
  /// stopped mattering the moment the work was done.
  ///
  /// Сравнивает даты сервер (#36944): «сегодня» у плиток главной и «сегодня» у списка
  /// обязаны быть одним днём, а у телефона он свой — часовой пояс, сдвинутые руками
  /// часы, полночь, наступившая раньше или позже серверной. Признак приезжает в строке
  /// и кэшируется вместе с ней, поэтому в самолётном режиме фильтр работает по
  /// последнему известному ответу, а не отключается.
  ///
  /// Локальная закрытость проверяется ДО серверного признака и остаётся выше него:
  /// про завершение, которое ещё лежит в очереди, сервер не знает, а строка «Завершена
  /// — не отправлена» не должна продолжать краснеть.
  ///
  /// Признака нет (старый сервер или задача, рождённая на телефоне) — считаем
  /// по-прежнему от даты устройства, ровно как с executionKind: обновлять сервер и
  /// приложение можно порознь.
  bool get overdue {
    if (closed) return false;
    final flag = task.overdue;
    if (flag != null) return flag;
    final d = task.deadlineDate;
    if (d == null) return false;
    final now = DateTime.now();
    return d.isBefore(DateTime(now.year, now.month, now.day));
  }

  /// Срок — сегодня. Источник даты и правила отката — те же, что у [overdue].
  bool get dueToday {
    if (closed) return false;
    final flag = task.dueToday;
    if (flag != null) return flag;
    final d = task.deadlineDate;
    if (d == null) return false;
    final now = DateTime.now();
    return d == DateTime(now.year, now.month, now.day);
  }
}

/// The task lists the home screen can drill into. Mirrors HomeTaskFilter on the server;
/// an unknown value falls back to «all», because a newer server offering a filter this
/// build does not know is not a reason to show nothing.
/// «Выполненные» is deliberately absent: `apiTasks` only ever sends open tasks, so such
/// a filter would always show an empty list.
enum TaskFilter {
  all('Все задачи'),
  open('Открытые'),
  today('На сегодня'),
  overdue('Просроченные');

  final String title;
  const TaskFilter(this.title);

  static TaskFilter parse(String? code) => switch (code) {
        'open' => TaskFilter.open,
        'today' => TaskFilter.today,
        'overdue' => TaskFilter.overdue,
        _ => TaskFilter.all,
      };

  /// Три фильтра из четырёх — двойники плиток главной, и тап по плитке открывает
  /// именно их. Плитка считает «мои» (HomeScreen.lsf: myOpen / myToday / myOverdue от
  /// mine(Task, User)) — значит и фильтр обязан считать «мои», иначе просроченная
  /// задача свободного пула снова разводит цифру на плитке со списком, который она
  /// открывает (#36944, продолжение #36751). «Все задачи» — единственный чип без
  /// плитки-двойника: он показывает список целиком, всеми группами, и через него
  /// видно то, что остальные три прячут.
  bool matches(TaskView v) => switch (this) {
        TaskFilter.all => true,
        TaskFilter.open => v.group == TaskGroup.mine && !v.closed,
        TaskFilter.today => v.group == TaskGroup.mine && v.dueToday,
        TaskFilter.overdue => v.group == TaskGroup.mine && v.overdue,
      };
}

/// Порядок списка (#36915). [route] — прежний «маршрутный» порядок (#36837): задачи
/// объекта, где человек стоит, — сверху, чужие — ниже по расстоянию. Явная сортировка
/// его перекрывает: попросивший «по сроку» спрашивает о сроках всего списка, а не
/// маршрута. Группы (#36836) сортировка не ломает — порядок наводится внутри каждой.
enum TaskSort {
  route('По умолчанию'),
  deadline('По сроку'),
  priority('По приоритету'),
  created('По дате создания');

  final String title;
  const TaskSort(this.title);

  static TaskSort parse(String? code) => switch (code) {
        'deadline' => TaskSort.deadline,
        'priority' => TaskSort.priority,
        'created' => TaskSort.created,
        _ => TaskSort.route,
      };

  /// Чем упорядочивается группа; null — маршрутный порядок, наведённый _reload.
  /// «Просроченные первыми» у сортировки по сроку выходит сам собой: их даты — самые
  /// ранние. Задачи без срока (приоритета, даты) — в конец: сортировать их нечем.
  /// Равные остаются как были — компаратор дополняется исходным индексом в _sorted.
  int Function(TaskView, TaskView)? get comparator => switch (this) {
        TaskSort.route => null,
        TaskSort.deadline =>
          (a, b) => _nullsLast(a.task.deadlineDate, b.task.deadlineDate),
        TaskSort.priority =>
          (a, b) => a.task.priorityRank.compareTo(b.task.priorityRank),
        // новые первыми: «что мне добавили» — вопрос, ради которого так сортируют
        TaskSort.created => (a, b) => _nullsLast(
            _when(a.task.postedAt), _when(b.task.postedAt),
            descending: true),
      };

  static DateTime? _when(String? iso) =>
      iso == null ? null : DateTime.tryParse(iso);

  static int _nullsLast<T extends Comparable<T>>(T? a, T? b,
      {bool descending = false}) {
    if (a == null) return b == null ? 0 : 1;
    if (b == null) return -1;
    final c = a.compareTo(b);
    return descending ? -c : c;
  }
}

/// Как человек разобрал свой список (#36915): чип, отобранные статусы и приоритеты,
/// сортировка. Рабочая настройка, а не разовый ввод — хранится в базе пользователя
/// (CacheDao.saveListPrefs) и переживает перезапуск; текст поиска сюда не входит:
/// поиск — вопрос момента.
class ListPrefs {
  final TaskFilter chip;
  final TaskSort sort;
  final Set<String> statusIds;
  final Set<String> priorityKeys; // Task.priorityKey отобранных приоритетов

  const ListPrefs({
    this.chip = TaskFilter.all,
    this.sort = TaskSort.route,
    this.statusIds = const {},
    this.priorityKeys = const {},
  });

  Map<String, dynamic> toJson() => {
        'chip': chip.name,
        'sort': sort.name,
        'statusIds': [...statusIds],
        'priorityKeys': [...priorityKeys],
      };

  /// Терпим к мусору поштучно: parse-методы незнакомое читают как «по умолчанию»,
  /// а не-список — как пустой набор. Ронять список из-за нечитаемой настройки нельзя.
  factory ListPrefs.fromJson(Map<String, dynamic> j) => ListPrefs(
        chip: TaskFilter.parse(j['chip']?.toString()),
        sort: TaskSort.parse(j['sort']?.toString()),
        statusIds: _strings(j['statusIds']),
        priorityKeys: _strings(j['priorityKeys']),
      );

  static Set<String> _strings(Object? v) =>
      v is List ? {for (final s in v) '$s'} : const {};
}
