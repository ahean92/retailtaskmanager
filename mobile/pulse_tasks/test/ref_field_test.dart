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
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'support/fake_server.dart';
import 'support/fake_fill_db.dart';

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
        final action = actionOf(request);
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
            return okJson('[]');
          case 'apiRowSubjects':
            final q = request.url.queryParameters['query'] ?? '';
            subjectQueries.add(q);
            return okJson(jsonEncode([
              for (final e in employees)
                if (q.isEmpty ||
                    e.name.toLowerCase().contains(q.toLowerCase()))
                  {'subjectId': e.id, 'name': e.name, 'available': true}
            ]));
          case 'apiExecutionFields':
            return okJson(jsonEncode([
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
            return okJson(jsonEncode([
              {'object': 'Магазин №1', 'template': 'Акт', 'total': 1}
            ]));
          default:
            return okJson('[]');
        }
      });

  static String? _nameOf(String? id) {
    for (final e in employees) {
      if (e.id == id) return e.name;
    }
    return null;
  }

}

FillController _controller(_FakeServer server, FakeFillDb db) {
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
    final db = FakeFillDb();
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
    final db = FakeFillDb();
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
    final db = FakeFillDb();
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
    final db = FakeFillDb();
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
