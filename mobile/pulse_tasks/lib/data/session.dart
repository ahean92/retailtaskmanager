import 'package:shared_preferences/shared_preferences.dart';

import 'password_hash.dart';
import 'secure_store.dart';

/// Who is signed in on this device: the platform token every request rides on, the
/// credentials that silently re-issue it, and when the server was last heard from.
///
/// All of it lives in [SecureStore] — Keychain on iOS, Keystore on Android. The password
/// is kept at all because re-issuing an expired token means authenticating again; the hash
/// beside it cannot do that, it only answers «is this the same password» while offline.
/// Earlier builds kept the lot in plain shared_preferences; [_migrateFromPreferences]
/// moves what such a device still has and wipes the originals.
class Session {
  /// How long the device may be signed in without reaching the server. Deliberately equal
  /// to the platform's token lifetime (`authTokenExpiration`, a day by default): were this
  /// window shorter there would be a state where the token is still good but the person
  /// cannot get in, and longer would let a device outlive its own credentials.
  static const offlineWindow = Duration(hours: 24);

  String login;
  String password;

  /// PBKDF2 over the password — what an offline sign-in is checked against. See
  /// [PasswordHash] for why it is not a bare sha256 any more.
  String passwordHash;

  /// The platform JWT from `Authentication.getAuthToken`.
  String token;

  /// The executor profile from `apiCurrentUser` — shown in the task list header so the
  /// person can see whose tasks these are.
  String name;
  String performerId;

  /// Last time the server answered anything at all. This — not the last sign-in — is what
  /// the offline window counts from: somebody who signed in on Monday and worked online
  /// all week must not be locked out on Tuesday morning in a shop without a signal.
  DateTime? lastContact;

  /// Whether somebody is signed in right now. A flag of its own rather than "there is a
  /// token": an offline sign-in issues no token, and a token left over on a signed-out
  /// device is not a session.
  bool signedIn;

  Session({
    this.login = '',
    this.password = '',
    this.passwordHash = '',
    this.token = '',
    this.name = '',
    this.performerId = '',
    this.lastContact,
    this.signedIn = false,
  });

  bool get isActive => signedIn && login.isNotEmpty;

  bool get offlineWindowOpen {
    final t = lastContact;
    return t != null && DateTime.now().difference(t) < offlineWindow;
  }

  /// Same login (case-insensitively, as the platform treats it) and the same password.
  Future<bool> matches(String candidateLogin, String candidatePassword) async =>
      passwordHash.isNotEmpty &&
      login.toLowerCase() == candidateLogin.trim().toLowerCase() &&
      await PasswordHash.verify(candidatePassword, passwordHash);

  static const _keyLogin = 'login';
  static const _keyPassword = 'password';
  static const _keyPasswordHash = 'passwordHash';
  static const _keyToken = 'authToken';
  static const _keyName = 'performerName';
  static const _keyPerformerId = 'performerId';
  static const _keySignedIn = 'signedIn';
  static const _keyLastContact = 'lastContact';

  static Future<Session> load() async {
    var stored = await SecureStore.readAll();
    if (stored.isEmpty) {
      // either a clean device or one updated from a build that kept the session in
      // shared_preferences
      stored = await _migrateFromPreferences();
    } else {
      // the secure store is already the source of truth; anything still lying in
      // shared_preferences is a migration that got interrupted halfway, and the password
      // in it must not survive another launch
      await _forgetLegacyPreferences();
    }

    final contact = int.tryParse(stored[_keyLastContact] ?? '');
    return Session(
      login: stored[_keyLogin] ?? '',
      password: stored[_keyPassword] ?? '',
      passwordHash: stored[_keyPasswordHash] ?? '',
      token: stored[_keyToken] ?? '',
      name: stored[_keyName] ?? '',
      performerId: stored[_keyPerformerId] ?? '',
      lastContact:
          contact == null ? null : DateTime.fromMillisecondsSinceEpoch(contact),
      signedIn: stored[_keySignedIn] == '1',
    );
  }

