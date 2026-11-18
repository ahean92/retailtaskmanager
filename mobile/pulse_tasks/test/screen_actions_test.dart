import 'dart:async';
import 'dart:convert';
import 'dart:io';

// заглушке камеры нужен сам платформенный интерфейс — пакет camera его не реэкспортирует
// ignore: depend_on_referenced_packages
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:pulse_tasks/app_controllers.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/ui/camera_screen.dart';
import 'package:pulse_tasks/ui/simple_execution_screen.dart';
import 'package:pulse_tasks/ui/task_detail_screen.dart';
import 'package:pulse_tasks/ui/task_list_screen.dart';
import 'package:pulse_tasks/ui/task_result_screen.dart';
import 'package:pulse_tasks/ui/widgets/task_card.dart';
import 'support/fake_server.dart';
import 'support/test_env.dart';

/// Экраны задачи на настоящих контроллерах и sqlite: экран результата показывает
/// момент сдачи, а не начала работы, и комментарий сразу; главное действие карточки
/// — «Взять» у свободной, «Ждёт отправки» у завершённой на телефоне, «Посмотреть» у
/// взятой коллегой; опустевшая выбранная группа списка не держит пустой экран;
/// просрочка — по календарным дням; камера поднимается после системного диалога;
/// ответ главной без блоков не теряет числа дня.

int _seq = 0;

class _Srv {
  final calls = <String>[];
  bool offline = false;
  List<Map<String, Object?>> tasks = [];
  Map<String, Object?> simpleInfo = {};
  Map<String, Object?>? home;
  late final Session session;
  late final ApiClient api;

  _Srv(Settings settings) {
    session = Session(
        login: 'scr${_seq++}',
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
        case 'apiHome':
          return okJson(jsonEncode(home == null ? const [] : [home]));
        default:
          return okJson('[]');
      }
    }));
  }
}

Map<String, Object?> _task(String id,
        {String kind = 'fill', Map<String, Object?> more = const {}}) =>
    {
      'id': id,
      'name': 'Задача $id',
      'objectId': 'o1',
      'typeId': kind == 'fill' ? 'checklist' : 'errand',
      'executionKind': kind,
      'statusId': 'in_progress',
      'status': 'В работе',
      ...more,
    };

Future<AppControllers> _appOf(Settings s, _Srv srv) async {
  final app = AppControllers(api: srv.api, settings: s, session: srv.session);
  await app.account.updateSettings(s);
  await app.repo.refresh();
  return app;
}

