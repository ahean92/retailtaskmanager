import '../api_client.dart';

/// Главная: блоки с посчитанными числами, каталог объектов (#37047) и внешние приложения
/// секции главной (#36840). Уведомления, устройства, пресеты создания и AI — в своих
/// файлах рядом; бренд идёт без авторизации и поэтому живёт рядом со входом —
/// ApiClient.fetchBrand.
extension HomeApi on ApiClient {
  /// The home screen for the logged-in user: which blocks, in which order, with their
  /// numbers already computed. One call rather than one per block — the screen is drawn
  /// whole, and a half-arrived home page is not a thing worth rendering.
  ///
  /// С координатами (#37047) сервер отдаёт не весь каталог объектов, а те, что рядом,
  /// объекты открытых задач вошедшего и [objectId] — выбранный на главной; без
  /// координат — каталог целиком, как раньше, если не попросить [self]: тогда только
  /// объекты открытых задач и [objectId]. Пустые значения в запрос не кладутся.
  Future<Map<String, dynamic>?> fetchHome(
      {double? lat, double? lon, String? objectId, bool self = false}) async {
    final params = {
      if (lat != null) 'lat': '$lat',
      if (lon != null) 'lon': '$lon',
      if (objectId != null && objectId.isNotEmpty) 'objectId': objectId,
      if (self) 'scope': 'self',
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

  /// Внешние приложения для секции главной (#36840). Сервер уже отфильтровал по ролям.
  /// Ручка живёт в необязательном модуле (ExternalApp.lsf): сборка без него отвечает
  /// 404, и решать, что это значит для секции, — забота репозитория, не транспорта.
  Future<String> fetchExternalAppsRaw() => getRaw(exec('apiExternalApps'));
}