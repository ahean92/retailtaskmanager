import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pulse_tasks/app_controllers.dart';
import 'package:pulse_tasks/data/account_controller.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/local_db.dart';
import 'package:pulse_tasks/data/password_hash.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';

import 'support/fake_server.dart';
import 'support/test_env.dart';

/// Токен просрочен — телефон получает новый сам, и человек этого не замечает; не выдают
/// нового (сменили пароль, заблокировали) — телефон возвращается на вход, а очередь ждёт
/// в базе человека. Так на обеих платформах, хотя отказывают они по-разному: master —
/// 401, встроенный HTTP сервера 6.2 — 500 с текстом исключения в теле. На 6.2 телефон
/// показывал этот текст («Failed to parse token …» с токеном целиком) на «Завершить» и
/// на любом другом запросе, пока человек сам не выходил и не входил снова.

int _seq = 0;

const _base = 'http://test.local:9080';

enum _Platform { master, v62 }

/// Ответ 500 встроенного HTTP сервера 6.2 на ручку, которая упала: текст исключения.
http.Response _serverFailure() =>
    http.Response.bytes(utf8.encode('База данных недоступна'), 500,
        headers: {'content-type': 'text/html; charset=utf-8'});

class _Server {
  _Server(this.platform);

  final _Platform platform;

  /// Логин уникален: имя базы содержит его.
  final login = 'sidorov${_seq++}';

  final requests = <http.Request>[];

  /// Пароль на сервере. Сменили — сохранённый на телефоне больше не подходит.
  String password = 'secret';

  bool locked = false;

  /// Ручки падают сбоем сервера, токен тут ни при чём.
  bool failing = false;

  int _issued = 0;

  /// Токен, который сервер принимает; остальные просрочены. Сессия в тестах начинает
  /// с jwt0.
  String? _live = 'jwt0';

  void expireToken() => _live = null;

  /// Отказ в аутентификации: тексты те, что шлёт платформа, а код зависит от неё.
  http.Response _refused(String text) => http.Response.bytes(
      utf8.encode(text), platform == _Platform.master ? 401 : 500,
      headers: {'content-type': 'text/html; charset=utf-8'});

  List<String> get actions => [for (final r in requests) actionOf(r)];

  late final http.Client client = MockClient((request) async {
    requests.add(request);
    final auth = request.headers['Authorization'] ?? '';
    final action = actionOf(request);
    if (action == 'getAuthToken') {
      if (auth != 'Basic ${base64Encode(utf8.encode('$login:$password'))}') {
        return _refused('Неправильное имя пользователя или пароль');
      }
      if (locked) return _refused('Пользователь заблокирован');
      return http.Response(_live = 'jwt${++_issued}', 200);
    }
    if (auth != 'Bearer $_live') {
      return _refused('Failed to parse token ${auth.replaceFirst('Bearer ', '')}: '
          'JWT expired at 2026-11-11T16:44:27Z. Current time: '
          '2026-11-11T16:54:48Z, a difference of 621193 milliseconds.  '
          'Allowed clock skew: 0 milliseconds.');
    }
    if (failing) return _serverFailure();
    if (action == 'apiCurrentUser') {
      return okJson('[{"id":"p1","name":"Сидоров С.С."}]');
    }
    return request.method == 'POST' ? http.Response('', 200) : okJson('[]');
  });

  /// Приложение с сохранённой сессией, как после перезапуска: токен выдан при входе,
  /// база вошедшего открыта. Не через signIn: тот запускает фоновую синхронизацию, и её
  /// запросы смешались бы с проверяемыми.
  Future<AppControllers> signedIn() async {
    final settings = Settings(baseUrl: _base);
    final session = Session(
      login: login,
      password: 'secret',
      passwordHash: await PasswordHash.create('secret'),
      token: 'jwt0',
      name: 'Сидоров С.С.',
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
}

/// Дождаться того, что приложение отпустило без await: закрытия базы после потери
/// сессии.
Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 300 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  initTestEnv();

  setUp(resetMockStores);

  for (final platform in _Platform.values) {
    group(platform.name, () {
      test('«Завершить» с просроченным токеном проходит под новым — без ошибки и '
          'без входа', () async {
        final server = _Server(platform);
        final app = await server.signedIn();

        server.expireToken();
        await app.api.finishExecution('ST0001', at: '2026-11-11T19:54:48');

        expect(server.actions, [
          'apiFinishExecution',
          'getAuthToken',
          'apiCurrentUser',
          'apiFinishExecution',
        ]);
        expect(app.session.token, 'jwt1');
        expect(app.session.isActive, isTrue);
        await app.account.signOut(); // закрыть базу за собой
      });

      test('токен просрочен, а пароль сменили — вход «Сессия истекла», очередь цела',
          () async {
        final server = _Server(platform);
        final app = await server.signedIn();
        final key = app.repo.db.userKey;
        await app.repo.db.tasks.enqueue(
            'ST0001', 's2', 'Выполнена', DateTime.now().toIso8601String());
        var loginForm = false;
        app.account.addListener(() => loginForm = !app.session.isActive);

        server
          ..password = 'changed'
          ..expireToken();
        await app.sync.pushPending();
        await _until(() => app.base.db == null);

        expect(server.actions, ['apiSetStatus', 'getAuthToken'],
            reason: 'после отказа в токене не ушло ничего');
        expect(loginForm, isTrue, reason: 'приложение вернулось к форме входа');
        expect(app.session.isActive, isFalse);
        expect(app.repo.error, 'Сессия истекла — войдите заново');
        final db = await LocalDb.open(key);
        expect((await db.tasks.getOutbox()).keys, ['ST0001'],
            reason: 'очередь ждёт в базе того, кто её сделал');
        await db.close();
      });

      test('токен просрочен, а учётную запись заблокировали — тоже на вход',
          () async {
        final server = _Server(platform);
        final app = await server.signedIn();

        server
          ..locked = true
          ..expireToken();
        await expectLater(
            app.api.fetchTasks(), throwsA(isA<SessionExpiredException>()));
        await _until(() => app.base.db == null);

        expect(server.actions, ['apiTasks', 'getAuthToken']);
        expect(app.session.isActive, isFalse);
      });

      test('вход с неверным паролем — «Неверный логин или пароль»', () async {
        final server = _Server(platform);
        final settings = Settings(baseUrl: _base);
        final session = Session();
        final app = AppControllers(
            api: ApiClient(settings, session, client: server.client),
            settings: settings,
            session: session);

        await expectLater(
            app.account.signIn(server.login, 'wrong'),
            throwsA(isA<LoginException>().having(
                (e) => e.message, 'message', 'Неверный логин или пароль')));
      });
    });
  }

  test('6.2: сбой ручки кодом 500 — не отказ токена: ни перевыпуска, ни выхода',
      () async {
    final server = _Server(_Platform.v62)..failing = true;
    final app = await server.signedIn();

    await expectLater(
        app.api.fetchTasks(),
        throwsA(isA<ApiException>()
            .having((e) => e.status, 'status', 500)
            .having((e) => e.message, 'message', 'HTTP 500: База данных недоступна')));

    expect(server.actions, ['apiTasks']);
    expect(app.session.isActive, isTrue);
    expect(app.session.token, 'jwt0');
    await app.account.signOut();
  });
}
