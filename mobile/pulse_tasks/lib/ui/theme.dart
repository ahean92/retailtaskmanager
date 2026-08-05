import 'package:flutter/material.dart';

import 'brand.dart';

/// Palette accessor. The names and the look are the WMS ones mirrored from the lsFusion
/// ARM (`resources/web/storeTasks/mobileTask.css` / `armMenu.js`), so the Flutter client
/// and the web interface stay recognisably one product.
///
/// These are getters over the active [Brand], not constants: a customer's palette is
/// decided after the binary is built. That is also why call sites cannot be `const` —
/// the compiler would otherwise freeze today's colours into the widget tree.
class Wms {
  Wms._();

  /// The active brand, behind a notifier so the app repaints when the server sends a
  /// different one. Assigning it is what rebrands a running app.
  static final ValueNotifier<Brand> notifier = ValueNotifier(Brand.pulse);

  static Brand get brand => notifier.value;
  static set brand(Brand b) => notifier.value = b;

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

  /// Soft card shadow — rgba(0,0,0,.08) 0 1 3.
  static const cardShadow = [
    BoxShadow(color: Color(0x14000000), blurRadius: 3, offset: Offset(0, 1)),
  ];

  /// Header/app-bar shadow — rgba(0,0,0,.15) 0 2 6.
  static const headerShadow = [
    BoxShadow(color: Color(0x26000000), blurRadius: 6, offset: Offset(0, 2)),
  ];
}

/// Builds the theme for [b] (the active brand by default). Call it again after the brand
/// changes — the theme captures colours by value, so a rebuild is what repaints the app.
ThemeData buildAppTheme([Brand? b]) {
  final brand = b ?? Wms.brand;
  final scheme = ColorScheme.fromSeed(
    seedColor: brand.primary,
    brightness: Brightness.light,
  ).copyWith(
    primary: brand.primary,
    onPrimary: Colors.white,
    error: brand.warn,
    surface: brand.card,
    onSurface: brand.text,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: brand.bg,
    // the accent lands where nothing sits on top of it — progress, selection
    progressIndicatorTheme: ProgressIndicatorThemeData(color: brand.accent),
    textTheme: ThemeData.light()
        .textTheme
        .apply(bodyColor: brand.text, displayColor: brand.text),
    appBarTheme: AppBarTheme(
      backgroundColor: brand.primary,
      foregroundColor: Colors.white,
      elevation: 2,
      scrolledUnderElevation: 2,
      shadowColor: const Color(0x40000000),
      centerTitle: false,
      iconTheme: const IconThemeData(color: Colors.white),
      actionsIconTheme: const IconThemeData(color: Colors.white),
      titleTextStyle: const TextStyle(
          color: Colors.white, fontSize: 19, fontWeight: FontWeight.w700),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 46),
        backgroundColor: Wms.primary,
        foregroundColor: Colors.white,
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 44),
        foregroundColor: Wms.primary,
        side: BorderSide(color: Wms.primary),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}
