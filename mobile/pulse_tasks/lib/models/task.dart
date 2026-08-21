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
  final String? priority;
  final String? assignedTo;
  final String? assigneeId; // id of the assignee, as the server reports it
  final String? deadline; // ISO-ish date string as exported by lsFusion
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

  const Task({
    required this.id,
    this.clientId,
    this.name,
    this.object,
    this.objectId,
    this.distance,
    this.address,
    this.type,
    this.typeId,
    this.status,
    this.statusId,
    this.priority,
    this.assignedTo,
    this.assigneeId,
    this.deadline,
    this.progress,
    this.subtitle,
    this.takenById,
    this.takenBy,
    this.takenAt,
    this.canTake,
    this.mine,
  });

  factory Task.fromJson(Map<String, dynamic> j) => Task(
        id: '${j['id']}',
        clientId: _str(j['clientId']),
        name: _str(j['name']),
        object: _str(j['object']),
        objectId: _str(j['objectId']),
        distance: _toDouble(j['distance']),
        address: _str(j['address']),
        type: _str(j['type']),
        typeId: _str(j['typeId']),
        status: _str(j['status']),
        statusId: _str(j['statusId']),
        priority: _str(j['priority']),
        assignedTo: _str(j['assignedTo']),
        assigneeId: _str(j['assigneeId']),
        deadline: _str(j['deadline']),
        progress: _toInt(j['progress']),
        subtitle: _str(j['subtitle']),
        takenById: _str(j['takenById']),
        takenBy: _str(j['takenBy']),
        takenAt: _str(j['takenAt']),
        canTake: _optFlag(j['canTake']),
        mine: _optFlag(j['mine']),
      );

  /// Row shape for the local sqflite `tasks` table.
  Map<String, Object?> toMap() => {
        'id': id,
        'clientId': clientId,
        'name': name,
        'object': object,
        'objectId': objectId,
        'distance': distance,
        'address': address,
        'type': type,
        'typeId': typeId,
        'status': status,
        'statusId': statusId,
        'priority': priority,
        'assignedTo': assignedTo,
        'assigneeId': assigneeId,
        'deadline': deadline,
        'progress': progress,
        'subtitle': subtitle,
        'takenById': takenById,
        'takenBy': takenBy,
        'takenAt': takenAt,
        // тройственность переживает sqlite: null так и хранится, true/false — 1/0
        'canTake': canTake == null ? null : (canTake! ? 1 : 0),
        'mine': mine == null ? null : (mine! ? 1 : 0),
      };

  factory Task.fromMap(Map<String, Object?> m) => Task(
        id: m['id'] as String,
        clientId: m['clientId'] as String?,
        name: m['name'] as String?,
        object: m['object'] as String?,
        objectId: m['objectId'] as String?,
        distance: (m['distance'] as num?)?.toDouble(),
        address: m['address'] as String?,
        type: m['type'] as String?,
        typeId: m['typeId'] as String?,
        status: m['status'] as String?,
        statusId: m['statusId'] as String?,
        priority: m['priority'] as String?,
        assignedTo: m['assignedTo'] as String?,
        assigneeId: m['assigneeId'] as String?,
        deadline: m['deadline'] as String?,
        progress: m['progress'] as int?,
        subtitle: m['subtitle'] as String?,
        takenById: m['takenById'] as String?,
        takenBy: m['takenBy'] as String?,
        takenAt: m['takenAt'] as String?,
        canTake: m['canTake'] == null ? null : m['canTake'] == 1,
        mine: m['mine'] == null ? null : m['mine'] == 1,
      );

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
