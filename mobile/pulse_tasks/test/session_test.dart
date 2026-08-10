import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:shared_preferences/shared_preferences.dart';

Session _signedIn({Duration? sinceContact, String login = 'ivanov'}) => Session(
      login: login,
      password: 'secret',
      passwordHash: Session.hashPassword(login, 'secret'),
      token: 'jwt',
      name: 'Иванов И.И.',
      performerId: 'p1',
      lastContact: sinceContact == null
          ? null
          : DateTime.now().subtract(sinceContact),
      signedIn: true,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized(); // shared_preferences mock needs it

  test('the password is checked against the hash, never stored in the clear form', () {
    final s = _signedIn();
    expect(s.matches('ivanov', 'secret'), isTrue);
    expect(s.matches('ivanov', 'Secret'), isFalse);
    expect(s.matches('petrov', 'secret'), isFalse);
    expect(s.passwordHash, isNot(contains('secret')));
  });

  // The platform treats logins case-insensitively; typing IVANOV on a phone keyboard must
  // not be the reason somebody cannot start their shift.
  test('the login matches regardless of case', () {
    expect(_signedIn().matches('IVANOV', 'secret'), isTrue);
  });

  test('a device that has never signed in matches nothing', () {
    expect(Session().matches('ivanov', 'secret'), isFalse);
  });

  // The window is measured from the last contact with the server, not from the last
  // sign-in — that is what keeps somebody who worked online all week from being locked
  // out on the first morning without a signal.
  test('the offline window is open for a day after the last contact', () {
    expect(_signedIn(sinceContact: const Duration(hours: 23)).offlineWindowOpen,
        isTrue);
    expect(_signedIn(sinceContact: const Duration(hours: 25)).offlineWindowOpen,
        isFalse);
    expect(_signedIn().offlineWindowOpen, isFalse);
  });

  // Deliberately the same as the platform's token lifetime: no state where the token has
  // expired but the offline sign-in is still allowed.
  test('the offline window equals the token lifetime', () {
    expect(Session.offlineWindow, const Duration(hours: 24));
  });

  test('a session is what the flag says, not what the token says', () {
    expect(_signedIn().isActive, isTrue);
    expect(Session(login: 'ivanov', token: 'jwt').isActive, isFalse);
    expect(Session(signedIn: true).isActive, isFalse);
  });

  // Signing out must not burn the bridge back: the way in from a shop without a signal is
  // the stored hash, and wiping it on sign-out would make «вход без сети» unreachable.
  test('signing out keeps what an offline sign-in needs', () async {
    SharedPreferences.setMockInitialValues({});
    final s = _signedIn(sinceContact: const Duration(hours: 2));
    await s.save();
    await s.signOut();

    final reloaded = await Session.load();
    expect(reloaded.isActive, isFalse);
    expect(reloaded.matches('ivanov', 'secret'), isTrue);
    expect(reloaded.offlineWindowOpen, isTrue);
  });

  // The server refused the credentials — nothing here is worth remembering, and least of
  // all anything that would let the old password back in offline.
  test('a cleared session lets nobody in', () async {
    SharedPreferences.setMockInitialValues({});
    final s = _signedIn(sinceContact: const Duration(hours: 2));
    await s.save();
    await s.clear();

    final reloaded = await Session.load();
    expect(reloaded.isActive, isFalse);
    expect(reloaded.matches('ivanov', 'secret'), isFalse);
    expect(reloaded.offlineWindowOpen, isFalse);
  });
}
