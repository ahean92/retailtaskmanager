import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pulse_tasks/app_controllers.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/models/place.dart';
import 'support/fake_server.dart';
import 'support/test_env.dart';

/// Список задач приходит страницами (#37346): телефон берёт их подряд, пока не придёт
/// неполная, и только после последней заменяет кэш. Настоящий sqlite (ffi): проверяется
/// именно то, что лежит в кэше после refresh, а не то, что вернул fetchTasks.

int _seq = 0;

/// Сервер со страницами: отдаёт следующие `limit` строк за `after`, у каждой — `cursor`.
/// [legacy] — сервер до #37346: параметров страницы не знает, отдаёт всё одним ответом и
/// без `cursor`. [failOnRequest] — какой по счёту запрос списка оборвать (с единицы).
class _Server {
  final requests = <Map<String, String>>[]; // параметры каждого запроса apiTasks
  List<Map<String, Object?>> tasks = [];
  bool legacy = false;
  int? failOnRequest;

  late final Session session;
  late final ApiClient api;

  _Server(Settings settings) {
    session = Session(
      login: 'pages${_seq++}', // логин уникален: имя базы содержит его
      name: 'Иванов И.И.',
      token: 'token',
      signedIn: true,
      performerId: 'p1',
      geoRequired: false,
    );
    api = ApiClient(settings, session, client: MockClient((request) async {
      if (actionOf(request) != 'apiTasks') return okJson('[]');
      final q = request.url.queryParameters;
      requests.add(q);
      if (requests.length == failOnRequest) {
        throw http.ClientException('connection reset');
      }
      if (legacy) return okJson(jsonEncode(tasks));
      final after = int.tryParse(q['after'] ?? '') ?? 0;
      final limit = int.tryParse(q['limit'] ?? '');
      final rows = [
        for (var i = 0; i < tasks.length; i++)
          if (i + 1 > after) {...tasks[i], if (limit != null) 'cursor': i + 1},
      ];
      return okJson(
          jsonEncode(limit == null ? rows : rows.take(limit).toList()));
    }));
  }
}

List<Map<String, Object?>> _tasks(int n, [String prefix = 'T']) => [
      for (var i = 1; i <= n; i++)
        {'id': '$prefix$i', 'name': 'Задача $i', 'objectId': 'o1'},
    ];

Future<AppControllers> _app(Settings settings, _Server server) async {
  final app = AppControllers(
      api: server.api, settings: settings, session: server.session);
  await app.account.updateSettings(settings); // открывает базу этого логина
  app.location.place = Place(
      objects: [], latitude: 53.9, longitude: 27.56, answered: true);
  return app;
}

List<String> _ids(AppControllers app) =>
    app.repo.tasks.map((v) => v.id).toList()..sort();

void main() {
  initTestEnv();

  late Settings settings;
  late _Server server;

  setUp(() {
    resetMockStores();
    settings = Settings(baseUrl: 'http://test.local:9080');
    server = _Server(settings);
  });

  test('страницы идут подряд до неполной, в кэше — весь список', () async {
    server.tasks = _tasks(2 * tasksPageSize + 50);
    final app = await _app(settings, server);
    await app.repo.refresh();

    expect(server.requests, hasLength(3));
    expect(server.requests.map((q) => q['limit']).toSet(), {'$tasksPageSize'});
    expect(server.requests.map((q) => q['after']).toList(),
        [null, '$tasksPageSize', '${2 * tasksPageSize}'],
        reason: 'следующая страница — за cursor последней строки предыдущей');
    expect(server.requests.first['lat'], '53.9',
        reason: 'координаты едут, как и раньше');
    expect(app.repo.error, isNull);
    expect(_ids(app),
        (server.tasks.map((t) => '${t['id']}').toList()..sort()));
    app.dispose();
  });

  test('обычный список — один запрос', () async {
    server.tasks = _tasks(30);
    final app = await _app(settings, server);
    await app.repo.refresh();

    expect(server.requests, hasLength(1));
    expect(app.repo.tasks, hasLength(30));
    app.dispose();
  });

  test('список ровно в страницу: следующая пуста, и на ней цикл кончается',
      () async {
    server.tasks = _tasks(tasksPageSize);
    final app = await _app(settings, server);
    await app.repo.refresh();

    expect(server.requests, hasLength(2));
    expect(app.repo.tasks, hasLength(tasksPageSize));
    app.dispose();
  });

  test('обрыв посреди страниц оставляет прежний кэш нетронутым', () async {
    server.tasks = _tasks(3, 'OLD');
    final app = await _app(settings, server);
    await app.repo.refresh();
    expect(_ids(app), ['OLD1', 'OLD2', 'OLD3']);

    // сервер теперь отдаёт другой, длинный список — и рвётся на второй странице
    server.tasks = _tasks(2 * tasksPageSize + 50, 'NEW');
    server.requests.clear();
    server.failOnRequest = 2;
    await app.repo.refresh();

    expect(server.requests, hasLength(2));
    expect(app.repo.error, isNotNull);
    expect(_ids(app), ['OLD1', 'OLD2', 'OLD3'],
        reason: 'первая страница уже пришла, но в кэш не попала');

    // связь вернулась — список заменяется целиком
    server.failOnRequest = null;
    await app.repo.refresh();
    expect(app.repo.error, isNull);
    expect(app.repo.tasks, hasLength(2 * tasksPageSize + 50));
    expect(_ids(app).any((id) => id.startsWith('OLD')), isFalse);
    app.dispose();
  });

  test('сервер без страниц: всё одним ответом, второго запроса нет', () async {
    server.legacy = true;
    server.tasks = _tasks(2 * tasksPageSize + 50);
    final app = await _app(settings, server);
    await app.repo.refresh();

    expect(server.requests, hasLength(1),
        reason: 'строки без cursor — сервер страниц не знает, спрашивать дальше нечего');
    expect(app.repo.tasks, hasLength(2 * tasksPageSize + 50));
    app.dispose();
  });

  test('сервер, повторяющий страницу, не зацикливает телефон', () async {
    final stuck = ApiClient(settings, server.session,
        client: MockClient((request) async => okJson(jsonEncode([
              for (var i = 1; i <= tasksPageSize; i++)
                {'id': 'T$i', 'name': 'Задача $i', 'cursor': tasksPageSize},
            ]))));
    await expectLater(stuck.fetchTasks(), throwsA(isA<ApiException>()));
  });
}
