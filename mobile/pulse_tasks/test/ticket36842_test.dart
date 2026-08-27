import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/data/task_file_cache.dart';
import 'package:pulse_tasks/data/task_repository.dart';
import 'package:pulse_tasks/ui/task_detail_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Карточка задачи (#36842): описание, кто поставил и когда, снимок проблемы («было»)
/// и выполнения со снимком результата («стало»). Настоящий sqlite (ffi): всё это едет
/// вместе с задачей и обязано пережить офлайн — кэш здесь и есть предмет проверки, а
/// не декорация вокруг него.

int _seq = 0;

/// Однопиксельный PNG: миниатюре в тесте нужно быть настоящей картинкой, иначе
/// Image.file уйдёт в errorBuilder и проверка «снимок показан» ничего не докажет.
final _png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmM'
    'IQAAAABJRU5ErkJggg==');

class _Server {
  final calls = <String>[];
  final fileCalls = <String>[]; // id + '?thumb' — что именно качали
  List<Map<String, Object?>> tasks = [];
  bool down = false;

  late final Session session;
  late final ApiClient api;

  _Server(Settings settings) {
    session = Session(
      // логин уникален и между прогонами: имя базы содержит его, а файл ffi-sqlite
      // переживает запуск — прошлый кэш иначе пережил бы тест
      login: 'petrov${DateTime.now().microsecondsSinceEpoch}_${_seq++}',
      name: 'Петров П.П.',
      token: 'token',
      signedIn: true,
      performerId: 'p1',
    );
    api = ApiClient(settings, session, client: MockClient((request) async {
      final action = request.url.path.split('.').last;
      calls.add(action);
      if (down) throw const SocketException('нет сети');
      if (action == 'apiTaskFile') {
        final q = request.url.queryParameters;
        fileCalls.add('${q['id']}${q['thumb'] == '1' ? '?thumb' : ''}');
        return http.Response.bytes(_png, 200,
            headers: {'content-type': 'image/png'});
      }
      final body = action == 'apiTasks' ? jsonEncode(tasks) : '[]';
      return http.Response.bytes(utf8.encode(body), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    }));
  }
}

Future<TaskRepository> _repo(Settings settings, _Server server) async {
  final repo = TaskRepository(
      api: server.api, settings: settings, session: server.session);
  await repo.updateSettings(settings); // открывает базу этого логина
  await repo.refresh();
  return repo;
}

TaskView _view(TaskRepository repo, String id) =>
    repo.tasks.firstWhere((v) => v.id == id);

/// Задача, какой её отдаёт apiTasks после #36842: описание уже без разметки, автор и
/// дата постановки, файлы задачи и выполнения.
Map<String, Object?> _task({
  String id = 'ST1',
  String? description,
  List<Map<String, Object?>> files = const [],
  List<Map<String, Object?>> executions = const [],
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
      if (description != null) 'description': description,
      'author': 'Головнин С.',
      'authorId': 'p9',
      'postedAt': '2026-08-16',
      if (files.isNotEmpty) 'files': files,
      if (executions.isNotEmpty) 'executions': executions,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Settings settings;
  late _Server server;
  late Directory docs;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    // фото задачи живут файлами в каталоге приложения — на настольной машине его
    // никто не подставляет, поэтому подставляем сами: без этого кэш миниатюр (то,
    // ради чего карточка открывается офлайн) в тесте не существует
    docs = Directory.systemTemp.createTempSync('pulse_docs');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => docs.path);
    settings = Settings(baseUrl: 'http://test.local:9080');
    server = _Server(settings);
  });

  tearDown(() {
    if (docs.existsSync()) docs.deleteSync(recursive: true);
  });

  group('данные карточки', () {
    test('описание, автор и дата постановки доезжают и живут в кэше', () async {
      server.tasks = [
        _task(description: 'Убрать мусор у витрины\nи протереть стекло'),
      ];
      final repo = await _repo(settings, server);

      final t = _view(repo, 'ST1').task;
      expect(t.description, 'Убрать мусор у витрины\nи протереть стекло');
      expect(t.author, 'Головнин С.');
      expect(t.postedAt, '2026-08-16');

      // связь пропала — карточка обязана открыться на том же самом
      server.down = true;
      await repo.refresh();
      final offline = _view(repo, 'ST1').task;
      expect(offline.description, t.description,
          reason: 'описание читается из sqlite, а не из ответа сервера');
      expect(offline.author, 'Головнин С.');
      repo.dispose();
    });

    test('«было» и «стало» разведены: файлы задачи отдельно, выполнения отдельно',
        () async {
      server.tasks = [
        _task(
          description: 'Мусор у витрины',
          files: [
            {
              'id': '11',
              'name': 'Фото к задаче.jpg',
              'image': true,
              'dateTime': '2026-08-16 09:12',
              'author': 'Головнин С.',
            },
            {'id': '12', 'name': 'Регламент.pdf'},
          ],
          executions: [
            {
              'id': '77',
              'dateTime': '2026-08-17 14:05',
              'executor': 'Петров П.П.',
              'finished': true,
              'result': 'Выполнено',
              'photoId': '13',
            },
          ],
        ),
      ];
      final repo = await _repo(settings, server);

      final t = _view(repo, 'ST1').task;
      expect(t.files.map((f) => f.id), ['11', '12']);
      expect(t.files.first.image, isTrue);
      expect(t.files.first.author, 'Головнин С.');
      expect(t.files.last.image, isFalse,
          reason: 'pdf — значок файла, а не миниатюра');
      expect(t.files.map((f) => f.id), isNot(contains('13')),
          reason: 'снимок результата в «было» не попадает — иначе '
              '«зафиксировал изменение» перестаёт читаться');

      expect(t.executions, hasLength(1));
      expect(t.executions.single.executor, 'Петров П.П.');
      expect(t.executions.single.finished, isTrue);
      expect(t.executions.single.photoId, '13');

      // и всё это — из кэша, тем же составом
      server.down = true;
      await repo.refresh();
      final offline = _view(repo, 'ST1').task;
      expect(offline.files.map((f) => f.id), ['11', '12']);
      expect(offline.executions.single.photoId, '13');
      repo.dispose();
    });

    test('строка старого сервера (без новых ключей) читается как раньше', () async {
      server.tasks = [
        {'id': 'ST9', 'name': 'Старая', 'objectId': 'o1'},
      ];
      final repo = await _repo(settings, server);

      final t = _view(repo, 'ST9').task;
      expect(t.description, isNull);
      expect(t.author, isNull);
      expect(t.files, isEmpty);
      expect(t.executions, isEmpty);
      repo.dispose();
    });
  });

  group('миниатюры', () {
    test('префетч тянет только картинки, только миниатюрами и один раз',
        () async {
      server.tasks = [
        _task(
          files: [
            {'id': '11', 'name': 'Фото.jpg', 'image': true},
            {'id': '12', 'name': 'Регламент.pdf'},
          ],
          executions: [
            {'id': '77', 'executor': 'Петров П.П.', 'photoId': '13'},
          ],
        ),
      ];
      final repo = await _repo(settings, server);
      await TaskFileCache.deleteAll(repo.db.userKey); // чистый диск

      await repo.prefetchTaskPhotos();
      expect(server.fileCalls, ['11?thumb', '13?thumb'],
          reason: 'pdf не картинка, полный размер — только по тапу');

      // второй проход не ходит в сеть: миниатюры уже на диске
      await repo.prefetchTaskPhotos();
      expect(server.fileCalls, ['11?thumb', '13?thumb']);

      await TaskFileCache.deleteAll(repo.db.userKey);
      repo.dispose();
    });
  });

  group('экран', () {
    // настоящий sqlite не живёт в FakeAsync-зоне testWidgets — работа с базой и
    // сетью идёт внутри runAsync, где время и I/O настоящие
    testWidgets('видно описание, кто поставил, «было» и «стало»',
        (tester) async {
      await tester.runAsync(() async {
        server.tasks = [
          _task(
            description: 'Убрать мусор у витрины',
            files: [
              {'id': '11', 'name': 'Фото.jpg', 'image': true},
            ],
            executions: [
              {
                'id': '77',
                'dateTime': '2026-08-17 14:05',
                'executor': 'Петров П.П.',
                'finished': true,
                'result': 'Выполнено',
                'photoId': '13',
              },
            ],
          ),
        ];
        final repo = await _repo(settings, server);

        await tester.pumpWidget(ChangeNotifierProvider<TaskRepository>.value(
          value: repo,
          child: const MaterialApp(home: TaskDetailScreen(taskId: 'ST1')),
        ));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.text('Убрать мусор у витрины'), findsOneWidget);
        expect(find.text('Головнин С.'), findsOneWidget);
        expect(find.text('16.08.2026'), findsOneWidget,
            reason: 'дата постановки — по-человечески, а не как её хранит база');
        expect(find.textContaining('Было'), findsOneWidget);
        expect(find.textContaining('Стало'), findsOneWidget);
        expect(find.text('Петров П.П.'), findsOneWidget);
        expect(find.textContaining('17.08.2026 14:05'), findsOneWidget);
        expect(find.text('Выполнено'), findsOneWidget);

        await TaskFileCache.deleteAll(repo.db.userKey);
        repo.dispose();
      });
    });

    testWidgets('задача без описания, файлов и выполнений выглядит как раньше',
        (tester) async {
      await tester.runAsync(() async {
        server.tasks = [_task()];
        final repo = await _repo(settings, server);

        await tester.pumpWidget(ChangeNotifierProvider<TaskRepository>.value(
          value: repo,
          child: const MaterialApp(home: TaskDetailScreen(taskId: 'ST1')),
        ));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.textContaining('Было'), findsNothing,
            reason: 'пустой блок с заголовком — шум, а не информация');
        expect(find.textContaining('Стало'), findsNothing);
        expect(find.text('Головнин С.'), findsOneWidget);

        repo.dispose();
      });
    });
  });
}
