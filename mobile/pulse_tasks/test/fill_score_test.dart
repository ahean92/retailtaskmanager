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
import 'package:pulse_tasks/models/fill.dart';
import 'support/fake_server.dart';
import 'support/fake_fill_db.dart';

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
        final action = actionOf(request);
        if (offline) throw const SocketException('нет связи');
        calls.add(action);
        switch (action) {
          case 'apiSetField':
            final b = jsonDecode(request.body) as Map<String, dynamic>;
            answers[b['field'] as String] = b['optCode'] as String;
            return okJson('[]');
          case 'apiFinishExecution':
            finished = true;
            return okJson('[]');
          case 'apiExecutionInfo':
            final yes = answers.values.where((v) => v == 'yes').length;
            return okJson(jsonEncode([
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
            return okJson(jsonEncode([
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
            return okJson(jsonEncode([
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
            return okJson('[]');
        }
      });

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

  test('ответ при связи двигает балл, не выходя с бланка', () async {
    final server = _FakeServer();
    final db = FakeFillDb();
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
    final db = FakeFillDb();
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
    final c = _controller(server, FakeFillDb());
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
    final c = _controller(server, FakeFillDb());
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
    final c = _controller(_FakeServer(), FakeFillDb());
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
    final db = FakeFillDb();
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
