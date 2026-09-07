import 'dart:convert';

import 'package:http/http.dart' as http;

import 'session.dart';
import 'settings.dart';

export 'api/comment_api.dart';
export 'api/fill_api.dart';
export 'api/home_api.dart';
export 'api/simple_api.dart';
export 'api/task_api.dart';

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
///
/// Здесь — транспорт и вход; сами ручки лежат по областям расширениями в api/
/// (задачи, главная, бланк, поручение, переписка) и экспортируются отсюда, так что
/// вызов остаётся `api.fetchTasks(...)`, а файл — про одну область.
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

  Uri exec(String action, [Map<String, String>? params]) {
    final uri = Uri.parse('$_base/exec/StoreTask.$action');
    return params == null ? uri : uri.replace(queryParameters: params);
  }

  // --- authentication ---

  /// Step one of signing in: the platform issues a JWT (a day's lifetime by default) for
  /// these credentials. The only request that carries Basic.
  ///
  /// The action belongs to the platform's own `Authentication` namespace, so the path is
  /// spelled out here instead of going through [exec]. It answers with the bare token
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
    check(r);
    final token = utf8.decode(r.bodyBytes, allowMalformed: true).trim();
    if (token.isEmpty) throw ApiException('Сервер не выдал токен');
    return token;
  }

  /// Step two: whose token this is. HTTP 403 means the account is not linked to a
  /// performer — the app has no tasks to show such a user and says so plainly.
  Future<Map<String, dynamic>?> fetchCurrentUser() async {
    final r = await get(exec('apiCurrentUser'));
    final list = decodeList(r.bodyBytes);
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
  ///
  /// [accept] — статусы, которые для вызывающего не ошибка, а ответ по существу
  /// (409 взятия несёт, кто успел раньше): такие возвращаются как есть, с телом.
  Future<http.Response> _send(
      Future<http.Response> Function(Map<String, String> headers) run,
      {Set<int> accept = const {}}) async {
    var r = await run(_headers);
    if (r.statusCode == 401 && session.isActive) {
      if (await _reissueToken()) r = await run(_headers);
      if (r.statusCode == 401) {
        await session.clear();
        onSessionLost?.call();
        throw SessionExpiredException();
      }
    }
    if (!accept.contains(r.statusCode)) check(r);
    await session.touch();
    return r;
  }

  Future<http.Response> get(Uri uri,
          {Duration timeout = const Duration(seconds: 20)}) =>
      _send((h) => _http.get(uri, headers: h).timeout(timeout));

  /// POST a mutation with its arguments as a JSON object in the request body.
  /// Fields whose value is null are dropped by the callers, so the server-side
  /// IMPORT JSON leaves the corresponding local NULL. Numbers are sent natively
  /// (not stringified) so INTEGER/NUMERIC parameters bind correctly.
  Future<http.Response> postJson(String action, Map<String, dynamic> body,
      {Duration timeout = const Duration(seconds: 20),
      Set<int> accept = const {}}) async {
    final uri = exec(action);
    return _send(
        (h) => _http
            .post(
              uri,
              headers: {...h, 'Content-Type': 'application/json'},
              body: jsonEncode(body),
            )
            .timeout(timeout),
        accept: accept);
  }

  /// GET, тело которого кладётся в кэш как есть.
  Future<String> getRaw(Uri uri) async {
    final r = await get(uri);
    return utf8.decode(r.bodyBytes, allowMalformed: true).trim();
  }

  void check(http.Response r) {
    if (r.statusCode < 200 || r.statusCode >= 300) {
      final body = utf8.decode(r.bodyBytes, allowMalformed: true).trim();
      // Сообщение, написанное сервером для человека, показывается как есть; если из
      // тела ничего внятного не достаётся, остаётся прежняя форма с кодом — «HTTP 500»
      // без текста хотя бы говорит, что это отказ сервера, а не обрыв связи.
      final human = humanError(body);
      throw ApiException(
          human.isNotEmpty && human != body
              ? human
              : 'HTTP ${r.statusCode}${body.isEmpty ? '' : ': $body'}',
          status: r.statusCode);
    }
  }

  /// Человеческая часть отказа сервера. Тело ошибки lsFusion — это Java-исключение
  /// целиком: класс, обёртка «Внутренняя ошибка сервера», стек в полсотни строк — а
  /// написана для человека в нём ровно одна строка: сообщение констрейнта или
  /// throwException. Её и показываем: «если сервер отказал, приложение показывает
  /// причину» (#36872) означает причину, которую можно прочесть, а не стек, в котором
  /// она утоплена.
  ///
  /// Ничего не узнав, возвращаем тело как есть (обрезанное): непонятный отказ лучше
  /// показать сырым, чем проглотить.
  static String humanError(String body) {
    if (body.isEmpty) return '';
    // Отказ ручки — компактный JSON {error, message}: человеку показывается message,
    // код error остаётся машине (по нему клиент различает alreadyTaken/notPerformer).
    // Разбор идёт первым: в таком теле нет ни имени класса исключения, ни стека, и
    // разбор ниже вернул бы его целиком — вместе с фигурными скобками и кодом.
    if (body.startsWith('{')) {
      try {
        final j = json.decode(body);
        if (j is Map && j['message'] is String && (j['message'] as String).isNotEmpty) {
          return j['message'] as String;
        }
      } catch (_) {
        // не JSON, хотя начинается со скобки — разбираем как текст исключения
      }
    }
    var s = body;
    // сообщение идёт после имени класса исключения — берём хвост последнего
    for (final marker in const ['LSFException ', 'Exception: ', 'Exception ']) {
      final i = s.lastIndexOf(marker);
      if (i >= 0) {
        s = s.substring(i + marker.length);
        break;
      }
    }
    // и обрывается стеком, разделителем подробностей констрейнта или переводом строки
    for (final stop in const ['\n', '\r', '\tat ', ' at lsfusion', '-----']) {
      final i = s.indexOf(stop);
      if (i > 0) s = s.substring(0, i);
    }
    s = s.trim();
    if (s.isEmpty) s = body;
    return s.length > 300 ? '${s.substring(0, 300)}…' : s;
  }

  /// lsFusion returns a top-level JSON array; an empty result may come back as
  /// an empty body (Content-Type application/null). Be tolerant of both, and of
  /// an accidental single-object or {data:[...]} wrapper.
  List<Map<String, dynamic>> decodeList(List<int> bodyBytes) {
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
