import 'dart:convert';
import 'dart:io';

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

/// Главная по местоположению и каталог объектов фоном (#37047). Несущие стены:
///  - apiHome зовётся с координатами места и выбранным объектом, а без места — без
///    параметров: сервер без координат отдаёт весь каталог, как раньше;
///  - каталог качается apiObjects только при смене catalogVersion из профиля,
///    ложится в базу вошедшего и переживает перезапуск — выбор на главной живёт им
///    без сети;
///  - выбор не ограничен ответом главной: объект из каталога, которого в apiHome
///    нет, выбирается, и следующая главная уходит за ним с objectId;
///  - сервер постарше (без версии — значит, и без ручки), обрыв связи и отказ
///    ручки оставляют то, что есть.
///
/// Настоящий sqlite (ffi): кэш каталога и его чтение при входе — то, что здесь
/// проверяется.

int _seq = 0;

const _home = {
  'objects': [
    {
      'id': 'SOS-103',
      'name': '«Соседи» в Уручье',
      'address': 'пр-т Независимости, 168'
    },
    {'id': '777', 'name': 'Офис', 'address': 'пр-т Независимости, 185'},
  ],
  'blocks': [
    {
      'code': 'myKpi',
      'type': 'metrics',
      'view': 'tiles',
      'byObject': true,
      'title': 'Сводка',
      'metrics': [
        {
          'code': 'myOpen',
          'name': 'Открытых',
          'value': 6,
          'values': [
            {'object': 'SOS-103', 'value': 2},
            {'object': '777', 'value': 1},
          ],
        },
      ],
    },
  ],
};

/// Дословный ответ apiObjects: строка без ключа — то, что сервер отдать не должен,
/// но клиент обязан пережить.
const _catalog = '''
[{"id":"SOS-101","name":"«Соседи» на Притыцкого","address":"ул. Притыцкого, 29","latitude":53.9078,"longitude":27.4715},
 {"id":"SOS-103","name":"«Соседи» в Уручье","address":"пр-т Независимости, 168","latitude":53.941,"longitude":27.672},
 {"id":"777","name":"Офис","address":"пр-т Независимости, 185","latitude":53.947616,"longitude":27.692599},
 {"name":"Без ключа","latitude":1,"longitude":1}]
''';

/// Сервер, у которого посреди теста меняются версия каталога, его тело и связь.
class _Server {
  final calls = <Uri>[];
  String? catalogVersion = '2026-09-08 12:00:00';
  String catalogBody = _catalog;
  int catalogStatus = 200;
  bool down = false;

  late final Session session;
  late final ApiClient api;

  _Server(Settings settings) {
    session = Session(
      login: 'petrov${_seq++}', // логин уникален: имя базы содержит его
      name: 'Петров П.П.',
      token: 'token',
      signedIn: true,
      performerId: 'p1',
    );
    api = ApiClient(settings, session, client: MockClient((request) async {
      if (down) throw const SocketException('нет сети');
      calls.add(request.url);
      switch (actionOf(request)) {
        case 'apiHome':
          return okJson(jsonEncode([_home]));
        case 'apiCurrentUser':
          return okJson(jsonEncode([
            {
              'login': session.login,
              'name': session.name,
              'id': 'p1',
              if (catalogVersion != null) 'catalogVersion': catalogVersion,
            }
          ]));
        case 'apiObjects':
          return http.Response.bytes(utf8.encode(catalogBody), catalogStatus,
              headers: {'content-type': 'application/json; charset=utf-8'});
      }
      return okJson('[]');
    }));
  }

  int count(String action) =>
      calls.where((u) => u.path.endsWith('.$action')).length;

  Uri? last(String action) =>
      calls.where((u) => u.path.endsWith('.$action')).lastOrNull;
}

Future<AppControllers> _app(Settings settings, _Server server) async {
  final app = AppControllers(
      api: server.api, settings: settings, session: server.session);
  await app.account.updateSettings(settings); // открывает базу этого логина
  return app;
}

/// Человек стоит в Уручье.
Place _at({String? objectId}) => Place(
      objects: const [
        NearbyObject(
            id: 'SOS-103', name: '«Соседи» в Уручье', distance: 40, nearby: true),
      ],
      objectId: objectId,
      latitude: 53.941,
      longitude: 27.672,
      answered: true,
    );

