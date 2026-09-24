// Сквозная приёмка #37175 на живом стенде (192.168.42.28:8888, demo.user1).
// Throwaway-драйвер: сеть и публикацию следующей редакции делает внешний шелл по
// маркерам в логе — NET_OFF (выключить сеть) и PUBLISH (опубликовать на сервере
// следующую редакцию чек-листа ZZZ37175, потом вернуть сеть). Сид чек-листа и пресета
// до прогона и сверку редакций созданных задач после — тоже шелл, через /eval: номер
// редакции задачи телефону не виден, виден только состав её бланка.
//
// Приёмка тикета целиком:
//  1) проверка, созданная и заполненная офлайн по редакции 1, после публикации
//     редакции 2 и синхронизации уходит с номером 1: ответы по пункту, которого во
//     второй редакции уже нет, на месте, и бланк задачи с сервера — того же состава;
//  2) поручение из AI-черновика и задача без засеянного бланка, созданные тогда же
//     офлайн, уходят без номера — сервер ставит их на текущую, вторую;
//  3) сервер без редакций (номер из ответа apiTemplates вырезан на проводе): тело
//     создания без номера, задача создаётся как раньше.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:pulse_tasks/data/client_id.dart';
import 'package:pulse_tasks/data/fill_controller.dart';
import 'package:pulse_tasks/models/ai_draft.dart';
import 'package:pulse_tasks/models/fill.dart';
import 'package:pulse_tasks/models/quick_create.dart';
import 'support/e2e_harness.dart';

const _login = String.fromEnvironment('E2E_LOGIN', defaultValue: 'demo.user1');

/// Чек-лист и пресет, которые шелл заводит до прогона (редакция 1: fridge, shelf).
const _template = 'ZZZ37175';
const _preset = 'zzz37175';

/// Провод приложения: запоминает тела apiCreateTask (каждую попытку, и оборвавшуюся)
/// и по флагу вырезает номер редакции из apiTemplates — так отвечает сервер без
/// редакций.
class _Wire extends http.BaseClient {
  _Wire(this._inner);
  final http.Client _inner;
  bool oldServer = false;
  final created = <Map<String, dynamic>>[];

