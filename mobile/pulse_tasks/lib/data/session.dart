import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Who is signed in on this device: the platform token every request rides on, the
/// credentials that silently re-issue it, and when the server was last heard from.
///
/// NOTE: for the MVP the password is stored in plain shared_preferences. It is stored at
/// all because re-issuing an expired token means authenticating again — the hash below
/// cannot do that, it only answers "is this the same password" while offline. For a real
/// deployment switch to flutter_secure_storage (see README).
class Session {
  /// How long the device may be signed in without reaching the server. Deliberately equal
  /// to the platform's token lifetime (`authTokenExpiration`, a day by default): were this
  /// window shorter there would be a state where the token is still good but the person
  /// cannot get in, and longer would let a device outlive its own credentials.
  static const offlineWindow = Duration(hours: 24);

  String login;
  String password;

  /// sha256 of the credentials — what an offline sign-in is checked against.
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
  bool matches(String candidateLogin, String candidatePassword) =>
      passwordHash.isNotEmpty &&
      login.toLowerCase() == candidateLogin.trim().toLowerCase() &&
      passwordHash == hashPassword(login, candidatePassword);

  /// The login is the salt: two people who picked the same password get different hashes.
  /// That is all this hash has to do — it never leaves the device and is never sent.
  static String hashPassword(String login, String password) =>
      sha256.convert(utf8.encode('$login:$password')).toString();

  static Future<Session> load() async {
    final sp = await SharedPreferences.getInstance();
    final contact = sp.getInt('lastContact');
    return Session(
      login: sp.getString('login') ?? '',
      password: sp.getString('password') ?? '',
      passwordHash: sp.getString('passwordHash') ?? '',
      token: sp.getString('authToken') ?? '',
      name: sp.getString('performerName') ?? '',
      performerId: sp.getString('performerId') ?? '',
      lastContact:
          contact == null ? null : DateTime.fromMillisecondsSinceEpoch(contact),
      signedIn: sp.getBool('signedIn') ?? false,
    );
  }

  Future<void> save() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString('login', login.trim());
    await sp.setString('password', password);
    await sp.setString('passwordHash', passwordHash);
    await sp.setString('authToken', token);
    await sp.setString('performerName', name);
    await sp.setString('performerId', performerId);
    await sp.setBool('signedIn', signedIn);
    final contact = lastContact;
    if (contact == null) {
      await sp.remove('lastContact');
    } else {
      await sp.setInt('lastContact', contact.millisecondsSinceEpoch);
    }
  }

  /// The server just answered — restart the offline window. Called after every successful
  /// response, which is exactly the point: the window follows the last contact.
  Future<void> touch() async {
    lastContact = DateTime.now();
    final sp = await SharedPreferences.getInstance();
    await sp.setInt('lastContact', lastContact!.millisecondsSinceEpoch);
  }

  /// Sign out, but keep what this device remembers about the account: the hash and the
  /// last-contact time are exactly what lets the same person back in from a shop without a
  /// signal, and the leftover token is no more of a secret than the password beside it.
  Future<void> signOut() async {
    signedIn = false;
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
    await save();
  }
}
