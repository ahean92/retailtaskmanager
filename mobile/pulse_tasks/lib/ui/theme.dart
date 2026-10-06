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

  // ——— Роли редизайна #37411 (mobile-redesign-A-v2.pdf, стр. 1) ———
  //
  // Это клиентские константы, а не поля бренда: сервер управляет фирменными
  // цветами (primary/accent/ok/warn), а фон, рамки, текстовые серые и сигнальные
  // пары у всех заказчиков одинаковые. Значения тёмной темы фиксированы макетом
  // — они не выводятся из светлых, чтобы красный «опасно» в тёмном зале остался
  // именно заданным красным.

  /// Разделитель внутри карточки и между строками. #EEF0F3 / #252B33.
  static Color get divider =>
      _isDark ? const Color(0xFF252B33) : const Color(0xFFEEF0F3);

  /// Второй уровень текста — мета-строки, подписи значений. #3B434D / #C3CAD3.
  static Color get text2 =>
      _isDark ? const Color(0xFFC3CAD3) : const Color(0xFF3B434D);

  /// Подложка нейтрального чипа и незалитого поля. #EEF0F3 / #252B33.
  static Color get chipBg =>
      _isDark ? const Color(0xFF252B33) : const Color(0xFFEEF0F3);

  /// «Опасно» — просрочка, отказ сервера, деструктивное: сильный цвет парой с
  /// подложкой; текст на подложке пишется сильным цветом.
  static Color get danger =>
      _isDark ? const Color(0xFFFF8A80) : const Color(0xFFB3261E);
  static Color get dangerTint =>
      _isDark ? const Color(0xFF3B2220) : const Color(0xFFFDECEA);

  /// «Внимание» — ожидание, неполное состояние.
  static Color get caution =>
      _isDark ? const Color(0xFFF0C274) : const Color(0xFF7A4300);
  static Color get cautionTint =>
      _isDark ? const Color(0xFF3A2E17) : const Color(0xFFFFF4E0);

  /// «Готово» — завершённое, принятое.
  static Color get done =>
      _isDark ? const Color(0xFF5DD39A) : const Color(0xFF1E7D45);
  static Color get doneTint =>
      _isDark ? const Color(0xFF173022) : const Color(0xFFE6F4EA);

  /// Подложка бренда: светлая тема — фирменный цвет при 10 %, тёмная —
  /// поднятый до читаемого при 18 % (это и есть [Brand.active] тёмного
  /// варианта). Текст и иконки на ней — [Wms.primary] текущей палитры: в
  /// светлой теме он читается на почти белом, в тёмной уже поднят.
  static Color get brandTint =>
      _isDark ? brand.active : Color.alphaBlend(brand.primary.withValues(alpha: 0.10), brand.card);

  /// Мягкая подложка под красным — строка с несоответствием, полоса «офлайн».
  /// Именно подложка, а не цвет: поверх неё читают текст, и в тёмной теме она обязана
  /// остаться тёмной, иначе получится та самая «белая плашка на тёмном».
  static Color get warnTint => brand.warn.withValues(alpha: 0.12);

  /// Подложка под белым значком поверх фотографии (крестик «убрать», счётчик
  /// кадров) — полупрозрачная чёрная в обеих темах: снимок от темы не темнеет,
  /// и значок на нём должен читаться одинаково. Константа намеренно — бренд её
  /// не задаёт, а полупрозрачность поверх любого фото одна.
  static const Color scrim = Colors.black54;

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

  // Разделитель темы: значения — константы редизайна (см. Wms.divider), здесь
  // локально, чтобы тема собиралась из одной палитры без обращения к Wms.
  final divider = dark ? const Color(0xFF252B33) : const Color(0xFFEEF0F3);
  final text2 = dark ? const Color(0xFFC3CAD3) : const Color(0xFF3B434D);

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: palette.bg,
    fontFamily: 'Golos Text',
    dividerTheme: DividerThemeData(color: divider, thickness: 1, space: 1),
    // the accent lands where nothing sits on top of it — progress, selection
    progressIndicatorTheme: ProgressIndicatorThemeData(color: palette.accent),
    textTheme: (dark ? ThemeData.dark() : ThemeData.light())
        .textTheme
        .apply(bodyColor: palette.text, displayColor: palette.text),
    // Шапка redesign #37411: светлая (цвет фона экрана), без тени и цветной
    // заливки — «крупный заголовок» рисуют сами экраны, AppBar остаётся
    // тонкой полосой под статус-баром с действиями.
    appBarTheme: AppBarTheme(
      backgroundColor: palette.bg,
      foregroundColor: palette.text,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      iconTheme: IconThemeData(color: palette.text),
      actionsIconTheme: IconThemeData(color: palette.text),
      titleTextStyle: TextStyle(
          color: palette.text, fontSize: 17, fontWeight: FontWeight.w600),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 52),
        backgroundColor: chrome,
        foregroundColor: onChrome,
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 52),
        foregroundColor: text2,
        side: BorderSide(color: palette.line),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: palette.primary,
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: dark ? const Color(0xFF252B33) : const Color(0xFFEEF0F3),
      side: BorderSide.none,
      shape: const StadiumBorder(),
      labelStyle: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: dark ? const Color(0xFFC3CAD3) : const Color(0xFF3B434D)),
      padding: const EdgeInsets.symmetric(horizontal: 12),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: palette.card,
      modalBackgroundColor: palette.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      showDragHandle: true,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: palette.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? const Color(0xFF252B33) : const Color(0xFFEEF0F3),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: palette.primary, width: 1.5),
      ),
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}
