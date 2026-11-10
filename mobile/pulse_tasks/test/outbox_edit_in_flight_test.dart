import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:pulse_tasks/app_controllers.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/fill_controller.dart';
import 'package:pulse_tasks/data/local_db.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/data/simple_controller.dart';
import 'package:pulse_tasks/models/task.dart';
import 'package:pulse_tasks/models/task_status.dart';
import 'support/fake_server.dart';
import 'support/test_env.dart';

/// Правка, сделанная, пока прежнее значение той же строки едет на сервер.
///
/// Строка очереди одна на ключ и заменяется новой правкой, а проход отправляет
/// снимок, прочитанный до отправки. Снимать после ответа надо ту редакцию, что
/// уехала, — по её createdAt, — а не любую строку с этим ключом: иначе новая
/// правка снималась неотправленной. На экране новое, на сервере старое, очередь
/// пуста, и «Завершить» проходит по ней. Строка таблицы и кадр, удалённые, пока их
/// создание в полёте, — тот же случай с другой стороны: «ещё не уехало, просто
/// убрать» оказывалось неправдой, и они оставались на сервере.
///
/// Сервер здесь придерживает ответ на первый запрос нужной ручки, а вторая правка
/// делается, пока он держит.

final int _runId = DateTime.now().microsecondsSinceEpoch;
int _seq = 0;

Future<LocalDb> _openDb() async => LocalDb.open('t10x1_${_runId}_${_seq++}');

final _png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');

/// Ответ, придержанный сервером: [arrived] — запрос дошёл, [release] — отпустить.
class _Hold {
  final arrived = Completer<void>();
  final _gate = Completer<void>();
  void release() => _gate.complete();
}

/// Сервер, который помнит записанное: по нему видно и что дошло, и что откроется.
class _Server {
  /// Пишущие вызовы по порядку: ручка и тело.
  final writes = <(String, Map<String, dynamic>)>[];
  final _holds = <String, _Hold>{};

  /// Связи нет: запись не доходит, очередь остаётся.
  bool down = false;

  final texts = <String, String?>{};
  String? resolution;
  final cells = <String, num?>{};
  final rows = <String>{};
  final photos = <int>[];
  String? simpleComment;
  final statuses = <String, String>{};

  late final Session session;
  late final ApiClient api;

  _Server(Settings settings) {
    session = Session(
      login: 'kozlov$_runId${_seq++}', // логин уникален: имя базы содержит его
      name: 'Козлов К.К.',
      token: 'token',
      signedIn: true,
      performerId: 'p1',
    );
    api = ApiClient(settings, session, client: MockClient(_handle));
  }

  /// Придержать ответ на ближайший запрос [action].
  _Hold hold(String action) => _holds[action] = _Hold();

  List<Map<String, dynamic>> of(String action) =>
      [for (final (a, b) in writes) if (a == action) b];

  Future<http.Response> _handle(http.Request request) async {
    final action = actionOf(request);
    final h = _holds.remove(action);
    if (h != null) {
      h.arrived.complete();
      await h._gate.future;
    }
    if (request.method == 'POST' && action != 'apiStartExecution') {
      if (down) throw const SocketException('нет сети');
      final b = request.body.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(request.body) as Map<String, dynamic>;
      writes.add((action, b));
      switch (action) {
        case 'apiSetField':
          texts[b['field'] as String] = b['text'] as String?;
        case 'apiSetResolution':
          resolution = b['resolution'] as String?;
        case 'apiSetCell':
          cells['${b['rowKey']}/${b['col']}'] = b['number'] as num?;
        case 'apiAddRow':
          rows.add(b['rowKey'] as String);
        case 'apiDeleteRow':
          rows.remove(b['rowKey'] as String);
        case 'apiSetFieldPhoto':
          // сервер нумерует новый снимок «максимум + 1», индексы не уплотняет
          photos.add(photos.fold(0, (m, i) => i > m ? i : m) + 1);
        case 'apiDeleteFieldPhoto':
          photos.remove(b['index'] as int);
        case 'apiSetSimpleComment':
          simpleComment = b['comment'] as String?;
        case 'apiSetStatus':
          statuses[b['id'] as String] = b['statusId'] as String;
      }
      return okJson('[]');
    }
    switch (action) {
      case 'apiExecutionBundle':
        return okJson(bundleJson(
          info: {'object': 'Магазин №1', 'template': 'Чек-лист', 'date': '2026-11-10T10:00:00'},
          fields: [
            {
              'sectionIndex': 1,
              'section': 'Зал',
              'fieldIndex': 1,
              'code': 'f1',
              'name': 'Витрина',
              'type': 'text',
              if (texts['f1'] != null) 'text': texts['f1'],
              if (photos.isNotEmpty) 'photoCount': photos.length,
              if (photos.isNotEmpty) 'photoIndexes': photos.join(','),
            },
            {
              'sectionIndex': 1,
              'section': 'Зал',
              'fieldIndex': 2,
              'code': 'tab',
              'name': 'Остатки',
              'type': 'table',
              'allowManual': true,
            },
          ],
          columns: [
            {'fieldCode': 'tab', 'colCode': 'fact', 'name': 'Факт', 'type': 'number'},
          ],
          rows: [
            for (final key in {'k1', ...rows})
              {
                'fieldCode': 'tab',
                'rowIndex': 1,
                'rowKey': key,
                'colCode': 'fact',
                if (cells['$key/fact'] != null) 'number': cells['$key/fact'],
              }
          ],
        ));
      case 'apiTasks':
        return okJson(jsonEncode([
          {'id': 'T1', 'name': 'Проверка', 'statusId': statuses['T1'] ?? 'new'}
        ]));
      case 'apiStatuses':
        return okJson(jsonEncode(_statuses));
      case 'apiSimpleInfo':
        return okJson('{}');
      default:
        return okJson('[]');
    }
  }
}