void main() {
  initTestEnv();

  late Settings settings;
  late _Server server;

  setUp(() {
    resetMockStores();
    settings = Settings(baseUrl: 'http://test.local:9080');
    server = _Server(settings);
  });

  group('apiHome', () {
    test('с местом — координаты и выбранный объект, без места — без параметров',
        () async {
      final app = await _app(settings, server);
      await app.home.refreshHome();
      expect(server.last('apiHome')!.queryParameters, isEmpty,
          reason: 'место не определяли — весь каталог, как раньше');
      expect(app.home.layout.objects.map((o) => o.id), ['SOS-103', '777']);

      app.location.place = _at(objectId: 'SOS-103');
      settings.objectId = '777';
      await app.home.refreshHome();
      final q = server.last('apiHome')!.queryParameters;
      expect(q['lat'], '53.941');
      expect(q['lon'], '27.672');
      expect(q['objectId'], '777');
      app.dispose();
    });
  });

  group('каталог', () {
    test('качается при первой синхронизации и не качается, пока версия та же',
        () async {
      final app = await _app(settings, server);
      await app.home.refreshCatalog();
      expect(app.home.catalog.map((o) => o.id), ['SOS-101', 'SOS-103', '777'],
          reason: 'строка без ключа выброшена');
      expect(app.home.catalogVersion, '2026-09-08 12:00:00');
      expect(server.count('apiObjects'), 1);

      await app.home.refreshCatalog();
      await app.home.refreshCatalog();
      expect(server.count('apiObjects'), 1,
          reason: 'версия та же — каталог не тянется');
      expect(server.count('apiCurrentUser'), 3,
          reason: 'а профиль сверяется на каждой синхронизации');

      server.catalogVersion = '2026-09-08 13:00:00';
      server.catalogBody = '[{"id":"NEW","name":"Новый"}]';
      await app.home.refreshCatalog();
      expect(server.count('apiObjects'), 2);
      expect(app.home.catalog.single.id, 'NEW');
      expect(app.home.catalogVersion, '2026-09-08 13:00:00');
      app.dispose();
    });

    test('переживает перезапуск и даёт выбрать объект вне ответа главной',
        () async {
      final app = await _app(settings, server);
      await app.home.refreshHome();
      await app.home.refreshCatalog();

      // тот же логин, новый процесс, сервер молчит: каталог и главная — из базы
      server.down = true;
      final again = await _app(settings, server);
      expect(again.home.catalog.map((o) => o.id), ['SOS-101', 'SOS-103', '777']);
      expect(again.home.catalogVersion, '2026-09-08 12:00:00');
      expect(again.home.layout.objects.map((o) => o.id), ['SOS-103', '777']);
      expect(again.home.selectableObjects.map((o) => o.id),
          ['SOS-101', 'SOS-103', '777'],
          reason: 'лист выбора — весь каталог, а не ответ главной');
      expect(again.home.createObjectChoices.map((o) => o.id),
          ['SOS-101', 'SOS-103', '777'],
          reason: 'и объект для создаваемой задачи — из него же');

      // SOS-101 — далеко и без задач: в ответе главной его нет, в каталоге есть
      await again.home.selectObject('SOS-101');
      expect(again.home.objectId, 'SOS-101');
      expect(again.home.currentObject?.name, '«Соседи» на Притыцкого');
      expect(again.home.objectById('SOS-101')?.latitude, 53.9078);

      // связь вернулась — следующая главная уходит за выбранным
      server.down = false;
      await again.home.refreshHome();
      expect(server.last('apiHome')!.queryParameters['objectId'], 'SOS-101');
      app.dispose();
      again.dispose();
    });

    test('сервер без версии — каталог не тянется, выбор из ответа главной',
        () async {
      server.catalogVersion = null;
      server.catalogStatus = 500;
      final app = await _app(settings, server);
      await app.home.refreshHome();
      await app.home.refreshCatalog();
      expect(server.count('apiObjects'), 0,
          reason: 'без версии в профиле ручки у сервера тоже нет');
      expect(app.home.catalog, isEmpty);
      expect(app.home.selectableObjects.map((o) => o.id), ['SOS-103', '777']);
      expect(app.home.createObjectChoices.map((o) => o.id), ['SOS-103', '777']);
      app.dispose();
    });

    test('обрыв связи и отказ ручки оставляют кэш и его версию', () async {
      final app = await _app(settings, server);
      await app.home.refreshCatalog();
      expect(app.home.catalog, hasLength(3));

      server.down = true;
      await app.home.refreshCatalog();
      expect(app.home.catalog, hasLength(3));

      server.down = false;
      server.catalogVersion = '2026-09-08 14:00:00';
      server.catalogStatus = 403;
      server.catalogBody = '{"error":"notPerformer"}';
      await app.home.refreshCatalog();
      expect(app.home.catalog, hasLength(3));
      expect(app.home.catalogVersion, '2026-09-08 12:00:00',
          reason: 'версия двигается только вместе с каталогом');
      expect(await app.repo.db.cache.getCatalog(),
          (_catalog.trim(), '2026-09-08 12:00:00'));
      app.dispose();
    });
  });
}
