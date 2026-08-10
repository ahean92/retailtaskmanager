import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_tasks/data/password_hash.dart';

void main() {
  test('the password verifies against its own hash and nothing else', () async {
    final hash = await PasswordHash.create('secret');
    expect(await PasswordHash.verify('secret', hash), isTrue);
    expect(await PasswordHash.verify('Secret', hash), isFalse);
    expect(await PasswordHash.verify('', hash), isFalse);
  });

  // An empty password is what the dev server's `admin` has, and it must hash and verify
  // like any other rather than being treated as "no hash at all".
  test('an empty password is still a password', () async {
    final hash = await PasswordHash.create('');
    expect(hash, isNotEmpty);
    expect(await PasswordHash.verify('', hash), isTrue);
    expect(await PasswordHash.verify('secret', hash), isFalse);
  });

  // The salt is the difference between "somebody stole one hash" and "somebody who once
  // built a rainbow table reads every device in the fleet".
  test('the same password hashes differently every time', () async {
    final a = await PasswordHash.create('secret');
    final b = await PasswordHash.create('secret');
    expect(a, isNot(equals(b)));
    expect(await PasswordHash.verify('secret', b), isTrue);
  });

  test('the hash carries its parameters and not the password', () async {
    final hash = await PasswordHash.create('secret');
    final parts = hash.split(r'$');
    expect(parts, hasLength(4));
    expect(parts[0], 'pbkdf2-sha256');
    expect(int.parse(parts[1]), greaterThanOrEqualTo(100000));
    expect(hash, isNot(contains('secret')));
  });

  // A hash from some older or corrupted format must not crash the sign-in — it just means
  // this device cannot vouch for the password without the server.
  test('an unreadable hash verifies nothing', () async {
    for (final junk in [
      '',
      'deadbeef',
      r'sha256$1$c2FsdA==$aGFzaA==',
      r'pbkdf2-sha256$0$c2FsdA==$aGFzaA==',
      r'pbkdf2-sha256$100000$not base64!$aGFzaA==',
      r'pbkdf2-sha256$100000$c2FsdA==',
    ]) {
      expect(await PasswordHash.verify('secret', junk), isFalse,
          reason: 'accepted «$junk»');
    }
  });
}
