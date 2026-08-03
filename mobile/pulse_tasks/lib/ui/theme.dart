import 'package:flutter/material.dart';

/// WMS-style palette and theme, mirrored from the lsFusion ARM
/// (`resources/web/storeTasks/mobileTask.css` / `armMenu.js`) so the Flutter
/// client matches that look: a blue app-bar, a light gray-blue background, and
/// white "wms" list rows with an icon tile, a bold caption and a chevron.
class Wms {
  Wms._();

  static const primary = Color(0xFF2069B4);
  static const primaryDark = Color(0xFF17518F);
  static const ok = Color(0xFF2E9E4F);
  static const warn = Color(0xFFD9342B);
  static const bg = Color(0xFFEEF1F4);
  static const card = Color(0xFFFFFFFF);
  static const line = Color(0xFFDFE4E9);
  static const muted = Color(0xFF6C7581);
  static const text = Color(0xFF1D2733);
  static const active = Color(0xFFE8F1FB); // row :active / selected tint

  /// Soft card shadow — rgba(0,0,0,.08) 0 1 3.
  static const cardShadow = [
    BoxShadow(color: Color(0x14000000), blurRadius: 3, offset: Offset(0, 1)),
  ];

  /// Header/app-bar shadow — rgba(0,0,0,.15) 0 2 6.
  static const headerShadow = [
    BoxShadow(color: Color(0x26000000), blurRadius: 6, offset: Offset(0, 2)),
  ];
}

ThemeData buildWmsTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: Wms.primary,
    brightness: Brightness.light,
  ).copyWith(
    primary: Wms.primary,
    onPrimary: Colors.white,
    error: Wms.warn,
    surface: Wms.card,
    onSurface: Wms.text,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: Wms.bg,
    textTheme: ThemeData.light()
        .textTheme
        .apply(bodyColor: Wms.text, displayColor: Wms.text),
    appBarTheme: const AppBarTheme(
      backgroundColor: Wms.primary,
      foregroundColor: Colors.white,
      elevation: 2,
      scrolledUnderElevation: 2,
      shadowColor: Color(0x40000000),
      centerTitle: false,
      iconTheme: IconThemeData(color: Colors.white),
      actionsIconTheme: IconThemeData(color: Colors.white),
      titleTextStyle: TextStyle(
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
        side: const BorderSide(color: Wms.primary),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}
