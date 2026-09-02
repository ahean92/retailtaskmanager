import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/fill_controller.dart';
import 'package:pulse_tasks/data/local_db.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/data/unsent.dart';
import 'package:pulse_tasks/models/fill.dart';
import 'package:pulse_tasks/ui/widgets/fill_field_tile.dart';
import 'support/test_env.dart';
import 'support/fake_server.dart';

/// Удаление одного снимка пункта вместо сброса галереи (#36946).
///
/// Проверяется то, чего в клиенте не было: связь «локальный файл ↔ серверный индекс».
/// Сервер снимок по индексу удаляет давно, но индекс своему кадру телефон должен знать
/// сам — apiSetFieldPhoto его не возвращает. Поэтому здесь настоящий sqlite и сервер,
/// который нумерует снимки ровно как lsFusion («максимум + 1», дыры не уплотняются):
/// на моке с одним счётчиком ни промах по индексу, ни сверка не были бы видны.

/// Сервер-заглушка: снимки пункта как на сервере — по индексам, с дырами.
class _Server {
  /// fieldCode → {индекс: содержимое}
  final Map<String, Map<int, String>> photos = {};
  final calls = <String>[];
  bool offline = false;

  /// Тело последнего apiSetFieldPhoto — им проверяется «стереть весь набор».
  final setPhotoBodies = <Map<String, dynamic>>[];

  int get deleteCalls => calls.where((c) => c == 'apiDeleteFieldPhoto').length;

  List<int> indexesOf(String field) =>
      (photos[field]?.keys.toList() ?? <int>[])..sort();

  http.Client get client => MockClient((request) async {
        final action = actionOf(request);
        if (offline) throw const SocketException('нет связи');
        calls.add(action);
        switch (action) {
          case 'apiSetFieldPhoto':
            final b = jsonDecode(request.body) as Map<String, dynamic>;
            setPhotoBodies.add(b);
            final field = b['field'] as String;
            final photo = b['photo'] as String?;
            final set = photos.putIfAbsent(field, () => {});
            if (photo == null) {
              // как настоящий сервер: ОТСУТСТВИЕ ключа — это NULL, и обе ветки
              // apiSetFieldPhoto мимо; набор остаётся на месте (проверено на стенде)
            } else if (photo.isEmpty) {
              set.clear();
            } else {
              // ровно правило сервера: lastPhotoIndex + 1, индексы не уплотняются
              final max = set.keys.isEmpty
                  ? 0
                  : set.keys.reduce((a, b) => a > b ? a : b);
              set[max + 1] = photo;
            }
            return okJson('[]');
          case 'apiDeleteFieldPhoto':
            final b = jsonDecode(request.body) as Map<String, dynamic>;
            // удаление несуществующего индекса — no-op, как и на сервере
            photos[b['field'] as String]?.remove(b['index'] as int);
            return okJson('[]');
          case 'apiFieldPhoto':
            final field = request.url.queryParameters['field']!;
            final index = int.parse(request.url.queryParameters['index']!);
            final body = photos[field]?[index];
            if (body == null) return http.Response('', 404);
            return http.Response.bytes(base64Decode(body), 200,
                headers: {'content-type': 'image/jpeg'});
          case 'apiExecutionInfo':
            return okJson(jsonEncode([
              {
                'object': 'Магазин №1',
                'template': 'Витрина',
                'answered': 0,
                'total': 1,
                'finished': false,
              }
            ]));
          case 'apiExecutionFields':
            final idx = indexesOf('q1');
            return okJson(jsonEncode([
              {
                'sectionIndex': 1,
                'section': 'Зал',
                'fieldIndex': 1,
                'code': 'q1',
                'name': 'Витрина',
                'type': 'photo',
                'photoCount': idx.length,
                if (idx.isNotEmpty) 'photoIndexes': idx.join(','),
              }
            ]));
          default:
            return okJson('[]');
        }
      });

}

int _seq = 0;

Future<LocalDb> _openDb() async =>
    LocalDb.open('t36946_${DateTime.now().microsecondsSinceEpoch}_${_seq++}');

/// Минимальный настоящий PNG — снимок, который камера кладёт на диск.
final _png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');

Future<String> _shot(Directory dir, String name) async {
  final f = File(p.join(dir.path, name));
  await f.writeAsBytes(_png);
  return f.path;
}

/// Тот же снимок, но синхронно: внутри testWidgets время фальшивое, и настоящий
/// асинхронный ввод-вывод там не завершается никогда — тест повисает без ошибки.
String _shotSync(Directory dir, String name) {
  final f = File(p.join(dir.path, name))..writeAsBytesSync(_png);
  return f.path;
}

