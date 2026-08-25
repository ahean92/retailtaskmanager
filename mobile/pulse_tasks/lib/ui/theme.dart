import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'brand.dart';

/// Palette accessor. The names and the look are the WMS ones mirrored from the lsFusion
/// ARM (`resources/web/storeTasks/mobileTask.css` / `armMenu.js`), so the Flutter client
/// and the web interface stay recognisably one product.
///
/// These are getters over the active [Brand], not constants: a customer's palette is
/// decided after the binary is built. That is also why call sites cannot be `const` —
/// the compiler would otherwise freeze today's colours into the widget tree.
///
/// Тёмная тема (#36917) ничего в вызовах не меняет: экраны как брали цвет отсюда, так и
/// берут, а вот отдаётся им теперь либо светлая палитра бренда, либо её тёмный вариант.
/// Поэтому «покрасить приложение в тёмное» — это подменить палитру в одном месте, а не
/// пройти по всем экранам.
class Wms {
  Wms._();

  /// Палитра, которой рисуют прямо сейчас, за нотификатором: приложение перекрашивается
  /// и когда сервер прислал бренд заказчика, и когда сменилась тема.
  static final ValueNotifier<Brand> notifier = ValueNotifier(Brand.pulse);

  /// Выбор человека: «как в системе», «светлая», «тёмная». Отдельным нотификатором,
  /// потому что его слушает и сам MaterialApp — [ThemeMode] решает не только палитру,
  /// но и то, какую тему подставит Flutter своим стандартным виджетам.
  static final ValueNotifier<ThemeMode> mode = ValueNotifier(ThemeMode.system);

  static const _modeKey = 'themeMode';

  static Brand _base = Brand.pulse;
  static Brand _dark = Brand.pulse.darkVariant;
  static bool _isDark = false;

  /// Бренд, как его прислал сервер, — он всегда светлый: заказчик подбирает палитру
  /// под белый лист. Из него считается всё остальное.
  static Brand get base => _base;

  /// Тёмный вариант того же бренда. Считается один раз на бренд, а не по требованию:
  /// геттеры палитры дёргаются сотнями за кадр, и осветлять цвета в каждом было бы
  /// платой за тему в каждом пикселе.
  static Brand get darkPalette => _dark;

  /// Тёмная ли тема сейчас — с уже учтённой системной настройкой телефона.
  static bool get isDark => _isDark;

  static Brand get brand => notifier.value;

  /// Присвоение бренда — это и есть перебрендирование живого приложения. Тёмный
  /// вариант пересчитывается здесь же, чтобы смена темы после этого была бесплатной.
  static set brand(Brand b) {
    _base = b;
    _dark = b.darkVariant;
    _apply();
  }

  static Color get primary => brand.primary;
  static Color get primaryDark => brand.primaryDark;
  static Color get accent => brand.accent;
  static Color get ok => brand.ok;
  static Color get warn => brand.warn;
  static Color get bg => brand.bg;
  static Color get card => brand.card;
  static Color get line => brand.line;
  static Color get muted => brand.muted;
  static Color get text => brand.text;
  static Color get active => brand.active; // row :active / selected tint

  /// Мягкая подложка под красным — строка с несоответствием, полоса «офлайн».
  /// Именно подложка, а не цвет: поверх неё читают текст, и в тёмной теме она обязана
  /// остаться тёмной, иначе получится та самая «белая плашка на тёмном».
  static Color get warnTint => brand.warn.withValues(alpha: 0.12);

  /// Цвет шапки и залитых кнопок — фирменный цвет заказчика, ОДИН для обеих тем.
  /// Тёмная тема гасит лист, а не бренд: шапка остаётся той же, что человек привык
  /// видеть, и белый текст на ней читается в обеих темах одинаково.
  static Color get chrome => _base.primary;

  /// Текст и иконки поверх [chrome].
  static Color get onChrome => on(chrome);

  /// Чем писать поверх заливки [c]: на тёмном — белым, на светлом — почти чёрным.
  /// Нужен там, где плашку заливают цветом состояния (зелёная «Завершить»), а сам
  /// цвет зависит и от темы, и от бренда — белый текст на осветлённом зелёном
  /// перестаёт читаться ровно в тот момент, когда зелёный светлеет.
  static Color on(Color c) =>
      c.computeLuminance() > 0.45 ? const Color(0xFF11161C) : Colors.white;

  /// Чужой цвет — метрики с сервера, фиксированная палитра диаграммы — поднятый до
  /// читаемого на текущей карточке. В светлой теме отдаётся как есть: эти цвета
  /// подбирали под белый фон, и трогать их незачем.
  static Color readable(Color c) =>
      _isDark ? Brand.readableOn(c, brand.card) : c;

  /// Soft card shadow — rgba(0,0,0,.08) 0 1 3.
  static const cardShadow = [
    BoxShadow(color: Color(0x14000000), blurRadius: 3, offset: Offset(0, 1)),
  ];

  /// Header/app-bar shadow — rgba(0,0,0,.15) 0 2 6.
  static const headerShadow = [
    BoxShadow(color: Color(0x26000000), blurRadius: 6, offset: Offset(0, 2)),
  ];

