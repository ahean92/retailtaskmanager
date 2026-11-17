import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/local_db.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/data/simple_controller.dart';
import 'package:pulse_tasks/data/unsent.dart';
import 'support/fake_server.dart';
import 'support/test_env.dart';

/// Снимки фотоотчёта поручения покадрово — как у пункта бланка (photo_delete_test):
/// у своего кадра телефон знает серверный индекс, крестик удаляет ровно этот кадр, а
/// кадры, снятые на другом устройстве, видны вместе со своими.
///
/// Сервер-заглушка нумерует снимки ровно как lsFusion (`lastPhotoIndex + 1`, дыры не
/// уплотняются): на моке с одним счётчиком промах по индексу не был бы виден.
class _Server {
  /// индекс → содержимое (base64)
  final Map<int, String> photos = {};
  final calls = <String>[];
  bool offline = false;

  List<int> get indexes => photos.keys.toList()..sort();

  http.Client get client => MockClient((request) async {
        final action = actionOf(request);
        if (offline) throw const SocketException('нет связи');
        calls.add(action);
        switch (action) {
          case 'apiSetSimplePhoto':
            final photo = (jsonDecode(request.body) as Map)['photo'] as String?;
            if (photo == null || photo.isEmpty) {
              photos.clear();
            } else {
              final max = photos.keys.fold(0, (a, b) => a > b ? a : b);
              photos[max + 1] = photo;
            }
            return okJson('[]');
          case 'apiDeleteSimplePhoto':
            // удаление несуществующего индекса — no-op, как и на сервере
            photos.remove((jsonDecode(request.body) as Map)['index'] as int);
            return okJson('[]');
          case 'apiSimplePhoto':
            final body =
                photos[int.parse(request.url.queryParameters['index']!)];
            if (body == null) return http.Response('', 404);
            return http.Response.bytes(base64Decode(body), 200,
                headers: {'content-type': 'image/jpeg'});
          case 'apiSimpleInfo':
            return okJson(jsonEncode([
              {
                'object': 'Магазин №1',
                'name': 'Убрать витрину',
                'date': '2026-11-05T10:00:00',
                'photoCount': photos.length,
                if (photos.isNotEmpty) 'photoIndexes': indexes.join(','),
              }
            ]));
          default:
            return okJson('[]');
        }
      });
}

int _seq = 0;

