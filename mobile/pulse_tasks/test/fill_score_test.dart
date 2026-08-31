import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/fill_controller.dart';
import 'package:pulse_tasks/data/local_db.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/models/fill.dart';

/// Балл считает только сервер, и приезжает он ответом apiExecutionInfo. Значит вопрос
/// не в том, как его посчитать, а в том, когда его спросить: пока спрашивали ровно раз
/// при открытии экрана, число на бланке отставало ровно на одно открытие.

/// Сервер-заглушка: хранит ответы, считает по ним процент и запоминает порядок вызовов —
/// «сначала отправили, потом спросили» здесь такая же часть правильного поведения, как и
/// само число.
class _FakeServer {
  final answers = <String, String>{};
  bool finished = false;

  /// Связи нет: запрос не доходит вовсе — так же, как в подсобке без сигнала.
  bool offline = false;
  final calls = <String>[];

  /// По 50% за каждый ответ «да» — правило неважно, важно, что оно живёт на сервере.
  double get percent => 50.0 * answers.values.where((v) => v == 'yes').length;

  http.Client get client => MockClient((request) async {
        final action = request.url.path.split('.').last;
        if (offline) throw const SocketException('нет связи');
        calls.add(action);
        switch (action) {
          case 'apiSetField':
            final b = jsonDecode(request.body) as Map<String, dynamic>;
            answers[b['field'] as String] = b['optCode'] as String;
            return _ok('[]');
          case 'apiFinishExecution':
            finished = true;
            return _ok('[]');
          case 'apiExecutionInfo':
            final yes = answers.values.where((v) => v == 'yes').length;
            return _ok(jsonEncode([
              {
                'object': 'Санта №18',
                'template': 'Чек-лист приёмки',
                'hasScored': true,
                'percent': percent,
                'passed': percent >= 100,
                'verdict': finished ? (percent >= 100 ? 'Зачёт' : 'Незачёт') : null,
                'answered': answers.length,
                'total': 2,
                'finished': finished,
                // подытоги по разделам (#36945): как на сервере — раздел без
                // отвеченных оцениваемых полей в выдачу не попадает вовсе
                if (answers.isNotEmpty)
                  'sections': [
                    {
                      'index': 1,
                      'name': 'Зал',
                      'score': yes,
                      'max': answers.length,
                      'percent': 100.0 * yes / answers.length,
                    }
                  ],
              }
            ]));
          case 'apiExecutionFields':
            return _ok(jsonEncode([
              for (final code in const ['q1', 'q2'])
                {
                  'sectionIndex': 1,
                  'section': 'Зал',
                  'fieldIndex': code == 'q1' ? 1 : 2,
                  'code': code,
                  'name': 'Вопрос $code',
                  'type': 'scale',
                  'optionCode': answers[code],
                }
            ]));
          case 'apiExecutionOptions':
            return _ok(jsonEncode([
              for (final code in const ['q1', 'q2']) ...[
                {'fieldCode': code, 'code': 'yes', 'name': 'Да', 'score': 1},
                {
                  'fieldCode': code,
                  'code': 'no',
                  'name': 'Нет',
                  'score': 0,
                  'nonconformity': true
                },
              ]
            ]));
          default:
            return _ok('[]');
        }
      });

  static http.Response _ok(String body) => http.Response.bytes(
      utf8.encode(body), 200,
      headers: {'content-type': 'application/json; charset=utf-8'});
}

/// Очередь и кэш в памяти — на настоящей sqlite это integration_test, здесь нужны только
/// сами очереди: что в них лежит перед открытием и что остаётся после отправки.
class _FakeDb implements LocalDb {
  final fieldOutbox = <String, Map<String, Object?>>{};
  Map<String, Object?>? cache;

  @override
  String get userKey => 'test';

  @override
  Future<Map<String, Object?>?> getFillCache(String taskId) async => cache;

  @override
  Future<void> saveFillCache(String taskId, String fieldsJson,
      String optionsJson, String infoJson, String fetchedAtIso,
      {String columnsJson = '[]',
      String rowsJson = '[]',
      String subjectsJson = '{}'}) async {
    cache = {
      'taskId': taskId,
      'fieldsJson': fieldsJson,
      'optionsJson': optionsJson,
      'infoJson': infoJson,
      'columnsJson': columnsJson,
      'rowsJson': rowsJson,
      'subjectsJson': subjectsJson,
      'fetchedAt': fetchedAtIso,
    };
  }

  @override
  Future<void> saveFillInfo(String taskId, String infoJson) async {
    cache?['infoJson'] = infoJson;
  }

  @override
  Future<void> enqueueField(String taskId, String fieldCode,
      {required String type,
      String? optionCode,
      double? number,
      String? text,
      bool? boolVal,
      String? dateVal,
      String? comment,
      String? refId,
      String? refName,
      required String createdAtIso}) async {
    fieldOutbox[fieldCode] = {
      'taskId': taskId,
      'fieldCode': fieldCode,
      'type': type,
      'optionCode': optionCode,
      'number': number,
      'text': text,
      'boolVal': boolVal == null ? null : (boolVal ? 1 : 0),
      'dateVal': dateVal,
      'comment': comment,
      'refId': refId,
      'refName': refName,
      'createdAt': createdAtIso,
    };
  }

  @override
  Future<List<Map<String, Object?>>> getFieldOutbox(String taskId) async =>
      fieldOutbox.values.toList();

  @override
  Future<void> dequeueField(String taskId, String fieldCode) async {
    fieldOutbox.remove(fieldCode);
  }

  @override
  Future<List<Map<String, Object?>>> getCellOutbox(String taskId) async =>
      const [];

  @override
  Future<List<Map<String, Object?>>> getRowOutbox(String taskId) async =>
      const [];