  /// Читает выбранную тему с устройства. Зовётся до первого кадра — иначе приложение
  /// откроется светлым и перекрасится на глазах, а это читается как сбой, а не как
  /// настройка.
  static Future<void> loadMode() async {
    final sp = await SharedPreferences.getInstance();
    final saved = sp.getString(_modeKey);
    mode.value = ThemeMode.values.firstWhere((m) => m.name == saved,
        orElse: () => ThemeMode.system);
    resolve();
  }

  /// Выбор человека: применяется сразу и сохраняется. Перезапуск не нужен — палитра
  /// меняется под всем деревом, а MaterialApp перестраивается по нотификатору.
  static Future<void> setMode(ThemeMode m) async {
    if (mode.value != m) {
      mode.value = m;
      resolve();
    }
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_modeKey, m.name);
  }

  /// Пересчитывает, тёмная ли тема сейчас: выбор человека, а для «как в системе» —
  /// ещё и настройка телефона. Зовётся при смене выбора и из
  /// `didChangePlatformBrightness` — ночной режим по расписанию должен доходить до
  /// приложения сам.
  static void resolve() {
    final system =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;
    final dark = mode.value == ThemeMode.dark ||
        (mode.value == ThemeMode.system && system == Brightness.dark);
    if (dark == _isDark) return;
    _isDark = dark;
    _apply();
  }

  static void _apply() {
    notifier.value = _isDark ? _dark : _base;
    _repaintOpenScreens();
  }

  /// Палитра здесь глобальная, а не InheritedWidget: экран пишет `Wms.card`, без
  /// контекста. Плата за это — смена палитры сама собой доходит только до тех, кто
  /// перестраивается: корень по нотификатору перестроится, а список под открытой
  /// карточкой и шапка бланка останутся в старых цветах до первой своей перестройки.
  /// Проверено на устройстве: белые карточки на тёмном фоне (#36917).
  ///
  /// Поэтому смена палитры — это ещё и один проход по дереву: пометить всё
  /// построенным заново. Стоит он одного кадра и случается ровно дважды за жизнь
  /// экрана — при переключении темы и когда сервер прислал бренд заказчика (там та же
  /// беда, просто её никто не ловил).
  static void _repaintOpenScreens() {
    void mark(Element e) {
      e.markNeedsBuild();
      e.visitChildren(mark);
    }

    // до первого кадра дерева ещё нет — бренд из настроек применяется как раз тогда
    WidgetsBinding.instance.rootElement?.visitChildren(mark);
  }
}

/// Builds the theme for [palette]. Call it again after the brand changes — the theme
/// captures colours by value, so a rebuild is what repaints the app.
///
/// [dark] — не «сделай потемнее», а «палитра уже тёмная»: [palette] к этому моменту
/// тёмный вариант бренда, а флаг говорит, какую сторону Material'а под него подложить
/// (яркость схемы, тёмный текстовый набор, тёмные контейнеры диалогов и листов).
ThemeData buildAppTheme(Brand palette, {bool dark = false}) {
  final chrome = Wms.chrome;
  final onChrome = Wms.on(chrome);
  var scheme = ColorScheme.fromSeed(
    seedColor: chrome,
    brightness: dark ? Brightness.dark : Brightness.light,
  ).copyWith(
    primary: palette.primary,
    onPrimary: Wms.on(palette.primary),
    error: palette.warn,
    onError: Wms.on(palette.warn),
    surface: palette.card,
    onSurface: palette.text,
  );
  if (dark) {
    // Светлую тему семейством surfaceContainer* не трогаем — она такая уже принята.
    // А в тёмной эти роли решают, какого цвета будут диалог, нижний лист и чип: без
    // них Material возьмёт свои, выведенные из seed'а, и рядом с карточками бренда
    // они смотрятся как из другого приложения.
    scheme = scheme.copyWith(
      surfaceContainerLowest: palette.bg,
      surfaceContainerLow: palette.card,
      surfaceContainer: palette.card,
      surfaceContainerHigh: palette.line,
      surfaceContainerHighest: palette.line,
      onSurfaceVariant: palette.muted,
      outline: palette.muted,
      outlineVariant: palette.line,
      secondaryContainer: palette.active,
      onSecondaryContainer: palette.primary,
    );
  }

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: palette.bg,
    // the accent lands where nothing sits on top of it — progress, selection
    progressIndicatorTheme: ProgressIndicatorThemeData(color: palette.accent),
    textTheme: (dark ? ThemeData.dark() : ThemeData.light())
        .textTheme
        .apply(bodyColor: palette.text, displayColor: palette.text),
    appBarTheme: AppBarTheme(
      backgroundColor: chrome,
      foregroundColor: onChrome,
      elevation: 2,
      scrolledUnderElevation: 2,
      shadowColor: const Color(0x40000000),
      centerTitle: false,
      iconTheme: IconThemeData(color: onChrome),
      actionsIconTheme: IconThemeData(color: onChrome),
      titleTextStyle: TextStyle(
          color: onChrome, fontSize: 19, fontWeight: FontWeight.w700),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 46),
        backgroundColor: chrome,
        foregroundColor: onChrome,
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 44),
        foregroundColor: palette.primary,
        side: BorderSide(color: palette.primary),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}
