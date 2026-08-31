import 'dart:convert';

import 'fill.dart';
import 'task_file.dart';

/// «120 м», «1,2 км», «12 км». Метры, пока шаг в сотню метров ещё что-то значит для
/// того, кто идёт пешком; дальше километры, и десятые доли в них уже только мешают.
/// Одна на задачу и на объект из apiNearbyObjects: расстояние в шапке и на карточке
/// задачи обязано читаться одинаково.
String formatDistance(double d) {
  if (d < 1000) return '${d.round()} м';
  final km = d / 1000;
  if (km < 10) return '${km.toStringAsFixed(1).replaceAll('.', ',')} км';
  return '${km.round()} км';
}

/// A store task as delivered by the lsFusion `apiTasks` endpoint and cached
/// locally. Fields mirror the JSON keys exported by `StoreTask.apiTasks`.
/// Nullable fields are simply omitted from the JSON when empty on the server.
class Task {
  final String id; // business id, e.g. "ST000001" — the stable sync key

  /// UUID minted by the phone that created this task offline (#36716). For a local,
  /// not-yet-synced row it equals [id]; on a row fetched from the server it is how the
  /// client recognises its own creation and collapses the two into one. NULL for tasks
  /// born in the back office. Fill screens address the task by it when present — the
  /// local fill cache and queues are keyed by the UUID for the task's whole life.
  final String? clientId;
  final String? name;

  /// Что именно не так (#36842) — описание задачи. С сервера приходит уже без разметки
  /// (там оно RICHTEXT, то есть HTML): телефон показывает текст, а не теги.
  final String? description;
  final String? object;

  /// The addressable half of [object]: «задачи магазина, в котором я стою» is a filter,
  /// and a filter cannot be built on a display name. What the list is narrowed by — see
  /// `Place.holds`.
  final String? objectId;

  /// Метры от точки последней синхронизации до объекта задачи — считает сервер при
  /// каждом fetch (#36837). Им сортируются задачи чужих объектов: список должен
  /// читаться как маршрут. Число живёт от синхронизации до синхронизации и офлайн
  /// честно устаревает — это лучшее, что есть у телефона без сети.
  final double? distance;
  final String? address;
  final String? type;
  final String? typeId;
  final String? status; // server-side status name
  final String? statusId; // server-side status id

  /// Чем открывать задачу — решает сервер (#36872): `fill` — бланк, `simple` —
  /// фотоотчёт с комментарием, null — сервер ключа не прислал (старая выдача), и
  /// тогда работает прежний список типов на клиенте (см. [opensFill]). Держать этот
  /// список у себя значило требовать релиз приложения на каждый новый тип задачи —
  /// «Поручение» приложение умело создавать и не умело закрывать именно поэтому.
  final String? executionKind;

  /// Фото выполнения обязательно (#36872): кнопка «Выполнено» недоступна, пока снимка
  /// нет. Приезжает вместе с задачей, а не выясняется отказом сервера постфактум —
  /// человек к тому моменту уже ушёл с точки.
  final bool? requirePhoto;
  final String? priority;

  /// Ключ приоритета из справочника (#36915) — то, чем задача сортируется «срочные
  /// первыми»: название заказчик волен переименовать, id остаётся. NULL — приоритета
  /// нет или сервер старый и ключа не шлёт (тогда ранг ищется по названию).
  final String? priorityId;
  final String? assignedTo;
  final String? assigneeId; // id of the assignee, as the server reports it

  /// Кто поставил задачу и когда (#36842): поручение от директора и поручение от
  /// коллеги читаются по-разному, и без этих двух полей карточка не отвечает на
  /// вопрос «чьё это». [postedAt] — дата постановки (`start` на сервере), не путать
  /// с моментом, когда исполнитель физически начал работу (#36838).
  final String? author;
  final String? authorId;
  final String? postedAt;
  final String? deadline; // ISO-ish date string as exported by lsFusion

  /// «На сегодня» и «просрочено» — по СЕРВЕРНОЙ дате (#36944). Раньше телефон выводил
  /// их из [deadline] и DateTime.now(), а плитки главной считались от currentDate()
  /// сервера: часовой пояс, сдвинутые руками часы и полночь разводили список с той
  /// самой плиткой, из которой в него провалились.
  ///
  /// Трёхзначны, как флаги взятия, и по той же причине: null — ключа в ответе не было
  /// (старый сервер или строка, рождённая на телефоне до синхронизации), и тогда
  /// работает прежний локальный расчёт — см. TaskView.overdue. Новый сервер шлёт 0 или
  /// 1 у КАЖДОЙ строки: будь это «есть или нет», задача со сроком в будущем приезжала
  /// бы без ключей, то есть неотличимо от старой выдачи.
  final bool? dueToday;
  final bool? overdue;
  final int? progress;
  final String? subtitle;

