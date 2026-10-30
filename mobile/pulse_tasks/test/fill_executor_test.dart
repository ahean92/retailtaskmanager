import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/fill_controller.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/models/fill.dart';
import 'support/fake_server.dart';
import 'support/fake_fill_db.dart';

/// Бланк пишет его исполнитель (#37349). Серверная половина (гварды ручек и 409
/// filledBy с именем и временем) живёт в lsFusion; телефонная — эта: экран узнаёт
/// по executorId, что бланк держит коллега, и открывает его просмотром с подписью
/// «Заполняет Иванова с 10:42», а отказ 409 по офлайн-ответу остаётся строкой
/// «Не отправлено» с той же причиной — не молча и не джемя очередь.

/// Сервер-заглушка: шапка с исполнителем, одно текстовое поле и режим «заполнение
/// передали другому» — apiSetField отвечает 409 filledBy тем же телом, что и
/// настоящий (компактный JSON с message).
class _FakeServer {
  String executorId;
  bool fillTakenOver = false;

  _FakeServer({this.executorId = 'p1'});

  Map<String, dynamic> get infoBody => {
        'object': 'Санта №18',
        'template': 'Чек-лист приёмки',
        'executor': 'Иванова И.И.',
        'executorId': executorId,
        'date': '2026-10-30T10:42:00',
        'finished': false,
      };

  http.Client get client => MockClient((request) async {
        final action = actionOf(request);
        switch (action) {
          case 'apiSetField':
            if (fillTakenOver) {
              return http.Response.bytes(
                  utf8.encode(jsonEncode({
                    'error': 'filledBy',
                    'filledById': 'p9',
                    'filledBy': 'Сидорова С.С.',
                    'filledAt': '2026-10-30T11:05:00',
                    'message':
                        'Бланк заполняет Сидорова С.С., начало 30.10.2026 11:05',
                  })),
                  409,
                  headers: {'content-type': 'application/json; charset=utf-8'});
            }
            return okJson('[]');
          case 'apiStartExecution':
            return okJson('[]');
          case 'apiExecutionInfo':
            return okJson(jsonEncode([infoBody]));
          case 'apiExecutionBundle':
            return okJson(bundleJson(info: infoBody, fields: const [
              {
                'sectionIndex': 1,
                'section': 'Зал',
                'fieldIndex': 1,
                'code': 'note',
                'name': 'Заметка',
                'type': 'text',
              }
            ]));
          default:
            return okJson('[]');
        }
      });
}

FillController _controller(_FakeServer server, FakeFillDb db,
        {String performerId = 'p1'}) =>
    FillController(
      db: db,
      api: ApiClient(
        Settings(baseUrl: 'http://test.local:9080'),
        Session(
          login: 'ivanov',
          name: 'Иванов И.И.',
          token: 'token',
          signedIn: true,
          performerId: performerId,
        ),
        client: server.client,
      ),
      taskId: '42',
      performerId: performerId,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('бланк коллеги открывается только для чтения', () async {
    final c = _controller(_FakeServer(executorId: 'p2'), FakeFillDb());
    await c.load();

    expect(c.fields, isNotEmpty, reason: 'бланк загружен — есть что смотреть');
    expect(c.filledByOther, isTrue);
    expect(c.viewOnly, isTrue);
    // не путать с завершённостью: бланк жив, писать в него просто нельзя
    expect(c.confirmedFinished, isFalse);
  });

  test('свой бланк и сервер без executorId read-only не включают', () async {
    final mine = _controller(_FakeServer(executorId: 'p1'), FakeFillDb());
    await mine.load();
    expect(mine.filledByOther, isFalse);
    expect(mine.viewOnly, isFalse);

    // старый сервер поля не шлёт: пустой id не запирает бланк
    final server = _FakeServer();
    final old = _controller(server, FakeFillDb());
    await old.load();
    expect(old.filledByOther, isFalse);
  });

  test('подпись «Заполняет … с …»: время сегодня, дата в другой день', () {
    final now = DateTime.now();
    String iso(DateTime d) => d.toIso8601String();

    final today = FillSummary.filledByLine('Иванова И.И.', iso(now));
    expect(today, startsWith('Иванова И.И. с '));
    expect(today, matches(RegExp(r'^Иванова И\.И\. с \d{2}:\d{2}$')),
        reason: 'начало сегодня — одного времени достаточно');

    final otherDay =
        FillSummary.filledByLine('Иванова И.И.', iso(now.subtract(const Duration(days: 2))));
    expect(otherDay, matches(RegExp(r' с \d{2}\.\d{2} \d{2}:\d{2}$')),
        reason: 'начало не сегодня — с датой, иначе «с 10:42» висло бы неделями');

    expect(FillSummary.filledByLine(null, iso(now)), startsWith('другой сотрудник с '),
        reason: 'имени нет (старые данные) — кто-то же держит бланк');
    expect(FillSummary.filledByLine('Петров П.П.', null), 'Петров П.П.',
        reason: 'без времени остаётся имя: рисовать дату из ничего нельзя');
  });

  test('409 filledBy: ответ остаётся в «Не отправлено» с причиной, очередь не встаёт',
      () async {
    final server = _FakeServer(); // бланк ещё мой
    final db = FakeFillDb();
    final c = _controller(server, db);
    await c.load();

    // заполнение передали коллеге, пока этот телефон был офлайн с ответом
    server.fillTakenOver = true;
    await c.setText(c.fields.first, 'витрина чистая');
    await pumpEventQueue();

    expect(c.online, isTrue, reason: 'сервер ОТВЕТИЛ — сети это не касается');
    expect(db.fieldOutbox, contains('note'),
        reason: 'отказ обычной строки её не снимает');
    expect(c.lastSyncError, contains('Бланк заполняет Сидорова'),
        reason: 'причина — имя держащего, а не безликое «не удалось»');
    final errors = await db.queues.getSyncErrors();
    expect(errors['fill:42']?.message, contains('Бланк заполняет Сидорова'),
        reason: 'экран «Не отправлено» читает причину из sync_errors');
  });
}
