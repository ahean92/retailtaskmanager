import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pulse_tasks/app_controllers.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/error_journal.dart';
import 'package:pulse_tasks/data/fill_controller.dart';
import 'package:pulse_tasks/data/local_db.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/data/simple_controller.dart';
import 'package:pulse_tasks/data/sync/outbox_drain.dart';
import 'package:pulse_tasks/models/task.dart';
import 'support/test_env.dart';
import 'support/fake_server.dart';

/// Политика дренажа офлайн-очередей — одна на бланк, отчёт поручения, статусы и
/// взятия, и здесь она записана сценариями, а не словами:
///
///   - обрыв связи (сокет, таймаут, TLS) — стоп всей цепочки, строка остаётся,
///     online = false; следующие шаги даже не пробуются;
///   - отказ (4xx) или сбой (5xx) сервера на барьерном шаге (создание, старт) — стоп
///     цепочки: полям несуществующего выполнения ехать некуда; online = true —
///     сервер ответил;
///   - отказ или сбой по обычной строке (поле, снимок) — строка остаётся с
///     причиной в sync_errors, а цикл идёт дальше по следующим строкам и шагам;
///     отказу человек может убрать строку («Убрать из очереди»), сбою — нет: он
///     пройдёт, когда сервер оживёт;
///   - ошибка приложения (ответ не той формы) — как сбой, но вердикта о сети нет, а
///     ошибка ложится в журнал ошибок;
///     смена статуса — исключение: отказ со словом для человека приговорён этому
///     переходу навсегда, она снимается с очереди и становится плашкой на списке
///     задач, а неразобранный отказ («HTTP …») строку оставляет, как и везде;
///   - завершение уходит только по пустым очередям тела: застрявшая строка держит
///     его, и это правильно.
///
/// Настоящий sqlite (ffi): очереди и их порядок живут в схеме.

int _seq = 0;
const _uuid = '33333333-3333-4333-8333-333333333333';

Future<LocalDb> _openDb() async =>
    LocalDb.open('tpolicy_${_seq++}');

/// Сервер, который отказывает выборочно — по ручке И по телу запроса: «отвергни
/// поле f1, но прими f2» иначе не выразить. Умеет «пропадать» целиком.
class _Server {
  final calls = <String>[]; // POST-попытки, включая оборвавшиеся
  bool down = false;
  int? Function(String action, String body) fail = (_, __) => null;

  /// Тело отказа: настоящий lsFusion кладёт в него слово для человека — строку
  /// констрейнта или throwException, — и клиент достаёт её из стека. Без текста
  /// ('boom') отказ читается как «HTTP …» — неразобранный.
  String? failText;

  /// Тело ответа на чтение — по ручке; null — пустой ответ, как раньше.
  String? Function(String action) getBody = (_) => null;

  late final Session session;
  late final ApiClient api;

  _Server(Settings settings) {
    session = Session(
      login: 'sidorov${_seq++}', // логин уникален: имя базы содержит его
      name: 'Сидоров С.С.',
      token: 'token',
      signedIn: true,
      performerId: 'p1',
    );
    api = ApiClient(settings, session, client: MockClient((request) async {
      final action = actionOf(request);
      if (request.method == 'POST') {
        calls.add(action); // попытка записывается до «обрыва сети»
        if (down) throw const SocketException('нет сети');
        final status = fail(action, request.body);
        // телом — байты utf8, как у okJson: строкой http.Response кодирует latin1
        // и падает на кириллице ещё внутри мока, до клиента
        if (status != null) {
          return http.Response.bytes(
              utf8.encode(failText ?? 'boom'), status);
        }
        return http.Response('', 200);
      }
      if (down) throw const SocketException('нет сети');
      return okJson(
          getBody(action) ?? (action == 'apiExecutionInfo' ? '{}' : '[]'));
    }));
  }
}

Future<File> _shot() async {
  final dir = await Directory.systemTemp.createTemp('pulse_policy');
  final f = File('${dir.path}/shot.jpg');
  await f.writeAsBytes([1, 2, 3]);
  return f;
}

