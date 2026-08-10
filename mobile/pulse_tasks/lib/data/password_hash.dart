import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

/// The password as this device remembers it: PBKDF2-HMAC-SHA256 over a random salt.
///
/// It exists for one purpose — the offline sign-in (`Session.matches`) — and it is never
/// sent anywhere. A bare sha256 would have been enough to answer «is this the same
/// password», but not enough to survive the phone itself falling into the wrong hands:
/// four-digit-grade passwords fall to a dictionary in seconds against a fast hash. The
/// salt kills precomputed tables, the iteration count makes each guess cost real time.
///
/// The encoded form carries its own parameters — `pbkdf2-sha256$<iterations>$<salt>$<key>`
/// — so raising [_iterations] later still verifies hashes made by an older build; they get
/// re-made on the next successful sign-in anyway.
class PasswordHash {
  const PasswordHash._();

  /// Chosen for the slowest phone that will run this, not for a server: the derivation is
  /// pure Dart, and everything above this starts to be felt as a pause on «Войти».
  static const _iterations = 100000;
  static const _saltBytes = 16;

  static const _algorithm = 'pbkdf2-sha256';

  static final _random = Random.secure();

  /// A fresh salt every time, so the same password on two devices — or the same password
  /// hashed twice on one — never produces the same string.
  static Future<String> create(String password) {
    final salt = Uint8List.fromList(
        List<int>.generate(_saltBytes, (_) => _random.nextInt(256)));
    return _encode(password, salt, _iterations);
  }

  /// Whether [password] is the one [encoded] was made from. False — rather than a throw —
  /// for anything unreadable: a hash left over from some older format is not a reason to
  /// keep somebody out of the app with a crash, it just means this device cannot vouch for
  /// the password offline.
  static Future<bool> verify(String password, String encoded) async {
    final parts = encoded.split(r'$');
    if (parts.length != 4 || parts[0] != _algorithm) return false;
    final iterations = int.tryParse(parts[1]);
    if (iterations == null || iterations <= 0) return false;
    final Uint8List salt;
    try {
      salt = base64Decode(parts[2]);
    } on FormatException {
      return false;
    }
    final candidate = await _encode(password, salt, iterations);
    return _constantTimeEquals(candidate, encoded);
  }

  static Future<String> _encode(
      String password, Uint8List salt, int iterations) async {
    // off the UI isolate: a hundred thousand HMACs is a third of a second on a decent
    // phone, and «Войти» must not freeze mid-spinner
    final key = await compute(
      _derive,
      (password: password, salt: salt, iterations: iterations),
    );
    return '$_algorithm\$$iterations\$${base64Encode(salt)}\$${base64Encode(key)}';
  }

  /// Comparison that takes the same time whatever the mismatch. Overkill for a local
  /// check — but the cheap habit, not the exception.
  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}

/// RFC 8018 PBKDF2, one block wide: SHA-256 gives 32 bytes and that is the whole key, so
/// there is no second block to concatenate. Top-level because it runs in its own isolate.
Uint8List _derive(
    ({String password, Uint8List salt, int iterations}) request) {
  final hmac = Hmac(sha256, utf8.encode(request.password));
  // U1 = PRF(password, salt || INT(1))
  var u = Uint8List.fromList(hmac.convert([...request.salt, 0, 0, 0, 1]).bytes);
  final result = Uint8List.fromList(u);
  for (var i = 1; i < request.iterations; i++) {
    u = Uint8List.fromList(hmac.convert(u).bytes);
    for (var j = 0; j < result.length; j++) {
      result[j] ^= u[j];
    }
  }
  return result;
}
