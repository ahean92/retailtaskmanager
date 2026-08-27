import 'dart:convert';

/// Внешние приложения, настроенные на сервере (#36840): терминал сбора данных, сканер,
/// что-то ещё из контура заказчика.
///
/// Список — данные модуля `ExternalApp.lsf`, который в сборку сервера может быть и не
/// включён: тогда ручки apiExternalApps нет, ответа нет и секции на главной нет. Для
/// клиента это не ошибка, а обычное состояние — APK один на всех заказчиков.
///
/// Чего у записи нет, так это гарантии, что приложение стоит на телефоне: с Android 11
/// чужой пакет виден только из `<queries>` манифеста, поэтому справочник настраивается
/// данными, но каждое новое приложение — ещё и релиз клиента (см. AndroidManifest.xml).
class ExternalApp {
  final String code;
  final String title;

  /// Эмодзи из настройки на сервере — как у блоков главной: картинка приезжает данными,
  /// без релиза клиента.
  final String? icon;

  /// `android` | `ios` — см. AppPlatform на сервере. Телефон показывает только своё;
  /// запись неизвестной платформы пропускается, как незнакомый тип блока главной.
  final String platform;

  /// Имя пакета Android — запуск на главный экран приложения. Работает всегда (в
  /// отличие от шаблона URI, который требует договорённости с тем приложением).
  final String? package;

  /// Шаблон URI с подстановками `{objectId}`, `{taskId}`, `{login}` — для приложений,
  /// умеющих принять контекст ссылкой. Заполняется через [launchUri], который экранирует
  /// значения: адрес с пробелом или кириллицей иначе сломает запуск.
  final String? uriTemplate;

  /// Куда послать за отсутствующим приложением. Пусто — диалог ограничится сообщением.
  final String? marketUrl;

  const ExternalApp({
    required this.code,
    required this.title,
    this.icon,
    this.platform = 'android',
    this.package,
    this.uriTemplate,
    this.marketUrl,
  });

  factory ExternalApp.fromJson(Map<String, dynamic> j) => ExternalApp(
        code: _str(j['code']) ?? '',
        title: _str(j['title']) ?? '',
        icon: _str(j['icon']),
        platform: _str(j['platform']) ?? 'android',
        package: _str(j['package']),
        uriTemplate: _str(j['uri']),
        marketUrl: _str(j['market']),
      );

  /// Разбор сырого тела apiExternalApps — того же, что лежит в кэше (apps_cache):
  /// свежий ответ и кэш, поднятый без сети, проходят через одну и ту же функцию.
  static List<ExternalApp> parseList(String raw) {
    if (raw.trim().isEmpty) return const [];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    return [
      for (final e in decoded.whereType<Map>())
        ExternalApp.fromJson(e.cast<String, dynamic>()),
    ];
  }

  /// Собранный из шаблона URI запуска — или null, когда шаблона нет и запускать надо
  /// по имени пакета.
  ///
  /// Значения подстановок экранируются ([Uri.encodeComponent]): «Санта №5» в сыром виде
  /// делает URI невалидным, и запуск падает ещё до чужого приложения. Плейсхолдер, для
  /// которого значения нет (на главной нет текущей задачи — некому стать {taskId}),
  /// заменяется пустой строкой: оставить `%7BtaskId%7D` в адресе значило бы скормить
  /// чужому приложению литерал вместо контекста.
  String? launchUri({String? objectId, String? taskId, String? login}) {
    final template = uriTemplate;
    if (template == null || template.isEmpty) return null;
    final values = {
      'objectId': objectId,
      'taskId': taskId,
      'login': login,
    };
    return template.replaceAllMapped(
      RegExp(r'\{(\w+)\}'),
      (m) {
        final v = values[m.group(1)];
        return v == null ? '' : Uri.encodeComponent(v);
      },
    );
  }
}

String? _str(Object? v) {
  final s = v?.toString().trim();
  return (s == null || s.isEmpty) ? null : s;
}
