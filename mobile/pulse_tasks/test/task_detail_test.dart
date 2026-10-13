import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:pulse_tasks/app_controllers.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/data/task_file_cache.dart';
import 'package:pulse_tasks/models/task_view.dart';
import 'package:pulse_tasks/ui/task_detail_screen.dart';
import 'package:pulse_tasks/ui/theme.dart';
import 'package:pulse_tasks/ui/widgets/ds.dart';
import 'support/test_env.dart';
import 'support/fake_server.dart';

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
      final action = actionOf(request);
      calls.add(action);
      if (down) throw const SocketException('нет сети');
      if (action == 'apiTaskFile') {
        final q = request.url.queryParameters;
        fileCalls.add('${q['id']}${q['thumb'] == '1' ? '?thumb' : ''}');
        return http.Response.bytes(_png, 200,
            headers: {'content-type': 'image/png'});
      }
      final body = action == 'apiTasks' ? jsonEncode(tasks) : '[]';
      return okJson(body);
    }));
  }
}

Future<AppControllers> _repo(Settings settings, _Server server) async {
  final app = AppControllers(
      api: server.api, settings: settings, session: server.session);
  await app.account.updateSettings(settings); // открывает базу этого логина
  await app.repo.refresh();
  return app;
}

TaskView _view(AppControllers app, String id) =>
    app.repo.tasks.firstWhere((v) => v.id == id);