  /// Взятие на себя (#36836): кто держит задачу из пула подразделения и можно ли её
  /// взять мне. [canTake] и [mine] считает сервер — оргструктура приложению не видна,
  /// и группировка списка не пересобирает «мою» из [takenById]/[assigneeId] (#36751).
  ///
  /// Флаги трёхзначны, и это несёт смысл: true/false — сервер сказал, null — ключа в
  /// ответе не было. lsFusion не экспортирует NULL, поэтому старый сервер (и строка,
  /// рождённая на телефоне) не присылает НИ ОДНОГО из этих ключей — а новый у любой
  /// открытой задачи присылает хотя бы один. На этой разнице держится совместимость:
  /// строка совсем без ключей — личная задача старой выдачи, то есть «моя».
  final String? takenById;
  final String? takenBy;
  final String? takenAt; // DATETIME as lsFusion exports it
  final bool? canTake;
  final bool? mine;

  /// Участие (#36844): [assigned] — назначена на меня (с иерархией), [authored] — я
  /// автор. Трёхзначны так же, как флаги взятия: null — ключа в ответе не было (старый
  /// сервер или строка, рождённая на телефоне до синхронизации), и такая строка читается
  /// как назначенная. Задача «авторская и только» видна ради переписки: работать по ней
  /// (бланк, статус, взятие) нельзя — см. [authoredOnly].
  final bool? assigned;
  final bool? authored;

  /// Переписка (#36844), по данным сервера на момент fetch: сколько сообщений в ленте и
  /// сколько из них мне не прочитано. Локальная правка поверх (прочитано на телефоне,
  /// ещё не ушло) — в TaskView.
  final int? commentCount;
  final int? unreadComments;

  /// «Было» (#36842): файлы задачи — снимок проблемного участка от автора и всё
  /// прочее, приложенное к самой задаче. Вложения переписки сюда не попадают: их
  /// место — лента (#36844), иначе один снимок показан на карточке дважды. Едут
  /// вместе с задачей и кэшируются с ней, поэтому карточка открывается офлайн; сами
  /// байты качаются по требованию, миниатюрами.
  final List<TaskFileRef> files;

  /// «Стало» (#36842): выполнения задачи — кто работал, когда, с каким результатом
  /// и со снимком результата.
  final List<TaskExecution> executions;

  const Task({
    required this.id,
    this.clientId,
    this.name,
    this.description,
    this.object,
    this.objectId,
    this.distance,
    this.address,
    this.type,
    this.typeId,
    this.status,
    this.statusId,
    this.executionKind,
    this.requirePhoto,
    this.priority,
    this.priorityId,
    this.assignedTo,
    this.assigneeId,
    this.author,
    this.authorId,
    this.postedAt,
    this.deadline,
    this.dueToday,
    this.overdue,
    this.progress,
    this.subtitle,
    this.takenById,
    this.takenBy,
    this.takenAt,
    this.canTake,
    this.mine,
    this.assigned,
    this.authored,
    this.commentCount,
    this.unreadComments,
    this.files = const [],
    this.executions = const [],
  });

  factory Task.fromJson(Map<String, dynamic> j) => Task(
        id: '${j['id']}',
        clientId: _str(j['clientId']),
        name: _str(j['name']),
        description: _str(j['description']),
        object: _str(j['object']),
        objectId: _str(j['objectId']),
        distance: _toDouble(j['distance']),
        address: _str(j['address']),
        type: _str(j['type']),
        typeId: _str(j['typeId']),
        status: _str(j['status']),
        statusId: _str(j['statusId']),
        executionKind: _str(j['executionKind']),
        requirePhoto: _optFlag(j['requirePhoto']),
        priority: _str(j['priority']),
        priorityId: _str(j['priorityId']),
        assignedTo: _str(j['assignedTo']),
        assigneeId: _str(j['assigneeId']),
        author: _str(j['author']),
        authorId: _str(j['authorId']),
        postedAt: _str(j['postedAt']),
        deadline: _str(j['deadline']),
        dueToday: _optFlag(j['dueToday']),
        overdue: _optFlag(j['overdue']),
        progress: _toInt(j['progress']),
        subtitle: _str(j['subtitle']),
        takenById: _str(j['takenById']),
        takenBy: _str(j['takenBy']),
        takenAt: _str(j['takenAt']),
        canTake: _optFlag(j['canTake']),
        mine: _optFlag(j['mine']),
        assigned: _optFlag(j['assigned']),
        authored: _optFlag(j['authored']),
        commentCount: _toInt(j['commentCount']),
        unreadComments: _toInt(j['unreadComments']),
        files: TaskFileRef.listFrom(j['files']),
        executions: TaskExecution.listFrom(j['executions']),
      );

