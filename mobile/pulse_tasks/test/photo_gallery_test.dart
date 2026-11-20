import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:pulse_tasks/app_controllers.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/models/fill.dart';
import 'package:pulse_tasks/ui/simple_execution_screen.dart';
import 'package:pulse_tasks/ui/widgets/fill/photo_field.dart';
import 'package:pulse_tasks/ui/widgets/fill_field_tile.dart';
import 'package:pulse_tasks/ui/widgets/task_comments.dart';
import 'package:pulse_tasks/ui/widgets/task_photo.dart';
import 'support/fake_server.dart';
import 'support/test_env.dart';

/// Галереи снимков на экранах: сколько их у пункта, что видно в просмотре, и что
/// перерисовка экрана не идёт за снимками в сеть заново.

final int _run = DateTime.now().microsecondsSinceEpoch;
int _seq = 0;

/// Минимальный настоящий PNG.
final _png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');

class _Srv {
  final calls = <String>[];
  bool offline = false;

  /// Снимки задачи не отдаются (связь есть, а файл — нет).
  bool filesDown = false;
  List<Map<String, Object?>> tasks = [];
  Map<String, Object?> simpleInfo = {};
  List<Map<String, Object?>> comments = [];
  late final Session session;
  late final ApiClient api;

  _Srv(Settings settings) {
    session = Session(
        login: 'gal$_run${_seq++}',
        name: 'Орлов',
        token: 't',
        signedIn: true,
        performerId: 'p1');
    api = ApiClient(settings, session, client: MockClient((r) async {
      final a = actionOf(r);
      calls.add(a);
      if (offline) throw const SocketException('нет сети');
      switch (a) {
        case 'apiTasks':
          return okJson(r.url.queryParameters['archive'] != null
              ? '[]'
              : jsonEncode(tasks));
        case 'apiSimpleInfo':
          return okJson(jsonEncode([simpleInfo]));
        case 'apiTaskFile':
          if (filesDown) throw const SocketException('файл не доехал');
          return http.Response.bytes(_png, 200,
              headers: {'content-type': 'image/png'});
        case 'apiSimplePhoto':
          return http.Response.bytes(_png, 200,
              headers: {'content-type': 'image/png'});
        case 'apiTaskComments':
          return okJson(jsonEncode(comments));
        default:
          return okJson('[]');
      }
    }));
  }

  int count(String action) => calls.where((c) => c == action).length;
}

Future<AppControllers> _appOf(Settings s, _Srv srv) async {
  final app = AppControllers(api: srv.api, settings: s, session: srv.session);
  await app.account.updateSettings(s);
  await app.repo.refresh();
  return app;
}

/// Реальные await внутри runAsync: время теста фальшивое, а ввод-вывод — нет.
Future<void> _settle(WidgetTester t, [int n = 14]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 50));
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Future<void> _close(WidgetTester t) async {
  await t.pumpWidget(const SizedBox());
  await Future<void>.delayed(const Duration(milliseconds: 100));
  await t.pump();
}

Widget _host(AppControllers app, Widget home) =>
    MultiProvider(providers: app.providers, child: MaterialApp(home: home));

Widget _bare(Widget child) =>
    MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child)));

FillFieldTile _editTile(FillField f, {Key? key}) => FillFieldTile(
      key: key,
      field: f,
      onComment: (_) {},
      actions: FieldActions(
        onOption: (_) {},
        onNumber: (_) {},
        onText: (_) {},
        onBool: (_) {},
        onDatePick: () {},
        onScan: () {},
        onPhoto: () {},
        onPhotoSource: (_) {},
        onRemovePhoto: () {},
        onDeleteShot: (_) {},
        onCell: (_, __, ___) {},
        onCellText: (_, __, ___) {},
        onAddRow: (_, __, {code}) async => null,
        onDeleteRow: (_) {},
        onRowSubjectSearch: (_, {allItems = false}) async => const [],
        onRef: (_, __) {},
        onRefSearch: (_) async => const [],
      ),
    );

