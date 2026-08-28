// #36841 — поле-ссылка на справочник хоста: кандидаты кэшируются вместе с бланком,
// выбор уезжает ссылкой и текстом-снимком, офлайн работают и поиск, и очередь,
// свободный ввод — снимок без ссылки.

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

/// Сервер-заглушка: шаблон с одним полем-ссылкой канала 'employee', справочник из
/// двух сотрудников. Повторяет контракт FillApi #36841: apiRowSubjects ищет по
/// имени, apiSetField принимает refId/refName (пустые строки — очистка), снимок
/// без текста клиента добирается именем ссылки.
class _FakeServer {
  static const employees = [
    (id: 'u1', name: 'Петров Пётр'),
    (id: 'u2', name: 'Сидорова Анна'),
  ];

  String? refId;
  String? refName;
  bool offline = false;
  final calls = <String>[];
  final subjectQueries = <String>[];

  http.Client get client => MockClient((request) async {
        if (offline) throw const SocketException('нет связи');
        final action = request.url.path.split('.').last;
        calls.add(action);
        switch (action) {
          case 'apiSetField':
            final b = jsonDecode(request.body) as Map<String, dynamic>;
            final id = b['refId'] as String?;
            final name = b['refName'] as String?;
            refId = (id == null || id.isEmpty) ? null : id;
            // серверный снимок: текст клиента, иначе имя разрешённой ссылки
            refName = (name != null && name.isNotEmpty)
                ? name
                : _nameOf(refId);
            return _ok('[]');
          case 'apiRowSubjects':
            final q = request.url.queryParameters['query'] ?? '';
            subjectQueries.add(q);
            return _ok(jsonEncode([
              for (final e in employees)
                if (q.isEmpty ||
                    e.name.toLowerCase().contains(q.toLowerCase()))
                  {'subjectId': e.id, 'name': e.name, 'available': true}
            ]));
          case 'apiExecutionFields':
            return _ok(jsonEncode([
              {
                'sectionIndex': 1,
                'section': 'Итог',
                'fieldIndex': 1,
                'code': 'ack',
                'name': 'Ознакомлен',
                'type': 'objectref',
                'refKind': 'employee',
                'allowFreeSubject': true,
                if (refId != null) 'refId': refId,
                if (refName != null) 'ref': refName,
              }
            ]));
          case 'apiExecutionInfo':
            return _ok(jsonEncode([
              {'object': 'Магазин №1', 'template': 'Акт', 'total': 1}
            ]));
          default:
            return _ok('[]');
        }
      });

  static String? _nameOf(String? id) {
    for (final e in employees) {
      if (e.id == id) return e.name;
    }
    return null;
  }

  static http.Response _ok(String body) => http.Response.bytes(
      utf8.encode(body), 200,
      headers: {'content-type': 'application/json; charset=utf-8'});
}

/// Очередь и кэш в памяти (см. fill_score_test): здесь важно, что ложится в кэш
/// бланка (subjectsJson) и в очередь поля (refId/refName) и что оттуда уходит.
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

  test('кандидаты канала приезжают при загрузке и ложатся в кэш бланка',
      () async {
    final server = _FakeServer();
    final db = _FakeDb();
    final c = _controller(server, db);
    await c.load();

    final f = c.fields.single;
    expect(f.refKind, 'employee');
    expect(f.allowFreeSubject, isTrue);
    expect(c.subjectsByField['ack']!.map((x) => x.id), ['u1', 'u2']);
    // кэш держит кандидатов рядом с бланком — офлайн-выбор собирается из него
    expect(db.cache!['subjectsJson'], contains('Петров'));
  });

  test('выбор уезжает ссылкой и снимком; сервер отдаёт их обратно', () async {
    final server = _FakeServer();
    final db = _FakeDb();
    final c = _controller(server, db);
    await c.load();

    await c.setRef(c.fields.single, id: 'u1', name: 'Петров Пётр');
    await pumpEventQueue();

    expect(c.pendingCount, 0);
    expect(server.refId, 'u1');
    expect(server.refName, 'Петров Пётр');

    // повторное открытие: значение приезжает с сервера
    final again = _controller(server, db);
    await again.load();
    expect(again.fields.single.refId, 'u1');
    expect(again.fields.single.refName, 'Петров Пётр');
  });

  test('офлайн: поиск по фамилии из кэша, выбор ждёт в очереди и дожимается',
      () async {
    final server = _FakeServer();
    final db = _FakeDb();
    // первое открытие при связи наполняет кэш
    final warm = _controller(server, db);
    await warm.load();

    server.offline = true;
    final c = _controller(server, db);
    await c.load(); // из кэша
    expect(c.online, isFalse);
    final f = c.fields.single;
    expect(c.subjectsByField['ack'], isNotEmpty,
        reason: 'кандидаты пережили пропажу сети вместе с бланком');

    // поиск офлайн — фильтр по кэшу, сервер не спрошен
    final before = server.subjectQueries.length;
    final found = await c.searchSubjects(f, 'сидорова');
    expect(found.map((x) => x.id), ['u2']);
    expect(server.subjectQueries.length, before);

    await c.setRef(f, id: 'u2', name: 'Сидорова Анна');
    await pumpEventQueue();
    expect(db.fieldOutbox['ack']!['refId'], 'u2');
    expect(server.refId, isNull, reason: 'сервер правки ещё не видел');

    server.offline = false;
    await c.syncAll();
    expect(c.pendingCount, 0);
    expect(server.refId, 'u2');
    expect(server.refName, 'Сидорова Анна');
  });

  test('свободный ввод — снимок без ссылки; очистка стирает оба слота',
      () async {
    final server = _FakeServer();
    final db = _FakeDb();
    final c = _controller(server, db);
    await c.load();
    final f = c.fields.single;

    await c.setRef(f, name: 'Стажёр Смирнова');
    await pumpEventQueue();
    expect(server.refId, isNull);
    expect(server.refName, 'Стажёр Смирнова');

    await c.setRef(f);
    await pumpEventQueue();
    expect(server.refId, isNull);
    expect(server.refName, isNull);
    expect(f.answered, isFalse, reason: 'очищенное поле снова не отвечено');
  });
}
