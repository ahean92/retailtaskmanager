import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pulse_tasks/data/password_hash.dart';
import 'package:pulse_tasks/data/secure_store.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The half of the storage change that unit tests cannot reach: a real Keystore on a real
/// Android, a real Keychain on a real iOS, and the actual shared_preferences file the old
/// build left the password in.
///
///     flutter test integration_test -d <device>
///
/// The last test deliberately leaves a migrated session on the device, so that
/// `adb shell run-as com.mycompany.pulse_tasks cat shared_prefs/FlutterSharedPreferences.xml`
/// can be read afterwards and shown to contain no password.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> wipe() async {
    await SecureStore.deleteAll();
    await (await SharedPreferences.getInstance()).clear();
  }

  setUp(wipe);

  testWidgets('сессия переживает перезапуск: пишется и читается из Keystore',
      (tester) async {
    final saved = Session(
      login: 'ivanov',
      password: 'secret',
      passwordHash: await PasswordHash.create('secret'),
      token: 'jwt-from-the-platform',
      name: 'Иванов И.И.',
      performerId: 'p1',
      lastContact: DateTime.now().subtract(const Duration(hours: 2)),
      signedIn: true,
    );
    await saved.save();

    // то же, что делает main() на следующем запуске приложения
    final reloaded = await Session.load();
    expect(reloaded.isActive, isTrue);
    expect(reloaded.token, 'jwt-from-the-platform');
    expect(reloaded.name, 'Иванов И.И.');
    expect(reloaded.performerId, 'p1');
    expect(reloaded.offlineWindowOpen, isTrue);
    expect(await reloaded.matches('IVANOV', 'secret'), isTrue);
    expect(await reloaded.matches('ivanov', 'other'), isFalse);

    // и ничего из этого не оказалось в открытом хранилище
    final sp = await SharedPreferences.getInstance();
    expect(sp.getKeys(), isEmpty);
  });

  testWidgets('выход стирает токен, но вход без сети остаётся возможен',
      (tester) async {
    final s = Session(
      login: 'ivanov',
      password: 'secret',
      passwordHash: await PasswordHash.create('secret'),
      token: 'jwt',
      lastContact: DateTime.now().subtract(const Duration(hours: 2)),
      signedIn: true,
    );
    await s.save();
    await s.signOut();

    final reloaded = await Session.load();
    expect(reloaded.isActive, isFalse);
    expect(reloaded.token, isEmpty);
    expect(await reloaded.matches('ivanov', 'secret'), isTrue);
    expect(reloaded.offlineWindowOpen, isTrue);

    await reloaded.clear();
    final cleared = await Session.load();
    expect(await cleared.matches('ivanov', 'secret'), isFalse);
    expect(cleared.login, isEmpty);
  });

  // Сколько на самом деле стоит PBKDF2 на этом устройстве — число из замера, а не из
  // предположения: если оно уедет за пару секунд, итерации придётся пересматривать.
  testWidgets('хэширование пароля укладывается в две секунды', (tester) async {
    final sw = Stopwatch()..start();
    final hash = await PasswordHash.create('secret');
    final created = sw.elapsedMilliseconds;
    sw.reset();
    expect(await PasswordHash.verify('secret', hash), isTrue);
    final verified = sw.elapsedMilliseconds;

    debugPrint('PBKDF2 на устройстве: create $created мс, verify $verified мс');
    expect(created, lessThan(2000));
    expect(verified, lessThan(2000));
  });

  testWidgets(
      'обновление поверх старой сборки: пароль уезжает из shared_preferences',
      (tester) async {
    final sp = await SharedPreferences.getInstance();
    // ровно то, что писала прошлая версия Session.save()
    await sp.setString('login', 'ivanov');
    await sp.setString('password', 'secret');
    await sp.setString('passwordHash', 'a0b1c2d3e4f5');
    await sp.setString('authToken', 'jwt');
    await sp.setString('performerName', 'Иванов И.И.');
    await sp.setString('performerId', 'p1');
    await sp.setBool('signedIn', true);
    await sp.setInt('lastContact',
        DateTime.now().subtract(const Duration(hours: 2)).millisecondsSinceEpoch);
    // не сессия — адрес принадлежит установке и переезжать никуда не должен
    await sp.setString('baseUrl', 'http://10.0.2.2:9080');

    final migrated = await Session.load();
    expect(migrated.isActive, isTrue, reason: 'вход заново не требуется');
    expect(migrated.token, 'jwt');
    expect(migrated.offlineWindowOpen, isTrue);
    expect(await migrated.matches('ivanov', 'secret'), isTrue,
        reason: 'хэш пересчитан из перенесённого пароля');

    final after = await SharedPreferences.getInstance();
    expect(after.getString('password'), isNull);
    expect(after.getString('passwordHash'), isNull);
    expect(after.getString('authToken'), isNull);
    expect(after.getString('login'), isNull);
    expect(after.getBool('signedIn'), isNull);
    expect(after.getInt('lastContact'), isNull);
    expect(after.getString('baseUrl'), 'http://10.0.2.2:9080');
  });

  // «Пароль не читается ни из shared_preferences, ни из бэкапа» — проверяется не по
  // ключам API, а по байтам: приложение обходит собственный каталог данных (всё, что
  // попадает в бэкап устройства) и ищет там свой же пароль. Маркеры выбраны так, чтобы
  // совпадение нельзя было списать на случайность.
  testWidgets('в каталоге данных приложения пароля и токена нет открытым текстом',
      (tester) async {
    const password = 'PLAINTEXT-PASSWORD-MARKER-42';
    const token = 'PLAINTEXT-TOKEN-MARKER-42';

    // сначала так, как хранила старая сборка, — и переезд
    final sp = await SharedPreferences.getInstance();
    await sp.setString('login', 'ivanov');
    await sp.setString('password', password);
    await sp.setString('authToken', token);
    await sp.setBool('signedIn', true);
    await sp.setInt('lastContact', DateTime.now().millisecondsSinceEpoch);
    final migrated = await Session.load();
    expect(await migrated.matches('ivanov', password), isTrue);
    // и ещё раз — обычным сохранением уже нового кода
    await migrated.save();
    await migrated.touch();

    final root = (await getApplicationSupportDirectory()).parent;
    final needles = [utf8.encode(password), utf8.encode(token)];
    final searched = <String>[];
    final leaking = <String>[];
    await for (final entry in root.list(recursive: true, followLinks: false)) {
      if (entry is! File) continue;
      // kernel_blob.bin — Dart-код этого самого теста, который в debug-сборке едет на
      // устройство целиком, вместе с константами выше. Это артефакт запуска тестов, а не
      // хранилище: в release-сборке его нет.
      if (entry.path.contains('flutter_assets')) continue;
      final List<int> bytes;
      try {
        bytes = await entry.readAsBytes();
      } on FileSystemException {
        continue; // не наш файл — читать нечем и незачем
      }
      searched.add(entry.path);
      if (needles.any((n) => _contains(bytes, n))) leaking.add(entry.path);
    }

    debugPrint('просмотрено файлов в ${root.path}: ${searched.length}');
    expect(searched, isNotEmpty, reason: 'каталог данных пуст — проверять нечего');
    expect(searched.where((p) => p.contains('FlutterSecureStorage')), isNotEmpty,
        reason: 'защищённое хранилище должно было материализоваться на диске');
    expect(leaking, isEmpty);
  });
}

/// Наивный поиск подстроки в байтах: файлов десятки, а не тысячи.
bool _contains(List<int> haystack, List<int> needle) {
  if (needle.isEmpty || haystack.length < needle.length) return false;
  for (var i = 0; i <= haystack.length - needle.length; i++) {
    var j = 0;
    while (j < needle.length && haystack[i + j] == needle[j]) {
      j++;
    }
    if (j == needle.length) return true;
  }
  return false;
}
