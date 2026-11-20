import '../api_client.dart';

/// Создание в поле: предзагрузка пресетов и справочников (#36713). Сырые тела, а не
/// разобранные модели: кэш хранит ответ сервера как есть (см. quick_cache), и парсит
/// его одна и та же QuickCreateData.parse — что для свежего ответа, что для кэша,
/// поднятого без сети.
extension QuickApi on ApiClient {
  /// Что этому пользователю разрешено создавать. Сервер уже отфильтровал по ролям.
  Future<String> fetchQuickActionsRaw() => getRaw(exec('apiQuickActions'));

  /// Шаблоны целиком (поля, варианты, колонки) — только те, на которые ссылается
  /// видимый пресет.
  Future<String> fetchTemplatesRaw() => getRaw(exec('apiTemplates'));

  /// Исполнители с их ролями на объектах — только те, у кого роль есть хотя бы где-то.
  Future<String> fetchPerformersRaw() => getRaw(exec('apiPerformers'));
}