void main() {
  initTestEnv();

  late Settings settings;
  late _Server server;

  setUp(() {
    resetMockStores();
    ErrorJournal.reset();
    settings = Settings(baseUrl: 'http://test.local:9080');
    server = _Server(settings);
  });

  group('бланк', () {
    test('отказ на старте — барьер: ответы не едут, сеть считается живой',
        () async {
      final db = await _openDb();
      await db.queues.createLocalTask(
        const Task(id: _uuid, clientId: _uuid, name: 'Витрина', typeId: 'form'),
        payloadJson: jsonEncode({'clientId': _uuid, 'typeId': 'form'}),
        createdAtIso: '2026-09-07T10:00:00.000',
        queueStart: true,
      );
      await db.fill.enqueueField(_uuid, 'clean',
          type: 'text', text: 'ок', createdAtIso: '2026-09-07T10:01:00.000');
      server.fail = (a, _) => a == 'apiStartExecution' ? 500 : null;

      final c = FillController(db: db, api: server.api, taskId: _uuid);
      await c.syncAll(refreshSummary: false);

      expect(server.calls, ['apiCreateTask', 'apiStartExecution'],
          reason: 'поле выполнения, которого нет, ехать не может');
      expect(await db.queues.getCreateEntry(_uuid), isNull, reason: 'создание ушло');
      expect(await db.queues.getStartEntry(_uuid), isNotNull, reason: 'старт остался');
      expect(await db.fill.getFieldOutbox(_uuid), hasLength(1));
      expect(c.online, isTrue, reason: 'сервер ответил — это не офлайн');
      expect(c.lastSyncError, isNotNull);
      c.dispose();
      await db.close();
    });

    test('отказ по одному полю не держит остальные, но держит завершение',
        () async {
      final db = await _openDb();
      const id = 'ST-R';
      await db.fill.enqueueField(id, 'f1',
          type: 'text', text: 'а', createdAtIso: '2026-09-07T10:00:00.000');
      await db.fill.enqueueField(id, 'f2',
          type: 'text', text: 'б', createdAtIso: '2026-09-07T10:01:00.000');
      await db.fill.setResolutionOutbox(id, 'passed', '2026-09-07T10:02:00.000');
      await db.queues.enqueueFinish(id, '2026-09-07T10:03:00.000');
      server.fail = (a, body) =>
          a == 'apiSetField' && body.contains('"field":"f1"') ? 500 : null;

      final c = FillController(db: db, api: server.api, taskId: id);
      await c.syncAll(refreshSummary: false);

      expect(server.calls, ['apiSetField', 'apiSetField', 'apiSetResolution'],
          reason: 'f2 и итог уехали вслед за отвергнутым f1; finish — нет');
      final left = await db.fill.getFieldOutbox(id);
      expect(left.map((e) => e['fieldCode']), ['f1']);
      expect(await db.fill.getResolutionOutbox(id), isNull);
      expect(await db.queues.getFinishEntry(id), isNotNull,
          reason: 'застрявшее поле держит завершение');
      expect(c.online, isTrue);
      expect(c.lastSyncError, isNotNull);
      expect((await db.queues.getSyncErrors()).keys, contains('fill:$id'),
          reason: 'причина — под операцией экрана «Не отправлено»');
      c.dispose();
      await db.close();
    });

    test('обрыв связи — одна попытка, дальше цепочка не идёт', () async {
      final db = await _openDb();
      const id = 'ST-O';
      await db.fill.enqueueField(id, 'f1',
          type: 'text', text: 'а', createdAtIso: '2026-09-07T10:00:00.000');
      await db.fill.enqueueField(id, 'f2',
          type: 'text', text: 'б', createdAtIso: '2026-09-07T10:01:00.000');
      await db.fill.setResolutionOutbox(id, 'passed', '2026-09-07T10:02:00.000');
      server.down = true;

      final c = FillController(db: db, api: server.api, taskId: id);
      await c.syncAll(refreshSummary: false);

      expect(server.calls, ['apiSetField'],
          reason: 'следующие строки упрутся в тот же обрыв — их не пробуют');
      expect(await db.fill.getFieldOutbox(id), hasLength(2));
      expect(await db.fill.getResolutionOutbox(id), 'passed');
      expect(c.online, isFalse);
      expect((await db.queues.getSyncErrors())['fill:$id']?.message, 'Нет сети');
      expect(c.lastSyncError, 'Нет сети',
          reason: 'экран говорит то же, что «Не отправлено»');
      c.dispose();
      await db.close();
    });

    test('«Завершить» без связи закрывает бланк одинаково при пустой и непустой очереди',
        () async {
      final db = await _openDb();
      const id = 'ST-F';
      server.down = true;

      // очередь тела пуста: связь пропала на самом вызове завершения
      final direct = FillController(db: db, api: server.api, taskId: id);
      expect(await direct.finish(), isTrue);
      expect(direct.finished, isTrue);
      expect(direct.error, isNull);
      expect(await db.queues.hasFinish(id), isTrue,
          reason: 'завершение встало в очередь и уедет со связью');
      expect(direct.lastSyncError, 'Нет сети',
          reason: 'причина словами, а не строкой исключения');
      expect((await db.queues.getSyncErrors())['fill:$id']?.message, 'Нет сети');
      direct.dispose();
      await db.queues.dequeueFinish(id);

      // ответ ещё в очереди: завершение встаёт за ним, бланк закрыт так же. Счётчик
      // очереди открытый экран знает с загрузки — здесь его даёт проход синхронизации
      await db.fill.enqueueField(id, 'f1',
          type: 'text', text: 'а', createdAtIso: '2026-09-07T10:00:00.000');
      final queued = FillController(db: db, api: server.api, taskId: id);
      await queued.syncAll(refreshSummary: false);
      expect(await queued.finish(), isTrue);
      expect(queued.finished, isTrue);
      expect(await db.queues.hasFinish(id), isTrue);
      expect(await db.fill.getFieldOutbox(id), hasLength(1));
      queued.dispose();

      // связь вернулась — ответ и завершение уезжают по порядку
      server.down = false;
      server.calls.clear();
      final drain = FillController(db: db, api: server.api, taskId: id);
      await drain.syncAll(refreshSummary: false);
      expect(server.calls, ['apiSetField', 'apiFinishExecution']);
      expect(await db.queues.hasFinish(id), isFalse);
      drain.dispose();
      await db.close();
    });
  });

  group('отказ против сбоя', () {
    /// Два поля в очереди бланка; первое сервер не принимает ответом [status] с
    /// телом [body], второе — принимает.
    Future<({LocalDb db, FillController c})> twoFields(
        String id, int status, String body) async {
      final db = await _openDb();
      await db.fill.enqueueField(id, 'f1',
          type: 'text', text: 'а', createdAtIso: '2026-09-07T10:00:00.000');
      await db.fill.enqueueField(id, 'f2',
          type: 'text', text: 'б', createdAtIso: '2026-09-07T10:01:00.000');
      server.fail = (a, b) =>
          a == 'apiSetField' && b.contains('"field":"f1"') ? status : null;
      server.failText = body;
      final c = FillController(db: db, api: server.api, taskId: id);
      await c.syncAll(refreshSummary: false);
      return (db: db, c: c);
    }

    test('4xx — отказ: причина словами сервера и «Убрать» человеку', () async {
      final r = await twoFields('ST-4', 422,
          'lsfusion.server.logics.action.flow.LSFStatusException '
          'Бланк заполняет Сидорова');

      expect(server.calls, ['apiSetField', 'apiSetField'],
          reason: 'отказ по f1 не держит f2');
      expect((await r.db.fill.getFieldOutbox('ST-4')).map((e) => e['fieldCode']),
          ['f1']);
      final e = (await r.db.queues.getSyncErrors())['fill:ST-4']!;
      expect(e.message, 'Отклонено сервером: Бланк заполняет Сидорова');
      expect(e.refused, isTrue, reason: 'тот же запрос получит тот же отказ');
      expect(r.c.online, isTrue);
      expect(r.c.lastSyncError, 'Бланк заполняет Сидорова');
      r.c.dispose();
      await r.db.close();
    });

    test('5xx — сбой: строка ждёт сервер, убрать её не предлагают', () async {
      final r = await twoFields(
          'ST-5',
          500,
          'Внутренняя ошибка сервера: java.lang.NullPointerException\n'
              '\tat lsfusion.server.logics.action.SystemAction.execute');

      expect(server.calls, ['apiSetField', 'apiSetField']);
      expect(await r.db.fill.getFieldOutbox('ST-5'), hasLength(1));
      final e = (await r.db.queues.getSyncErrors())['fill:ST-5']!;
      expect(e.message, startsWith('Сбой сервера: '));
      expect(e.message, contains('NullPointerException'));
      expect(e.refused, isFalse, reason: 'оживший сервер строку примет');
      expect(r.c.online, isTrue, reason: 'сервер ответил — это не офлайн');
      expect(r.c.lastSyncError, startsWith('Сбой сервера: '));
      r.c.dispose();
      await r.db.close();
    });

    test('отказ кодом 500 (сервер 6.2, старые ручки) узнаётся по классу исключения',
        () async {
      final r = await twoFields(
          'ST-L',
          500,
          'Внутренняя ошибка сервера: '
              'lsfusion.server.logics.action.flow.LSFException '
              'Execution already finished\n\tat lsfusion.server.Foo');

      final e = (await r.db.queues.getSyncErrors())['fill:ST-L']!;
      expect(e.message, 'Отклонено сервером: Execution already finished');
      expect(e.refused, isTrue);
      r.c.dispose();
      await r.db.close();
    });

    test('ошибка приложения — не обрыв: вердикт о сети прежний, ошибка в журнале',
        () async {
      final db = await _openDb();
      await ErrorJournal.attach(db);
      final drain = OutboxDrain(() => db, kind: 'fill', taskId: 'ST-T');
      var sent = <int>[];

      final go = await drain.each<int>([1, 2], (i) async {
        if (i == 1) throw TypeError();
        sent.add(i);
      });

      expect(go, isTrue, reason: 'строка с ошибкой не держит следующие');
      expect(sent, [2]);
      expect(drain.online, isTrue, reason: 'об отсутствии связи ничто не говорит');
      final e = (await db.queues.getSyncErrors())['fill:ST-T']!;
      expect(e.message, 'Ошибка приложения — записана в журнал');
      expect(e.refused, isFalse);
      await ErrorJournal.flushed();
      final logged = await db.errors.oldest(10);
      expect(logged, hasLength(1));
      expect(logged.single['kind'], 'sync');
      expect(logged.single['place'], 'fill:ST-T');
      expect(logged.single['message'] as String, contains('TypeError'));

      // и офлайн, раз установленный обрывом, ошибка приложения не снимает
      drain.online = false;
      sent = [];
      await drain.each<int>([1], (_) async => throw TypeError());
      expect(drain.online, isFalse);
      await db.close();
    });

    test('ответ не той формы при открытии бланка — не «нет данных офлайн»',
        () async {
      final db = await _openDb();
      await ErrorJournal.attach(db);
      // поля — числом вместо списка: так выглядит сменившаяся форма ответа
      server.getBody = (a) =>
          a == 'apiExecutionBundle' ? '[{"info":{},"fields":5}]' : null;

      final c = FillController(db: db, api: server.api, taskId: 'ST-B');
      await c.load();

      expect(c.error, 'Ошибка приложения — записана в журнал');
      expect(c.online, isTrue);
      await ErrorJournal.flushed();
      final logged = await db.errors.oldest(10);
      expect(logged.single['kind'], 'call');
      expect(logged.single['place'], 'fill:ST-B');
      c.dispose();
      await db.close();
    });

    test('разбор ответа: 4xx — отказ, 5xx — сбой, кроме отказа 6.2 кодом 500', () {
      final api = ApiClient(settings, server.session);
      ApiException thrown(int status, String body) {
        try {
          api.check(http.Response.bytes(utf8.encode(body), status));
        } on ApiException catch (e) {
          return e;
        }
        fail('ответ $status принят');
      }

      expect(thrown(422, 'нельзя').refusal, isTrue);
      expect(thrown(403, '{"error":"notPerformer","message":"Не ваша"}').refusal,
          isTrue);
      expect(thrown(500, 'boom').refusal, isFalse);
      expect(thrown(502, '<html>Bad Gateway</html>').refusal, isFalse);
      final legacy = thrown(
          500,
          'Внутренняя ошибка сервера: '
          'lsfusion.server.logics.action.flow.LSFStatusException Предел балла — 5');
      expect(legacy.refusal, isTrue);
      expect(legacy.message, 'Предел балла — 5');
      expect(ApiException('Сервер не выдал токен').refusal, isFalse,
          reason: 'без статуса — не ответ ручки по существу');
    });
  });

  group('отчёт поручения', () {
    test('отказ по снимку не держит комментарий, но держит завершение',
        () async {
      final db = await _openDb();
      const id = 'ST-S';
      final shot = await _shot();
      await db.simple.saveSimplePhoto(id, 1, shot.path, '2026-09-07T10:00:00.000');
      await db.simple.enqueueSimpleComment(id, 'готово', '2026-09-07T10:01:00.000');
      await db.simple.enqueueSimpleFinish(id, '2026-09-07T10:02:00');
      server.fail = (a, _) => a == 'apiSetSimplePhoto' ? 500 : null;

      final c = SimpleExecutionController(db: db, api: server.api, taskId: id);
      await c.syncAll(refreshInfo: false);

      expect(server.calls, ['apiSetSimplePhoto', 'apiSetSimpleComment']);
      expect(await db.simple.getPendingSimplePhotos(id), hasLength(1));
      expect(await db.simple.getSimpleComment(id), isNull);
      expect(await db.simple.getSimpleFinishEntry(id), isNotNull,
          reason: 'застрявший снимок держит «Выполнено»');
      expect(c.online, isTrue);
      expect((await db.queues.getSyncErrors()).keys, contains('simple:$id'));
      c.dispose();
      await db.close();
    });
  });

  group('репозиторий', () {
    Future<AppControllers> repoWith(List<Map<String, Object?>> fetched) async {
      final app = AppControllers(
          api: server.api, settings: settings, session: server.session);
      await app.account.updateSettings(settings); // открывает базу этого логина
      for (final j in fetched) {
        await app.repo.db.tasks.insertLocalTask(Task.fromJson(j.cast<String, dynamic>()));
      }
      return app;
    }

    test('отказ на взятии — стоп без повтора по кругу, сеть живая', () async {
      final app = await repoWith([
        {'id': 'ST2', 'name': 'Пул', 'canTake': true},
      ]);
      await app.repo.db.tasks.enqueueTake('ST2', 'take', '2026-09-07T10:00:00.000');
      server.fail = (a, _) => a == 'apiTakeTask' ? 500 : null;

      await app.repo.syncTakes();

      expect(server.calls, ['apiTakeTask'],
          reason: 'перечитывающий проход не зацикливается на отвергнутой строке');
      expect(await app.repo.db.tasks.getTakeOutbox(), hasLength(1));
      expect(app.repo.online, isTrue);
      expect((await app.repo.db.queues.getSyncErrors()).keys, contains('take:ST2'));
      app.dispose();
    });

    test('отказ по статусу одной задачи не держит статус другой', () async {
      final app = await repoWith([
        {'id': 'ST1', 'name': 'Первая'},
        {'id': 'ST2', 'name': 'Вторая'},
      ]);
      await app.repo.db.tasks.enqueue('ST1', 's2', 'В работе', '2026-09-07T10:00:00.000');
      await app.repo.db.tasks.enqueue('ST2', 's2', 'В работе', '2026-09-07T10:01:00.000');
      server.fail = (a, body) =>
          a == 'apiSetStatus' && body.contains('"id":"ST1"') ? 500 : null;

      await app.repo.syncOutbox();

      expect(server.calls, ['apiSetStatus', 'apiSetStatus']);
      expect((await app.repo.db.tasks.getOutbox()).keys, ['ST1']);
      expect(app.repo.online, isTrue, reason: 'сервер ответил — это не офлайн');
      expect((await app.repo.db.queues.getSyncErrors()).keys, contains('status:ST1'));
      app.dispose();
    });

    test('отказ со словом сервера снимает смену с очереди, а не ретраит её вечно',
        () async {
      final app = await repoWith([
        {'id': 'ST1', 'name': 'Первая'},
      ]);
      await app.repo.db.tasks
          .enqueue('ST1', 'canceled', 'Отменено', '2026-09-07T10:00:00.000');
      server.fail = (a, _) => a == 'apiSetStatus' ? 500 : null;
      server.failText = 'LSFException Такой переход статуса вам не разрешён';

      final touched = await app.repo.syncOutbox();

      expect(touched, isTrue,
          reason: 'очередь поговорила с сервером — кэшу нужна свежая выдача');
      expect((await app.repo.db.tasks.getOutbox()).keys, isEmpty,
          reason: 'тот же запрос получил бы тот же отказ всегда');
      expect(app.repo.statusNotice,
          'Смена статуса не принята: Такой переход статуса вам не разрешён');
      // строки в очереди больше нет — и её причина не оседает в «Не отправлено»:
      // слово сервера человек увидел плашкой, а сборка вычистила осиротевший ключ
      expect((await app.repo.db.queues.getSyncErrors()).keys, isEmpty);

      // и второй заход ту же смену уже не возит — ей больше нет в очереди
      await app.repo.syncOutbox();
      expect(server.calls, ['apiSetStatus']);
      app.dispose();
    });
  });
}
