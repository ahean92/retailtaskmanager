import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/notification.dart';
import '../models/place.dart';
import '../models/task.dart';
import '../models/task_status.dart';
import 'session.dart';
import 'settings.dart';

class ApiException implements Exception {
  final String message;

  /// HTTP status when the server answered at all — the login screen turns 401 and 403
  /// into two different sentences, and the token retry keys off 401.
  final int? status;
  ApiException(this.message, {this.status});
  @override
  String toString() => message;
}

/// The saved credentials no longer buy a token: the password was changed on the server.
/// Separate from [ApiException] because nothing here is retryable — only the person can
/// resolve it, by signing in again.
class SessionExpiredException implements Exception {
  @override
  String toString() => 'Сессия истекла — войдите заново';
}

/// Thin client over the lsFusion HTTP Action API (`/exec/StoreTask.*`).
///
/// Read endpoints are GET with query parameters; mutations are POST with a JSON
/// object in the request body (the server unpacks it with IMPORT JSON — see the
/// FillApi header). Every fillable task (checklist or procedure) is driven by the
/// unified engine: apiStartExecution / apiExecution{Info,Fields,Options} /
/// apiSetField / apiSetFieldPhoto / apiSetResolution / apiFinishExecution, with
/// fields addressed by their stable `code`.
///
/// Authentication is a platform JWT: [fetchAuthToken] trades Basic for a token once, and
/// every other request carries `Authorization: Bearer <token>`. The password therefore
/// leaves the device exactly once per token rather than on every request.
class ApiClient {
  Settings settings;
  final Session session;

  /// Called when the session is dropped mid-work, whichever screen's request ran into it.
  /// Filling in a checklist goes through this client too, and the app has to come back to
  /// the login form from there just the same.
  void Function()? onSessionLost;

  final http.Client _http;

  ApiClient(this.settings, this.session, {http.Client? client})
      : _http = client ?? http.Client();

  Map<String, String> get _headers {
    final h = <String, String>{'Accept': 'application/json'};
    if (session.token.isNotEmpty) {
      h['Authorization'] = 'Bearer ${session.token}';
    }
    return h;
  }

  String get _base => settings.baseUrl.trim().replaceAll(RegExp(r'/+$'), '');

  Uri _exec(String action, [Map<String, String>? params]) {
    final uri = Uri.parse('$_base/exec/StoreTask.$action');
    return params == null ? uri : uri.replace(queryParameters: params);
  }

  // --- authentication ---

  /// Step one of signing in: the platform issues a JWT (a day's lifetime by default) for
  /// these credentials. The only request that carries Basic.
  ///
  /// The action belongs to the platform's own `Authentication` namespace, so the path is
  /// spelled out here instead of going through [_exec]. It answers with the bare token
  /// (`exportText`), not with JSON.
  Future<String> fetchAuthToken(String login, String password) async {
    final r = await _http.get(
      Uri.parse('$_base/exec/Authentication.getAuthToken'),
      headers: {
        'Accept': 'text/plain',
        'Authorization':
            'Basic ${base64Encode(utf8.encode('$login:$password'))}',
      },
    ).timeout(const Duration(seconds: 20));
    _check(r);
    final token = utf8.decode(r.bodyBytes, allowMalformed: true).trim();
    if (token.isEmpty) throw ApiException('Сервер не выдал токен');
    return token;
  }

  /// Step two: whose token this is. HTTP 403 means the account is not linked to a
  /// performer — the app has no tasks to show such a user and says so plainly.
  Future<Map<String, dynamic>?> fetchCurrentUser() async {
    final r = await _get(_exec('apiCurrentUser'));
    final list = _decodeList(r.bodyBytes);
    return list.isEmpty ? null : list.first;
  }

  /// Silently swap an expired token for a fresh one. Returns false only when the server
  /// itself refused the credentials; a network failure propagates, because losing the
  /// signal mid-request must not be read as «the password changed».
  Future<bool> _reissueToken() async {
    try {
      session.token = await fetchAuthToken(session.login, session.password);
      await session.save();
      return true;
    } on ApiException catch (e) {
      if (e.status == 401) return false;
      rethrow;
    }
  }