const _statuses = [
  {'id': 'new', 'name': 'Новая', 'sortingOrder': 1},
  {'id': 'in_progress', 'name': 'В работе', 'sortingOrder': 2},
  {'id': 'paused', 'name': 'Приостановлена', 'sortingOrder': 3},
];

void main() {
  initTestEnv();

  late Settings settings;
  late _Server server;
  late Directory docs;
  late Directory tmp;

  setUp(() {
    resetMockStores();
    settings = Settings(baseUrl: 'http://test.local:9080');
    server = _Server(settings);
    docs = Directory.systemTemp.createTempSync('t10x1_docs');
    tmp = Directory.systemTemp.createTempSync('t10x1_shots');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => docs.path);
  });

  tearDown(() {
    if (docs.existsSync()) docs.deleteSync(recursive: true);
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<LocalDb> openDb() async {
    final db = await _openDb();
    addTearDown(() async => db.close());
    return db;
  }

  Future<FillController> openForm(LocalDb db) async {
    final c = FillController(db: db, api: server.api, taskId: 'ST1');
    addTearDown(c.dispose);
    await c.load();
    return c;
  }

  group('бланк', () {
    test('поле: вторая правка во время отправки доходит', () async {
      final db = await openDb();
      final c = await openForm(db);
      final f = c.fields.firstWhere((x) => x.code == 'f1');

      final h = server.hold('apiSetField');
      await c.setText(f, 'старое');
      await h.arrived.future;
      await c.setText(f, 'новое');
      h.release();
      await c.syncAll();

      expect([for (final b in server.of('apiSetField')) b['text']],
          ['старое', 'новое']);
      expect(await db.fill.getFieldOutbox('ST1'), isEmpty);

      final again = await openForm(db);
      expect(again.fields.firstWhere((x) => x.code == 'f1').text, 'новое');
    });

    test('поле: правка после ответа уходит, как раньше', () async {
      final db = await openDb();
      final c = await openForm(db);
      final f = c.fields.firstWhere((x) => x.code == 'f1');

      await c.setText(f, 'старое');
      await c.syncAll();
      await c.setText(f, 'новое');
      await c.syncAll();

      expect([for (final b in server.of('apiSetField')) b['text']],
          ['старое', 'новое']);
      expect(await db.fill.getFieldOutbox('ST1'), isEmpty);
    });

    test('итог: вторая правка во время отправки доходит', () async {
      final db = await openDb();
      final c = await openForm(db);

      final h = server.hold('apiSetResolution');
      await c.setResolution('fixed');
      await h.arrived.future;
      await c.setResolution('escalated');
      h.release();
      await c.syncAll();

      expect([for (final b in server.of('apiSetResolution')) b['resolution']],
          ['fixed', 'escalated']);
      expect(server.resolution, 'escalated');
      expect(await db.fill.getResolutionOutbox('ST1'), isNull);
    });

    test('ячейка: вторая правка во время отправки доходит', () async {
      final db = await openDb();
      final c = await openForm(db);
      final f = c.fields.firstWhere((x) => x.code == 'tab');
      final row = f.rows.firstWhere((r) => r.rowKey == 'k1');
      final col = f.columns.single;

      final h = server.hold('apiSetCell');
      await c.setCellNumber(f, row, col, 5);
      await h.arrived.future;
      await c.setCellNumber(f, row, col, 7);
      h.release();
      await c.syncAll();

      expect([for (final b in server.of('apiSetCell')) b['number']], [5, 7]);
      expect(await db.fill.getCellOutbox('ST1'), isEmpty);

      final again = await openForm(db);
      final r = again.fields
          .firstWhere((x) => x.code == 'tab')
          .rows
          .firstWhere((r) => r.rowKey == 'k1');
      expect(r.numbers['fact'], 7);
    });

    test('строка, удалённая во время своего создания, удаляется на сервере',
        () async {
      final db = await openDb();
      final c = await openForm(db);
      final f = c.fields.firstWhere((x) => x.code == 'tab');

      final h = server.hold('apiAddRow');
      final row = await c.addRow(f);
      await h.arrived.future;
      await c.deleteRow(f, row);
      h.release();
      await c.syncAll();

      expect([for (final (a, _) in server.writes) a],
          ['apiAddRow', 'apiDeleteRow']);
      expect(server.rows, isEmpty);
      expect(await db.fill.getRowOutbox('ST1'), isEmpty);
    });

    test('строка, удалённая до отправки, на сервер не едет — как раньше',
        () async {
      final db = await openDb();
      final c = await openForm(db);
      final f = c.fields.firstWhere((x) => x.code == 'tab');

      // без связи создание остаётся в очереди, удаление его просто снимает
      server.down = true;
      final row = await c.addRow(f, subjectName: 'Молоко');
      await c.syncAll();
      await c.deleteRow(f, row);
      server.down = false;
      await c.syncAll();

      expect(server.of('apiAddRow'), isEmpty);
      expect(server.of('apiDeleteRow'), isEmpty);
      expect(await db.fill.getRowOutbox('ST1'), isEmpty);
    });

    test('кадр, удалённый во время своей отправки, удаляется на сервере',
        () async {
      final db = await openDb();
      final c = await openForm(db);
      final f = c.fields.firstWhere((x) => x.code == 'f1');
      final src = File(p.join(tmp.path, 'shot.jpg'))..writeAsBytesSync(_png);

      final h = server.hold('apiSetFieldPhoto');
      await c.addPhoto(f, src.path);
      await h.arrived.future;
      final shot = c.fields.firstWhere((x) => x.code == 'f1').shots.single;
      await c.deleteShot(c.fields.firstWhere((x) => x.code == 'f1'), shot);
      h.release();
      await c.syncAll();

      expect([for (final (a, _) in server.writes) a],
          ['apiSetFieldPhoto', 'apiDeleteFieldPhoto']);
      expect(server.of('apiDeleteFieldPhoto').single['index'], 1);
      expect(server.photos, isEmpty);
      expect(await db.fill.getPhotoDeletes('ST1'), isEmpty);
      expect(await db.fill.getFillPhotos('ST1'), isEmpty);
    });
  });

  test('поручение: второй комментарий во время отправки доходит', () async {
    final db = await openDb();
    final c = SimpleExecutionController(db: db, api: server.api, taskId: 'ST2');
    addTearDown(c.dispose);

    final h = server.hold('apiSetSimpleComment');
    await c.setComment('убрал витрину');
    await h.arrived.future;
    await c.setComment('убрал витрину и склад');
    h.release();
    await c.syncAll(refreshInfo: false);

    expect([for (final b in server.of('apiSetSimpleComment')) b['comment']],
        ['убрал витрину', 'убрал витрину и склад']);
    expect(await db.simple.getSimpleComment('ST2'), isNull);
  });

  test('статус: смена во время отправки доходит следующим проходом', () async {
    final app = AppControllers(
        api: server.api, settings: settings, session: server.session);
    await app.account.updateSettings(settings); // открывает базу этого логина
    final db = app.repo.db;
    await db.tasks
        .replaceStatuses([for (final s in _statuses) TaskStatus.fromJson(s)]);
    await db.tasks.insertLocalTask(
        const Task(id: 'T1', name: 'Проверка', statusId: 'new'));
    await app.repo.reloadLocal();
    TaskStatus st(String id) =>
        TaskStatus.fromJson(_statuses.firstWhere((s) => s['id'] == id));

    final h = server.hold('apiSetStatus');
    await app.repo.setStatus('T1', st('in_progress'));
    await h.arrived.future;
    await app.repo.setStatus('T1', st('paused'));
    h.release();
    for (var i = 0; i < 100 && app.repo.syncing; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect((await db.tasks.getOutbox())['T1']?.statusId, 'paused',
        reason: 'вторая смена осталась в очереди — её не сняли вместе с первой');

    await app.repo.syncOutbox(); // следующий проход
    expect([for (final b in server.of('apiSetStatus')) b['statusId']],
        ['in_progress', 'paused']);
    expect(server.statuses['T1'], 'paused');
    expect(await db.tasks.getOutbox(), isEmpty);
  });
}
