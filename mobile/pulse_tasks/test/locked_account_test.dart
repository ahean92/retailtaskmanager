import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pulse_tasks/app_controllers.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/local_db.dart';
import 'package:pulse_tasks/data/password_hash.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';

import 'support/fake_server.dart';
import 'support/test_env.dart';

/// Учётную запись заблокировали на сервере, а телефон с токеном, выданным до блокировки,
/// работал ещё до суток (#37179, вопрос 9 журнала приёмки): платформа проверяет
/// блокировку только при выдаче токена, а выданный принимает до истечения срока. Сервер
/// теперь отвечает заблокированному 401 с любой ручки, а новый токен ему по-прежнему не
/// выдаёт. Здесь записано, что телефон делает с таким 401: один раз пробует перевыпустить
/// токен, получает отказ и возвращается к форме входа — не повторяя запрос и ничего не
/// отправляя от имени закрытой учётки; очередь при этом остаётся в базе человека. Тот же
/// путь у входа без сети: первая связь с сервером выводит на форму входа (#37178).

int _seq = 0;

const _base = 'http://test.local:9080';

/// Сервер стенда после исправления. Токен выдаёт по паролю, профиль — по токену; после
/// блокировки старый токен принимает — и отказывает уже гвардом ручки, 401 с кодом
/// locked. Выдаёт ли она заблокированной НОВЫЙ токен, зависит от версии платформы:
/// стенд выдаёт (isLocked при выдаче не смотрит) — тогда отказывает профиль под новым
/// токеном; платформа поновее отказывает в самом токене (LockedException, 401).
class _Server {
  /// Логин уникален и между прогонами: имя базы содержит его, а файл ffi-sqlite
  /// переживает запуск.
  final login = 'petrov${DateTime.now().microsecondsSinceEpoch}_${_seq++}';

  final requests = <http.Request>[];

  /// Сети нет — запрос обрывается, не дойдя до сервера.
  bool down = false;

  /// Администратор заблокировал учётную запись.
  bool locked = false;

  /// Платформа выдаёт токен и заблокированной учётке (как на стенде); false —
  /// отказывает в токене сама.
  bool issuesTokenWhenLocked = true;

  int _issued = 0;

  /// Ручки, которые спросили. Бренд не в счёт: его приложение спрашивает само после
  /// входа, без токена и в любой момент — к блокировке он отношения не имеет.
  List<String> get actions => [
        for (final r in requests)
          if (actionOf(r) != 'apiBrand') actionOf(r)
      ];

  late final http.Client client = MockClient((request) async {
    if (down) throw const SocketException('нет сети');
    requests.add(request);
    final auth = request.headers['Authorization'];
    final action = actionOf(request);
    if (action == 'getAuthToken') {
      final basic = 'Basic ${base64Encode(utf8.encode('$login:secret'))}';
      if (auth != basic) return http.Response('', 401);
      // платформа поновее: заблокированной учётке токена нет — 401 без тела для машины,
      // тот же ответ, что на неверный пароль
      if (locked && !issuesTokenWhenLocked) {
        return http.Response('Unauthorized', 401);
      }
      return http.Response('jwt${++_issued}', 200);
    }
    if (action == 'apiBrand') return okJson('[{"name":"Пульс"}]');
    // ручки: токен, выданный до блокировки, платформа принимает — отказывает гвард ручки
    // (ApiCommon.denyLocked)
    if (locked) {
      return http.Response.bytes(
          utf8.encode('{"error":"locked",'
              '"message":"Учётная запись заблокирована: $login"}'),
          401,
          headers: {'content-type': 'application/json; charset=utf-8'});
    }
    if (action == 'apiCurrentUser') {
      return okJson('[{"id":"p1","name":"Петров П.П."}]');
    }
    return request.method == 'POST' ? http.Response('', 200) : okJson('[]');
  });

  /// Приложение с сохранённой сессией — как после перезапуска: токен выдан до
  /// блокировки, профиль сверен при прошлом входе, база вошедшего открыта. Не через
  /// signIn: тот запускает фоновую синхронизацию, и её запросы смешались бы с
  /// проверяемыми.
  Future<AppControllers> signedInOnline() async {
    final settings = Settings(baseUrl: _base);
    final session = Session(
      login: login,
      password: 'secret',
      passwordHash: await PasswordHash.create('secret'),
      token: 'jwt0',
      name: 'Петров П.П.',
      performerId: 'p1',
      signedIn: true,
      lastContact: DateTime.now(),
    );
    final api = ApiClient(settings, session, client: client);
    final app = AppControllers(api: api, settings: settings, session: session);
    await app.base.rebind();
    await app.repo.reloadLocal();
    expect(app.base.db, isNotNull, reason: 'база вошедшего не открылась');
    return app;
  }

