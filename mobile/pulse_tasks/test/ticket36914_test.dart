import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/fill_controller.dart';
import 'package:pulse_tasks/data/local_db.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/data/task_file_controller.dart';
import 'package:pulse_tasks/data/task_repository.dart';
import 'package:pulse_tasks/models/task.dart';
import 'package:pulse_tasks/ui/task_detail_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Фото при создании задачи и дозагрузка к задаче (#36914).
///
/// Проверяется ровно то, что обещано в приёмке: несколько кадров доезжают до задачи и
/// в онлайне, и после офлайн-создания; кадр, от которого отказались, не появляется на
/// сервере и не остаётся на диске; снимок цепляется к самой задаче, а не к комментарию;
/// предел на количество виден человеку до того, как он снял лишнее.
///
/// Настоящий sqlite (ffi) и настоящие файлы: очередь снимков, барьер «создание раньше
/// файлов» и уборка с диска живут в схеме и в файловой системе — мокать их значит не
/// проверить ничего.

int _seq = 0;

const _uuid = '22222222-2222-4222-8222-222222222222';

/// Однопиксельный PNG — плитке нужен настоящий файл картинки, иначе Image.file уйдёт
/// в errorBuilder и «снимок показан» ничего не докажет.
final _png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmM'
    'IQAAAABJRU5ErkJggg==');

Future<LocalDb> _openDb() async =>
    LocalDb.open('t36914_${DateTime.now().microsecondsSinceEpoch}_${_seq++}');

class _Server {
  final calls = <String>[];
  final bodies = <(String, String)>[];
  List<Map<String, Object?>> tasks = [];
  bool down = false;
  final failWith = <String, int>{};

  late final Session session;
  late final ApiClient api;