Future<void> _settle(WidgetTester t, [int n = 12]) async {
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

String _ymd(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Камера-заглушка: инициализация проходит сразу, кадров не нужно.
class _FakeCam extends CameraPlatform {
  int created = 0;
  final _init = StreamController<CameraInitializedEvent>.broadcast();

  @override
  Future<List<CameraDescription>> availableCameras() async => const [
        CameraDescription(
            name: 'b',
            lensDirection: CameraLensDirection.back,
            sensorOrientation: 0)
      ];

  @override
  Future<int> createCameraWithSettings(CameraDescription d, MediaSettings? m) async =>
      ++created;

  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int id) =>
      _init.stream.where((e) => e.cameraId == id);

  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() =>
      const Stream.empty();

  // контроллер камеры ждёт первое событие этого потока — пустой поток роняет его
  @override
  Stream<CameraResolutionChangedEvent> onCameraResolutionChanged(int id) =>
      Stream.value(CameraResolutionChangedEvent(id, 640, 480));

  // ошибок и закрытий нет — потоки молчат, но не закрываются: контроллер ждёт их
  // первое событие, а у пустого закрытого потока его нет (Bad state)
  @override
  Stream<CameraClosingEvent> onCameraClosing(int id) =>
      StreamController<CameraClosingEvent>().stream;

  @override
  Stream<CameraErrorEvent> onCameraError(int id) =>
      StreamController<CameraErrorEvent>().stream;

  @override
  Future<void> initializeCamera(int id,
      {ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown}) async {
    scheduleMicrotask(() => _init.add(CameraInitializedEvent(
        id, 640, 480, ExposureMode.auto, true, FocusMode.auto, true)));
  }

  @override
  Future<void> dispose(int id) async {}

  @override
  Widget buildPreview(int id) => const SizedBox(key: ValueKey('fakePreview'));
}

void main() {
  initTestEnv();
  late Settings settings;
  late _Srv srv;
  late Directory docs;

  setUp(() {
    resetMockStores();
    docs = Directory.systemTemp.createTempSync('screens_docs');
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

  testWidgets('результат: «сдал» — момент сдачи, метка по сроку, комментарий '
      'сразу после загрузки отчёта', (t) async {
    await t.runAsync(() async {
      // начато до срока, сдано после — раньше экран писал «сдал» временем начала
      // и «в срок»
      srv.tasks = [
        _task('ST1', kind: 'simple', more: {
          'assigned': true,
          'statusId': 'acceptance',
          'deadline': '2026-11-02',
          'submittedAt': '2026-11-05T18:00:00',
          'executions': [
            {
              'id': 1,
              'dateTime': '2026-11-01T09:00:00',
              'executor': 'Иванов',
              'finished': true
            }
          ],
        }),
        _task('ST2', kind: 'simple', more: {
          'assigned': true,
          'statusId': 'acceptance',
          'submittedAt': '2026-11-05T18:00:00',
        }),
      ];
      srv.simpleInfo = {
        'date': '2026-11-01T09:00:00',
        'executor': 'Иванов',
        'finished': true,
        'comment': 'Сделано всё',
      };
      final app = await _appOf(settings, srv);
      await t.pumpWidget(_host(app, const TaskResultScreen(taskId: 'ST1')));
      await _settle(t, 20);
      expect(find.text('Сделано всё'), findsOneWidget,
          reason: 'отчёт доехал — экран перерисован без постороннего повода');
      expect(find.text('Без комментария'), findsNothing);
      final submitted = find.textContaining('сдал');
      expect(submitted, findsOneWidget);
      expect((t.widget<Text>(submitted)).data, contains('18:00'),
          reason: 'момент сдачи, а не начала работы (09:00)');
      expect(find.text('с опозданием'), findsOneWidget);
      expect(find.text('в срок'), findsNothing);
      await _close(t);

      await t.pumpWidget(_host(app, const TaskResultScreen(taskId: 'ST2')));
      await _settle(t, 20);
      expect(find.text('в срок'), findsNothing,
          reason: 'без срока сказать «в срок» нечем');
      expect(find.text('с опозданием'), findsNothing);
      await _close(t);
      app.dispose();
    });
  });

  testWidgets('карточка: свободная — «Взять», завершённая на телефоне — «Ждёт '
      'отправки», взятая коллегой — «Посмотреть»', (t) async {
    await t.runAsync(() async {
      srv.tasks = [
        _task('F1', more: {'canTake': true, 'mine': false}),
        _task('S1', kind: 'simple', more: {'canTake': true, 'mine': false}),
        _task('F2', more: {'assigned': true, 'mine': true}),
        _task('F3', more: {
          'mine': false,
          'takenById': 'p9',
          'takenBy': 'Петров П.П.',
          'canTake': false,
        }),
      ];
      final app = await _appOf(settings, srv);
      Future<void> open(String id) async {
        await t.pumpWidget(
            _host(app, TaskDetailScreen(key: ValueKey(id), taskId: id)));
        await _settle(t);
      }

      for (final id in ['F1', 'S1']) {
        await open(id);
        expect(find.text('Взять'), findsOneWidget, reason: id);
        expect(find.text('Заполнить чек-лист'), findsNothing, reason: id);
        expect(find.text('Выполнить'), findsNothing, reason: id);
        await _close(t);
      }

      // завершена здесь, завершение ещё в очереди
      srv.offline = true;
      await app.repo.db.queues.enqueueFinish('F2', '2026-11-18T10:00:00');
      await app.repo.reloadLocal();
      await open('F2');
      final waiting = find.widgetWithText(FilledButton, 'Ждёт отправки');
      expect(waiting, findsOneWidget);
      expect(t.widget<FilledButton>(waiting).onPressed, isNull,
          reason: 'работа сделана — звать в бланк незачем');
      await _close(t);

      await open('F3');
      expect(find.text('Посмотреть'), findsOneWidget,
          reason: 'бланк коллеги — только читать (вопрос 34)');
      expect(find.text('Заполнить чек-лист'), findsNothing);
      await _close(t);
      app.dispose();
    });
  });

  testWidgets('список: выбранная группа опустела — показывается первая непустая',
      (t) async {
    await t.runAsync(() async {
      srv.tasks = [
        _task('M1', more: {'assigned': true, 'mine': true}),
        _task('D1', more: {
          'reviewing': true,
          'awaitingDecision': true,
          'statusId': 'acceptance'
        }),
      ];
      final app = await _appOf(settings, srv);
      await t.pumpWidget(_host(app, const TaskListScreen(asTab: true)));
      await _settle(t);
      await t.tap(find.text('Решить'));
      await _settle(t);
      expect(find.byType(TaskCard), findsOneWidget);

      // решение по последней задаче в «Решить» принято
      srv.tasks = [srv.tasks.first];
      await app.repo.refresh();
      await _settle(t);
      expect(find.text('Решить'), findsNothing);
      expect(find.byType(TaskCard), findsOneWidget,
          reason: 'на экране «Мои», а не пустота под скрытым чипом');
      await _close(t);
      app.dispose();
    });
  });

  testWidgets('поручение: срок вчера — «просрочено на 1 день»', (t) async {
    await t.runAsync(() async {
      final y = DateTime.now().subtract(const Duration(days: 1));
      srv.tasks = [
        _task('S1', kind: 'simple', more: {
          'assigned': true,
          'overdue': 1,
          'dueToday': 0,
          'deadline': _ymd(y),
        }),
      ];
      srv.simpleInfo = {'started': true};
      final app = await _appOf(settings, srv);
      await t.pumpWidget(_host(app, const SimpleExecutionScreen(taskId: 'S1')));
      await _settle(t, 20);
      expect(find.textContaining('просрочено на 1 день'), findsOneWidget);
      await _close(t);
      app.dispose();
    });
  });

  testWidgets('камера поднимается после системного диалога и шторки', (t) async {
    final cam = _FakeCam();
    CameraPlatform.instance = cam;
    await t.runAsync(() async {
      await t.pumpWidget(const MaterialApp(home: CameraScreen(limit: 3)));
      await _settle(t, 10);
      expect(find.byKey(const ValueKey('fakePreview')), findsOneWidget);
      // диалог или шторка: inactive, затем resumed
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await _settle(t, 6);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _settle(t, 20);
      expect(cam.created, 2, reason: 'отпущенная камера создана заново');
      expect(find.byKey(const ValueKey('fakePreview')), findsOneWidget);
      await _close(t);
    });
  });

  test('главная без блоков не теряет «сегодня сделано N из M»', () async {
    srv.home = {
      'blocks': [
        {'code': 't', 'type': 'text', 'title': 'Памятка', 'body': '<p>x</p>'}
      ],
      'todayDone': 1,
      'todayTotal': 4,
    };
    final app = await _appOf(settings, srv);
    await app.home.refreshHome();
    expect(app.home.layout.blocks, hasLength(1));

    // сервер без настроенной главной — блоков нет, а числа дня есть
    srv.home = {'blocks': <Object>[], 'todayDone': 3, 'todayTotal': 5};
    await app.home.refreshHome();
    expect(app.home.layout.blocks, hasLength(1),
        reason: 'рабочая главная не заменяется пустой');
    expect(app.home.layout.todayDone, 3);
    expect(app.home.layout.todayTotal, 5);
    app.dispose();
  });
}
