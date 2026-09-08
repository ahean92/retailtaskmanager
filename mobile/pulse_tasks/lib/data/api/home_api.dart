import '../../models/ai_draft.dart';
import '../../models/notification.dart';
import '../api_client.dart';

/// Главная и всё, что телефон забирает при синхронизации помимо задач: бренд,
/// блоки главной, уведомления (#36717) и реестр устройств (#36720), пресеты создания
/// со справочниками (#36713), внешние приложения (#36840), AI.
extension HomeApi on ApiClient {
  /// The customer's branding. Answered without authentication on purpose — the client
  /// asks for it the moment the address is known, before anyone has logged in.
  Future<Map<String, dynamic>?> fetchBrand() async {
    final r = await get(exec('apiBrand'), timeout: const Duration(seconds: 10));
    final list = decodeList(r.bodyBytes);
    return list.isEmpty ? null : list.first;
  }
  /// The home screen for the logged-in user: which blocks, in which order, with their
  /// numbers already computed. One call rather than one per block — the screen is drawn
  /// whole, and a half-arrived home page is not a thing worth rendering.
  ///
  /// С координатами (#37047) сервер отдаёт не весь каталог объектов, а те, что рядом,
  /// объекты открытых задач вошедшего и [objectId] — выбранный на главной; без
  /// координат — каталог целиком, как раньше. Пустые значения в запрос не кладутся.
  Future<Map<String, dynamic>?> fetchHome(
      {double? lat, double? lon, String? objectId}) async {
    final params = {
      if (lat != null) 'lat': '$lat',
      if (lon != null) 'lon': '$lon',
      if (objectId != null && objectId.isNotEmpty) 'objectId': objectId,
    };
    final r = await get(exec('apiHome', params.isEmpty ? null : params));
    final list = decodeList(r.bodyBytes);
    return list.isEmpty ? null : list.first;
  }
  /// Полный каталог объектов проверки (#37047) — сырое тело как есть: кэш хранит
  /// ответ сервера, а разбирает его одна и та же HomeObject.parseList — что для
  /// свежего ответа, что для кэша, поднятого без сети. Тянется фоном и только при
  /// смене `catalogVersion` из [fetchCurrentUser].
  Future<String> fetchObjectsRaw() => getRaw(exec('apiObjects'));
  /// Журнал уведомлений вызывающего исполнителя за последние 30 дней (#36717).
  Future<List<NotificationItem>> fetchNotifications() async {
    final r = await get(exec('apiNotifications'));
    return decodeList(r.bodyBytes).map(NotificationItem.fromJson).toList();
  }
  /// Отметить уведомление прочитанным — адресом (событие, задача, дата), тем же,
  /// каким сервер запись дедуплицирует. Идемпотентна: повтор по уже прочитанному —
  /// тот же 200, поэтому пачка на открытие ленты и ретраи безопасны.
  Future<void> markNotificationViewed(
          String event, String? taskId, String date) =>
      postJson('apiMarkNotificationViewed', {
        'event': event,
        if (taskId != null) 'taskId': taskId,
        'date': date,
      });
  /// Зарегистрировать телефон для пуш-уведомлений (#36720). Владельца сервер берёт из
  /// сессии, а не из тела: параметр «чьё устройство» позволил бы подписать свой телефон
  /// на чужие уведомления. Идемпотентна — клиент шлёт её на каждом запуске.
  Future<void> registerDevice(
          String token, String platform, String appVersion) =>
      postJson('apiRegisterDevice', {
        'token': token,
        'platform': platform,
        'appVersion': appVersion,
      });
  /// Снять регистрацию — при выходе из аккаунта. Не сделать этого значит отправить
  /// уведомления следующего сотрудника на телефон предыдущего.
  Future<void> unregisterDevice(String token) =>
      postJson('apiUnregisterDevice', {'token': token});

  // --- создание в поле: предзагрузка пресетов и справочников (#36713) ---
  // Сырые тела, а не разобранные модели: кэш хранит ответ сервера как есть (см.
  // quick_cache), и парсит его одна и та же QuickCreateData.parse — что для свежего
  // ответа, что для кэша, поднятого без сети.
  /// Что этому пользователю разрешено создавать. Сервер уже отфильтровал по ролям.
  Future<String> fetchQuickActionsRaw() => getRaw(exec('apiQuickActions'));
  /// Шаблоны целиком (поля, варианты, колонки) — только те, на которые ссылается
  /// видимый пресет.
  Future<String> fetchTemplatesRaw() => getRaw(exec('apiTemplates'));
  /// Исполнители с их ролями на объектах — только те, у кого роль есть хотя бы где-то.
  Future<String> fetchPerformersRaw() => getRaw(exec('apiPerformers'));
  /// Внешние приложения для секции главной (#36840). Сервер уже отфильтровал по ролям.
  /// Ручка живёт в необязательном модуле (ExternalApp.lsf): сборка без него отвечает
  /// 404, и решать, что это значит для секции, — забота репозитория, не транспорта.
  Future<String> fetchExternalAppsRaw() => getRaw(exec('apiExternalApps'));

  // --- постановка задачи текстом (AI) ---
  /// Включён ли AI на этом сервере и какая за ним модель. Спрашивается при
  /// синхронизации: пункт «AI» в меню создания появляется только после «включён» —
  /// на стенде без AI-сервиса человек упирался бы в ошибку вместо ответа.
  Future<AiInfo> fetchAiInfo() async {
    final r = await get(exec('apiAiInfo'), timeout: const Duration(seconds: 10));
    final list = decodeList(r.bodyBytes);
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
    final r = await postJson('apiAiDraft', {
      'dialogId': dialogId,
      'text': text,
      if (objectId != null && objectId.isNotEmpty) 'objectId': objectId,
      if (lat != null) 'lat': lat,
      if (lon != null) 'lon': lon,
    }, timeout: const Duration(seconds: 180));
    final list = decodeList(r.bodyBytes);
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
}
