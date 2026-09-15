import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:pulse_tasks/app_controllers.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/local_db.dart';
import 'package:pulse_tasks/data/password_hash.dart';
import 'package:pulse_tasks/data/push_service.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/ui/settings_screen.dart';

import 'support/fake_server.dart';
import 'support/test_env.dart';

/// После «Выйти» и входа без сети у сессии нет токена, и запросы к ручкам уходили
/// анонимными. Стенд приёмки в dev-режиме исполнял их под admin: телефон показывал чужой
/// список, писал журнал координат под чужим логином и отправлял накопленную очередь от
/// чужого имени (#37178, дефект 26 журнала приёмки). Здесь это записано сценариями: без
/// токена к ручке не уходит ничего, личность подтверждается до первого запроса, а
/// непризнанная сервером — возвращает к форме входа.

int _seq = 0;

const _base = 'http://test.local:9080';

/// Сервер стенда. Токен выдаёт по паролю, профиль — по токену, а запрос без
/// Authorization — как стенд в dev-режиме — не отвергает. Он только запоминает каждый
/// запрос, и тест видит всё, что ушло.
class _Server {
  /// Логин уникален и между прогонами: имя базы содержит его, а файл ffi-sqlite
  /// переживает запуск.
  final login = 'ivanov${DateTime.now().microsecondsSinceEpoch}_${_seq++}';

  final requests = <http.Request>[];

  /// Сети нет — запрос обрывается, не дойдя до сервера.
  bool down = true;

  /// Пароль, который сервер принимает сейчас.
  String password = 'secret';

  /// Кого сервер видит за учётной записью; null — она не исполнитель.
  String? performerId = 'p1';

  /// Токен, срок которого истёк: ручки отвечают на него 401.
  String? expired;

  int _issued = 0;

  List<String> get actions => [for (final r in requests) actionOf(r)];

  /// Запросы к ручкам без Authorization — то, чего быть не должно. Бренд не в счёт:
  /// его спрашивают до входа.
  List<String> get anonymous => [
        for (final r in requests)
          if (r.url.path.contains('/exec/StoreTask.') &&
              actionOf(r) != 'apiBrand' &&
              !r.headers.containsKey('Authorization'))
            actionOf(r)
      ];

  late final http.Client client = MockClient((request) async {
    if (down) throw const SocketException('нет сети');
    requests.add(request);
    final auth = request.headers['Authorization'];
    switch (actionOf(request)) {
      case 'getAuthToken':
        final basic = 'Basic ${base64Encode(utf8.encode('$login:$password'))}';
        if (auth != basic) return http.Response('', 401);
        return http.Response('jwt${++_issued}', 200);
      case 'apiBrand':
        return okJson('[{"name":"Пульс"}]');
    }
    if (expired != null && auth == 'Bearer $expired') {
      return http.Response('', 401);
    }
    if (actionOf(request) == 'apiCurrentUser') {
      final id = performerId;
      if (id == null) {
        return http.Response('{"error":"notPerformer","message":"-"}', 403);
      }
      return okJson('[{"id":"$id","name":"Иванов И.И."}]');
    }
    return request.method == 'POST' ? http.Response('', 200) : okJson('[]');
  });

  /// Приложение, в которое вошли без сети — после «Выйти», поэтому без токена. Вход
  /// настоящий: пароль сверяется с хэшем, база вошедшего открывается.
  Future<AppControllers> signedInOffline(
      {PushService Function(ApiClient api, Session session)? push}) async {
    final settings = Settings(baseUrl: _base);
    final session = Session(
      login: login,
      password: 'secret',
      passwordHash: await PasswordHash.create('secret'),
      name: 'Иванов И.И.',
      performerId: 'p1',
      lastContact: DateTime.now(), // окно входа без сети открыто
    );
    final api = ApiClient(settings, session, client: client);
    final app = AppControllers(
        api: api,
        settings: settings,
        session: session,
        push: push?.call(api, session));
    await app.account.signIn(login, 'secret');
    expect(session.isActive, isTrue, reason: 'вход без сети не состоялся');
    expect(session.token, isEmpty);
    return app;
  }
}

