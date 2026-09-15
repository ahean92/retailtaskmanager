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
///
/// Тем же кончается подтверждение личности, которое не сошлось (#37178): сервер видит за
/// учётной записью другого исполнителя или никого. И запрос, которому идти не за кого:
/// сессии нет вовсе.
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
/// Без токена к ручкам не уходит ничего: кем считать анонима, решил бы сервер, а стенд в
/// dev-режиме считает его admin (#37178). Исключение одно — бренд ([fetchBrand]): его
/// спрашивают до входа.
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

  /// Личность подтверждена после входа без сети: у сессии снова есть токен, и сервер
  /// назвал за ним того же исполнителя. Учётная запись регистрирует здесь телефон под
  /// пуш — при входе без сети регистрировать его было не под кем.
  void Function()? onIdentityConfirmed;

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

  /// The customer's branding. Answered without authentication on purpose — the client
  /// asks for it the moment the address is known, before anyone has logged in.
  ///
  /// Мимо [_send]: без токена и без отметки контакта. Бренд спрашивает и проверка адреса
  /// в настройках, а адрес там ещё не сохранён и может вести к чужому серверу: токену
  /// вошедшего туда не место, и ответ оттуда не должен продлевать окно входа без сети.
  Future<Map<String, dynamic>?> fetchBrand() async {
    final r = await _http.get(
      exec('apiBrand'),
      headers: const {'Accept': 'application/json'},
    ).timeout(const Duration(seconds: 10));
    check(r);
    final list = decodeList(r.bodyBytes);
    return list.isEmpty ? null : list.first;
  }

  /// Токен, который выписывается прямо сейчас, — один на все запросы, ждущие его.
  Future<void>? _renewing;

  /// A fresh token from the saved credentials, and the server's word that it still
  /// belongs to the same performer. One for every request waiting on it: the requests
  /// that ran into the same expired token, or the first burst after an offline sign-in,
  /// all get their token from a single call.
  ///
  /// Ends one of three ways. The token is saved. The server refused the credentials or
  /// does not see the same performer behind them — the session is dropped
  /// ([_loseSession]). Or there is no network, and that error propagates as it is,
  /// because losing the signal mid-request must not be read as «the password changed».
  Future<void> _renewToken() =>
      _renewing ??= _renew().whenComplete(() => _renewing = null);

  Future<void> _renew() async {
    // без токена сессия бывает только после входа без сети: её личность сервер ещё не
    // подтверждал, и регистрация телефона ждала именно этого
    final unconfirmed = session.token.isEmpty;
    final String token;
    try {
      token = await fetchAuthToken(session.login, session.password);
    } on ApiException catch (e) {
      if (e.status == 401) await _loseSession();
      rethrow;
    }
    // профиль — этим токеном, но мимо _send: он и есть проверка, которой _send ждёт
    final r = await _http.get(
      exec('apiCurrentUser'),
      headers: {
        'Accept': 'application/json',
        'Authorization': 'Bearer $token',
      },
    ).timeout(const Duration(seconds: 20));
    // 403 — учётная запись больше не исполнитель, другой id — сервер связал её с другим
    // человеком: под такой сессией телефон работал бы не за того, кто вошёл
    if (r.statusCode == 401 || r.statusCode == 403) await _loseSession();
    check(r);
    final profile = decodeList(r.bodyBytes);
    final id = profile.isEmpty ? '' : profile.first['id']?.toString() ?? '';
    if (id != session.performerId) await _loseSession();
    // человек успел выйти, пока шла проверка: токен выписан уже не этой сессии
    if (!session.isActive) throw SessionExpiredException();
    session.token = token;
    await session.save();
    await session.touch();
    if (unconfirmed) onIdentityConfirmed?.call();
  }

  /// The server no longer accepts the credentials or the person behind them: the session
  /// goes, and the app comes back to the login form.
  Future<Never> _loseSession() async {
    await session.clear();
    onSessionLost?.call();
    throw SessionExpiredException();
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
    if (session.token.isEmpty) {
      // Запрос без токена уходит анонимным, и кем его счесть, решает сервер: стенд в
      // dev-режиме исполнял его под admin, и телефон молча работал под чужой учёткой
      // (#37178). Токена нет после входа без сети — тогда сначала подтверждается
      // личность, и до этого не уходит ничего: ни очереди, накопленные без сети, ни
      // регистрация телефона. А без сессии запросу идти не за кого.
      if (!session.isActive) throw SessionExpiredException();
      await _renewToken();
    }
    final sent = session.token;
    var r = await run(_headers);
    if (r.statusCode == 401 && session.isActive) {
      // пока запрос шёл, токен мог смениться — тогда его достаточно повторить
      if (session.token == sent) await _renewToken();
      r = await run(_headers);
      if (r.statusCode == 401) await _loseSession();
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
      final raw = utf8.decode(r.bodyBytes, allowMalformed: true).trim();
      // Страница вместо текста — её отдают прокси перед сервером и чужие веб-серверы,
      // не глядя на Accept, — ничего написанного для человека не несёт, а её первая
      // строка («<html>») на экране сыра, как строка исключения: остаётся код.
      // Узнаётся по телу, а не по Content-Type: текст исключения lsFusion приходит
      // тоже как text/html.
      final body = raw.startsWith('<') ? '' : raw;
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
