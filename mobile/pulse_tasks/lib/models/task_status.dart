/// A task status from the lsFusion `apiStatuses` endpoint. `closed` is omitted
/// from the JSON when false (lsFusion BOOLEAN NULL), so absence means "open".
class TaskStatus {
  final String id;
  final String? name;
  final bool closed;
  final int sortingOrder;

  const TaskStatus({
    required this.id,
    this.name,
    this.closed = false,
    this.sortingOrder = 0,
  });

  factory TaskStatus.fromJson(Map<String, dynamic> j) => TaskStatus(
        id: '${j['id']}',
        name: j['name'] == null ? null : '${j['name']}',
        closed: j['closed'] == true,
        sortingOrder: _toInt(j['sortingOrder']) ?? 0,
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'closed': closed ? 1 : 0,
        'sortingOrder': sortingOrder,
      };

  factory TaskStatus.fromMap(Map<String, Object?> m) => TaskStatus(
        id: m['id'] as String,
        name: m['name'] as String?,
        closed: (m['closed'] as int? ?? 0) != 0,
        sortingOrder: m['sortingOrder'] as int? ?? 0,
      );

  static int? _toInt(Object? v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse('$v');
  }
}
