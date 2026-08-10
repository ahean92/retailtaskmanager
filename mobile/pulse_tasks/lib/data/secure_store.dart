import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Where the secrets of the signed-in account live: Keychain on iOS, Keystore-backed
/// EncryptedSharedPreferences on Android.
///
/// Only what would let somebody else into the account goes here — the token, the
/// credentials it is silently re-issued with, and the hash the offline sign-in is checked
/// against. The server address and the cached brand/home are not secrets and stay in
/// shared_preferences, where they can be read fast and restored from a backup.
class SecureStore {
  const SecureStore._();

  static const _storage = FlutterSecureStorage(
    // AES under a master key held by the Keystore, rather than the plugin's older
    // per-value RSA scheme. Needs API 23; the app's minSdk is 24.
    //
    // resetOnError: an unreadable store (the Keystore key gone after a restore or a system
    // upgrade — the classic EncryptedSharedPreferences failure) throws on every read
    // otherwise, and an app that cannot start is worse than one that asks for the password
    // again. Nothing irreplaceable is kept here: the person signs in and it is all back.
    aOptions: AndroidOptions(
        encryptedSharedPreferences: true, resetOnError: true),
    // `first_unlock` and not `unlocked`: the sync runs in the background, and the phone in
    // an apron pocket is locked most of the shift. `_this_device` is what keeps the item
    // out of iCloud and out of an encrypted device backup — it never leaves this phone.
    iOptions: IOSOptions(
        accessibility: KeychainAccessibility.first_unlock_this_device),
  );

  /// The whole session in one platform call — on Android every read decrypts, and eight
  /// separate reads at startup are eight of them.
  static Future<Map<String, String>> readAll() => _storage.readAll();

  /// An empty value is stored as no value at all: a key that is not there reads back as
  /// `''` anyway, and leaving blanks behind would keep the shape of a session that is gone.
  static Future<void> write(String key, String value) => value.isEmpty
      ? _storage.delete(key: key)
      : _storage.write(key: key, value: value);

  static Future<void> writeAll(Map<String, String> values) async {
    for (final e in values.entries) {
      await write(e.key, e.value);
    }
  }

  static Future<void> deleteAll() => _storage.deleteAll();
}