  _Server(Settings settings) {
    session = Session(
      login: 'petrov${DateTime.now().microsecondsSinceEpoch}_${_seq++}',
      name: 'Петров П.П.',
      token: 'token',
      signedIn: true,
      performerId: 'p1',
    );
    api = ApiClient(settings, session, client: MockClient((request) async {
      final action = request.url.path.split('.').last;
      if (request.method == 'POST') {
        calls.add(action);
        if (down) throw const SocketException('нет сети');
        final fail = failWith[action];
        if (fail != null) return http.Response('boom', fail);
        bodies.add((action, request.body));
        return http.Response('', 200);
      }
      calls.add(action);
      if (down) throw const SocketException('нет сети');
      if (action == 'apiTaskFile') {
        return http.Response.bytes(_png, 200,
            headers: {'content-type': 'image/png'});
      }
      final body = action == 'apiTasks' ? jsonEncode(tasks) : '[]';
      return http.Response.bytes(utf8.encode(body), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    }));
  }

  List<String> postsOf(String action) =>
      [for (final (a, b) in bodies) if (a == action) b];
}

Task _localTask(String uuid) => Task(
      id: uuid,
      clientId: uuid,
      name: 'Витрина',
      object: 'Магазин №1',
      objectId: 'b24',
      typeId: 'issue',
      status: 'Ожидает отправки',
    );

/// Снимок на диске — то, что кладёт в очередь камера или выбиратель.
Future<String> _shot(Directory dir, String name) async {
  final f = File(p.join(dir.path, name));
  await f.writeAsBytes(_png);
  return f.path;
}

/// Задача, какой её отдаёт apiTasks — с файлами, если они уже на сервере.
Map<String, Object?> _task({
  String id = 'ST1',
  List<Map<String, Object?>> files = const [],
}) =>
    {
      'id': id,
      'name': 'Витрина у входа',
      'object': 'Магазин №1',
      'objectId': 'o1',
      'typeId': 'issue',
      'statusId': 'new',
      'status': 'Новая',
      'assigned': true,
      'author': 'Головнин С.',
      'authorId': 'p9',
      'postedAt': '2026-08-16',
      if (files.isNotEmpty) 'files': files,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Settings settings;
  late _Server server;
  late Directory docs;
  late Directory tmp;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    docs = Directory.systemTemp.createTempSync('pulse_docs');
    tmp = Directory.systemTemp.createTempSync('pulse_shots');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => docs.path);
    settings = Settings(baseUrl: 'http://test.local:9080');
    server = _Server(settings);
  });

  tearDown(() {
    if (docs.existsSync()) docs.deleteSync(recursive: true);
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('очередь снимков', () {
    test('три кадра при создании уезжают по одному, после самой задачи',
        () async {
      final db = await _openDb();
      final photos = {
        'f1': await _shot(tmp, 'a.jpg'),
        'f2': await _shot(tmp, 'b.jpg'),
        'f3': await _shot(tmp, 'c.jpg'),
      };
      await db.createLocalTask(
        _localTask(_uuid),
        payloadJson: jsonEncode({
          'clientId': _uuid,
          'typeId': 'issue',
          'objectId': 'b24',
          'name': 'Витрина',
        }),
        photos: photos,
        createdAtIso: '2026-08-24T10:00:00.000',
      );

      // создание — барьер: пока задача не уехала, кадрам ехать некуда
      await TaskFilesController.drainAll(db, server.api,
          skip: await db.getCreateTaskIds());
      expect(server.calls, isEmpty,
          reason: 'файл к задаче, которой сервер не знает, ехать не может');
      expect(await db.getTaskFileOutbox(_uuid), hasLength(3));

      await FillController.pushCreate(db, server.api, _uuid);
      await TaskFilesController.drainAll(db, server.api,
          skip: await db.getCreateTaskIds());

      expect(server.calls,
          ['apiCreateTask', 'apiAddTaskFile', 'apiAddTaskFile', 'apiAddTaskFile']);
      // задача уехала БЕЗ фото внутри: кадров может быть много, и место им — в своей
      // очереди, а не в теле создания
      final create = jsonDecode(server.postsOf('apiCreateTask').single) as Map;
      expect(create.containsKey('photo'), isFalse);
      final sent = [
        for (final b in server.postsOf('apiAddTaskFile'))
          jsonDecode(b) as Map<String, dynamic>
      ];
      expect(sent.map((m) => m['id']).toSet(), {_uuid});
      expect(sent.map((m) => m['clientId']).toSet(), photos.keys.toSet(),
          reason: 'у каждого кадра свой ключ идемпотентности');
      expect(sent.every((m) => (m['photo'] as String).isNotEmpty), isTrue);
      // очередь пуста, копии с диска убраны — место в телефоне не занято
      expect(await db.getTaskFileOutbox(_uuid), isEmpty);
      for (final path in photos.values) {
        expect(File(path).existsSync(), isFalse);
      }
      await db.close();
    });

    test('связи нет — одна попытка, очередь и файлы целы', () async {
      final db = await _openDb();
      final path = await _shot(tmp, 'a.jpg');
      await db.enqueueTaskFile('f1', 'ST7',
          path: path, createdAtIso: '2026-08-24T10:00:00.000');
      await db.enqueueTaskFile('f2', 'ST7',
          path: await _shot(tmp, 'b.jpg'),
          createdAtIso: '2026-08-24T10:01:00.000');
      server.down = true;

      final error = await TaskFilesController.drainAll(db, server.api);

      expect(server.calls, ['apiAddTaskFile'],
          reason: 'следующие кадры упрутся в тот же обрыв');
      expect(error, isNotNull);
      expect(await db.getTaskFileOutbox('ST7'), hasLength(2));
      expect(File(path).existsSync(), isTrue,
          reason: 'копия в телефоне — единственная, пока кадр не доехал');
      await db.close();
    });

    test('сервер отверг один кадр — остальные едут', () async {
      final db = await _openDb();
      await db.enqueueTaskFile('f1', 'ST7',
          path: await _shot(tmp, 'a.jpg'),
          createdAtIso: '2026-08-24T10:00:00.000');
      await db.enqueueTaskFile('f2', 'ST7',
          path: await _shot(tmp, 'b.jpg'),
          createdAtIso: '2026-08-24T10:01:00.000');
      server.failWith['apiAddTaskFile'] = 403;

      final error = await TaskFilesController.drainAll(db, server.api);

      expect(server.calls, ['apiAddTaskFile', 'apiAddTaskFile']);
      expect(error, isNotNull);
      expect(await db.getTaskFileOutbox('ST7'), hasLength(2),
          reason: 'отвергнутый кадр остаётся в очереди и пробуется снова');
      await db.close();
    });

    test('файл пропал с диска — запись не висит вечно', () async {
      final db = await _openDb();
      final path = await _shot(tmp, 'a.jpg');
      await db.enqueueTaskFile('f1', 'ST7',
          path: path, createdAtIso: '2026-08-24T10:00:00.000');
      await File(path).delete(); // очищенное хранилище

      final error = await TaskFilesController.drainAll(db, server.api);

      expect(server.calls, isEmpty);
      expect(error, isNull);
      expect(await db.getTaskFileOutbox('ST7'), isEmpty);
      await db.close();
    });

    test('кадр, убранный до отправки, не уезжает и не занимает место', () async {
      final db = await _openDb();
      final path = await _shot(tmp, 'a.jpg');
      final clientId = await TaskFilesController.attach(db, 'ST7', path);
      final stored = (await db.getTaskFileOutbox('ST7')).single['path'] as String;
      expect(File(stored).existsSync(), isTrue);

      await TaskFilesController.discard(db, clientId);
      await TaskFilesController.drainAll(db, server.api);

      expect(server.calls, isEmpty);
      expect(await db.getTaskFileOutbox('ST7'), isEmpty);
      expect(File(stored).existsSync(), isFalse);
      expect(File(path).existsSync(), isTrue,
          reason: 'исходник камеры — не наша копия, его мы не трогаем');
      await db.close();
    });
  });

  group('обновление приложения', () {
    test('единственный кадр старой очереди переезжает в очередь снимков',
        () async {
      final key = 'mig36914_${DateTime.now().microsecondsSinceEpoch}';
      final path = p.join((await getDatabasesPath()), 'pulse_tasks_$key.db');
      // база, какой её оставила версия 17: фото автора — колонкой в task_outbox
      final old = await databaseFactory.openDatabase(path,
          options: OpenDatabaseOptions(
            version: 17,
            onCreate: (db, _) async {
              await db.execute('''
                CREATE TABLE task_outbox (
                  clientId TEXT PRIMARY KEY,
                  payload TEXT NOT NULL,
                  photoPath TEXT,
                  createdAt TEXT NOT NULL
                )''');
            },
          ));
      await old.insert('task_outbox', {
        'clientId': _uuid,
        'payload': '{"clientId":"$_uuid"}',
        'photoPath': 'C:/shots/old.jpg',
        'createdAt': '2026-08-20T10:00:00.000',
      });
      await old.close();

      final db = await LocalDb.open(key);

      final queued = await db.getTaskFileOutbox(_uuid);
      expect(queued, hasLength(1),
          reason: 'снимок мог быть единственной копией — терять его нельзя');
      expect(queued.single['path'], 'C:/shots/old.jpg');
      expect(await db.getCreateEntry(_uuid), isNotNull,
          reason: 'само создание переезд не трогает');
      await db.close();
      await databaseFactory.deleteDatabase(path);
    });
  });

  group('карточка задачи', () {
    Future<TaskRepository> repoOf() async {
      final repo = TaskRepository(
          api: server.api, settings: settings, session: server.session);
      await repo.updateSettings(settings);
      await repo.refresh();
      return repo;
    }

    testWidgets('снимок цепляется к задаче и виден до отправки', (tester) async {
      await tester.runAsync(() async {
        server.tasks = [_task()];
        final repo = await repoOf();
        server.down = true; // подвал: кадр обязан лечь в очередь и показаться

        await repo.attachTaskPhoto('ST1', await _shot(tmp, 'a.jpg'));

        await tester.pumpWidget(ChangeNotifierProvider<TaskRepository>.value(
          value: repo,
          child: const MaterialApp(home: TaskDetailScreen(taskId: 'ST1')),
        ));
        await tester.pump();
        // очередь снимков читается из sqlite — настоящая асинхронность, которую
        // fake-часы теста не двигают
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();

        expect(find.text('Приложить фото'), findsOneWidget);
        expect(find.textContaining('Было'), findsOneWidget,
            reason: 'кадр в очереди показывается там же, где приехавшие');
        expect(await repo.pendingTaskPhotos('ST1'), hasLength(1));
        // ни одного комментария при этом не создано
        expect(server.calls.contains('apiAddTaskComment'), isFalse);

        // связь вернулась — кадр уезжает своей ручкой
        server.down = false;
        await repo.drainLocalTasks();
        expect(server.postsOf('apiAddTaskFile'), hasLength(1));
        final sent =
            jsonDecode(server.postsOf('apiAddTaskFile').single) as Map;
        expect(sent['id'], 'ST1');
        expect(await repo.pendingTaskPhotos('ST1'), isEmpty);

        repo.dispose();
      });
    });

    testWidgets('на задаче с десятью снимками приложить больше нельзя',
        (tester) async {
      await tester.runAsync(() async {
        server.tasks = [
          _task(files: [
            for (var i = 1; i <= TaskFilesController.maxPerTask; i++)
              {'id': '$i', 'name': 'Фото$i.jpg', 'image': true},
          ]),
        ];
        final repo = await repoOf();

        await tester.pumpWidget(ChangeNotifierProvider<TaskRepository>.value(
          value: repo,
          child: const MaterialApp(home: TaskDetailScreen(taskId: 'ST1')),
        ));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        final button = tester.widget<OutlinedButton>(find.ancestor(
          of: find.text('Приложить фото'),
          matching: find.byType(OutlinedButton),
        ));
        expect(button.onPressed, isNull,
            reason: 'предел объявляется до съёмки, а не отказом сервера');
        expect(find.textContaining('Не больше'), findsOneWidget);

        repo.dispose();
      });
    });
  });
}