  @override
  Future<List<Map<String, Object?>>> getFillPhotos(String taskId) async =>
      const [];

  @override
  Future<List<Map<String, Object?>>> getPendingFillPhotos(
          String taskId) async =>
      const [];

  @override
  Future<List<Map<String, Object?>>> getPhotoDeletes(String taskId) async =>
      const [];

  @override
  Future<String?> getResolutionOutbox(String taskId) async => null;

  // обычная серверная задача: жизненного цикла «рождена на телефоне» (#36716) у неё нет
  @override
  Future<bool> lifecyclePending(String taskId) async => false;

  @override
  Future<Map<String, Object?>?> getCreateEntry(String taskId) async => null;

  @override
  Future<bool> hasStart(String taskId) async => false;

  @override
  Future<bool> hasFinish(String taskId) async => false;

  @override
  Future<Map<String, Object?>?> getStartEntry(String taskId) async => null;

  @override
  Future<Map<String, Object?>?> getFinishEntry(String taskId) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

FillController _controller(_FakeServer server, _FakeDb db) {
  final settings = Settings(baseUrl: 'http://test.local:9080');
  final session = Session(
      login: 'ivanov', name: 'Иванов И.И.', token: 'token', signedIn: true);
  return FillController(
    db: db,
    api: ApiClient(settings, session, client: server.client),
    taskId: '42',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('ответ при связи двигает балл, не выходя с бланка', () async {
    final server = _FakeServer();
    final db = _FakeDb();
    final c = _controller(server, db);
    await c.load();
    expect(c.summary.percent, 0);

    await c.setOption(c.fields.first, 'yes');
    await pumpEventQueue();

    // повторного load() не было — число обновилось после того, как очередь ушла
    expect(c.pendingCount, 0);
    expect(c.summary.percent, 50);
  });

  test('при открытии очередь уходит раньше, чем спрашивают балл', () async {
    final server = _FakeServer();
    final db = _FakeDb();
    // ответ, поставленный в прошлый раз и не дошедший до сервера
    await db.enqueueField('42', 'q1',
        type: 'scale', optionCode: 'yes', createdAtIso: '2026-08-13T10:00:00');

    final c = _controller(server, db);
    await c.load();

    expect(server.calls.indexOf('apiSetField'),
        lessThan(server.calls.indexOf('apiExecutionInfo')));
    // сервер успел пересчитать до того, как его спросили — второе открытие не нужно
    expect(c.summary.percent, 50);
    expect(c.fields.first.optionCode, 'yes');
  });

  test('офлайн балл не выдумывается, а догоняет, когда очередь ушла', () async {
    final server = _FakeServer();
    final c = _controller(server, _FakeDb());
    await c.load();

    server.offline = true;
    await c.setOption(c.fields.first, 'yes');
    await pumpEventQueue();

    // сервер правки не видел: показывать нечего, кроме прежнего числа — экран пометит
    // его неактуальным по этой самой очереди
    expect(c.online, isFalse);
    expect(c.pendingCount, 1);
    expect(c.summary.percent, 0);

    server.offline = false;
    await c.syncAll();

    expect(c.pendingCount, 0);
    expect(c.summary.percent, 50);
  });

  test('ответ двигает подытог своего раздела, не выходя с бланка', () async {
    final server = _FakeServer();
    final c = _controller(server, _FakeDb());
    await c.load();
    // ничего не отвечено — раздела в выдаче нет, значит нет и строки в шапке
    expect(c.sectionScore(0), isNull);

    await c.setOption(c.fields.first, 'yes');
    await pumpEventQueue();
    expect(c.sectionScore(0)?.line, '1 из 1 · 100%');

    await c.setOption(c.fields.last, 'no');
    await pumpEventQueue();
    expect(c.sectionScore(0)?.line, '1 из 2 · 50%');
  });

  test('подытог ищется по серверному index раздела, а не по номеру страницы', () {
    final c = _controller(_FakeServer(), _FakeDb());
    // индексы разделов не обязаны быть плотными: страница 1 — это раздел 5
    c.fields = assembleFillFields([
      {'sectionIndex': 2, 'section': 'Зал', 'code': 'a', 'type': 'boolean'},
      {'sectionIndex': 5, 'section': 'Склад', 'code': 'b', 'type': 'boolean'},
    ], [], [], []);
    c.summary = FillSummary.fromJson({
      'sections': [
        {'index': 5, 'name': 'Склад', 'score': 3, 'max': 4, 'percent': 75},
      ]
    });
    expect(c.sectionScore(0), isNull); // у «Зала» оценки нет — строки нет
    expect(c.sectionScore(1)?.line, '3 из 4 · 75%');
    expect(c.sectionScore(7), isNull); // за пределами страниц — не падать
  });

  test('строка подытога: хвост нулей отрезается, без процента — только «из»',
      () {
    expect(const SectionScore(index: 1, score: 12, max: 15, percent: 80).line,
        '12 из 15 · 80%');
    expect(const SectionScore(index: 1, score: 12.5, max: 15).line,
        '12.5 из 15');
    // балл NULL при живом максимуме (вариант без настроенного балла) — ноль
    expect(SectionScore.fromJson(const {'index': 2, 'max': 4}).line, '0 из 4');
  });

  test('после завершения вердикт перечитывается с сервера', () async {
    final server = _FakeServer();
    final db = _FakeDb();
    final c = _controller(server, db);
    await c.load();
    for (final f in c.fields) {
      await c.setOption(f, 'yes');
    }
    await pumpEventQueue();

    expect(await c.finish(), isTrue);
    expect(c.finished, isTrue);
    expect(c.summary.verdict, 'Зачёт');
    expect(c.summary.percent, 100);
  });
}