  Map<String, dynamic> lastCreate(String clientId) =>
      created.lastWhere((b) => b['clientId'] == clientId);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final action = request.url.path.split('.').last;
    if (action == 'apiCreateTask' && request is http.Request) {
      created.add((jsonDecode(request.body) as Map).cast<String, dynamic>());
    }
    final r = await _inner.send(request);
    if (!oldServer || action != 'apiTemplates' || r.statusCode != 200) return r;
    final bytes = await r.stream.toBytes();
    final list = jsonDecode(utf8.decode(bytes)) as List;
    for (final t in list) {
      (t as Map).remove('version');
    }
    final body = utf8.encode(jsonEncode(list));
    return http.StreamedResponse(Stream.value(body), r.statusCode,
        contentLength: body.length,
        headers: {...r.headers}..remove('content-length'),
        request: r.request);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('37175: офлайн-проверка остаётся на редакции своего бланка',
      (tester) async {
    // клиент под проводом — вне зоны, иначе провод звал бы сам себя (#37178)
    final wire = _Wire(http.Client());
    await http.runWithClient(() async {
      final app = await bootApp(tester, login: _login);

      // --- пятница: телефон забирает чек-лист редакции 1 — и главную: объект для
      // создания экран берёт с неё, а после смены учётки её ещё нет ---
      await app.sync.syncAndRefresh();
      await until(tester, 'объект для создания',
          () => app.home.createObject != null,
          seconds: 120);
      debugPrint('OBJECT ${app.home.createObject}');
      QuickPreset preset() =>
          app.home.quickCreate.actions.firstWhere((a) => a.code == _preset);
      final v1 = app.home.quickCreate.templateOf(preset())!;
      debugPrint('CACHE version=${v1.version} '
          'fields=${v1.fields.map((f) => f.code).join(',')}');
      expect(v1.version, 1, reason: 'сид шелла заводит редакцию 1');
      expect(v1.fields.map((f) => f.code), ['fridge', 'shelf']);

      // --- понедельник, подвал: сети нет ---
      debugPrint('NET_OFF');
      await until(tester, 'авиарежим', () => !app.repo.online, seconds: 240);

      // 1) внезапная проверка — с экрана создания, как её создаёт человек
      final before = {for (final t in app.repo.tasks) t.task.clientId ?? t.id};
      await tester.tap(find.byTooltip('Создать'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(preset().title).last);
      await tester.pumpAndSettle();
      final startBtn = find.widgetWithText(FilledButton, 'Начать проверку');
      await tester.scrollUntilVisible(startBtn, 300,
          scrollable: find.byType(Scrollable).first);
      await tester.ensureVisible(startBtn);
      await tester.pumpAndSettle();
      await tester.tap(startBtn);
      await tester.pumpAndSettle();
      await until(tester, 'экран бланка',
          () => find.text('Заполнение').evaluate().isNotEmpty,
          seconds: 60);
      await shot(tester, 'SHOT_OFFLINE_BLANK');
      final check = app.repo.tasks
          .firstWhere((t) => t.pending && !before.contains(t.task.clientId));
      final checkUuid = check.task.clientId!;
      final objectId = check.task.objectId!;
      debugPrint('CHECK_UUID=$checkUuid object=$objectId');
      await tester.pageBack();
      await tester.pumpAndSettle();

      // номер лёг в тело очереди в момент создания — до всякой отправки
      final queued = await app.repo.db.queues.getCreateEntry(checkUuid);
      final queuedBody = jsonDecode(queued!['payload'] as String) as Map;
      debugPrint('QUEUED ${jsonEncode(queuedBody)}');
      expect(queuedBody['templateId'], _template);
      expect(queuedBody['templateVersion'], 1);

      // заполняет headless-контроллер — та же база, те же очереди, что у экрана
      final fill =
          FillController(db: app.repo.db, api: app.api, taskId: checkUuid);
      await fill.load();
      expect(fill.fields.map((f) => f.code), ['fridge', 'shelf']);
      FillField field(String code) =>
          fill.fields.firstWhere((f) => f.code == code);
      await fill.setNumber(field('fridge'), 5);
      await fill.setNumber(field('shelf'), 3);
      // не завершаем: завершённая проверка закрывается и из списка уходит, а приёмка
      // — про бланк, который продолжают заполнять после синхронизации
      await fill.syncAll(refreshSummary: false); // дождаться попыток из _commit
      fill.dispose();

      // 2) поручение из AI-черновика по тому же шаблону: бланк у него есть и в кэше
      // лежит, но заполнять его будут потом — номер не нужен
      final aiUuid = await app.home.createFromAiDraft(AiDraft.fromJson({
        'dialogId': newClientId(),
        'outcome': 'ok',
        'name': 'ZZZ 37175: поручение из AI',
        'typeId': preset().typeId,
        'usesTemplate': true,
        'templateCode': _template,
        'objectId': objectId,
      }));
      // 3) задача, чей бланк не приехал: код есть, шаблона под рукой нет
      final noSeedUuid = await app.repo.createTask(
        typeId: preset().typeId!,
        objectId: objectId,
        name: 'ZZZ 37175: без засеянного бланка',
        templateCode: _template,
      );
      for (final id in [aiUuid, noSeedUuid]) {
        final e = await app.repo.db.queues.getCreateEntry(id);
        final body = jsonDecode(e!['payload'] as String) as Map;
        debugPrint('QUEUED ${jsonEncode(body)}');
        expect(body['templateId'], _template);
        expect(body.containsKey('templateVersion'), isFalse);
      }

      // --- 9:00 бэк-офис публикует редакцию 2, 11:00 телефон в сети ---
      debugPrint('PUBLISH');
      // ждём очереди именно этих задач: хвосты прошлых прогонов на эмуляторе не в счёт
      final db = app.repo.db;
      await untilAsync(tester, 'три создания и бланк проверки уехали', () async {
        for (final id in [checkUuid, aiUuid, noSeedUuid]) {
          if (await db.queues.getCreateEntry(id) != null) return false;
        }
        return (await db.fill.getFieldOutbox(checkUuid)).isEmpty;
      }, seconds: 300);
      debugPrint('SENT offline=${jsonEncode(wire.lastCreate(checkUuid))}');
      debugPrint('SENT ai=${jsonEncode(wire.lastCreate(aiUuid))}');
      debugPrint('SENT noseed=${jsonEncode(wire.lastCreate(noSeedUuid))}');
      expect(wire.lastCreate(checkUuid)['templateVersion'], 1);
      expect(wire.lastCreate(aiUuid).containsKey('templateVersion'), isFalse);
      expect(
          wire.lastCreate(noSeedUuid).containsKey('templateVersion'), isFalse);

      // кэш уже новой редакции — задача ушла по старой не потому, что новая не
      // доехала
      await app.home.refreshQuickCreate();
      final v2 = app.home.quickCreate.templateOf(preset())!;
      debugPrint('CACHE version=${v2.version} '
          'fields=${v2.fields.map((f) => f.code).join(',')}');
      expect(v2.version, 2);
      expect(v2.fields.map((f) => f.code),
          ['shelf', 'fridgeTemp', 'fridgeClean']);

      // бланк задачи с сервера — состав первой редакции, ответы на месте
      await app.sync.syncAndRefresh();
      await tester.pumpAndSettle();
      final rows = app.repo.tasks
          .where((t) => t.task.clientId == checkUuid || t.id == checkUuid)
          .toList();
      expect(rows, hasLength(1), reason: 'проверка без дубля');
      final serverId = rows.single.id;
      expect(serverId, startsWith('ST'));
      final after =
          FillController(db: app.repo.db, api: app.api, taskId: serverId);
      await after.load();
      final answers = {for (final f in after.fields) f.code: f.number};
      debugPrint('SERVER_BLANK $serverId ${jsonEncode(answers)}');
      expect(after.online, isTrue);
      expect(answers, {'fridge': 5.0, 'shelf': 3.0});
      after.dispose();

      // --- сервер без редакций: номера нет в ответе — нет и в создании ---
      wire.oldServer = true;
      await app.home.refreshQuickCreate();
      final bare = app.home.quickCreate.templateOf(preset())!;
      expect(bare.version, isNull);
      final oldUuid = await app.home.createFromPreset(PresetDraft(
        preset: preset(),
        template: bare,
        object: (
          id: objectId,
          name: check.task.object ?? objectId,
          address: null,
        ),
        name: 'ZZZ 37175: старый сервер',
      ));
      await untilAsync(tester, 'создание со «старым сервером» уехало',
          () async => await app.repo.db.queues.getCreateEntry(oldUuid) == null,
          seconds: 120);
      final oldBody = wire.lastCreate(oldUuid);
      debugPrint('SENT old=${jsonEncode(oldBody)}');
      expect(oldBody['templateId'], _template);
      expect(oldBody.containsKey('templateVersion'), isFalse);
      wire.oldServer = false;

      // сверка редакций на сервере — шелл, по этим ключам
      debugPrint('UUIDS offline=$checkUuid ai=$aiUuid noseed=$noSeedUuid '
          'old=$oldUuid');
      debugPrint('ALL_OK_37175');
    }, () => wire);
  });
}