void main() {
  initTestEnv();

  late Settings settings;
  late _Srv srv;
  late Directory docs;

  setUp(() {
    resetMockStores();
    docs = Directory.systemTemp.createTempSync('gallery_docs');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (c) async => docs.path);
    settings = Settings(baseUrl: 'http://test.local:9080');
    srv = _Srv(settings);
  });

  tearDown(() {
    try {
      docs.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('галерея на плитке пункта', () {
    testWidgets('у поля-фото с «всегда фото» галерея одна', (t) async {
      final f = FillField(
          sectionIndex: 1,
          fieldIndex: 1,
          code: 'p',
          name: 'Фото',
          type: 'photo',
          requirePhotoAlways: true);
      await t.pumpWidget(_bare(_editTile(f)));
      expect(find.byType(PhotoGallery), findsOneWidget);
      expect(find.text('Камера'), findsOneWidget);
    });

    testWidgets('ответ сменили на норму — снимок остаётся на экране', (t) async {
      final opts = [
        FillOption(fieldCode: 'c', code: 'bad', name: 'Плохо', nonconformity: true),
        FillOption(fieldCode: 'c', code: 'ok', name: 'Хорошо'),
      ];
      final f = FillField(
          sectionIndex: 1,
          fieldIndex: 1,
          code: 'c',
          name: 'Шкала',
          type: 'scale',
          requirePhoto: true,
          options: opts,
          optionCode: 'bad',
          shots: const [FillShot(path: 'x.jpg', localIdx: 0)]);
      await t.pumpWidget(_bare(_editTile(f)));
      expect(find.byType(PhotoGallery), findsOneWidget);

      f.optionCode = 'ok';
      await t.pumpWidget(_bare(_editTile(f, key: const ValueKey('x'))));
      expect(find.byType(PhotoGallery), findsOneWidget,
          reason: 'снимок уедет в проверку — убрать его можно только отсюда');
      expect(find.byTooltip('Удалить снимок'), findsOneWidget);
    });

    testWidgets('без снимка и без требования галереи у не-фото поля нет',
        (t) async {
      final f = FillField(
          sectionIndex: 1, fieldIndex: 1, code: 't', name: 'Т', type: 'text');
      await t.pumpWidget(_bare(_editTile(f)));
      expect(find.byType(PhotoGallery), findsNothing);
    });

    testWidgets('просмотр показывает все снимки поля — свои и с сервера',
        (t) async {
      final local = File(p.join(docs.path, 'x.jpg'))..writeAsBytesSync(_png);
      final f = FillField(
          sectionIndex: 1,
          fieldIndex: 1,
          code: 'm',
          name: 'Смесь',
          type: 'photo',
          serverPhotoCount: 2,
          serverPhotoIndexes: [1, 2],
          shots: [
            FillShot(path: local.path, localIdx: 0, serverIndex: 1, uploaded: true),
            const FillShot(serverIndex: 2, uploaded: true),
          ]);
      await t.pumpWidget(_bare(FillFieldTile(
          field: f,
          actions: FieldActions(
            readOnly: true,
            photoLoader: (i, {required thumb}) async => null,
          ),
        )));
      await t.pump();
      expect(find.byType(TaskPhotoThumb), findsOneWidget,
          reason: 'снимок с сервера виден рядом со своим');
      expect(find.byType(Image), findsOneWidget, reason: 'свой — файлом');
      expect(find.byTooltip('Удалить снимок'), findsNothing);
    });

    testWidgets('«Удалить все» спрашивает и без согласия ничего не стирает',
        (t) async {
      var cleared = 0;
      final f = FillField(
          sectionIndex: 1,
          fieldIndex: 1,
          code: 'p',
          name: 'Фото',
          type: 'photo',
          shots: const [FillShot(path: 'x.jpg', localIdx: 0)]);
      await t.pumpWidget(_bare(FillFieldTile(
        field: f,
        onComment: (_) {},
        actions: FieldActions(
          onOption: (_) {},
          onNumber: (_) {},
          onText: (_) {},
          onBool: (_) {},
          onDatePick: () {},
          onScan: () {},
          onPhoto: () {},
          onRemovePhoto: () => cleared++,
          onDeleteShot: (_) {},
          onCell: (_, __, ___) {},
          onAddRow: (_, __, {code}) async => null,
          onDeleteRow: (_) {},
          onRowSubjectSearch: (_, {allItems = false}) async => const [],
          onRef: (_, __) {},
          onRefSearch: (_) async => const [],
        ),
      )));
      await t.tap(find.text('Удалить все'));
      await t.pumpAndSettle();
      expect(find.text('Убрать все снимки?'), findsOneWidget);
      await t.tap(find.text('Отмена'));
      await t.pumpAndSettle();
      expect(cleared, 0);

      await t.tap(find.text('Удалить все'));
      await t.pumpAndSettle();
      await t.tap(find.text('Убрать'));
      await t.pumpAndSettle();
      expect(cleared, 1);
    });
  });

  group('миниатюра качается один раз на плитку', () {
    testWidgets('перерисовка не зовёт загрузчик снова, тап по «офлайн» — зовёт',
        (t) async {
      var calls = 0;
      Future<File?> loader({required bool thumb}) async {
        calls++;
        return null; // сети нет
      }

      Widget thumb() => _bare(TaskPhotoThumb(
          key: const ValueKey('one'), loader: loader));
      await t.pumpWidget(thumb());
      await t.pump();
      expect(calls, 1);
      expect(find.byIcon(Icons.cloud_off), findsOneWidget);

      for (var i = 0; i < 5; i++) {
        await t.pumpWidget(thumb());
        await t.pump();
      }
      expect(calls, 1, reason: 'неудача не повторяется на каждой перерисовке');

      await t.tap(find.byIcon(Icons.cloud_off));
      await t.pump();
      expect(calls, 2, reason: 'явный тап — повтор');
    });
  });

  testWidgets('экран поручения: перерисовка не качает снимки заново', (t) async {
    await t.runAsync(() async {
      srv.tasks = [
        {
          'id': 'S1',
          'name': 'Задача S1',
          'objectId': 'o1',
          'typeId': 'errand',
          'executionKind': 'simple',
          'statusId': 'in_progress',
          'status': 'В работе',
          'assigned': true,
        }
      ];
      srv.simpleInfo = {
        'started': true,
        'photoCount': 2,
        'photoIndexes': '1,2',
        'date': '2026-11-05T10:00:00',
      };
      final app = await _appOf(settings, srv);
      await t.pumpWidget(_host(app, const SimpleExecutionScreen(taskId: 'S1')));
      await _settle(t, 20);
      final first = srv.count('apiSimplePhoto');
      expect(first, 2, reason: 'по одной миниатюре на снимок');
      expect(find.byType(TaskPhotoThumb), findsNWidgets(2));
      for (var i = 0; i < 3; i++) {
        await app.repo.reloadLocal();
        await _settle(t, 6);
      }
      expect(srv.count('apiSimplePhoto'), first,
          reason: 'перерисовки не идут за снимками в сеть');
      await _close(t);
      app.dispose();
    });
  });

  testWidgets('лента: снимок не скачался — набор текста не дёргает загрузку',
      (t) async {
    await t.runAsync(() async {
      srv.tasks = [
        {
          'id': 'ST4',
          'name': 'Задача ST4',
          'objectId': 'o1',
          'typeId': 'checklist',
          'executionKind': 'fill',
          'statusId': 'in_progress',
          'status': 'В работе',
          'assigned': true,
        }
      ];
      srv.comments = [
        {
          'id': 'c1',
          'text': 'смотри',
          'author': 'Иван',
          'dateTime': '2026-11-05 10:00:00',
          'files': [
            {'id': 'F1', 'name': 'a.jpg', 'image': true}
          ],
        },
      ];
      srv.filesDown = true;
      final app = await _appOf(settings, srv);
      await t.pumpWidget(_host(
          app,
          const Scaffold(
              body: SingleChildScrollView(
                  child: TaskCommentsSection(taskId: 'ST4')))));
      await _settle(t, 20);
      expect(find.byType(TaskPhotoThumb), findsOneWidget);
      expect(find.byIcon(Icons.cloud_off), findsOneWidget);

      final before = srv.count('apiTaskFile');
      for (final s in ['а', 'аб', 'абв', 'абвг', 'абвгд']) {
        await t.enterText(find.byType(TextField), s);
        await _settle(t, 2);
      }
      expect(srv.count('apiTaskFile'), before,
          reason: 'пять символов — ни одного нового запроса снимка');

      // снимок снова доступен — тап по плитке скачивает его
      srv.filesDown = false;
      await t.tap(find.byIcon(Icons.cloud_off));
      await _settle(t, 6);
      expect(srv.count('apiTaskFile'), before + 1);
      await _close(t);
      app.dispose();
    });
  });
}