  Future<void> save() => SecureStore.writeAll(_asStored());

  Map<String, String> _asStored() => {
        _keyLogin: login.trim(),
        _keyPassword: password,
        _keyPasswordHash: passwordHash,
        _keyToken: token,
        _keyName: name,
        _keyPerformerId: performerId,
        _keySignedIn: signedIn ? '1' : '',
        _keyLastContact: lastContact?.millisecondsSinceEpoch.toString() ?? '',
      };

  /// The server just answered — restart the offline window. Called after every successful
  /// response, which is exactly the point: the window follows the last contact. One key,
  /// not the whole session: this runs on every request.
  Future<void> touch() async {
    lastContact = DateTime.now();
    await SecureStore.write(
        _keyLastContact, lastContact!.millisecondsSinceEpoch.toString());
  }

  /// Sign out. The token goes with the session — it is the one thing here that opens the
  /// server on its own, and the person who signs out on a shared phone means exactly that.
  /// What this device remembers about the account stays: the hash and the last-contact
  /// time are what lets the same person back in from a shop without a signal.
  Future<void> signOut() async {
    signedIn = false;
    token = '';
    await save();
  }

  /// Forget the account outright — for when the server itself refuses the credentials and
  /// nothing here is worth remembering any more. The connection settings survive: the
  /// address belongs to the installation, not to the person.
  Future<void> clear() async {
    login = '';
    password = '';
    passwordHash = '';
    token = '';
    name = '';
    performerId = '';
    lastContact = null;
    signedIn = false;
    await SecureStore.deleteAll();
  }

  static const _legacyKeys = [
    _keyLogin,
    _keyPassword,
    _keyPasswordHash,
    _keyToken,
    _keyName,
    _keyPerformerId,
    _keySignedIn,
    _keyLastContact,
  ];

  /// Move a session left behind by a build that kept it in shared_preferences — in the
  /// clear, and therefore in the device backup too. Runs once: the originals are removed,
  /// so the next launch finds nothing to move. Returns what the secure store now holds.
  ///
  /// Nobody has to sign in again after the update, which is the whole point of doing this
  /// instead of simply wiping the old keys.
  static Future<Map<String, String>> _migrateFromPreferences() async {
    final sp = await SharedPreferences.getInstance();
    if (!_legacyKeys.any(sp.containsKey)) return const {};

    // The old hash was a bare sha256 and cannot be upgraded on its own — but the password
    // it was made from is lying right there in the clear, so the new hash is computed
    // rather than moved. A device that somehow has no stored password loses only the
    // offline sign-in, until the next successful one online.
    final password = sp.getString(_keyPassword) ?? '';
    final moved = <String, String>{
      _keyLogin: sp.getString(_keyLogin) ?? '',
      _keyPassword: password,
      _keyPasswordHash: sp.containsKey(_keyPassword)
          ? await PasswordHash.create(password)
          : '',
      _keyToken: sp.getString(_keyToken) ?? '',
      _keyName: sp.getString(_keyName) ?? '',
      _keyPerformerId: sp.getString(_keyPerformerId) ?? '',
      _keySignedIn: (sp.getBool(_keySignedIn) ?? false) ? '1' : '',
      _keyLastContact: sp.getInt(_keyLastContact)?.toString() ?? '',
    };
    await SecureStore.writeAll(moved);

    // only now: a crash before this line costs one more launch with the old values still
    // in place, a crash after it would have cost the session
    await _forgetLegacyPreferences();
    moved.removeWhere((_, value) => value.isEmpty);
    return moved;
  }

  /// Erase the account keys an older build left in shared_preferences. The address, the
  /// brand and the cached home page stay — they were never secrets.
  static Future<void> _forgetLegacyPreferences() async {
    final sp = await SharedPreferences.getInstance();
    for (final key in _legacyKeys) {
      if (sp.containsKey(key)) await sp.remove(key);
    }
  }
}
