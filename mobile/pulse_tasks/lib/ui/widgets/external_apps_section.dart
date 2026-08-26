import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/external_app.dart';
import '../../models/home.dart';
import '../theme.dart';
import 'home_blocks.dart';

/// Чем секция открывает URI и пакет. Продовые реализации — url_launcher и
/// android_intent_plus; параметры-швы существуют для widget-тестов, где каналов
/// плагинов нет (url_launcher там даже не отказывает — его Future не завершается
/// в FakeAsync-петле теста). false — «открыть не вышло», дальше диалог.
typedef UriLauncher = Future<bool> Function(Uri uri);
typedef PackageLauncher = Future<bool> Function(String package);

/// Секция «Приложения» на главной (#36840): внешние андроид-приложения из справочника
/// на сервере — терминал сбора данных, сканер, что-то ещё из контура заказчика.
///
/// Секция, а не тип блока главной: список приезжает собственной ручкой необязательного
/// модуля (apiExternalApps), и на сборке сервера без него секции просто нет — apiHome
/// и HomeBlockType при этом не трогаются. Пустой список рисует ничего: сервер уже
/// отфильтровал записи по ролям, и «этому человеку ничего не положено» — не ошибка.
///
/// Только Android — на другой платформе секции нет независимо от данных: у iOS другой
/// механизм запуска (URL-схемы вместо пакетов), и он в задачу не входит.
class ExternalAppsSection extends StatelessWidget {
  final List<ExternalApp> apps;

  /// Контекст подстановок шаблона URI: объект, чьи цифры показывает главная, и логин
  /// вошедшего. Задачи на главной нет, поэтому {taskId} здесь всегда пуст.
  final String? objectId;
  final String? login;

  final UriLauncher _launchUri;
  final PackageLauncher _launchPackage;

  const ExternalAppsSection({
    super.key,
    required this.apps,
    this.objectId,
    this.login,
    UriLauncher? launchUriFn,
    PackageLauncher? launchPackageFn,
  })  : _launchUri = launchUriFn ?? _defaultLaunchUri,
        _launchPackage = launchPackageFn ?? _defaultLaunchPackage;

  /// Заголовок — тем же виджетом, что у блоков главной, только текст его не настройка,
  /// а константа клиента: секция живёт вне справочника блоков.
  static const _header = HomeBlock(
    code: 'externalApps',
    type: 'apps',
    title: 'Приложения',
    icon: '📱',
  );

  static Future<bool> _defaultLaunchUri(Uri uri) async {
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false; // нет обработчика схемы — то же «не установлено»
    }
  }

  /// Запуск по пакету — свой канал в MainActivity (getLaunchIntentForPackage +
  /// startActivity), а не android_intent_plus: тот резолвит MAIN/LAUNCHER-интент с
  /// MATCH_DEFAULT_ONLY, которому лаунчер-активити без CATEGORY_DEFAULT не видна, —
  /// установленный ТСД выглядел бы отсутствующим, а launch() при таком не-резолве
  /// молча снимает package и открывает системный лаунчер (проверено на эмуляторе).
  /// Приложение открывается на своём главном экране — ровно то, что разбор манифеста
  /// ТСД оставил доступным (внутренние экраны не экспортированы, своей схемы нет).
  /// false отвечает и на невидимый пакет: с Android 11 видимость даёт только запись
  /// в `<queries>` манифеста — потому справочник и требует релиза на новое приложение.
  static const _channel = MethodChannel('pulse_tasks/external_apps');

  static Future<bool> _defaultLaunchPackage(String package) async {
    try {
      return await _channel
              .invokeMethod<bool>('launchPackage', {'package': package}) ??
          false;
    } catch (_) {
      return false; // канал недоступен (не-Android среда) — то же «не установлено»
    }
  }

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return const SizedBox.shrink();
    }
    // запись неизвестной платформы пропускается, как незнакомый тип блока главной:
    // новее сервер — не повод ронять секцию
    final visible = [
      for (final a in apps)
        if (a.platform == 'android') a,
    ];
    if (visible.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const HomeSectionHeader(block: _header),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [for (final a in visible) _AppButton(app: a, section: this)],
          ),
        ),
      ],
    );
  }

  /// Запуск: шаблон URI, если он задан, иначе — пакет на его главный экран.
  ///
  /// Порядок не случаен: URI — это «открыться на текущем объекте», и раз администратор
  /// его настроил, просто поднять главный экран того приложения было бы потерей
  /// контекста, ради которого шаблон и заведён.
  Future<void> _launch(BuildContext context, ExternalApp app) async {
    final uri = app.launchUri(objectId: objectId, taskId: null, login: login);
    final bool ok;
    if (uri != null) {
      ok = await _launchUri(Uri.parse(uri));
    } else {
      final pkg = app.package;
      if (pkg == null) return; // активной записи без пакета и URI сервер не пускает
      ok = await _launchPackage(pkg);
    }
    if (!ok && context.mounted) await _notInstalled(context, app);
  }

  /// Внятное «не установлено» вместо молчания; если в справочнике задана ссылка на
  /// маркет — предложить её.
  Future<void> _notInstalled(BuildContext context, ExternalApp app) async {
    final market = app.marketUrl;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(app.title),
        content: const Text('Приложение не установлено на этом устройстве.'),
        actions: [
          if (market != null)
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                _launchUri(Uri.parse(market));
              },
              child: const Text('Установить'),
            ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
  }
}

/// Кнопка одного приложения: эмодзи из настройки и название. Карточка, а не ListTile —
/// мишень для пальца в торговом зале, по ширине содержимого, чтобы ряд коротких названий
/// не растягивался в столбец на полэкрана.
class _AppButton extends StatelessWidget {
  final ExternalApp app;
  final ExternalAppsSection section;
  const _AppButton({required this.app, required this.section});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Wms.card,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => section._launch(context, app),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(app.icon ?? '📦', style: const TextStyle(fontSize: 22)),
              const SizedBox(width: 8),
              Text(
                app.title,
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Wms.text),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
