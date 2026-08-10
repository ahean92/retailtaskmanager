/// A store task as delivered by the lsFusion `apiTasks` endpoint and cached
/// locally. Fields mirror the JSON keys exported by `StoreTask.apiTasks`.
/// Nullable fields are simply omitted from the JSON when empty on the server.
class Task {
  final String id; // business id, e.g. "ST000001" — the stable sync key
  final String? name;
  final String? object;
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

  const Task({
    required this.id,
    this.name,
    this.object,
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
  });

  factory Task.fromJson(Map<String, dynamic> j) => Task(
        id: '${j['id']}',
        name: _str(j['name']),
        object: _str(j['object']),
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
      );

  /// Row shape for the local sqflite `tasks` table.
  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'object': object,
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
      };

  factory Task.fromMap(Map<String, Object?> m) => Task(
        id: m['id'] as String,
        name: m['name'] as String?,
        object: m['object'] as String?,
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
      );

  /// The deadline as a date, or null when absent or unparseable. lsFusion exports
  /// `YYYY-MM-DD`; anything else is treated as "no deadline" rather than as an error —
  /// a malformed date must not keep the task off the list.
  DateTime? get deadlineDate {
    final d = deadline;
    if (d == null) return null;
    final parsed = DateTime.tryParse(d);
    return parsed == null ? null : DateTime(parsed.year, parsed.month, parsed.day);
  }

  static String? _str(Object? v) => v == null ? null : '$v';

  static int? _toInt(Object? v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse('$v');
  }
}
