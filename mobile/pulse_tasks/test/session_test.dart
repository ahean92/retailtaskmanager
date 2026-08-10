import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_tasks/data/password_hash.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<Session> _signedIn({
  Duration? sinceContact,
  String login = 'ivanov',
}) async =>
    Session(
      login: login,
      password: 'secret',
      passwordHash: await PasswordHash.create('secret'),
      token: 'jwt',
      name: 'Иванов И.И.',
      performerId: 'p1',
      lastContact:
          sinceContact == null ? null : DateTime.now().subtract(sinceContact),
      signedIn: true,
    );

/// The Keychain/Keystore of the test run: the returned map *is* the store, so a test can
/// look at what actually ended up on the device.
Map<String, String> _emptySecureStore() {
  final store = <String, String>{};
  FlutterSecureStorage.setMockInitialValues(store);
  return store;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized(); // shared_preferences mock needs it

  setUp(() {
    _emptySecureStore();
    SharedPreferences.setMockInitialValues({});
  });

  test('the password is checked against the hash, never stored in the clear form',
      () async {
    final s = await _signedIn();
    expect(await s.matches('ivanov', 'secret'), isTrue);
    expect(await s.matches('ivanov', 'Secret'), isFalse);
    expect(await s.matches('petrov', 'secret'), isFalse);
    expect(s.passwordHash, isNot(contains('secret')));
  });

  // The platform treats logins case-insensitively; typing IVANOV on a phone keyboard must
  // not be the reason somebody cannot start their shift.
  test('the login matches regardless of case', () async {
    expect(await (await _signedIn()).matches('IVANOV', 'secret'), isTrue);
  });

  test('a device that has never signed in matches nothing', () async {
    expect(await Session().matches('ivanov', 'secret'), isFalse);
  });

  // The window is measured from the last contact with the server, not from the last
  // sign-in — that is what keeps somebody who worked online all week from being locked
  // out on the first morning without a signal.
  test('the offline window is open for a day after the last contact', () async {
    expect(
        (await _signedIn(sinceContact: const Duration(hours: 23)))
            .offlineWindowOpen,
        isTrue);
    expect(
        (await _signedIn(sinceContact: const Duration(hours: 25)))
            .offlineWindowOpen,
        isFalse);
    expect((await _signedIn()).offlineWindowOpen, isFalse);
  });

  // Deliberately the same as the platform's token lifetime: no state where the token has
  // expired but the offline sign-in is still allowed.
  test('the offline window equals the token lifetime', () {
    expect(Session.offlineWindow, const Duration(hours: 24));
  });

  test('a session is what the flag says, not what the token says', () async {
    expect((await _signedIn()).isActive, isTrue);
    expect(Session(login: 'ivanov', token: 'jwt').isActive, isFalse);
    expect(Session(signedIn: true).isActive, isFalse);
  });

  // The whole point of the move: neither the password nor the token is left anywhere an
  // adb backup or a file browser can reach.
  test('nothing about the account is written to shared_preferences', () async {
    final secure = _emptySecureStore();
    final s = await _signedIn(sinceContact: const Duration(hours: 2));
    await s.save();
    await s.touch();

    final sp = await SharedPreferences.getInstance();
    expect(sp.getKeys(), isEmpty);
    expect(secure['password'], 'secret');
    expect(secure['authToken'], 'jwt');
    expect(secure['lastContact'], isNotNull);
  });

  // Signing out must not burn the bridge back: the way in from a shop without a signal is
  // the stored hash, and wiping it on sign-out would make «вход без сети» unreachable.
  // The token is another matter — it opens the server on its own.
  test('signing out drops the token and keeps what an offline sign-in needs',
      () async {
    final secure = _emptySecureStore();
    final s = await _signedIn(sinceContact: const Duration(hours: 2));
    await s.save();
    await s.signOut();

    final reloaded = await Session.load();
    expect(reloaded.isActive, isFalse);
    expect(reloaded.token, isEmpty);
    expect(secure.containsKey('authToken'), isFalse);
    expect(await reloaded.matches('ivanov', 'secret'), isTrue);
    expect(reloaded.offlineWindowOpen, isTrue);
  });

  // The server refused the credentials — nothing here is worth remembering, and least of
  // all anything that would let the old password back in offline.
  test('a cleared session lets nobody in', () async {
    final secure = _emptySecureStore();
    final s = await _signedIn(sinceContact: const Duration(hours: 2));
    await s.save();
    await s.clear();

    expect(secure, isEmpty);
    final reloaded = await Session.load();
    expect(reloaded.isActive, isFalse);
    expect(await reloaded.matches('ivanov', 'secret'), isFalse);
    expect(reloaded.offlineWindowOpen, isFalse);
  });

  group('обновление поверх сборки, хранившей сессию в shared_preferences', () {
    final lastContact =
        DateTime.now().subtract(const Duration(hours: 2)).millisecondsSinceEpoch;

    void legacyPreferences() => SharedPreferences.setMockInitialValues({
          'login': 'ivanov',
          'password': 'secret',
          // sha256('ivanov:secret') — what the old build wrote
          'passwordHash':
              '1c0b2b0f4e4ee0f9f0bd28b1fbcbbf5fcbe6c1d0e2b3a4c5d6e7f8091a2b3c4d',
          'authToken': 'jwt',
          'performerName': 'Иванов И.И.',
          'performerId': 'p1',
          'signedIn': true,
          'lastContact': lastContact,
          // not the session's — the address belongs to the installation and stays put
          'baseUrl': 'http://server:9080',
        });

    test('сессия переезжает целиком и вход заново не требуется', () async {
      final secure = _emptySecureStore();
      legacyPreferences();

      final s = await Session.load();
      expect(s.isActive, isTrue);
      expect(s.token, 'jwt');
      expect(s.name, 'Иванов И.И.');
      expect(s.performerId, 'p1');
      expect(s.offlineWindowOpen, isTrue);
      // старый sha256 не переносится, а пересчитывается из пароля, который лежал рядом
      expect(secure['passwordHash'], startsWith(r'pbkdf2-sha256$'));
      expect(await s.matches('ivanov', 'secret'), isTrue);
    });

    test('старые значения из shared_preferences затираются', () async {
      legacyPreferences();
      await Session.load();

      final sp = await SharedPreferences.getInstance();
      expect(sp.getString('password'), isNull);
      expect(sp.getString('passwordHash'), isNull);
      expect(sp.getString('authToken'), isNull);
      expect(sp.getString('login'), isNull);
      expect(sp.getBool('signedIn'), isNull);
      expect(sp.getInt('lastContact'), isNull);
      expect(sp.getString('baseUrl'), 'http://server:9080');
    });

    test('переезд одноразовый: то, что уже в защищённом хранилище, не трогается',
        () async {
      final secure = _emptySecureStore();
      legacyPreferences();
      await Session.load();
      secure['authToken'] = 'fresh-jwt';

      // на этом запуске в shared_preferences уже ничего нет — читаем что лежит
      expect((await Session.load()).token, 'fresh-jwt');
    });

    // Переезд успел записать секреты, но не успел стереть исходники — приложение убили
    // между двумя await. Пароль в открытом виде не должен пережить следующий запуск.
    test('недоделанный переезд дочищается на следующем запуске', () async {
      _emptySecureStore()['authToken'] = 'jwt';
      legacyPreferences();

      final s = await Session.load();
      expect(s.token, 'jwt');
      final sp = await SharedPreferences.getInstance();
      expect(sp.getString('password'), isNull);
      expect(sp.getString('baseUrl'), 'http://server:9080');
    });
  });
}
