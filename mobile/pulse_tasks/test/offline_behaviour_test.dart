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
import 'package:pulse_tasks/data/cache_sweep.dart';
import 'package:pulse_tasks/data/fill_controller.dart';
import 'package:pulse_tasks/data/geo.dart';
import 'package:pulse_tasks/data/local_db.dart';
import 'package:pulse_tasks/data/past_fill_controller.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/data/task_file_cache.dart';
import 'package:pulse_tasks/models/comment.dart';
import 'package:pulse_tasks/models/task.dart';
import 'package:pulse_tasks/models/task_file.dart';
import 'package:pulse_tasks/ui/settings_screen.dart';
import 'support/fake_server.dart';
import 'support/test_env.dart';

/// Офлайн-поведение телефона: что держится на диске после закрытия задачи, одно
/// число «не отправлено», сколько ждать точку на «Завершить» и чем по умолчанию
/// подключаться к серверу.

int _seq = 0;

/// Телефон, у которого спрашивают координаты: что ответил и сколько ждали.
class _Phone implements GeoPlatform {
  GeoPermission granted;
  int asked = 0;
  final timeouts = <Duration>[];
  _Phone(this.granted);

  @override
  Future<bool> servicesEnabled() async => true;
  @override
  Future<GeoPermission> permission() async => granted;
  @override
  Future<GeoPermission> requestPermission() async {
    asked++;
    return granted;
  }

  @override
  Future<GeoFix?> lastKnown() async => null;
  @override
  Future<GeoFix?> fix(Duration timeout) async {
    timeouts.add(timeout);
    return null;
  }

  @override
  Future<void> openSettings({required bool locationServices}) async {}
}