  /// Приложение, в которое вошли без сети — после «Выйти», поэтому без токена. Вход
  /// настоящий: пароль сверяется с хэшем, база вошедшего открывается.
  Future<AppControllers> signedInOffline() async {
    final settings = Settings(baseUrl: _base);
    final session = Session(
      login: login,
      password: 'secret',
      passwordHash: await PasswordHash.create('secret'),
      name: 'Петров П.П.',
      performerId: 'p1',
      lastContact: DateTime.now(), // окно входа без сети открыто
    );
    final api = ApiClient(settings, session, client: client);
    final app = AppControllers(api: api, settings: settings, session: session);
    await app.account.signIn(login, 'secret');
    expect(session.isActive, isTrue, reason: 'вход без сети не состоялся');
    expect(session.token, isEmpty);
    return app;
  }
}

/// Дождаться того, что приложение отпустило без await: закрытия базы после потери
/// сессии.
Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 300 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

String _now() => DateTime.now().toIso8601String();

void main() {
  initTestEnv();

  setUp(resetMockStores);

  for (final (platform, issues, expected) in [
    ('платформа выдаёт токен, отказывает профиль', true,
        ['apiTasks', 'getAuthToken', 'apiCurrentUser']),
    ('платформа отказывает в токене', false, ['apiTasks', 'getAuthToken']),
  ]) {
    test('работал онлайн, заблокировали — следующий запрос выводит на форму '
        'входа ($platform)', () async {
      final server = _Server()..issuesTokenWhenLocked = issues;
      final app = await server.signedInOnline();
      var loginForm = false;
      app.account.addListener(() => loginForm = !app.session.isActive);

      server.locked = true;
      await expectLater(
          app.api.fetchTasks(), throwsA(isA<SessionExpiredException>()));
      await _until(() => app.base.db == null);

      expect(server.actions, expected,
          reason: 'на 401 — одна попытка перевыпуска; после отказа ни повтора '
              'запроса, ни новых обращений');
      expect(loginForm, isTrue, reason: 'приложение вернулось к форме входа');
      expect(app.session.isActive, isFalse);
      expect(app.session.token, isEmpty,
          reason: 'ни старый, ни новый токен сессии не достался');
      expect(app.repo.error, 'Сессия истекла — войдите заново');
    });
  }

  test('очередь, накопленная до блокировки, остаётся в базе человека', () async {
    final server = _Server();
    final app = await server.signedInOnline();
    final key = app.repo.db.userKey;
    await app.repo.db.tasks.enqueue('ST0001', 's2', 'Выполнена', _now());

    server.locked = true;
    await app.sync.pushPending();
    await _until(() => app.base.db == null);

    expect(server.actions, ['apiSetStatus', 'getAuthToken', 'apiCurrentUser'],
        reason: 'мутация упёрлась в 401, профиль под новым токеном отказал — '
            'дальше не ушло ничего');
    expect(app.session.isActive, isFalse,
        reason: 'отправка очереди тоже кончается формой входа');
    final db = await LocalDb.open(key);
    expect((await db.tasks.getOutbox()).keys, ['ST0001'],
        reason: 'очередь ждёт в базе того, кто её сделал');
    await db.close();
  });

  test('вошёл без сети, а учётную запись заблокировали — первая связь выводит '
      'на форму входа', () async {
    final server = _Server()
      ..down = true
      ..locked = true;
    final app = await server.signedInOffline();
    var loginForm = false;
    app.account.addListener(() => loginForm = !app.session.isActive);

    server.down = false;
    await expectLater(
        app.api.fetchTasks(), throwsA(isA<SessionExpiredException>()));
    await _until(() => app.base.db == null);

    expect(server.actions, ['getAuthToken', 'apiCurrentUser'],
        reason: 'дальше отказа в профиле не ушло ничего');
    expect(loginForm, isTrue, reason: 'приложение вернулось к форме входа');
    expect(app.session.isActive, isFalse);
  });

  test('403 «не исполнитель» по-прежнему не сессия: ошибка запроса, вход цел',
      () async {
    // Код 401 у блокировки выбран сознательно — 403 телефон показывает как ошибку и
    // продолжает работать; здесь это закреплено, чтобы правка кодов на сервере не
    // прошла незамеченной.
    final server = _Server();
    final app = await server.signedInOnline();
    final api = ApiClient(Settings(baseUrl: _base), app.session,
        client: MockClient((request) async {
      server.requests.add(request);
      return http.Response('{"error":"notPerformer","message":"-"}', 403);
    }));

    await expectLater(api.fetchTasks(),
        throwsA(isA<ApiException>().having((e) => e.status, 'status', 403)));

    expect(server.actions, ['apiTasks'], reason: 'перевыпуска токена не было');
    expect(app.session.isActive, isTrue);
    await app.account.signOut(); // закрыть базу за собой
  });
}