/// Пуш без Firebase: регистрация — тот же запрос к серверу, что у настоящего сервиса.
class _Push extends PushService {
  _Push(ApiClient api, Session session) : super(api: api, session: session);

  int registered = 0;

  @override
  Future<void> register() async {
    registered++;
    await api.registerDevice('fcm', 'android', '1.0.0+1');
  }
}

/// Дождаться того, что приложение отпустило без await: регистрации телефона, закрытия
/// базы после потери сессии.
Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 300 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

String _now() => DateTime.now().toIso8601String();

void main() {
  initTestEnv();

  setUp(resetMockStores);

  group('после входа без сети', () {
    test('личность подтверждается до первого запроса — одна на все параллельные',
        () async {
      final server = _Server();
      final app = await server.signedInOffline();
      server.down = false;

      await Future.wait([
        app.api.fetchTasks(),
        app.api.fetchNotifications(),
        app.api.fetchHome(),
      ]);

      expect(server.actions.take(2), ['getAuthToken', 'apiCurrentUser'],
          reason: 'ни одна ручка не спрошена раньше подтверждения');
      expect(server.actions.where((a) => a == 'getAuthToken'), hasLength(1),
          reason: 'один токен на все запросы, ждавшие его');
      expect(server.anonymous, isEmpty);
      expect(
          {for (final r in server.requests.skip(1)) r.headers['Authorization']},
          {'Bearer jwt1'});
      expect(app.session.token, 'jwt1');
      await app.account.signOut(); // закрыть базу за собой
    });

    test('очередь и регистрация телефона уезжают от имени вошедшего', () async {
      final server = _Server();
      late _Push push;
      final app = await server.signedInOffline(
          push: (api, session) => push = _Push(api, session));
      await app.repo.db.tasks.enqueue('ST0001', 's2', 'Выполнена', _now());
      expect(server.requests, isEmpty, reason: 'без сети не ушло ничего');

      server.down = false;
      await app.sync.pushPending();
      await _until(() => server.actions.contains('apiRegisterDevice'));

      expect(server.actions,
          containsAllInOrder(['getAuthToken', 'apiCurrentUser', 'apiSetStatus']));
      expect(server.actions, contains('apiRegisterDevice'));
      expect(push.registered, 1,
          reason: 'телефон регистрируется следом за подтверждением, один раз');
      expect(server.anonymous, isEmpty);
      for (final r in server.requests.where((r) => r.method == 'POST')) {
        expect(r.headers['Authorization'], 'Bearer jwt1', reason: actionOf(r));
      }
      await app.account.signOut();
    });

    test('пароль сменили, пока телефона не было в сети, — форма входа, очередь ждёт',
        () async {
      final server = _Server()..password = 'changed';
      final app = await server.signedInOffline();
      final key = app.repo.db.userKey;
      await app.repo.db.tasks.enqueue('ST0001', 's2', 'Выполнена', _now());
      var loginForm = false;
      app.account.addListener(() => loginForm = !app.session.isActive);

      server.down = false;
      await app.sync.pushPending();
      await _until(() => app.base.db == null);

      expect(server.actions, ['getAuthToken'],
          reason: 'дальше выдачи токена не ушло ничего');
      expect(loginForm, isTrue, reason: 'приложение вернулось к форме входа');
      final db = await LocalDb.open(key);
      expect((await db.tasks.getOutbox()).keys, ['ST0001'],
          reason: 'очередь осталась в базе того, кто её сделал');
      await db.close();
    });

    for (final (who, performer) in [
      ('другого исполнителя', 'p2'),
      ('не исполнителя', null),
    ]) {
      test('сервер видит за учётной записью $who — форма входа, очередь ждёт',
          () async {
        final server = _Server()..performerId = performer;
        final app = await server.signedInOffline();
        await app.repo.db.tasks.enqueue('ST0001', 's2', 'Выполнена', _now());

        server.down = false;
        await app.sync.pushPending();
        await _until(() => app.base.db == null);

        expect(server.actions, ['getAuthToken', 'apiCurrentUser'],
            reason: 'очередь не ушла под учётной записью, которую сервер не признал');
        expect(app.session.isActive, isFalse);
        expect(app.session.token, isEmpty,
            reason: 'выписанный токен сессии не достался');
      });
    }
  });

  test('без сессии запрос к ручке не уходит вовсе', () async {
    final server = _Server()..down = false;
    final api = ApiClient(Settings(baseUrl: _base), Session(),
        client: server.client);

    await expectLater(
        api.fetchTasks(), throwsA(isA<SessionExpiredException>()));
    expect(server.requests, isEmpty);
  });

  // Суточный токен протухает у всех запросов разом: новый выписывается один, а не по
  // одному на каждый упёршийся в 401.
  test('протухший токен — один новый на все запросы, упёршиеся в 401', () async {
    final server = _Server()
      ..down = false
      ..expired = 'old';
    final session = Session(
        login: server.login,
        password: 'secret',
        token: 'old',
        performerId: 'p1',
        signedIn: true);
    final api =
        ApiClient(Settings(baseUrl: _base), session, client: server.client);

    await Future.wait(
        [api.fetchTasks(), api.fetchNotifications(), api.fetchHome()]);

    expect(server.actions.where((a) => a == 'getAuthToken'), hasLength(1));
    expect(session.token, 'jwt1');
  });

  group('без авторизации', () {
    test('бренд — без токена и без отметки контакта', () async {
      final server = _Server()..down = false;
      final contact = DateTime.now().subtract(const Duration(hours: 2));
      final session = Session(
          login: server.login,
          token: 'jwt',
          performerId: 'p1',
          signedIn: true,
          lastContact: contact);
      final api =
          ApiClient(Settings(baseUrl: _base), session, client: server.client);

      expect((await api.fetchBrand())?['name'], 'Пульс');
      expect(server.requests.single.headers.containsKey('Authorization'),
          isFalse);
      expect(session.lastContact, contact);
    });

    // Настройки открываются и из работающего приложения, а проверяется в них адрес,
    // который ещё не сохранён: он может вести к чужому серверу.
    testWidgets('проверка адреса в настройках не отправляет токен вошедшего',
        (tester) async {
      final contact = DateTime.now().subtract(const Duration(hours: 2));
      final session = Session(
          login: 'ivanov',
          name: 'Иванов И.И.',
          token: 'jwt',
          performerId: 'p1',
          signedIn: true,
          lastContact: contact);
      final settings = Settings(baseUrl: _base);
      final app = AppControllers(
          api: ApiClient(settings, session),
          settings: settings,
          session: session);
      final seen = <http.Request>[];
      final other = MockClient((request) async {
        seen.add(request);
        return okJson('[{"name":"Чужой сервер"}]');
      });

      await tester.pumpWidget(MultiProvider(
          providers: app.providers,
          child: const MaterialApp(home: SettingsScreen())));
      await tester.enterText(find.byType(TextFormField), '10.0.0.2:9080');
      // клиент проверки создаётся на нажатие — внутри этой зоны он и есть [other]
      await http.runWithClient(() async {
        await tester.tap(find.text('Проверить подключение'));
        await tester.pumpAndSettle();
      }, () => other);

      expect(seen, hasLength(1));
      expect(seen.single.url.toString(), 'http://10.0.0.2:9080/exec/StoreTask.apiBrand');
      expect(seen.single.headers.containsKey('Authorization'), isFalse,
          reason: 'токен вошедшего на проверяемый адрес не уезжает');
      expect(session.lastContact, contact,
          reason: 'ответ проверяемого сервера не продлевает окно входа без сети');
      expect(find.text('Сервер отвечает: Чужой сервер'), findsOneWidget);
    });
  });
}