void main() {
  initTestEnv();

  late Directory docs;
  late Settings settings;
  late Session session;

  setUp(() {
    resetMockStores();
    docs = Directory.systemTemp.createTempSync('pulse_offline_docs');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => docs.path);
    settings = Settings(baseUrl: 'http://test.local:9080');
    session = Session(
        login: 'off${DateTime.now().microsecondsSinceEpoch}${_seq++}',
        name: 'Орлов',
        token: 't',
        signedIn: true,
        performerId: 'p1');
  });

  tearDown(() {
    if (docs.existsSync()) docs.deleteSync(recursive: true);
  });

  group('уборка задач, которых больше нет в списках', () {
    /// Кэши задачи во всех местах, где телефон их держит. Возвращает файлы.
    Future<List<File>> seed(LocalDb db, String id) async {
      final key = db.userKey;
      await db.fill.saveFillCache(id, '[]', '[]', '{}', '2026-10-01T10:00:00');
      await db.simple.saveSimpleInfo(id, '{}');
      final photos = await FillController.photoDirectory(key);
      photos.createSync(recursive: true);
      final shot = File(p.join(photos.path, '${id}_q1_c1.jpg'))
        ..writeAsBytesSync(List.filled(1000, 1));
      await db.fill.saveFillPhoto(id, 'q1', 0, shot.path, '2026-10-01T10:00:00',
          clientId: 'c1');
      await db.fill.markFillPhotoUploaded(id, 'q1', 0, serverIdx: 1);
      await db.comments.replaceComments(id, [
        TaskComment(id: 'm-$id', files: [TaskFileRef(id: 'F-$id', image: true)])
      ]);
      final attachments = await TaskFileCache.directory(key);
      attachments.createSync(recursive: true);
      final attached = File(p.join(attachments.path, 'f_F-${id}_t.jpg'))
        ..writeAsBytesSync(List.filled(1000, 2));
      await db.cache.savePastFillCache(
          'result', id, '[]', '[]', '{}', '2026-10-01T10:00:00');
      final past = await PastFillController.photoDirectory(key);
      past.createSync(recursive: true);
      final result = File(p.join(
          past.path, '${PastFillController.photoPrefix('result', id)}r_1_t.jpg'))
        ..writeAsBytesSync(List.filled(1000, 3));
      return [shot, attached, result];
    }

    int bytesOf(List<File> files) =>
        files.where((f) => f.existsSync()).fold(0, (s, f) => s + f.lengthSync());

    test('закрытая давно уходит целиком, открытая, архивная и неотправленная — нет',
        () async {
      final db = await LocalDb.open('sweep_${session.login}');
      addTearDown(db.close);
      // в рабочем списке и в «Выполненных» (архив — окно 30 дней после закрытия)
      await db.tasks.replaceTasks([const Task(id: 'T-OPEN', name: 'Открытая')],
          closed: [
            const Task(
                id: 'T-RECENT',
                name: 'Закрыта вчера',
                closedAt: '2026-11-16T10:00:00')
          ]);
      final open = await seed(db, 'T-OPEN');
      final recent = await seed(db, 'T-RECENT');
      final old = await seed(db, 'T-OLD'); // ни в одном списке
      final queued = await seed(db, 'T-QUEUED'); // тоже, но с неотправленным
      await db.fill.enqueueField('T-QUEUED', 'q2',
          type: 'text', text: 'а', createdAtIso: '2026-10-01T10:00:00');
      // снимок с сервера, скачанный прежней версией, — в постоянном каталоге
      final legacy = File(p.join(
          (await FillController.photoDirectory(db.userKey)).path, 'srv_x_q1_1.jpg'))
        ..writeAsBytesSync(List.filled(1000, 4));

      final before = bytesOf([...open, ...recent, ...old, ...queued, legacy]);
      await sweepGoneTasks(db);
      final after = bytesOf([...open, ...recent, ...old, ...queued, legacy]);

      expect(old.any((f) => f.existsSync()), isFalse,
          reason: 'снимок, вложение ленты и результат давно закрытой — с диска');
      expect(legacy.existsSync(), isFalse);
      expect(before - after, 4000, reason: 'место освободили ровно эти файлы');
      expect(await db.fill.getFillCache('T-OLD'), isNull);
      expect(await db.simple.getSimpleCache('T-OLD'), isNull);
      expect(await db.fill.getFillPhotos('T-OLD'), isEmpty);
      expect(await db.comments.getComments('T-OLD'), isEmpty);
      expect(await db.cache.getPastFillCache('result', 'T-OLD'), isNull);

      for (final (id, files) in [
        ('T-OPEN', open),
        ('T-RECENT', recent),
        ('T-QUEUED', queued),
      ]) {
        expect(files.every((f) => f.existsSync()), isTrue, reason: id);
        expect(await db.fill.getFillCache(id), isNotNull, reason: id);
        expect(await db.comments.getComments(id), isNotEmpty, reason: id);
      }
      expect(await db.fill.getFieldOutbox('T-QUEUED'), hasLength(1),
          reason: 'неотправленное не трогается');
    });

    test('уборка идёт после обновления списка с сервера и не раньше', () async {
      var serverUp = false;
      final api = ApiClient(settings, session, client: MockClient((r) async {
        if (!serverUp) throw const SocketException('нет сети');
        final a = actionOf(r);
        if (a == 'apiTasks') {
          return okJson(r.url.queryParameters['archive'] != null
              ? '[]'
              : jsonEncode([
                  {'id': 'T-OPEN', 'name': 'Открытая', 'statusId': 'new'}
                ]));
        }
        return okJson('[]');
      }));
      final app = AppControllers(api: api, settings: settings, session: session);
      addTearDown(app.dispose);
      await app.account.updateSettings(settings);
      final db = app.repo.db;
      final gone = await seed(db, 'T-GONE');

      await app.repo.refresh(); // связи нет — список не обновлён, судить не по чему
      expect(gone.every((f) => f.existsSync()), isTrue);
      expect(await db.fill.getFillCache('T-GONE'), isNotNull);

      serverUp = true;
      await app.repo.refresh();
      expect(gone.any((f) => f.existsSync()), isFalse);
      expect(await db.fill.getFillCache('T-GONE'), isNull);
    });
  });

  test('вопрос перед выходом и бейдж считают одно и то же', () async {
    final api = ApiClient(settings, session,
        client: MockClient((_) async => throw const SocketException('нет сети')));
    final app = AppControllers(api: api, settings: settings, session: session);
    addTearDown(app.dispose);
    await app.account.updateSettings(settings);
    final db = app.repo.db;
    const now = '2026-11-17T10:00:00';
    await db.tasks.enqueue('ST1', 's2', 'Выполнена', now);
    await db.fill.enqueueField('ST1', 'temp',
        type: 'number', number: 4, createdAtIso: now);
    await db.fill.enqueueCell('ST1', 'table', 'row-1', 'qty',
        number: 7, createdAtIso: now);
    await db.fill.setResolutionOutbox('ST1', 'ok', now);
    await app.repo.reloadLocal();

    // смена статуса и заполненный бланк — две операции, а не четыре строки очередей
    expect(app.repo.pendingCount, 2);
    expect(await app.account.unsentChanges(), 2);
  });

  group('точка момента действия', () {
    test('ждёт несколько секунд и не спрашивает разрешения', () async {
      final denied = _Phone(GeoPermission.denied);
      expect(await Geo(platform: denied).locate(stamp: true),
          isA<GeoUnavailable>());
      expect(denied.asked, 0, reason: 'разрешение просит гео-гейт, не «Завершить»');

      final allowed = _Phone(GeoPermission.granted);
      await Geo(platform: allowed).locate(stamp: true);
      expect(allowed.timeouts, [Geo.stampTimeout]);
      expect(Geo.stampTimeout, lessThan(Geo.fixTimeout));

      // гейт спрашивает и ждёт, как прежде
      final gate = _Phone(GeoPermission.denied);
      await Geo(platform: gate).locate();
      expect(gate.asked, 1);
    });

    test('«Завершить» бланка без разрешения закрывается без системного диалога',
        () async {
      final phone = _Phone(GeoPermission.denied);
      final db = await LocalDb.open('stamp_${session.login}');
      addTearDown(db.close);
      final c = FillController(
        db: db,
        api: ApiClient(settings, session,
            client: MockClient((_) async => http.Response('', 200))),
        taskId: 'ST2',
        geo: Geo(platform: phone),
      );
      addTearDown(c.dispose);
      expect(await c.finish(), isTrue);
      expect(phone.asked, 0);
    });
  });

  group('подключение к серверу', () {
    Future<void> open(WidgetTester t, String baseUrl) async {
      final s = Settings(baseUrl: baseUrl);
      final app = AppControllers(
          api: ApiClient(s, Session()), settings: s, session: Session());
      addTearDown(app.dispose);
      await t.pumpWidget(MultiProvider(
          providers: app.providers,
          child: const MaterialApp(home: SettingsScreen(firstRun: true))));
      await t.pump();
    }

    bool httpsSelected(WidgetTester t) =>
        t.widget<SegmentedButton<bool>>(find.byType(SegmentedButton<bool>))
            .selected
            .single;

    testWidgets('новая установка — https, без предупреждения', (t) async {
      await open(t, '');
      expect(httpsSelected(t), isTrue);
      expect(find.textContaining('Соединение не шифруется'), findsNothing);

      // http остаётся доступным, но не молча
      await t.tap(find.text('http'));
      await t.pump();
      expect(httpsSelected(t), isFalse);
      expect(find.textContaining('Соединение не шифруется'), findsOneWidget);
    });

    testWidgets('сохранённый адрес остаётся на своём протоколе', (t) async {
      await open(t, 'http://192.168.42.28:8888');
      expect(httpsSelected(t), isFalse);
      expect(find.textContaining('Соединение не шифруется'), findsOneWidget);
    });
  });
}
