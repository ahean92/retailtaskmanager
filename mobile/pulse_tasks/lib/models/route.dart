import 'dart:convert';

import 'json.dart';

class RouteTask {
  final String id;
  final String name;
  final DateTime? deadline;
  final bool done;

  const RouteTask({
    required this.id,
    required this.name,
    this.deadline,
    this.done = false,
  });

  factory RouteTask.fromJson(Map<String, dynamic> j) => RouteTask(
        id: jsonStr(j['id']) ?? '',
        name: jsonStr(j['name']) ?? '',
        deadline: DateTime.tryParse(jsonStr(j['deadline']) ?? ''),
        done: jsonFlag(j['done']),
      );
}

class RouteStop {
  final String objectId;
  final String name;
  final String? address;
  final double? latitude;
  final double? longitude;
  final bool passed;
  final List<RouteTask> tasks;

  const RouteStop({
    required this.objectId,
    required this.name,
    this.address,
    this.latitude,
    this.longitude,
    this.passed = false,
    this.tasks = const [],
  });

  factory RouteStop.fromJson(Map<String, dynamic> j) => RouteStop(
        objectId: jsonStr(j['objectId']) ?? '',
        name: jsonStr(j['name']) ?? '',
        address: jsonStr(j['address']),
        latitude: jsonNum(j['latitude']),
        longitude: jsonNum(j['longitude']),
        passed: jsonFlag(j['passed']),
        tasks: jsonList(j['tasks'], RouteTask.fromJson),
      );
}

class RoutePlan {
  final String id;
  final DateTime? date;
  final String status;
  final String statusName;
  final int passed;
  final int total;
  final List<RouteStop> stops;

  const RoutePlan({
    required this.id,
    this.date,
    this.status = 'built',
    this.statusName = '',
    this.passed = 0,
    this.total = 0,
    this.stops = const [],
  });

  bool get closed => status == 'closed';

  factory RoutePlan.fromJson(Map<String, dynamic> j) {
    final stops = jsonList(j['stops'], RouteStop.fromJson);
    return RoutePlan(
      id: jsonStr(j['id']) ?? '',
      date: DateTime.tryParse(jsonStr(j['date']) ?? ''),
      status: jsonStr(j['status']) ?? 'built',
      statusName: jsonStr(j['statusName']) ?? '',
      passed: jsonInt(j['passed']) ?? stops.where((s) => s.passed).length,
      total: jsonInt(j['total']) ?? stops.length,
      stops: stops,
    );
  }

  static RoutePlan? parse(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final Object? decoded;
    try {
      decoded = json.decode(raw);
    } on FormatException {
      return null;
    }
    final Object? first =
        decoded is List ? (decoded.isEmpty ? null : decoded.first) : decoded;
    if (first is! Map) return null;
    final plan = RoutePlan.fromJson(first.cast<String, dynamic>());
    return plan.id.isEmpty ? null : plan;
  }

  RoutePlan reordered(List<RouteStop> order) => RoutePlan(
        id: id,
        date: date,
        status: status,
        statusName: statusName,
        passed: passed,
        total: total,
        stops: List.unmodifiable(order),
      );
}
