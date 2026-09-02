import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/fill_controller.dart';
import 'package:pulse_tasks/data/geo.dart';
import 'package:pulse_tasks/data/local_db.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/models/task.dart';
import 'support/test_env.dart';
import 'support/fake_server.dart';

/// Координаты начала и завершения — в саму задачу (#36838). Несущая стена тикета:
/// точка снимается УСТРОЙСТВОМ в момент действия и едет в очереди вместе с самой
/// операцией, поэтому задача, начатая в самолётном режиме и дожатая через час в
/// другом городе, несёт координаты места работы, а не места появления сети. И
/// обратное обязательство: там, где GPS не берёт, завершение проходит как обычно,
/// а координат честно нет — ни нулей, ни блокировки.
///
/// Настоящий sqlite (ffi), как в offline_create_test: очередь с её колонками — и
/// есть проверяемый механизм, мок скрыл бы ровно его.

int _seq = 0;

const _uuid = '22222222-2222-4222-8222-222222222222';

Future<LocalDb> _openDb() async =>
    LocalDb.open('t36838_${DateTime.now().microsecondsSinceEpoch}_${_seq++}');

/// Сервер, записывающий тела мутаций и умеющий «пропадать» (см. offline_create_test).
class _Server {
  final bodies = <(String, String)>[];
  bool down = false;

  late final Session session;
  late final ApiClient api;

  _Server(Settings settings) {
    session = Session(
      login: 'petrov${_seq++}',
      name: 'Петров П.П.',
      token: 'token',
      signedIn: true,
      performerId: 'p1',
    );
    api = ApiClient(settings, session, client: MockClient((request) async {
      if (down) throw const SocketException('нет сети');
      final action = actionOf(request);
      if (request.method == 'POST') {
        bodies.add((action, request.body));
        return http.Response('', 200);
      }
      final body = action == 'apiExecutionInfo' ? '{}' : '[]';
      return okJson(body);
    }));
  }

  Map<String, dynamic> lastBody(String action) {
    final raw = bodies.lastWhere((e) => e.$1 == action).$2;
    return (jsonDecode(raw) as Map).cast<String, dynamic>();
  }

  bool saw(String action) => bodies.any((e) => e.$1 == action);
}

/// Устройство с управляемым ответом на «где я»: фикс, который можно переставить
/// (переезд в другой город), или честное «координат нет». Считает обращения —
/// повторное открытие бланка не имеет права дёргать геолокацию.
class _FakePlatform implements GeoPlatform {
  GeoFix? current;
  int asked = 0;

  _FakePlatform(this.current);

  @override
  Future<bool> servicesEnabled() async => true;

  @override
  Future<GeoPermission> permission() async =>
      current == null ? GeoPermission.deniedForever : GeoPermission.granted;

  @override
  Future<GeoPermission> requestPermission() async => permission();

  @override
  Future<GeoFix?> lastKnown() async {
    asked++;
    return current;
  }

  @override
  Future<GeoFix?> fix(Duration timeout) async {
    asked++;
    return current;
  }

  @override
  Future<void> openSettings({required bool locationServices}) async {}
}

GeoFix _at(double lat, double lon) => GeoFix(lat, lon, DateTime.now());

Task _task() => const Task(
      id: _uuid,
      clientId: _uuid,
      name: 'Витрина',
      object: 'Магазин №1',
      objectId: 'b24',
      typeId: 'form',
      status: 'Ожидает отправки',
    );

/// Задача, рождённая на телефоне у витрины: create и start в очередях, у старта —
/// точка места создания (или её честное отсутствие).
Future<void> _seedBorn(LocalDb db, {double? lat, double? lon}) async {
  await db.createLocalTask(
    _task(),
    payloadJson: jsonEncode({'clientId': _uuid, 'typeId': 'form'}),
    createdAtIso: '2026-08-20T09:15:30.123456',
    queueStart: true,
    startLat: lat,
    startLon: lon,
  );
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

  test('очередь старта уносит точку постановки, а не точку отправки', () async {
    final db = await _openDb();
    await _seedBorn(db, lat: 53.9006, lon: 27.5590);

    // дожим происходит «в другом городе»: устройство уже видит другие координаты,
    // но очередь про них не спрашивает
    final c = FillController(
        db: db,
        api: server.api,
        taskId: _uuid,
        geo: Geo(platform: _FakePlatform(_at(55.7558, 37.6173))));
    await c.syncAll(refreshSummary: false);

    final start = server.lastBody('apiStartExecution');
    expect(start['lat'], 53.9006);
    expect(start['lon'], 27.5590);
    expect(start['at'], '2026-08-20T09:15:30',
        reason: 'время действия — из очереди, приведённое к секундам');
  });

  test('завершение в самолётном режиме: дожим через час не подменяет точку',
      () async {
    final db = await _openDb();
    await _seedBorn(db, lat: 53.9006, lon: 27.5590);

    final device = _FakePlatform(_at(53.9006, 27.5590)); // у витрины
    final c = FillController(
        db: db,
        api: server.api,
        taskId: _uuid,
        geo: Geo(platform: device));

    server.down = true;
    expect(await c.finish(), isTrue,
        reason: 'офлайн-завершение обещано: уедет при связи');
    expect(server.saw('apiFinishExecution'), isFalse);

    // час спустя, другой город, связь вернулась
    device.current = _at(55.7558, 37.6173);
    server.down = false;
    await c.syncAll(refreshSummary: false);

    final finish = server.lastBody('apiFinishExecution');
    expect(finish['lat'], 53.9006);
    expect(finish['lon'], 27.5590);
    expect(await db.hasFinish(_uuid), isFalse,
        reason: 'цепочка create → start → finish дожата целиком');
  });

  test('GPS не берёт: завершение проходит, координат в телах честно нет',
      () async {
    final db = await _openDb();
    await _seedBorn(db); // подвал: у создания координат уже не было

    final c = FillController(
        db: db,
        api: server.api,
        taskId: _uuid,
        geo: Geo(platform: _FakePlatform(null)));
    expect(await c.finish(), isTrue);

    for (final action in const ['apiStartExecution', 'apiFinishExecution']) {
      final body = server.lastBody(action);
      expect(body.containsKey('lat'), isFalse, reason: action);
      expect(body.containsKey('lon'), isFalse, reason: action);
      expect(body['at'], isNotNull,
          reason: '$action: время устройства есть и без координат');
    }
  });

  test('точку начала меряет только первое открытие бланка', () async {
    final db = await _openDb();
    final device = _FakePlatform(_at(53.9006, 27.5590));
    final c = FillController(
        db: db,
        api: server.api,
        taskId: 'ST-1',
        geo: Geo(platform: device));

    await c.load(); // первое открытие: кэша нет — точка снимается
    final start = server.lastBody('apiStartExecution');
    expect(start['lat'], 53.9006);
    expect(device.asked, greaterThan(0));

    device.asked = 0;
    final again = FillController(
        db: db,
        api: server.api,
        taskId: 'ST-1',
        geo: Geo(platform: device));
    await again.load(); // повторное: кэш есть, выполнение есть — геолокация молчит
    expect(device.asked, 0);
    expect(server.lastBody('apiStartExecution').containsKey('lat'), isFalse);
  });
}