void main() {
  initTestEnv();

  late Settings settings;
  late Session session;
  late _Server server;
  late Directory docs;
  late Directory tmp;

  setUp(() {
    resetMockStores();
    docs = Directory.systemTemp.createTempSync('pulse_docs_simple');
    tmp = Directory.systemTemp.createTempSync('pulse_shots_simple');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => docs.path);
    settings = Settings(baseUrl: 'http://test.local:9080');
    session = Session(
        login: 'simple${_seq++}', name: 'Петров', token: 't', signedIn: true);
    server = _Server();
  });

  tearDown(() {
    if (docs.existsSync()) docs.deleteSync(recursive: true);
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<LocalDb> openDb() async {
    final db = await LocalDb.open(
        'tsimple_${DateTime.now().microsecondsSinceEpoch}_${_seq++}');
    addTearDown(() async => db.close());
    return db;
  }

  ApiClient api() => ApiClient(settings, session, client: server.client);

  SimpleExecutionController controller(LocalDb db) {
    final c = SimpleExecutionController(db: db, api: api(), taskId: 'ST7');
    // раньше базы: teardown'ы идут в обратном порядке
    addTearDown(c.dispose);
    return c;
  }

  Future<String> shot(String name, List<int> bytes) async {
    final f = File(p.join(tmp.path, name));
    await f.writeAsBytes(bytes);
    return f.path;
  }

  test('средний кадр уходит по своему индексу — соседние остаются', () async {
    final db = await openDb();
    final c = controller(db);
    await c.load();
    for (var i = 1; i <= 3; i++) {
      await c.addPhoto(await shot('s$i.jpg', [i]));
    }
    await c.syncAll();
    expect(server.indexes, [1, 2, 3]);
    expect([for (final s in c.shots) s.serverIndex], [1, 2, 3]);

    final middle = c.shots[1];
    await c.deleteShot(middle);
    expect(c.shots, hasLength(2), reason: 'с экрана кадр ушёл сразу');
    await c.syncAll();
    expect(server.photos, {1: base64Encode([1]), 3: base64Encode([3])});
    expect(File(middle.path!).existsSync(), isFalse);
    expect([for (final s in c.shots) s.serverIndex], [1, 3]);
  });

  test('два кадра без сети: после дренажа без экрана удаление второго '
      'стирает на сервере второй', () async {
    final db = await openDb();
    final c = controller(db);
    await c.load();
    server.offline = true;
    await c.addPhoto(await shot('a.jpg', [1]));
    await c.addPhoto(await shot('b.jpg', [2]));
    await c.syncAll();

    server.offline = false;
    await SimpleExecutionController.drainAll(db, api());
    expect(server.indexes, [1, 2]);

    final screen = controller(db);
    await screen.load();
    expect(screen.shots, hasLength(2), reason: 'две плитки, а не три');
    await screen.deleteShot(screen.shots[1]);
    await screen.syncAll();
    expect(server.photos, {1: base64Encode([1])});
  });

  test('снятые на другом устройстве видны вместе со своими', () async {
    final db = await openDb();
    server.photos[1] = base64Encode([9]);
    final c = controller(db);
    await c.load();
    await c.addPhoto(await shot('a.jpg', [1]));
    await c.syncAll();
    expect(server.indexes, [1, 2]);
    expect(c.shots, hasLength(2),
        reason: 'свой кадр не прячет чужой: на экране столько же, сколько на сервере');
    expect(c.photoPaths, hasLength(1));
    expect(c.shots.firstWhere((s) => s.path == null).serverIndex, 1);
    expect(c.shots.firstWhere((s) => s.path != null).serverIndex, 2);

    // чужой кадр тоже убирается поштучно — по индексу сервера
    await c.deleteShot(c.shots.firstWhere((s) => s.path == null));
    await c.syncAll();
    expect(server.photos, {2: base64Encode([1])});
  });

  test('«Убрать все» стирает и кадр, уехавший фоновой отправкой', () async {
    final db = await openDb();
    final c = controller(db);
    await c.load(); // на сервере пусто — так и в кэше
    server.offline = true;
    await c.addPhoto(await shot('a.jpg', [1]));
    await c.syncAll();
    server.offline = false;
    await SimpleExecutionController.drainAll(db, api());
    expect(server.indexes, [1]);

    // экран открыт без связи: ответ сервера в кэше снимков ещё не знает
    server.offline = true;
    final screen = controller(db);
    await screen.load();
    expect(screen.serverPhotoCount, 0);
    await screen.clearPhotos();
    expect(screen.shots, isEmpty);

    server.offline = false;
    await screen.syncAll();
    expect(server.photos, isEmpty, reason: 'команда стирания ушла на сервер');
  });

  test('удалил и снял заново — новый кадр лежит в новом файле', () async {
    final db = await openDb();
    final c = controller(db);
    await c.load();
    await c.addPhoto(await shot('a.jpg', [1]));
    await c.syncAll();
    final first = c.shots.single.path!;
    await c.deleteShot(c.shots.single);
    await c.addPhoto(await shot('b.jpg', [2]));
    final second = c.photoPaths.single;
    expect(second, isNot(first));
    expect(File(second).readAsBytesSync(), [2]);
    await c.syncAll();
    // индекс нового кадра зависит от того, уехало ли удаление раньше съёмки; важно,
    // что на сервере ровно новый кадр и телефон знает, где он лежит
    expect(server.photos.values, [base64Encode([2])]);
    expect(c.shots.single.serverIndex, server.photos.keys.single);
  });

  test('кадры прошлой версии опознаются сверкой и удаляются поштучно', () async {
    final db = await openDb();
    server.photos.addAll({1: base64Encode([1]), 2: base64Encode([2])});
    for (var i = 0; i < 2; i++) {
      await db.simple.saveSimplePhoto(
          'ST7', i, await shot('old$i.jpg', [i + 1]), '2026-11-01T10:00:0$i');
      await db.simple.markSimplePhotoUploaded('ST7', i);
    }
    final c = controller(db);
    await c.load();
    expect(c.shots, hasLength(2));
    expect([for (final s in c.shots) s.serverIndex], [1, 2]);
    expect(c.shots.every((s) => s.canDelete), isTrue);

    await c.deleteShot(c.shots.first);
    await c.syncAll();
    expect(server.photos, {2: base64Encode([2])});
  });

  test('удаление без сети ждёт в «Не отправлено» и уезжает со связью', () async {
    final db = await openDb();
    final c = controller(db);
    await c.load();
    await c.addPhoto(await shot('a.jpg', [1]));
    await c.syncAll();

    server.offline = true;
    await c.deleteShot(c.shots.single);
    expect(c.pendingCount, 1);
    final ops = await loadUnsentOps(db);
    expect(ops.single.detail, contains('1 удаление фото'));
    expect(await db.queues.pendingChanges(), 1);

    // офлайн-экран после ухода удаления не возвращает кадр плиткой из кэша
    server.offline = false;
    await c.syncAll();
    expect(server.photos, isEmpty);
    server.offline = true;
    final again = controller(db);
    await again.load();
    expect(again.shots, isEmpty);
  });
}
