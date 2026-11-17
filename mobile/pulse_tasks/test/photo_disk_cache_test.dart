import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/local_db.dart';
import 'package:pulse_tasks/data/past_fill_controller.dart';
import 'package:pulse_tasks/data/photo_disk_cache.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/data/task_result_controller.dart';
import 'package:pulse_tasks/models/fill.dart';
import 'support/fake_server.dart';
import 'support/test_env.dart';

/// Скачанные снимки на диске — одна механика на все экраны ([PhotoDiskCache]).
///
/// Проверяется то, ради чего копии кэша сведены в одну: оборванная загрузка не
/// оставляет под итоговым именем полфайла, битый файл снимается и перекачивается
/// ровно один раз — и у прошлой проверки, и у отчёта результата, где сброса раньше
/// не было вовсе.
void main() {
  initTestEnv();

  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('pulse_disk_cache');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('PhotoDiskCache', () {
    test('файл скачивается один раз, повторные запросы — тот же ответ', () async {
      final cache = PhotoDiskCache(() async => dir);
      var fetches = 0;
      Future<List<int>> fetch() async {
        fetches++;
        return [1, 2, 3];
      }

      final a = cache.file('a.jpg', fetch);
      final b = cache.file('a.jpg', fetch);
      expect(identical(a, b), isTrue,
          reason: 'перерисовка галереи не тянет тот же снимок вторым запросом');
      expect((await a)!.readAsBytesSync(), [1, 2, 3]);
      expect(fetches, 1);

      // другой кэш того же каталога (экран открыли снова) берёт файл с диска
      final again = PhotoDiskCache(() async => dir);
      expect(await again.file('a.jpg', fetch), isNotNull);
      expect(fetches, 1);
    });

    test('неудача не запоминается и не оставляет файла', () async {
      final cache = PhotoDiskCache(() async => dir);
      expect(
          await cache.file('a.jpg', () async => throw const SocketException('')),
          isNull);
      expect(dir.listSync(), isEmpty,
          reason: 'ни итогового, ни временного файла от оборванной загрузки');
      expect((await cache.file('a.jpg', () async => [7]))!.readAsBytesSync(),
          [7],
          reason: 'следующий заход пробует снова');
    });

    test('битый файл снимается и перекачивается', () async {
      final cache = PhotoDiskCache(() async => dir);
      var fetches = 0;
      await cache.file('a.jpg', () async {
        fetches++;
        return [0];
      });
      await cache.evict(['a.jpg', 'a_t.jpg']);
      expect(File(p.join(dir.path, 'a.jpg')).existsSync(), isFalse);
      final f = await cache.file('a.jpg', () async {
        fetches++;
        return [1, 2];
      });
      expect(fetches, 2);
      expect(f!.readAsBytesSync(), [1, 2]);
    });

    test('reuseDisk: false — файл прошлого раза не берётся', () async {
      File(p.join(dir.path, 'srv.jpg')).writeAsBytesSync([9]);
      final cache = PhotoDiskCache(() async => dir);
      final f = await cache.file('srv.jpg', () async => [1], reuseDisk: false);
      expect(f!.readAsBytesSync(), [1],
          reason: 'индекс мог достаться другому кадру — прежний файл чужой');
    });
  });

  group('сброс битого файла у прошлой проверки и отчёта результата', () {
    late Directory docs;
    late Settings settings;
    late Session session;
    final fetched = <String>[];

    setUp(() {
      resetMockStores();
      fetched.clear();
      docs = Directory.systemTemp.createTempSync('pulse_docs_cache');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              (call) async => docs.path);
      settings = Settings(baseUrl: 'http://test.local:9080');
      session = Session(
          login: 'cache${DateTime.now().microsecondsSinceEpoch}',
          name: 'Иванов',
          token: 't',
          signedIn: true);
    });

    tearDown(() {
      if (docs.existsSync()) docs.deleteSync(recursive: true);
    });

    ApiClient api() => ApiClient(settings, session,
            client: MockClient((r) async {
          final a = actionOf(r);
          fetched.add(a);
          if (a == 'apiFieldPhoto' || a == 'apiSimplePhoto') {
            return http.Response.bytes([1, 2, 3], 200,
                headers: {'content-type': 'image/jpeg'});
          }
          if (a == 'apiSimpleInfo') {
            return okJson(jsonEncode([
              {'photoCount': 1, 'photoIndexes': '1', 'date': '2026-11-05T10:00:00'}
            ]));
          }
          return okJson('[]');
        }));

    test('прошлая проверка: один сброс — одно новое скачивание', () async {
      final db = await LocalDb.open('cache_past_${DateTime.now().microsecondsSinceEpoch}');
      addTearDown(db.close);
      final c = PastFillController.forObject(db, api(), 'o1');
      addTearDown(c.dispose);
      final f = FillField(sectionIndex: 1, fieldIndex: 1, code: 'q1', type: 'photo');

      final file = await c.photoFile(f, 1, thumb: true);
      expect(file, isNotNull);
      expect(await c.photoFile(f, 1, thumb: true), isNotNull);
      expect(fetched.where((a) => a == 'apiFieldPhoto'), hasLength(1));

      await c.evictPhoto(f, 1);
      expect(file!.existsSync(), isFalse);
      expect(await c.photoFile(f, 1, thumb: true), isNotNull);
      expect(fetched.where((a) => a == 'apiFieldPhoto'), hasLength(2));
    });

    test('отчёт результата: один сброс — одно новое скачивание', () async {
      final db = await LocalDb.open('cache_res_${DateTime.now().microsecondsSinceEpoch}');
      addTearDown(db.close);
      final c = TaskResultController(db: db, api: api(), taskId: 'T1');
      addTearDown(c.dispose);
      await c.load();

      final file = await c.photo(1, thumb: true);
      expect(file, isNotNull);
      expect(await c.photo(1, thumb: true), isNotNull);
      expect(fetched.where((a) => a == 'apiSimplePhoto'), hasLength(1));

      await c.evictPhoto(1);
      expect(file!.existsSync(), isFalse);
      expect(await c.photo(1, thumb: true), isNotNull);
      expect(fetched.where((a) => a == 'apiSimplePhoto'), hasLength(2));
    });
  });
}