void main() {
  initTestEnv();

  late Settings settings;
  late Session session;
  late _Server server;
  late Directory docs;
  late Directory tmp;

  setUp(() {
    resetMockStores();
    docs = Directory.systemTemp.createTempSync('pulse_docs');
    tmp = Directory.systemTemp.createTempSync('pulse_shots');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => docs.path);
    settings = Settings(baseUrl: 'http://test.local:9080');
    session = Session(
        login: 'ivanov', name: 'Иванов И.И.', token: 'token', signedIn: true);
    server = _Server();
  });

  tearDown(() {
    if (docs.existsSync()) docs.deleteSync(recursive: true);
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// База закрывается по окончании теста: ffi-sqlite держит процесс открытым, и
  /// незакрытая база — это не утечка «где-то там», а тест-раннер, который не выходит.
  Future<LocalDb> openDb() async {
    final db = await _openDb();
    addTearDown(() async => db.close());
    return db;
  }

  FillController controller(LocalDb db) {
    final c = FillController(
      db: db,
      api: ApiClient(settings, session, client: server.client),
      taskId: 'ST1',
    );
    // раньше базы (teardown'ы идут в обратном порядке): дожим очереди, начатый
    // последним тапом, не должен читать закрытую базу
    addTearDown(c.dispose);
    return c;
  }

  /// Три снимка, доехавшие до сервера, — исходная позиция почти каждой проверки.
  Future<FillController> withThreeShots(LocalDb db) async {
    final c = controller(db);
    await c.load();
    final f = c.fields.first;
    for (final name in const ['a.jpg', 'b.jpg', 'c.jpg']) {
      await c.addPhoto(f, await _shot(tmp, name));
    }
    await c.syncAll();
    return c;
  }

  test('средний кадр уходит по своему индексу — соседние остаются', () async {
    final db = await openDb();
    final c = await withThreeShots(db);
    var f = c.fields.first;

    expect(server.indexesOf('q1'), [1, 2, 3]);
    // отправитель знает, под какими индексами легли ЕГО снимки: сервер их не
    // называет, но нумерует предсказуемо
    expect([for (final s in f.shots) s.serverIndex], [1, 2, 3]);
    final kept = [f.shots[0].path!, f.shots[2].path!];
    final middle = f.shots[1];

    await c.deleteShot(f, middle);
    await c.syncAll();

    expect(server.indexesOf('q1'), [1, 3], reason: 'удалён ровно средний');
    expect(File(middle.path!).existsSync(), isFalse,
        reason: 'место на устройстве освободилось');
    for (final path in kept) {
      expect(File(path).existsSync(), isTrue,
          reason: 'переснимать соседние не нужно');
    }

    // а после синхронизации бланка их видно ровно два, и по своим индексам
    await c.load();
    f = c.fields.first;
    expect(f.serverPhotoCount, 2);
    expect([for (final s in f.shots) s.serverIndex], [1, 3]);
    expect(f.photoCount, 2);
  });

  test('офлайн бланк после удаления не показывает призрак кадра', () async {
    final db = await openDb();
    final c = await withThreeShots(db);
    await c.deleteShot(c.fields.first, c.fields.first.shots[1]);
    await c.syncAll();
    expect(await db.getPhotoDeletes('ST1'), isEmpty, reason: 'удаление уехало');

    // тот же телефон, но связи нет: бланк берётся из кэша, снятого ДО удаления
    server.offline = true;
    final offline = controller(db);
    await offline.load();
    final f = offline.fields.first;
    expect(f.shots, hasLength(2),
        reason: 'удалённый кадр не возвращается плиткой «недоступно офлайн»');
    expect([for (final s in f.shots) s.serverIndex], [1, 3]);
    expect(f.photoCount, 2);
  });

  test('кадр, снятый офлайн, удаляется из очереди — на сервер не уезжает',
      () async {
    final db = await openDb();
    final c = controller(db);
    await c.load();
    final f = c.fields.first;

    server.offline = true;
    await c.addPhoto(f, await _shot(tmp, 'a.jpg'));
    await c.syncAll();
    final shot = f.shots.single;
    expect(shot.uploaded, isFalse);
    expect(c.pendingCount, 1);

    await c.deleteShot(f, shot);
    expect(File(shot.path!).existsSync(), isFalse);
    expect(c.pendingCount, 0, reason: 'очередь опустела, а не пополнилась');

    server.offline = false;
    await c.syncAll();
    expect(server.photos['q1'] ?? const {}, isEmpty);
    expect(server.calls.contains('apiSetFieldPhoto'), isFalse,
        reason: 'кадр не уехал вовсе');
    expect(server.deleteCalls, 0,
        reason: 'удалять на сервере нечего — снимок туда не попадал');
  });

  test('удаление в самолётном режиме дожимается; повтор не роняет очередь',
      () async {
    final db = await openDb();
    final c = await withThreeShots(db);
    final f = c.fields.first;

    server.offline = true;
    await c.deleteShot(f, f.shots[1]);
    expect(c.pendingCount, 1);
    expect(server.indexesOf('q1'), [1, 2, 3], reason: 'связи не было');

    // строка «Не отправлено» называет и удаление — это такая же неотправленная правка
    final ops = await loadUnsentOps(db);
    expect(ops.single.detail, contains('1 удаление фото'));

    server.offline = false;
    await c.syncAll();
    expect(server.indexesOf('q1'), [1, 3]);
    expect(c.pendingCount, 0);

    // ретрай очереди по уже удалённому индексу: сервер отвечает согласием, строка уходит
    await db.enqueuePhotoDelete('ST1', 'q1', 2, '2026-08-28T10:00:00');
    await c.syncAll();
    expect(c.pendingCount, 0);
    expect(c.lastSyncError, isNull);
    expect(server.indexesOf('q1'), [1, 3]);
  });

  test('снимки прошлой версии опознаются сверкой с photoIndexes', () async {
    final db = await openDb();
    // на сервере три снимка, на устройстве — их файлы, отправленные версией, которая
    // серверных индексов не запоминала
    server.photos['q1'] = {1: 'a', 2: 'b', 3: 'c'};
    for (var i = 0; i < 3; i++) {
      final path = await _shot(tmp, 'old$i.jpg');
      await db.saveFillPhoto('ST1', 'q1', i, path, '2026-08-20T10:00:00');
      await db.markFillPhotoUploaded('ST1', 'q1', i);
    }

    final c = controller(db);
    await c.load();
    final f = c.fields.first;
    expect([for (final s in f.shots) s.serverIndex], [1, 2, 3],
        reason: 'свободные индексы розданы в порядке отправки');
    expect(f.shots.every((s) => s.canDelete), isTrue);

    await c.deleteShot(f, f.shots[2]);
    await c.syncAll();
    expect(server.indexesOf('q1'), [1, 2]);
  });

  test('«Удалить все» уезжает одним пустым фото и снимает поштучные удаления',
      () async {
    final db = await openDb();
    final c = await withThreeShots(db);
    final f = c.fields.first;

    server.offline = true;
    await c.deleteShot(f, f.shots[0]);
    expect((await db.getPhotoDeletes('ST1')), hasLength(1));

    await c.clearPhotos(f);
    expect(await db.getPhotoDeletes('ST1'), isEmpty,
        reason: 'набор стирается целиком — удалять по индексам уже нечего');

    server.offline = false;
    await c.syncAll();
    expect(server.photos['q1'] ?? const {}, isEmpty);
    expect(server.deleteCalls, 0);
    // именно ПУСТАЯ СТРОКА, а не отсутствие ключа: без ключа сервер не делает ничего
    expect(server.setPhotoBodies.last.containsKey('photo'), isTrue);
    expect(server.setPhotoBodies.last['photo'], '');
  });

  test('кадр, снятый на другом устройстве, удаляется по индексу сервера',
      () async {
    final db = await openDb();
    server.photos['q1'] = {1: 'a', 2: 'b'};

    final c = controller(db);
    await c.load();
    final f = c.fields.first;
    expect(f.shots, hasLength(2));
    expect(f.shots.every((s) => s.path == null), isTrue,
        reason: 'файлов этих снимков на устройстве нет');
    expect(f.shots.every((s) => s.canDelete), isTrue);

    await c.deleteShot(f, f.shots.first);
    await c.syncAll();
    expect(server.indexesOf('q1'), [2]);
  });

  testWidgets('крестик на плитке удаляет ровно свой кадр', (tester) async {
    final shots = [
      FillShot(path: _shotSync(tmp, 'w1.jpg'), localIdx: 0, serverIndex: 1, uploaded: true),
      FillShot(path: _shotSync(tmp, 'w2.jpg'), localIdx: 1, serverIndex: 2, uploaded: true),
      // кадр, уехавший старой версией и ещё не опознанный сверкой, — крестика нет
      const FillShot(path: '/nowhere/w3.jpg', localIdx: 2, uploaded: true),
    ];
    FillShot? deleted;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FillFieldTile(
          field: FillField(
            sectionIndex: 1,
            fieldIndex: 1,
            code: 'q1',
            name: 'Витрина',
            type: 'photo',
            shots: shots,
          ),
          // плитка требует полный набор колбэков редактирования — иначе ожившая
          // ручка молча тонула бы (assert в конструкторе)
          onOption: (_) {},
          onNumber: (_) {},
          onText: (_) {},
          onBool: (_) {},
          onDatePick: () {},
          onScan: () {},
          onComment: (_) {},
          onCell: (_, __, ___) {},
          onAddRow: (_, __) async {},
          onDeleteRow: (_) {},
          onRowSubjectSearch: (_, {allItems = false}) async => const [],
          onRef: (_, __) {},
          onRefSearch: (_) async => const [],
          onPhoto: () {},
          onRemovePhoto: () {},
          onDeleteShot: (s) => deleted = s,
        ),
      ),
    ));
    await tester.pump();

    expect(find.byTooltip('Удалить снимок'), findsNWidgets(2));
    expect(find.text('фото: 3'), findsOneWidget);

    await tester.tap(find.byTooltip('Удалить снимок').at(1));
    expect(deleted?.serverIndex, 2);
  });
}