  /// Runs a request under the current token and, if the server answers 401, once more
  /// under a freshly issued one. The token expires daily and the person must not notice:
  /// a password prompt in the middle of a shift is the failure this prevents.
  Future<http.Response> _send(
      Future<http.Response> Function(Map<String, String> headers) run) async {
    var r = await run(_headers);
    if (r.statusCode == 401 && session.isActive) {
      if (await _reissueToken()) r = await run(_headers);
      if (r.statusCode == 401) {
        await session.clear();
        onSessionLost?.call();
        throw SessionExpiredException();
      }
    }
    _check(r);
    await session.touch();
    return r;
  }

  Future<http.Response> _get(Uri uri,
          {Duration timeout = const Duration(seconds: 20)}) =>
      _send((h) => _http.get(uri, headers: h).timeout(timeout));

  /// POST a mutation with its arguments as a JSON object in the request body.
  /// Fields whose value is null are dropped by the callers, so the server-side
  /// IMPORT JSON leaves the corresponding local NULL. Numbers are sent natively
  /// (not stringified) so INTEGER/NUMERIC parameters bind correctly.
  Future<void> _postJson(String action, Map<String, dynamic> body,
      {Duration timeout = const Duration(seconds: 20)}) async {
    final uri = _exec(action);
    await _send((h) => _http
        .post(
          uri,
          headers: {...h, 'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(timeout));
  }

  /// Fetches the open tasks assigned to the signed-in user. The server filters by
  /// `currentUser()`, so what arrives is already this person's list.
  ///
  /// It narrows by place as well, for everyone the server says works by location: the
  /// tasks of [objectId] when one was picked, of the nearest object otherwise. Passing
  /// nothing is not the same as passing everything — an account that works by location
  /// and states no coordinates stands nowhere, and nowhere has no tasks. A role excused
  /// from geolocation gets its whole list whatever is passed here.
  Future<List<Task>> fetchTasks(
      {double? lat, double? lon, String? objectId}) async {
    final params = {
      if (lat != null) 'lat': '$lat',
      if (lon != null) 'lon': '$lon',
      if (objectId != null && objectId.isNotEmpty) 'objectId': objectId,
    };
    final r = await _get(_exec('apiTasks', params.isEmpty ? null : params));
    return _decodeList(r.bodyBytes).map(Task.fromJson).toList();
  }

  /// Which objects are near a point, nearest first.
  ///
  /// When nothing is inside the server's radius the answer still carries one object — the
  /// nearest there is, with `nearby` absent — so «рядом объектов с координатами нет» and
  /// «до ближайшего 12 км» stay two different answers instead of one empty list. An empty
  /// list therefore means the first of those; an empty *body* (which lsFusion sends when
  /// the coordinates are missing) means neither, and is never asked for here: this is
  /// called with a fix in hand or not at all.
  Future<List<NearbyObject>> fetchNearbyObjects(double lat, double lon) async {
    final r = await _get(
      _exec('apiNearbyObjects', {'lat': '$lat', 'lon': '$lon'}),
      timeout: const Duration(seconds: 15),
    );
    return _decodeList(r.bodyBytes).map(NearbyObject.fromJson).toList();
  }

  /// The customer's branding. Answered without authentication on purpose — the client
  /// asks for it the moment the address is known, before anyone has logged in.
  Future<Map<String, dynamic>?> fetchBrand() async {
    final r = await _get(_exec('apiBrand'), timeout: const Duration(seconds: 10));
    final list = _decodeList(r.bodyBytes);
    return list.isEmpty ? null : list.first;
  }

  /// The home screen for the logged-in user: which blocks, in which order, with their
  /// numbers already computed. One call rather than one per block — the screen is drawn
  /// whole, and a half-arrived home page is not a thing worth rendering.
  Future<Map<String, dynamic>?> fetchHome() async {
    final r = await _get(_exec('apiHome'));
    final list = _decodeList(r.bodyBytes);
    return list.isEmpty ? null : list.first;
  }

  Future<List<TaskStatus>> fetchStatuses() async {
    final r = await _get(_exec('apiStatuses'));
    return _decodeList(r.bodyBytes).map(TaskStatus.fromJson).toList();
  }

  /// Журнал уведомлений вызывающего исполнителя за последние 30 дней (#36717).
  Future<List<NotificationItem>> fetchNotifications() async {
    final r = await _get(_exec('apiNotifications'));
    return _decodeList(r.bodyBytes).map(NotificationItem.fromJson).toList();
  }

  /// Отметить уведомление прочитанным — адресом (событие, задача, дата), тем же,
  /// каким сервер запись дедуплицирует. Идемпотентна: повтор по уже прочитанному —
  /// тот же 200, поэтому пачка на открытие ленты и ретраи безопасны.
  Future<void> markNotificationViewed(
          String event, String? taskId, String date) =>
      _postJson('apiMarkNotificationViewed', {
        'event': event,
        if (taskId != null) 'taskId': taskId,
        'date': date,
      });

  // --- создание в поле: предзагрузка пресетов и справочников (#36713) ---
  // Сырые тела, а не разобранные модели: кэш хранит ответ сервера как есть (см.
  // quick_cache), и парсит его одна и та же QuickCreateData.parse — что для свежего
  // ответа, что для кэша, поднятого без сети.

  Future<String> _getRaw(Uri uri) async {
    final r = await _get(uri);
    return utf8.decode(r.bodyBytes, allowMalformed: true).trim();
  }

  /// Что этому пользователю разрешено создавать. Сервер уже отфильтровал по ролям.
  Future<String> fetchQuickActionsRaw() => _getRaw(_exec('apiQuickActions'));

  /// Шаблоны целиком (поля, варианты, колонки) — только те, на которые ссылается
  /// видимый пресет.
  Future<String> fetchTemplatesRaw() => _getRaw(_exec('apiTemplates'));

  /// Исполнители с их ролями на объектах — только те, у кого роль есть хотя бы где-то.
  Future<String> fetchPerformersRaw() => _getRaw(_exec('apiPerformers'));

  Future<void> setStatus(String id, String statusId) =>
      _postJson('apiSetStatus', {'id': id, 'statusId': statusId});

  /// Создать задачу, рождённую на телефоне (#36716). Тело — отложенный payload из
  /// task_outbox: clientId (UUID, на нём держится идемпотентность повторов), typeId,
  /// objectId, name и опциональные created/deadline/priorityId/description/assigneeId/
  /// templateId/requirePhoto/photo (base64 от автора). Повтор уже созданного clientId —
  /// тот же 200 без тела, поэтому ретраи безопасны.
  /// Тело с base64-фото на канале дальнего магазина не укладывается в общие 20 секунд,
  /// а недоехавший create — барьер, стопорящий всю цепочку задачи: таких телам даётся
  /// время по размеру ноши.
  Future<void> createTask(Map<String, dynamic> body) =>
      _postJson('apiCreateTask', body,
          timeout: body.containsKey('photo')
              ? const Duration(seconds: 120)
              : const Duration(seconds: 20));

  // --- unified fillable engine (checklist + form tasks) ---

  Future<void> startExecution(String taskId) =>
      _postJson('apiStartExecution', {'id': taskId});

  Future<Map<String, dynamic>?> fetchExecutionInfo(String taskId) async {
    final r = await _get(_exec('apiExecutionInfo', {'id': taskId}));
    final list = _decodeList(r.bodyBytes);
    return list.isEmpty ? null : list.first;
  }

  Future<List<Map<String, dynamic>>> fetchExecutionFields(String taskId) async {
    final r = await _get(_exec('apiExecutionFields', {'id': taskId}));
    return _decodeList(r.bodyBytes);
  }

  Future<List<Map<String, dynamic>>> fetchExecutionOptions(
      String taskId) async {
    final r = await _get(_exec('apiExecutionOptions', {'id': taskId}));
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
    final r = await _get(_exec('apiExecutionColumns', {'id': taskId}));
    return _decodeList(r.bodyBytes);
  }

  Future<List<Map<String, dynamic>>> fetchExecutionRows(String taskId) async {
    final r = await _get(_exec('apiExecutionRows', {'id': taskId}));
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
      throw ApiException(
          'HTTP ${r.statusCode}${body.isEmpty ? '' : ': $body'}',
          status: r.statusCode);
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
