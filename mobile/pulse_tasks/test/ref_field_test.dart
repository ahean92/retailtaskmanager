// #36841 — поле-ссылка на справочник хоста: кандидаты кэшируются вместе с бланком,
// выбор уезжает ссылкой и текстом-снимком, офлайн работают и поиск, и очередь,
// свободный ввод — снимок без ссылки.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/fill_controller.dart';
import 'package:pulse_tasks/data/local_db.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'support/app_host.dart';
import 'support/fake_server.dart';
import 'support/test_env.dart';

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
                  // канал сотрудников остатков не считает — ключа available
                  // в настоящем ответе нет
                  {'subjectId': e.id, 'name': e.name}
            ]));
          case 'apiExecutionInfo':
            return okJson(jsonEncode([
              {'object': 'Магазин №1', 'template': 'Акт', 'total': 1}
            ]));
          case 'apiExecutionBundle':
            return okJson(bundleJson(
              info: {'object': 'Магазин №1', 'template': 'Акт', 'total': 1},
              fields: [
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
              ],
              // первый эшелон канала — как прежде отдавала apiRowSubjects
              // пустым запросом при загрузке
              subjects: [
                for (final e in employees)
                  // бандл кандидатов доступность не считает (#37637)
                  {'fieldCode': 'ack', 'subjectId': e.id, 'name': e.name}
              ],
            ));
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

int _seq = 0;

/// Настоящая база бланка (sqlite через ffi): своя на каждый тест.
Future<LocalDb> _db() async {
  final db = await LocalDb.open('ref_field_${_seq++}');
  addTearDown(db.close);
  return db;
}

FillController _controller(_FakeServer server, LocalDb db) {
  final settings = Settings(baseUrl: 'http://test.local:9080');
  final session = Session(
      login: 'ivanov', name: 'Иванов И.И.', token: 'token', signedIn: true);
  final c = FillController(
    db: db,
    api: ApiClient(settings, session, client: server.client),
    taskId: '42',
  );
  // отправка последнего жеста идёт фоном и доживает до конца теста: дождаться её
  // до закрытия базы (syncAll присоединяется к идущему проходу)
  addTearDown(c.syncAll);
  return c;
}

void main() {
  initTestEnv();

  setUp(resetMockStores);

  test('кандидаты канала приезжают при загрузке и ложатся в кэш бланка',
      () async {
    final server = _FakeServer();
    final db = await _db();
    final c = _controller(server, db);
    await c.load();

    final f = c.fields.single;
    expect(f.refKind, 'employee');
    expect(f.allowFreeSubject, isTrue);
    expect(c.subjectsByField['ack']!.map((x) => x.id), ['u1', 'u2']);
    // кэш держит кандидатов рядом с бланком — офлайн-выбор собирается из него
    expect((await db.fill.getFillCache('42'))!['subjectsJson'], contains('Петров'));
  });

  test('выбор уезжает ссылкой и снимком; сервер отдаёт их обратно', () async {
    final server = _FakeServer();
    final db = await _db();
    final c = _controller(server, db);
    await c.load();

    await c.setRef(c.fields.single, id: 'u1', name: 'Петров Пётр');
    await eventually(() => c.pendingCount == 0, reason: 'выбор уехал');

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
    final db = await _db();
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
    await eventually(() => c.pendingCount == 1, reason: 'выбор лёг в очередь');
    expect((await db.fill.getFieldOutbox('42')).single['refId'], 'u2');
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
    final db = await _db();
    final c = _controller(server, db);
    await c.load();
    final f = c.fields.single;

    await c.setRef(f, name: 'Стажёр Смирнова');
    await eventually(() => server.refName != null, reason: 'снимок уехал');
    expect(server.refId, isNull);
    expect(server.refName, 'Стажёр Смирнова');

    await c.setRef(f);
    await eventually(() => server.refName == null, reason: 'очистка уехала');
    expect(server.refId, isNull);
    expect(server.refName, isNull);
    expect(f.answered, isFalse, reason: 'очищенное поле снова не отвечено');
  });
}