  /// Row shape for the local sqflite `tasks` table.
  Map<String, Object?> toMap() => {
        'id': id,
        'clientId': clientId,
        'name': name,
        'description': description,
        'object': object,
        'objectId': objectId,
        'distance': distance,
        'address': address,
        'type': type,
        'typeId': typeId,
        'status': status,
        'statusId': statusId,
        'executionKind': executionKind,
        'requirePhoto': requirePhoto == null ? null : (requirePhoto! ? 1 : 0),
        'priority': priority,
        'priorityId': priorityId,
        'assignedTo': assignedTo,
        'assigneeId': assigneeId,
        'author': author,
        'authorId': authorId,
        'postedAt': postedAt,
        'deadline': deadline,
        // трёхзначность переживает sqlite так же, как у флагов взятия: null остаётся
        // null, и офлайн-строка старого сервера не притворяется «не просроченной»
        'dueToday': dueToday == null ? null : (dueToday! ? 1 : 0),
        'overdue': overdue == null ? null : (overdue! ? 1 : 0),
        'progress': progress,
        'subtitle': subtitle,
        'takenById': takenById,
        'takenBy': takenBy,
        'takenAt': takenAt,
        // тройственность переживает sqlite: null так и хранится, true/false — 1/0
        'canTake': canTake == null ? null : (canTake! ? 1 : 0),
        'mine': mine == null ? null : (mine! ? 1 : 0),
        'assigned': assigned == null ? null : (assigned! ? 1 : 0),
        'authored': authored == null ? null : (authored! ? 1 : 0),
        'commentCount': commentCount,
        'unreadComments': unreadComments,
        // Списками в JSON-колонке, а не отдельными таблицами: строки читаются и
        // пишутся только целиком вместе с задачей (replaceTasks), и своей жизни у них
        // нет — тот же приём, что у columnsJson/rowsJson бланка. Пустой список
        // хранится пустым JSON, а не NULL: «файлов нет» и «сервер их не присылал» на
        // экране выглядят одинаково, и различать их незачем.
        'filesJson': jsonEncode([for (final f in files) f.toJson()]),
        'executionsJson': jsonEncode([for (final e in executions) e.toJson()]),
      };

  factory Task.fromMap(Map<String, Object?> m) => Task(
        id: m['id'] as String,
        clientId: m['clientId'] as String?,
        name: m['name'] as String?,
        description: m['description'] as String?,
        object: m['object'] as String?,
        objectId: m['objectId'] as String?,
        distance: (m['distance'] as num?)?.toDouble(),
        address: m['address'] as String?,
        type: m['type'] as String?,
        typeId: m['typeId'] as String?,
        status: m['status'] as String?,
        statusId: m['statusId'] as String?,
        executionKind: m['executionKind'] as String?,
        requirePhoto:
            m['requirePhoto'] == null ? null : m['requirePhoto'] == 1,
        priority: m['priority'] as String?,
        priorityId: m['priorityId'] as String?,
        assignedTo: m['assignedTo'] as String?,
        assigneeId: m['assigneeId'] as String?,
        author: m['author'] as String?,
        authorId: m['authorId'] as String?,
        postedAt: m['postedAt'] as String?,
        deadline: m['deadline'] as String?,
        dueToday: m['dueToday'] == null ? null : m['dueToday'] == 1,
        overdue: m['overdue'] == null ? null : m['overdue'] == 1,
        progress: m['progress'] as int?,
        subtitle: m['subtitle'] as String?,
        takenById: m['takenById'] as String?,
        takenBy: m['takenBy'] as String?,
        takenAt: m['takenAt'] as String?,
        canTake: m['canTake'] == null ? null : m['canTake'] == 1,
        mine: m['mine'] == null ? null : m['mine'] == 1,
        assigned: m['assigned'] == null ? null : m['assigned'] == 1,
        authored: m['authored'] == null ? null : m['authored'] == 1,
        commentCount: m['commentCount'] as int?,
        unreadComments: m['unreadComments'] as int?,
        files: TaskFileRef.listFrom(m['filesJson']),
        executions: TaskExecution.listFrom(m['executionsJson']),
      );

