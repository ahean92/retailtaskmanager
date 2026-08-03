import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/task.dart';
import '../models/task_status.dart';
import 'settings.dart';

class ApiException implements Exception {
  final String message;
  ApiException(this.message);
  @override
  String toString() => message;
}

/// Thin client over the lsFusion HTTP Action API (`/exec/StoreTask.*`).
///
/// Read endpoints are GET with query parameters; mutations are POST with a JSON
/// object in the request body (the server unpacks it with IMPORT JSON — see the
/// FillApi header). Every fillable task (checklist or procedure) is driven by the
/// unified engine: apiStartExecution / apiExecution{Info,Fields,Options} /
/// apiSetField / apiSetFieldPhoto / apiSetResolution / apiFinishExecution, with
/// fields addressed by their stable `code`.
class ApiClient {
  Settings settings;
  final http.Client _http;

  ApiClient(this.settings, {http.Client? client})
      : _http = client ?? http.Client();

  Map<String, String> get _headers {
    final h = <String, String>{'Accept': 'application/json'};
    if (settings.username.isNotEmpty) {
      final token =
          base64Encode(utf8.encode('${settings.username}:${settings.password}'));
      h['Authorization'] = 'Basic $token';
    }
    return h;
  }

  Uri _exec(String action, [Map<String, String>? params]) {
    final base = settings.baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.parse('$base/exec/StoreTask.$action');
    return params == null ? uri : uri.replace(queryParameters: params);
  }

  /// POST a mutation with its arguments as a JSON object in the request body.
  /// Fields whose value is null are dropped by the callers, so the server-side
  /// IMPORT JSON leaves the corresponding local NULL. Numbers are sent natively
  /// (not stringified) so INTEGER/NUMERIC parameters bind correctly.
  Future<void> _postJson(String action, Map<String, dynamic> body) async {
    final r = await _http
        .post(
          _exec(action),
          headers: {..._headers, 'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 20));
    _check(r);
  }

  /// Fetches all open tasks. The endpoint is parameterless by design (see the
  /// server module comment); assignee filtering happens client-side.
  Future<List<Task>> fetchTasks() async {
    final r = await _http
        .get(_exec('apiTasks'), headers: _headers)
        .timeout(const Duration(seconds: 20));
    _check(r);
    return _decodeList(r.bodyBytes).map(Task.fromJson).toList();
  }

  Future<List<TaskStatus>> fetchStatuses() async {
    final r = await _http
        .get(_exec('apiStatuses'), headers: _headers)
        .timeout(const Duration(seconds: 20));
    _check(r);
    return _decodeList(r.bodyBytes).map(TaskStatus.fromJson).toList();
  }

  Future<void> setStatus(String id, String statusId) =>
      _postJson('apiSetStatus', {'id': id, 'statusId': statusId});

  // --- unified fillable engine (checklist + form tasks) ---

  Future<void> startExecution(String taskId) =>
      _postJson('apiStartExecution', {'id': taskId});

  Future<Map<String, dynamic>?> fetchExecutionInfo(String taskId) async {
    final r = await _http
        .get(_exec('apiExecutionInfo', {'id': taskId}), headers: _headers)
        .timeout(const Duration(seconds: 20));
    _check(r);
    final list = _decodeList(r.bodyBytes);
    return list.isEmpty ? null : list.first;
  }

  Future<List<Map<String, dynamic>>> fetchExecutionFields(String taskId) async {
    final r = await _http
        .get(_exec('apiExecutionFields', {'id': taskId}), headers: _headers)
        .timeout(const Duration(seconds: 20));
    _check(r);
    return _decodeList(r.bodyBytes);
  }

  Future<List<Map<String, dynamic>>> fetchExecutionOptions(
      String taskId) async {
    final r = await _http
        .get(_exec('apiExecutionOptions', {'id': taskId}), headers: _headers)
        .timeout(const Duration(seconds: 20));
    _check(r);
    return _decodeList(r.bodyBytes);
  }

  /// Set one field value. Exactly one typed value is normally provided; a comment
  /// may accompany any of them. Numbers/booleans go over natively.
  Future<void> setField(String taskId, String fieldCode,
          {String? optionCode,
          double? number,
          String? text,
          bool? boolVal,
          String? date,
          String? comment}) =>
      _postJson('apiSetField', {
        'id': taskId,
        'field': fieldCode,
        if (optionCode != null) 'optCode': optionCode,
        if (number != null) 'number': number,
        if (text != null) 'text': text,
        if (boolVal != null) 'bool': boolVal,
        if (date != null) 'date': date,
        if (comment != null && comment.isNotEmpty) 'comment': comment,
      });

  // --- table fields ---
  Future<List<Map<String, dynamic>>> fetchExecutionColumns(
      String taskId) async {
    final r = await _http
        .get(_exec('apiExecutionColumns', {'id': taskId}), headers: _headers)
        .timeout(const Duration(seconds: 20));
    _check(r);
    return _decodeList(r.bodyBytes);
  }

  Future<List<Map<String, dynamic>>> fetchExecutionRows(String taskId) async {
    final r = await _http
        .get(_exec('apiExecutionRows', {'id': taskId}), headers: _headers)
        .timeout(const Duration(seconds: 20));
    _check(r);
    return _decodeList(r.bodyBytes);
  }

  /// Set one table cell. One typed value (number or text) per call.
  Future<void> setCell(
          String taskId, String fieldCode, int rowIndex, String colCode,
          {double? number, String? text}) =>
      _postJson('apiSetCell', {
        'id': taskId,
        'field': fieldCode,
        'row': rowIndex,
        'col': colCode,
        if (number != null) 'number': number,
        if (text != null) 'text': text,
      });

  Future<void> setFieldPhoto(
          String taskId, String fieldCode, String? photoBase64) =>
      _postJson('apiSetFieldPhoto', {
        'id': taskId,
        'field': fieldCode,
        if (photoBase64 != null) 'photo': photoBase64,
      });

  Future<void> setResolution(String taskId, String resolution) =>
      _postJson('apiSetResolution', {'id': taskId, 'resolution': resolution});

  Future<void> finishExecution(String taskId) =>
      _postJson('apiFinishExecution', {'id': taskId});

  void _check(http.Response r) {
    if (r.statusCode < 200 || r.statusCode >= 300) {
      final body = utf8.decode(r.bodyBytes, allowMalformed: true).trim();
      throw ApiException('HTTP ${r.statusCode}${body.isEmpty ? '' : ': $body'}');
    }
  }

  /// lsFusion returns a top-level JSON array; an empty result may come back as
  /// an empty body (Content-Type application/null). Be tolerant of both, and of
  /// an accidental single-object or {data:[...]} wrapper.
  List<Map<String, dynamic>> _decodeList(List<int> bodyBytes) {
    final body = utf8.decode(bodyBytes, allowMalformed: true).trim();
    if (body.isEmpty) return const [];
    final decoded = json.decode(body);
    if (decoded is List) {
      return decoded.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
    }
    if (decoded is Map && decoded['data'] is List) {
      return (decoded['data'] as List)
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
    }
    if (decoded is Map<String, dynamic>) return [decoded];
    return const [];
  }

  void close() => _http.close();
}
