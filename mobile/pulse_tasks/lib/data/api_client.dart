import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/ai_draft.dart';
import '../models/comment.dart';
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
    if (!accept.contains(r.statusCode)) _check(r);
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
  Future<http.Response> _postJson(String action, Map<String, dynamic> body,
      {Duration timeout = const Duration(seconds: 20),
      Set<int> accept = const {}}) async {
    final uri = _exec(action);
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

  /// Fetches the open tasks assigned to the signed-in user. The server filters by
  /// `currentUser()`, so what arrives is already this person's list.
  ///
  /// Место выдачу НЕ сужает (#36837): сервер отдаёт всё назначенное, а «здесь или не
  /// здесь» телефон решает сам ([TaskView.elsewhere]). Координаты и [objectId] всё же
  /// уезжают: по ним сервер считает `distance` каждой строки и ведёт гео-журнал.
  /// Старый сервер по этим же параметрам ещё фильтрует — про его пустой ответ
  /// «ниоткуда» см. страховку в `TaskRepository.refresh`.
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

  /// Зарегистрировать телефон для пуш-уведомлений (#36720). Владельца сервер берёт из
  /// сессии, а не из тела: параметр «чьё устройство» позволил бы подписать свой телефон
  /// на чужие уведомления. Идемпотентна — клиент шлёт её на каждом запуске.
  Future<void> registerDevice(
          String token, String platform, String appVersion) =>
      _postJson('apiRegisterDevice', {
        'token': token,
        'platform': platform,
        'appVersion': appVersion,
      });

  /// Снять регистрацию — при выходе из аккаунта. Не сделать этого значит отправить
  /// уведомления следующего сотрудника на телефон предыдущего.
  Future<void> unregisterDevice(String token) =>
      _postJson('apiUnregisterDevice', {'token': token});

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

  /// Внешние приложения для секции главной (#36840). Сервер уже отфильтровал по ролям.
  /// Ручка живёт в необязательном модуле (ExternalApp.lsf): сборка без него отвечает
  /// 404, и решать, что это значит для секции, — забота репозитория, не транспорта.
  Future<String> fetchExternalAppsRaw() => _getRaw(_exec('apiExternalApps'));

  // --- постановка задачи текстом (AI) ---

  /// Включён ли AI на этом сервере и какая за ним модель. Спрашивается при
  /// синхронизации: пункт «AI» в меню создания появляется только после «включён» —
  /// на стенде без AI-сервиса человек упирался бы в ошибку вместо ответа.
  Future<AiInfo> fetchAiInfo() async {
    final r = await _get(_exec('apiAiInfo'), timeout: const Duration(seconds: 10));
    final list = _decodeList(r.bodyBytes);
    return list.isEmpty ? const AiInfo() : AiInfo.fromJson(list.first);
  }

  /// Черновик задачи по фразе человека. [dialogId] — ключ разговора: один и тот же во
  /// всех уточнениях и он же станет clientId созданной задачи.
  ///
  /// Время ожидания — своё: за ручкой стоит языковая модель, которая на сервере без
  /// GPU думает секунды, а изредка и полминуты; общие 20 секунд обрывали бы её на
  /// полуслове. Ошибка модели приезжает не статусом, а полем `outcome` в теле — экран
  /// показывает человеку фразу, а не «HTTP 503».
  Future<AiDraft> aiDraft(String dialogId, String text,
      {String? objectId, double? lat, double? lon}) async {
    final r = await _postJson('apiAiDraft', {
      'dialogId': dialogId,
      'text': text,
      if (objectId != null && objectId.isNotEmpty) 'objectId': objectId,
      if (lat != null) 'lat': lat,
      if (lon != null) 'lon': lon,
    }, timeout: const Duration(seconds: 180));
    final list = _decodeList(r.bodyBytes);
    if (list.isEmpty) {
      // пустое тело от lsFusion — «ответить нечем»; для экрана это ошибка, а не «ok»
      return AiDraft(
        dialogId: dialogId,
        outcome: 'error',
        errorCode: 'emptyResponse',
        message: 'Сервер не вернул ответ AI',
      );
    }
    return AiDraft.fromJson(list.first);
  }

  Future<void> setStatus(String id, String statusId) =>
      _postJson('apiSetStatus', {'id': id, 'statusId': statusId});

  // --- взятие задачи из пула подразделения (#36836) ---

  /// Взять задачу на себя. null — принято (в том числе повтор своего же взятия и
  /// no-op по уже закрытой), [TakeRefusal] — задачу держит другой или в праве
  /// отказано; прочие статусы — исключение, как у любой ручки.
  Future<TakeRefusal?> takeTask(String id) => _takeCall('apiTakeTask', id);

  /// Вернуть задачу в пул. Те же исходы; несуществующий id и ничья задача отвечают
  /// пустым 200 — очередь ретраит снятие и не должна на них застревать.
  Future<TakeRefusal?> releaseTask(String id) => _takeCall('apiReleaseTask', id);

  Future<TakeRefusal?> _takeCall(String action, String id) async {
    final r =
        await _postJson(action, {'id': id}, accept: const {403, 409});
    if (r.statusCode < 400) return null;
    Map<String, dynamic> j;
    try {
      j = (json.decode(utf8.decode(r.bodyBytes, allowMalformed: true)) as Map)
          .cast<String, dynamic>();
    } catch (_) {
      j = const {}; // нечитаемое тело не делает отказ менее внятным исходом
    }
    return TakeRefusal.fromJson(r.statusCode, j);
  }

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

  /// Приложить снимок к самой задаче — без комментария (#36914). Одна ручка на оба
  /// места: кадры, снятые при создании (уезжают следом за apiCreateTask), и дозагрузка
  /// к задаче, которая давно на сервере. clientId — ключ идемпотентности: повтор уже
  /// принятого снимка сервер отвечает пустым 200, поэтому ретрай очереди безопасен.
  /// Тайм-аут — как у создания с фото: base64 на канале дальнего магазина в общие
  /// двадцать секунд не укладывается.
  Future<void> addTaskFile(String taskId, String clientId, String photoBase64) =>
      _postJson(
          'apiAddTaskFile',
          {'id': taskId, 'clientId': clientId, 'photo': photoBase64},
          timeout: const Duration(seconds: 120));

  // --- unified fillable engine (checklist + form tasks) ---

  /// [lat]/[lon]/[at] — где и когда, по часам устройства, работа началась (#36838).
  /// Сняты в момент действия, а не отправки: вызов из очереди несёт значения,
  /// записанные при постановке, — офлайн-дожим не подменяет место работы местом
  /// появления сети. Отсутствующие координаты не отправляются вовсе — пусто на
  /// сервере честнее нуля.
  Future<void> startExecution(String taskId,
          {double? lat, double? lon, String? at}) =>
      _postJson('apiStartExecution', {
        'id': taskId,
        if (lat != null) 'lat': lat,
        if (lon != null) 'lon': lon,
        if (at != null) 'at': at,
      });

  /// Одна тройка адресации у всех читающих ручек бланка (#36778): по задаче — её
  /// текущее заполнение; с prev — прошлая проверка того же объекта и шаблона; с
  /// objectId (без задачи) — последняя завершённая проверка объекта. Сервер отдаёт
  /// прошлое заполнение тем же JSON, что и текущее, — рендерер один.
  Map<String, String> _fillAddress(String? taskId,
          {bool prev = false, String? objectId}) =>
      {
        if (taskId != null) 'id': taskId,
        if (prev) 'prev': '1',
        if (objectId != null) 'objectId': objectId,
      };

  Future<Map<String, dynamic>?> fetchExecutionInfo(String? taskId,
      {bool prev = false, String? objectId}) async {
    final r = await _get(_exec('apiExecutionInfo',
        _fillAddress(taskId, prev: prev, objectId: objectId)));
    final list = _decodeList(r.bodyBytes);
    return list.isEmpty ? null : list.first;
  }

  Future<List<Map<String, dynamic>>> fetchExecutionFields(String? taskId,
      {bool prev = false, String? objectId}) async {
    final r = await _get(_exec('apiExecutionFields',
        _fillAddress(taskId, prev: prev, objectId: objectId)));
    return _decodeList(r.bodyBytes);
  }

  Future<List<Map<String, dynamic>>> fetchExecutionOptions(String? taskId,
      {bool prev = false, String? objectId}) async {
    final r = await _get(_exec('apiExecutionOptions',
        _fillAddress(taskId, prev: prev, objectId: objectId)));
    return _decodeList(r.bodyBytes);
  }

  /// Set one field value. Exactly one typed value is normally provided; a comment
  /// may accompany any of them. Numbers/booleans go over natively.
  ///
  /// [refId]/[refName] — поле-ссылка (#36841): идентификатор предмета в канале поля и
  /// текст-снимок на момент выбора. Пустые строки — явная очистка обоих слотов на
  /// сервере, поэтому они не выбрасываются из тела, как null.
  Future<void> setField(String taskId, String fieldCode,
          {String? optionCode,
          double? number,
          String? text,
          bool? boolVal,
          String? date,
          String? comment,
          String? refId,
          String? refName}) =>
      _postJson('apiSetField', {
        'id': taskId,
        'field': fieldCode,
        if (optionCode != null) 'optCode': optionCode,
        if (number != null) 'number': number,
        if (text != null) 'text': text,
        if (boolVal != null) 'bool': boolVal,
        if (date != null) 'date': date,
        if (comment != null && comment.isNotEmpty) 'comment': comment,
        if (refId != null) 'refId': refId,
        if (refName != null) 'refName': refName,
      });

  /// Кандидаты справочника для поля-ссылки или табличного поля (#36841): канал задан
  /// настройкой поля на сервере, поэтому адресация — задача + код поля. По умолчанию
  /// сервер отдаёт доступных на объекте задачи (или весь канал, если хост фильтра не
  /// дал); [query] — серверный поиск по имени, [all] — весь справочник.
  Future<List<Map<String, dynamic>>> fetchRowSubjects(
      String taskId, String fieldCode,
      {String? query, bool all = false}) async {
    final r = await _get(_exec('apiRowSubjects', {
      'id': taskId,
      'field': fieldCode,
      if (query != null && query.isNotEmpty) 'query': query,
      if (all) 'allItems': 'true',
    }));
    return _decodeList(r.bodyBytes);
  }

  // --- table fields ---
  Future<List<Map<String, dynamic>>> fetchExecutionColumns(String? taskId,
      {bool prev = false, String? objectId}) async {
    final r = await _get(_exec('apiExecutionColumns',
        _fillAddress(taskId, prev: prev, objectId: objectId)));
    return _decodeList(r.bodyBytes);
  }

  Future<List<Map<String, dynamic>>> fetchExecutionRows(String? taskId,
      {bool prev = false, String? objectId}) async {
    final r = await _get(_exec('apiExecutionRows',
        _fillAddress(taskId, prev: prev, objectId: objectId)));
    return _decodeList(r.bodyBytes);
  }

  /// Скачать один снимок поля (#36778): миниатюру для галереи просмотра или полный
  /// размер по явному тапу. Сырые jpg-байты, не base64 — см. apiFieldPhoto.
  Future<Uint8List> fetchFieldPhoto(String? taskId, String fieldCode, int index,
      {bool thumb = false, bool prev = false, String? objectId}) async {
    final r = await _get(
      _exec('apiFieldPhoto', {
        ..._fillAddress(taskId, prev: prev, objectId: objectId),
        'field': fieldCode,
        'index': '$index',
        if (thumb) 'thumb': '1',
      }),
      // полный размер по мобильной сети дальнего магазина в 20 секунд не обязан
      // укладываться — тайм-аут по размеру ноши, как у createTask с фото
      timeout: thumb ? const Duration(seconds: 20) : const Duration(seconds: 60),
    );
    return r.bodyBytes;
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

  /// [lat]/[lon]/[at] — где и когда нажато «Завершить», по часам устройства — та же
  /// механика момента действия, что у [startExecution].
  Future<void> finishExecution(String taskId,
          {double? lat, double? lon, String? at}) =>
      _postJson('apiFinishExecution', {
        'id': taskId,
        if (lat != null) 'lat': lat,
        if (lon != null) 'lon': lon,
        if (at != null) 'at': at,
      });

  // --- простое выполнение: фотоотчёт с комментарием (#36872) ---
  // Вторая половина выполнения рядом с первой: у бланка apiExecution*, здесь
  // apiSimple*. Адресация та же — идентификатор ЗАДАЧИ (ST-номер или UUID телефона).

  /// Начать работу: сервер заводит выполнение, если его ещё нет. [lat]/[lon]/[at] —
  /// момент действия, как у [startExecution] бланка.
  Future<void> startSimple(String taskId,
          {double? lat, double? lon, String? at}) =>
      _postJson('apiStartSimple', {
        'id': taskId,
        if (lat != null) 'lat': lat,
        if (lon != null) 'lon': lon,
        if (at != null) 'at': at,
      });

  /// Состояние выполнения: завершено ли, комментарий, сколько снимков и с какими
  /// индексами. Кэшируется целиком — экран открывается по нему и без сети.
  Future<Map<String, dynamic>?> fetchSimpleInfo(String taskId) async {
    final r = await _get(_exec('apiSimpleInfo', {'id': taskId}));
    final list = _decodeList(r.bodyBytes);
    return list.isEmpty ? null : list.first;
  }

  /// Приложить снимок — сервер дописывает его в конец набора. Пустой [photoBase64]
  /// (пустая строка) стирает весь набор, как у поля бланка. Время по размеру ноши:
  /// фото по мобильной сети дальнего магазина в общие 20 секунд не укладывается.
  Future<void> setSimplePhoto(String taskId, String? photoBase64) =>
      _postJson('apiSetSimplePhoto', {
        'id': taskId,
        if (photoBase64 != null) 'photo': photoBase64,
      },
          timeout: photoBase64 == null || photoBase64.isEmpty
              ? const Duration(seconds: 20)
              : const Duration(seconds: 120));

  Future<void> deleteSimplePhoto(String taskId, int index) =>
      _postJson('apiDeleteSimplePhoto', {'id': taskId, 'index': index});

  /// Снимок выполнения по индексу — миниатюра для галереи или полный размер по тапу.
  /// Сырые байты, как apiFieldPhoto. Нужен для снимков, сделанных на ДРУГОМ
  /// устройстве (или на этом же до переустановки): свои лежат файлами на диске.
  Future<Uint8List> fetchSimplePhoto(String taskId, int index,
      {bool thumb = false}) async {
    final r = await _get(
      _exec('apiSimplePhoto', {
        'id': taskId,
        'index': '$index',
        if (thumb) 'thumb': '1',
      }),
      timeout: thumb ? const Duration(seconds: 20) : const Duration(seconds: 60),
    );
    return r.bodyBytes;
  }

  /// Комментарий выполнения — перезапись, а не дописывание: он один, и повтор из
  /// очереди обязан приводить к тому же состоянию.
  Future<void> setSimpleComment(String taskId, String? comment) =>
      _postJson('apiSetSimpleComment', {
        'id': taskId,
        if (comment != null) 'comment': comment,
      });

  /// Завершить. Сервер проверяет требование фото и при отказе отвечает ошибкой с
  /// текстом констрейнта — «выполнено» без снимка не должно доезжать как успех.
  Future<void> finishSimple(String taskId,
          {double? lat, double? lon, String? at}) =>
      _postJson('apiFinishSimple', {
        'id': taskId,
        if (lat != null) 'lat': lat,
        if (lon != null) 'lon': lon,
        if (at != null) 'at': at,
      });

  // --- переписка по задаче (#36844) ---

  /// Лента комментариев задачи, старые сверху. Сервер пускает участников задачи —
  /// назначенного (с иерархией) и автора; чужая задача и несуществующий id отвечают
  /// одним и тем же 403.
  Future<List<TaskComment>> fetchTaskComments(String taskId) async {
    final r = await _get(_exec('apiTaskComments', {'id': taskId}));
    return _decodeList(r.bodyBytes).map(TaskComment.fromJson).toList();
  }

  /// Отправить сообщение: тело — строка очереди как есть (id задачи, clientId — UUID,
  /// по которому сервер узнаёт повтор, text и/или photo в base64). Повтор того же
  /// clientId — тот же 200 без тела, поэтому ретраи безопасны. Телу с фото — время по
  /// размеру ноши, как у createTask.
  Future<void> addTaskComment(Map<String, dynamic> body) =>
      _postJson('apiAddTaskComment', body,
          timeout: body.containsKey('photo')
              ? const Duration(seconds: 120)
              : const Duration(seconds: 20));

  /// Прочитано до [upTo] — серверного времени последнего показанного сообщения.
  /// Идемпотентна и монотонна на сервере: повтор и отставшая отметка безвредны.
  Future<void> markTaskCommentsRead(String taskId, String? upTo) =>
      _postJson('apiMarkTaskCommentsRead', {
        'id': taskId,
        if (upTo != null) 'upTo': upTo,
      });

  /// Файл задачи по id (#36844, общая ручка с файлами задачи #36842): миниатюра для
  /// ленты или полный размер по явному тапу. Сырые байты, не base64 — см. apiTaskFile.
  Future<Uint8List> fetchTaskFile(String fileId, {bool thumb = false}) async {
    final r = await _get(
      _exec('apiTaskFile', {'id': fileId, if (thumb) 'thumb': '1'}),
      timeout: thumb ? const Duration(seconds: 20) : const Duration(seconds: 60),
    );
    return r.bodyBytes;
  }

  void _check(http.Response r) {
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
