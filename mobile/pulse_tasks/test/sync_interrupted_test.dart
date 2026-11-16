import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pulse_tasks/app_controllers.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/models/task.dart';
import 'support/test_env.dart';
import 'support/fake_server.dart';

/// Синхронизация идёт без ожидания и переживает момент, когда её начали: человек
/// вышел из учётной записи, пока она шла, или приложение закрыто (в тестах — конец
/// теста). Дойдя до закрытой базы, она обязана тихо закончиться: не бросить
/// исключением мимо всех и не будить освобождённых слушателей. Ответ сервера
/// здесь держится, пока база не закрыта, — гонка воспроизводится каждый раз, а
/// не иногда.

int _seq = 0;
const _uuid = '44444444-4444-4444-8444-444444444444';

class _Server {
  final calls = <String>[];

  /// Ручка → ответ придержан до complete().
  final held = <String, Completer<void>>{};

  late final Session session;
  late final ApiClient api;

  _Server(Settings settings) {
    session = Session(
      login: 'held${_seq++}', // логин уникален: имя базы содержит его
      name: 'Иванов И.И.',
      token: 'token',
      signedIn: true,
      performerId: 'p1',
    );
    api = ApiClient(settings, session, client: MockClient((request) async {
      final action = actionOf(request);
      calls.add(action);
      await held[action]?.future;
      return okJson(action == 'apiExecutionInfo' ? '{}' : '[]');
    }));
  }

  /// Дождаться, пока придержанный запрос дойдёт до сервера.
  Future<void> reached(String action) async {
    for (var i = 0; i < 200 && !calls.contains(action); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(calls, contains(action));
  }
}

void main() {
  initTestEnv();

  late Settings settings;
  late _Server server;

  setUp(() {
    resetMockStores();
    settings = Settings(baseUrl: 'http://test.local:9080');
    server = _Server(settings);
  });

  Future<AppControllers> signedIn() async {
    final app = AppControllers(
        api: server.api, settings: settings, session: server.session);
    await app.account.updateSettings(settings); // открывает базу этого логина
    await app.repo.db.tasks
        .insertLocalTask(const Task(id: 'ST1', name: 'Витрина'));
    await app.repo.reloadLocal();
    return app;
  }

  test('конец работы посреди обновления списка — проход тихо заканчивается',
      () async {
    final app = await signedIn();
    server.held['apiTasks'] = Completer();

    final pass = app.sync.syncAndRefresh();
    await server.reached('apiTasks');
    app.dispose();
    server.held['apiTasks']!.complete();

    await expectLater(pass, completes,
        reason: 'ответ пришёл в закрытую базу и к освобождённому списку');
  });

  test('конец работы посреди дренажа рождённой на телефоне задачи', () async {
    final app = await signedIn();
    await app.repo.db.queues.createLocalTask(
      const Task(id: _uuid, clientId: _uuid, name: 'Бардак', typeId: 'issue'),
      payloadJson: jsonEncode({'clientId': _uuid, 'typeId': 'issue'}),
      createdAtIso: '2026-11-12T10:00:00.000',
    );
    server.held['apiCreateTask'] = Completer();

    final pass = app.sync.pushPending();
    await server.reached('apiCreateTask');
    app.dispose();
    server.held['apiCreateTask']!.complete();

    await expectLater(pass, completes,
        reason: 'дренаж договорил на закрытой базе и не будит освобождённых');
  });

  test('выход посреди синхронизации быстрый и не возвращает список ушедшего',
      () async {
    final app = await signedIn();
    expect(app.repo.tasks, hasLength(1));
    server.held['apiTasks'] = Completer();

    final pass = app.sync.syncAndRefresh();
    await server.reached('apiTasks');
    // выход не ждёт синхронизацию: ответ сервера ещё придержан
    await app.account.signOut();
    expect(app.session.isActive, isFalse);
    expect(app.repo.tasks, isEmpty);

    server.held['apiTasks']!.complete();
    await expectLater(pass, completes);
    expect(app.repo.tasks, isEmpty,
        reason: 'опоздавший ответ не кладёт задачи ушедшего обратно на экран');
    app.dispose();
  });
}