  /// Я автор, но не исполнитель (#36844): задача приехала ради переписки, и работа по
  /// ней — заполнение, статус, взятие — на этом телефоне недоступна; сервер такие
  /// вызовы и так отвергает. Строка без ключей участия — назначенная, как раньше.
  bool get authoredOnly => authored == true && assigned != true;

  /// Открывается бланком. Сервер сказал — верим ему; не сказал (старая выдача или
  /// строка, рождённая на телефоне до синхронизации) — падаем на прежний список
  /// типов, ровно то поведение, что было до #36872. Не наоборот: список на клиенте
  /// не знает про типы, добавленные после его релиза, а сервер знает про все.
  bool get opensFill => executionKind == null
      ? fillableTypeIds.contains(typeId)
      : executionKind == 'fill';

  /// Открывается простым выполнением — фотоотчёт с комментарием (#36872). Только по
  /// слову сервера: прежний клиент про этот вид не знал, и угадывать его по typeId
  /// значило бы вернуть тот самый захардкоженный список.
  bool get opensSimple => executionKind == 'simple';

  /// The deadline as a date, or null when absent or unparseable. lsFusion exports
  /// `YYYY-MM-DD`; anything else is treated as "no deadline" rather than as an error —
  /// a malformed date must not keep the task off the list.
  DateTime? get deadlineDate {
    final d = deadline;
    if (d == null) return null;
    final parsed = DateTime.tryParse(d);
    return parsed == null
        ? null
        : DateTime(parsed.year, parsed.month, parsed.day);
  }

  /// Расстояние до объекта — для карточки; null, когда сервер его не прислал
  /// (объект без координат или fetch без координат телефона).
  String? get distanceText => distance == null ? null : formatDistance(distance!);

  /// Чем задача считается в фильтре по приоритету (#36915): id справочника, пока
  /// сервер его шлёт, иначе название — у старого сервера другого ключа нет.
  String? get priorityKey => priorityId ?? priority;

  /// Ранг для сортировки «срочные первыми» (#36915). Четыре приоритета сида
  /// (StoreTaskInitial) ранжированы по id; старый сервер id не шлёт — те же четыре
  /// ищутся по названию. Незнакомый приоритет встаёт после известных, но раньше
  /// задач вовсе без приоритета: заказчикский «особый» всё же срочнее, чем ничего.
  int get priorityRank {
    const byId = {'urgent': 0, 'high': 1, 'normal': 2, 'low': 3};
    const byName = {'срочный': 0, 'высокий': 1, 'обычный': 2, 'низкий': 3};
    final id = priorityId;
    if (id != null) return byId[id] ?? 4;
    final name = priority;
    if (name != null) return byName[name.toLowerCase()] ?? 4;
    return 5;
  }

  static String? _str(Object? v) => v == null ? null : '$v';

  static int? _toInt(Object? v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse('$v');
  }

  static double? _toDouble(Object? v) {
    if (v is num) return v.toDouble();
    return double.tryParse('$v'.replaceAll(',', '.'));
  }

  /// Флаг, у которого «нет ключа» — отдельный ответ (см. [canTake]): null остаётся
  /// null, а не схлопывается во false.
  static bool? _optFlag(Object? v) {
    if (v == null) return null;
    if (v is bool) return v;
    if (v is num) return v != 0;
    final s = '$v'.toLowerCase();
    if (s == 'true') return true;
    if (s == 'false') return false;
    return null;
  }
}

/// Отказ `apiTakeTask`/`apiReleaseTask` — не исключение, а ответ по существу:
/// 409 `alreadyTaken` несёт имя и время того, кто успел, 403 — отказ в праве
/// (`notOwner` тоже с текущим владельцем, `notPerformer` — только с текстом).
/// Успех (включая повтор своего же взятия и no-op по закрытой) — null на месте
/// этого объекта.
class TakeRefusal {
  final int status;
  final String? error; // alreadyTaken | notOwner | notPerformer
  final String? takenById;
  final String? takenBy;
  final String? takenAt;
  final String? message;

  const TakeRefusal(this.status,
      {this.error, this.takenById, this.takenBy, this.takenAt, this.message});

  factory TakeRefusal.fromJson(int status, Map<String, dynamic> j) =>
      TakeRefusal(
        status,
        error: Task._str(j['error']),
        takenById: Task._str(j['takenById']),
        takenBy: Task._str(j['takenBy']),
        takenAt: Task._str(j['takenAt']),
        message: Task._str(j['message']),
      );
}
