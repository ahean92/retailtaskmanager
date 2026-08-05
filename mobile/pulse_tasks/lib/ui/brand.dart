import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

/// Everything that makes the app look like it belongs to one customer: the name it
/// shows, the palette it paints with, and an optional logo.
///
/// It is a value object rather than a set of constants on purpose — a constant is baked
/// into the binary at compile time, and branding that requires a rebuild is branding only
/// we can do. This can be swapped at runtime, which is what lets the server decide.
///
/// What CANNOT live here: the launcher icon and the name under it on the home screen.
/// Those are read by the OS from the manifest, so a fully-branded install still needs its
/// own build — see `assets/brand/README.md`.
@immutable
class Brand {
  /// shown in the app bar and on the login screen
  final String name;

  /// optional second line under the name (may be empty)
  final String tagline;

  /// The logo as base64, exactly as the server sends it. Base64 rather than a bundled
  /// asset because the whole point is that a customer's logo arrives at runtime; null or
  /// empty simply means "show the name".
  final String? logoBase64;

  /// Carries white text — app bar, filled buttons. Must be dark enough to read on.
  final Color primary;
  final Color primaryDark;

  /// Brand colour for surfaces that carry no white text: progress, selection tint,
  /// badges. Exists because a signature colour is often too light to put white on, and
  /// forcing it into the chrome would trade legibility for recognition.
  final Color accent;
  final Color ok;
  final Color warn;
  final Color bg;
  final Color card;
  final Color line;
  final Color muted;
  final Color text;
  final Color active;

  const Brand({
    required this.name,
    this.tagline = '',
    this.logoBase64,
    required this.primary,
    required this.primaryDark,
    required this.accent,
    required this.ok,
    required this.warn,
    required this.bg,
    required this.card,
    required this.line,
    required this.muted,
    required this.text,
    required this.active,
  });

  /// The product's own look — the WMS palette mirrored from the lsFusion ARM
  /// (`resources/web/storeTasks/mobileTask.css`), so the Flutter client and the web
  /// interface stay recognisably the same product.
  static const pulse = Brand(
    name: 'Пульс',
    tagline: 'Задачи',
    primary: Color(0xFF2069B4),
    primaryDark: Color(0xFF17518F),
    accent: Color(0xFF2069B4),
    ok: Color(0xFF2E9E4F),
    warn: Color(0xFFD9342B),
    bg: Color(0xFFEEF1F4),
    card: Color(0xFFFFFFFF),
    line: Color(0xFFDFE4E9),
    muted: Color(0xFF6C7581),
    text: Color(0xFF1D2733),
    active: Color(0xFFE8F1FB),
  );

  Brand copyWith({
    String? name,
    String? tagline,
    String? logoBase64,
    Color? primary,
    Color? primaryDark,
    Color? accent,
    Color? ok,
    Color? warn,
    Color? bg,
    Color? card,
    Color? line,
    Color? muted,
    Color? text,
    Color? active,
  }) =>
      Brand(
        name: name ?? this.name,
        tagline: tagline ?? this.tagline,
        logoBase64: logoBase64 ?? this.logoBase64,
        primary: primary ?? this.primary,
        primaryDark: primaryDark ?? this.primaryDark,
        accent: accent ?? this.accent,
        ok: ok ?? this.ok,
        warn: warn ?? this.warn,
        bg: bg ?? this.bg,
        card: card ?? this.card,
        line: line ?? this.line,
        muted: muted ?? this.muted,
        text: text ?? this.text,
        active: active ?? this.active,
      );

  /// Builds a brand from whatever the server (or a bundled brand file) supplies, falling
  /// back to [pulse] for anything absent. Partial branding is the normal case: a customer
  /// usually wants their name and their primary colour, not a whole palette.
  factory Brand.fromJson(Map<String, dynamic> j, {Brand base = pulse}) => base.copyWith(
        name: _str(j['name']),
        tagline: _str(j['tagline']),
        logoBase64: _str(j['logo']),
        primary: _color(j['primary']),
        primaryDark: _color(j['primaryDark']),
        accent: _color(j['accent']),
        ok: _color(j['ok']),
        warn: _color(j['warn']),
        bg: _color(j['bg']),
        card: _color(j['card']),
        line: _color(j['line']),
        muted: _color(j['muted']),
        text: _color(j['text']),
        active: _color(j['active']),
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'tagline': tagline,
        if (logoBase64 != null) 'logo': logoBase64,
        'primary': _hex(primary),
        'primaryDark': _hex(primaryDark),
        'accent': _hex(accent),
        'ok': _hex(ok),
        'warn': _hex(warn),
        'bg': _hex(bg),
        'card': _hex(card),
        'line': _hex(line),
        'muted': _hex(muted),
        'text': _hex(text),
        'active': _hex(active),
      };

  /// Decoded logo, or null when there is none or the payload is not an image. Cached by
  /// its own base64 so the app bar does not re-decode 9 KB on every frame.
  static final Map<String, Uint8List> _logoCache = {};

  Uint8List? get logoBytes {
    final b64 = logoBase64;
    if (b64 == null || b64.isEmpty) return null;
    try {
      return _logoCache.putIfAbsent(b64, () => base64Decode(b64));
    } catch (_) {
      return null; // a broken logo must not take the screen down with it
    }
  }

  /// Parses `#RRGGBB` / `RRGGBB` / `#AARRGGBB`; null when unparseable. Public because the
  /// home screen carries per-metric colours from the same config, in the same notation.
  static Color? parseColor(Object? v) => _color(v);

  static String? _str(Object? v) {
    final s = v?.toString().trim();
    return (s == null || s.isEmpty) ? null : s;
  }

  /// Accepts `#RRGGBB`, `RRGGBB` and `#AARRGGBB`. An unparseable value yields null so the
  /// base colour survives — a typo in a customer's palette must not black out the screen.
  static Color? _color(Object? v) {
    var s = v?.toString().trim();
    if (s == null || s.isEmpty) return null;
    if (s.startsWith('#')) s = s.substring(1);
    if (s.length == 6) s = 'FF$s';
    if (s.length != 8) return null;
    final n = int.tryParse(s, radix: 16);
    return n == null ? null : Color(n);
  }

  static String _hex(Color c) =>
      '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
}