/// Задача, какой её отдаёт apiTasks после #36842: описание уже без разметки, автор и
/// дата постановки, файлы задачи и выполнения.
Map<String, Object?> _task({
  String id = 'ST1',
  String? description,
  String? address,
  String? deadline,
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
      if (address != null) 'address': address,
      if (deadline != null) 'deadline': deadline,
      'author': 'Головнин С.',
      'authorId': 'p9',
      'postedAt': '2026-08-16',
      if (files.isNotEmpty) 'files': files,
      if (executions.isNotEmpty) 'executions': executions,
    };

void main() {
  initTestEnv();

  late Settings settings;
  late _Server server;
  late Directory docs;

  setUp(() {
    resetMockStores();
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
      final app = await _repo(settings, server);

      final t = _view(app, 'ST1').task;
      expect(t.description, 'Убрать мусор у витрины\nи протереть стекло');
      expect(t.author, 'Головнин С.');
      expect(t.postedAt, '2026-08-16');

      // связь пропала — карточка обязана открыться на том же самом
      server.down = true;
      await app.repo.refresh();
      final offline = _view(app, 'ST1').task;
      expect(offline.description, t.description,
          reason: 'описание читается из sqlite, а не из ответа сервера');
      expect(offline.author, 'Головнин С.');
      app.dispose();
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
      final app = await _repo(settings, server);

      final t = _view(app, 'ST1').task;
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
      await app.repo.refresh();
      final offline = _view(app, 'ST1').task;
      expect(offline.files.map((f) => f.id), ['11', '12']);
      expect(offline.executions.single.photoId, '13');
      app.dispose();
    });

    test('строка старого сервера (без новых ключей) читается как раньше', () async {
      server.tasks = [
        {'id': 'ST9', 'name': 'Старая', 'objectId': 'o1'},
      ];
      final app = await _repo(settings, server);

      final t = _view(app, 'ST9').task;
      expect(t.description, isNull);
      expect(t.author, isNull);
      expect(t.files, isEmpty);
      expect(t.executions, isEmpty);
      app.dispose();
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
      final app = await _repo(settings, server);
      await TaskFileCache.deleteAll(app.repo.db.userKey); // чистый диск

      await app.sync.prefetchTaskPhotos();
      expect(server.fileCalls, ['11?thumb', '13?thumb'],
          reason: 'pdf не картинка, полный размер — только по тапу');

      // второй проход не ходит в сеть: миниатюры уже на диске
      await app.sync.prefetchTaskPhotos();
      expect(server.fileCalls, ['11?thumb', '13?thumb']);

      await TaskFileCache.deleteAll(app.repo.db.userKey);
      app.dispose();
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
        final app = await _repo(settings, server);

        await tester.pumpWidget(MultiProvider(
          providers: app.providers,
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

        await TaskFileCache.deleteAll(app.repo.db.userKey);
        app.dispose();
      });
    });

    testWidgets('задача без описания, файлов и выполнений выглядит как раньше',
        (tester) async {
      await tester.runAsync(() async {
        server.tasks = [_task()];
        final app = await _repo(settings, server);

        await tester.pumpWidget(MultiProvider(
          providers: app.providers,
          child: const MaterialApp(home: TaskDetailScreen(taskId: 'ST1')),
        ));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.textContaining('Было'), findsNothing,
            reason: 'пустой блок с заголовком — шум, а не информация');
        expect(find.textContaining('Стало'), findsNothing);
        expect(find.text('Головнин С.'), findsOneWidget);

        app.dispose();
      });
    });

    // карточка по макету стр. 2 (#37411): объект пином под заголовком, «ключ —
    // значение» строками с разделителями, фото — только кнопкой нижней панели
    testWidgets('шапка, объект и блок «ключ — значение» — по макету стр. 2',
        (tester) async {
      await tester.runAsync(() async {
        server.tasks = [
          _task(address: 'ул. Ленина, 1', deadline: '2026-09-01'),
        ];
        final app = await _repo(settings, server);

        await tester.pumpWidget(MultiProvider(
          providers: app.providers,
          child: const MaterialApp(home: TaskDetailScreen(taskId: 'ST1')),
        ));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        // объект и адрес — пином, одной строкой под заголовком
        expect(find.byIcon(Icons.location_on_outlined), findsOneWidget);
        expect(find.text('Магазин №1, ул. Ленина, 1'), findsOneWidget);

        // отдельной кнопки «Приложить фото» в теле карточки больше нет —
        // фото живёт квадратом в нижней панели
        expect(find.text('Приложить фото'), findsNothing);
        expect(find.byKey(const ValueKey('taskAttachPhoto')), findsOneWidget);

        // строки справки разделены тонкими линиями, срок назван как в макете
        expect(find.text('Крайний срок'), findsOneWidget);
        expect(find.text('01.09.2026'), findsOneWidget);
        expect(
            find.byWidgetPredicate(
                (w) => w is Divider && w.color == Wms.line),
            findsAtLeastNWidgets(2),
            reason: 'между «поставил — поставлена — исполнитель» нужны разделители');

        // ширина карточек — на общих полях экрана (16), вровень с заголовком
        // и плашками: собственная маржа DsCard здесь выключена
        final cards = find.byType(DsCard);
        for (var i = 0; i < cards.evaluate().length; i++) {
          final rect = tester.getRect(cards.at(i));
          expect(rect.left, 16.0,
              reason: 'карточка начинается на общем поле экрана');
          expect(rect.right, 784.0,
              reason: 'карточка кончается на общем поле экрана');
        }

        app.dispose();
      });
    });

    // Длинные тип и статус не должны уплывать за экран: оба элемента яруса —
    // Flexible, лишнее режется многоточием (RenderFlex overflow в тесте падает сам)
    testWidgets('длинные тип и статус ужимаются в ярусе чипов', (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.runAsync(() async {
        server.tasks = [
          {
            ..._task(),
            'type': 'Проверка выкладки сезонных товаров и промо-конструкций',
            'status': 'Отправлена на согласование региональному руководителю',
          },
        ];
        final app = await _repo(settings, server);

        await tester.pumpWidget(MultiProvider(
          providers: app.providers,
          child: const MaterialApp(home: TaskDetailScreen(taskId: 'ST1')),
        ));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        // и тип, и пилюля статуса — в пределах поля экрана (320 − 16 − 16);
        // оба текста в карточке не одни (справка, переключатель) — берём первый
        final type = tester.renderObject<RenderBox>(
            find.textContaining('Проверка выкладки').first);
        expect(type.size.width, lessThan(320 - 32));
        final chip = tester.renderObject<RenderBox>(
            find.textContaining('Отправлена на согласование').first);
        expect(chip.size.width, lessThan(320 - 32));

        app.dispose();
      });
    });
  });
}
