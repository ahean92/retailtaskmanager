import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pulse_tasks/app_controllers.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/password_hash.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';

import 'support/test_env.dart';

/// Выход — один в один момент. Подтверждённый диалог держит экран, пока выход
/// идёт, но контроллер не может зависеть от того, что все дороги к выходу
/// ведут через этот диалог: повторный вызов (второй диалог, потеря сессии
/// посреди выхода) обязан получить уже идущий Future, а не второй параллельный
/// прогон — второй rebind базы поверх закрывающейся и второе снятие
/// регистрации гонялись бы с первым.

void main() {
  initTestEnv();

  setUp(resetMockStores);

  /// Приложение с вошедшим человеком и без сети: выход не ждёт ни одного
  /// запроса, и всё, что в нём происходит, — локальное. Логин уникален между
  /// прогонами: имя базы содержит его, а ffi-sqlite файл переживает запуск.
  Future<AppControllers> signedInOffline() async {
    final login = 'once${DateTime.now().microsecondsSinceEpoch}';
    final session = Session(
      login: login,
      password: 'secret',
      passwordHash: await PasswordHash.create('secret'),
      name: 'Иванов И.И.',
      performerId: 'p1',
      lastContact: DateTime.now(), // окно входа без сети открыто
    );
    final settings = Settings(baseUrl: 'http://test.local:9080');
    final api = ApiClient(settings, session,
        client: MockClient(
            (_) async => throw const SocketException('нет сети')));
    final app = AppControllers(api: api, settings: settings, session: session);
    await app.account.signIn(login, 'secret');
    return app;
  }

  test('повторный вызов ждёт идущий выход, а не бежит рядом', () async {
    final app = await signedInOffline();
    var notified = 0;
    app.account.addListener(() => notified++);

    await Future.wait([app.account.signOut(), app.account.signOut()]);

    expect(app.session.isActive, isFalse);
    expect(notified, 1,
        reason: 'второй вызов получил тот же Future — экран сменился один раз');
  });

  test('закончившийся выход не запирает следующий — смена на том же телефоне',
      () async {
    final app = await signedInOffline();
    await app.account.signOut();

    // тот же человек возвращается без сети: устройство помнит его учётку
    await app.account.signIn(app.session.login, 'secret');
    expect(app.session.isActive, isTrue);

    await app.account.signOut();
    expect(app.session.isActive, isFalse);
  });
}
