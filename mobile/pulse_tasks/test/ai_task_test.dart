import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/data/task_repository.dart';
import 'package:pulse_tasks/models/ai_draft.dart';
import 'package:pulse_tasks/ui/ai_task_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Постановка задачи текстом: разбор ответа сервера, обращение к ручке и — главное —
/// то, что подтверждение черновика идёт ОБЫЧНЫМ путём создания задачи.
///
/// Фикстура — дословный ответ стенда на демонстрационную фразу тикета: «Поставь
/// Иванову завтра до 18:00 задачу проверить выкладку Pepsi в магазине на Ленина и
/// сфотографировать нарушения». Поедет контракт ручки — сломается здесь, а не в поле.

const _draftJson = '''
{"dialogId":"11111111-2222-3333-4444-555555555555","step":1,"outcome":"ok",
 "name":"Проверить выкладку Pepsi","typeId":"issue","typeName":"Поручение",
 "objectId":"b24","objectName":"Санта на Ленина","objectAddress":"ул. Ленина, 15",
 "performerId":"ivanov","performerName":"Сергей Иванов",
 "deadline":"2026-08-23","photoRequired":true,
 "description":"Сфотографировать нарушения","confidence":0.87}
''';

const _dialogId = '11111111-2222-3333-4444-555555555555';

AiDraft _draft() =>
    AiDraft.fromJson(jsonDecode(_draftJson) as Map<String, dynamic>);

/// Сервер, отвечающий заданным телом на apiAiDraft и записывающий тела мутаций.
class _Server {
  final bodies = <(String, String)>[];
  String draftBody = _draftJson;
  String aiInfoBody = '[{"enabled":true,"model":"qwen2.5:3b"}]';

  late final Session session;
  late final ApiClient api;

  _Server(Settings settings) {
    session = Session(
      login: 'chief',
      name: 'Сидоров',
      token: 'token',
      signedIn: true,
      performerId: 'chief',
    );
    api = ApiClient(settings, session, client: MockClient((request) async {
      final action = request.url.path.split('.').last;
      if (request.method == 'POST') {
        bodies.add((action, request.body));
        final body = action == 'apiAiDraft' ? draftBody : '';
        return http.Response.bytes(utf8.encode(body), 200,
            headers: {'content-type': 'application/json; charset=utf-8'});
      }
      final body = action == 'apiAiInfo' ? aiInfoBody : '[]';
      return http.Response.bytes(utf8.encode(body), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    }));
  }

  Map<String, dynamic> lastBodyOf(String action) => jsonDecode(
      [for (final (a, b) in bodies) if (a == action) b].last) as Map<String, dynamic>;
}

/// Дождаться ответа сервера. Два разных ожидания в одном, и оба обязательны:
///
/// [WidgetTester.pumpAndSettle] здесь не годится вовсе — пока запрос в работе, в ленте
/// крутится бесконечный индикатор, и «успокоится» она уже никогда.
///
/// А просто прокрутить кадры мало: под testWidgets время поддельное, и ответ HTTP,
/// живущий в настоящем, до setState за такие кадры не доходит. [WidgetTester.runAsync]
/// возвращает настоящее время ровно на паузу, за которую ответ успевает прийти.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)));
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Settings settings;
  late _Server server;

  /// Хранилище для виджет-теста заводится ВНЕ поддельного времени: внутри него
  /// testWidgets подменяет часы, и всё, что ждёт настоящего таймера (а внутри
  /// updateSettings это база и синхронизация), не дождётся никогда — тест просто
  /// висит до своего десятиминутного предела. runAsync возвращает настоящее время
  /// на время подготовки.
  Future<TaskRepository> repoFor(WidgetTester tester) async {
    late TaskRepository repo;
    await tester.runAsync(() async {
      repo = TaskRepository(
          api: server.api, settings: settings, session: server.session);
      await repo.updateSettings(settings);
    });
    return repo;
  }

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    settings = Settings(baseUrl: 'http://test.local:9080');
    server = _Server(settings);
  });

  // --- разбор ответа ---

  test('разбирает черновик демонстрационной фразы', () {
    final d = _draft();

    expect(d.isOk, isTrue);
    expect(d.name, 'Проверить выкладку Pepsi');
    expect(d.typeId, 'issue');
    expect(d.objectId, 'b24');
    expect(d.objectName, 'Санта на Ленина');
    expect(d.performerId, 'ivanov');
    expect(d.deadlineDate, DateTime(2026, 8, 23));
    expect(d.photoRequired, isTrue);
    expect(d.missing, isNull, reason: 'такую задачу можно создавать');
    expect(d.lowConfidence, isFalse);
  });

  test('уточнение и ошибка — отдельные исходы, а не пустой черновик', () {
    final clarify = AiDraft.fromJson({
      'dialogId': _dialogId,
      'outcome': 'clarify',
      'question': 'В каком магазине выполнить проверку?',
      'name': 'Проверить выкладку Pepsi',
    });
    expect(clarify.needsClarification, isTrue);
    expect(clarify.question, 'В каком магазине выполнить проверку?');

    final failed = AiDraft.fromJson({
      'dialogId': _dialogId,
      'outcome': 'error',
      'errorCode': 'unavailable',
      'message': 'AI-сервис не отвечает',
    });
    expect(failed.isError, isTrue);
    expect(failed.errorCode, 'unavailable');
  });

  test('запрос не про задачи — понятный отказ, а не выдуманная задача', () {
    final d = AiDraft.fromJson({
      'dialogId': _dialogId,
      'outcome': 'error',
      'errorCode': 'unsupported',
      'message': 'Я могу помочь поставить задачу. Опишите, что нужно сделать.',
    });
    expect(d.isError, isTrue);
    expect(d.errorCode, 'unsupported');
    expect(d.name, isNull, reason: 'черновика нет — рисовать нечего');
  });

  test('к уточнению приезжают варианты, и выбор применяется без модели', () {
    final clarify = AiDraft.fromJson({
      'dialogId': _dialogId,
      'outcome': 'clarify',
      'question': 'Уточните объект — подходит несколько',
      'optionsFor': 'object',
      'name': 'Проверить выкладку',
      'typeId': 'issue',
      'objectOptions': [
        {'id': '1002', 'name': 'С - 2 г. Брест', 'note': 'ул.Мицкевича, 19'},
        {'id': '1003', 'name': 'С - 3 г. Брест', 'note': 'ул. Карбышева, 17'},
      ],
    });
    expect(clarify.needsClarification, isTrue);
    expect(clarify.options, hasLength(2));
    expect(clarify.options.first.note, 'ул.Мицкевича, 19');

    // выбор варианта — это готовый черновик, а не новый запрос к модели
    final chosen = clarify.copyWith(
        outcome: 'ok',
        objectId: clarify.options[1].id,
        objectName: clarify.options[1].name);
    expect(chosen.isOk, isTrue);
    expect(chosen.objectId, '1003');
    expect(chosen.missing, isNull);
  });

  test('ответ без исхода считается ошибкой, а не готовой задачей', () {
    // lsFusion не выгружает NULL: пустой объект — это «ответить нечем»
    expect(AiDraft.fromJson({'dialogId': _dialogId}).isError, isTrue);
  });

  test('чего не хватает — то и мешает создать', () {
    expect(_draft().copyWith(name: '  ').missing, 'Укажите название задачи');
    expect(
      AiDraft.fromJson({'dialogId': _dialogId, 'outcome': 'ok', 'name': 'Задача'})
          .missing,
      'AI не определил тип задачи',
    );
  });

  test('правка снимает срок и описание, а не оставляет прежние', () {
    final edited = _draft().copyWith(deadline: null, description: null);
    expect(edited.deadline, isNull);
    expect(edited.description, isNull);
    // остальное копируется как было
    expect(edited.objectId, 'b24');
    expect(edited.photoRequired, isTrue);
  });

  // --- обращение к ручке ---

  test('запрос несёт ключ разговора, текст и место', () async {
    await server.api.aiDraft(_dialogId, 'Проверить ценники',
        objectId: 'b24', lat: 53.9, lon: 27.56);

    final body = server.lastBodyOf('apiAiDraft');
    expect(body['dialogId'], _dialogId);
    expect(body['text'], 'Проверить ценники');
    expect(body['objectId'], 'b24');
    expect(body['lat'], 53.9);
    expect(body['lon'], 27.56);
  });

  test('пустое тело ответа — ошибка с понятным кодом, а не «ok»', () async {
    server.draftBody = '';
    final draft = await server.api.aiDraft(_dialogId, 'Проверить ценники');
    expect(draft.isError, isTrue);
    expect(draft.errorCode, 'emptyResponse');
  });

  test('apiAiInfo включает пункт AI', () async {
    expect((await server.api.fetchAiInfo()).enabled, isTrue);
    server.aiInfoBody = '{}'; // сервер без AI не присылает ни одного ключа
    expect((await server.api.fetchAiInfo()).enabled, isFalse);
  });

  // --- подтверждение = обычное создание ---

  test('подтверждённый черновик уходит обычной ручкой, ключ задачи — ключ разговора',
      () async {
    final repo = TaskRepository(
        api: server.api, settings: settings, session: server.session);
    await repo.updateSettings(settings);

    final uuid = await repo.createFromAiDraft(_draft());
    expect(uuid, _dialogId,
        reason: 'по этому ключу сервер связывает задачу с AI-запросом');

    await repo.drainLocalTasks();
    final body = server.lastBodyOf('apiCreateTask');
    expect(body['clientId'], _dialogId);
    expect(body['typeId'], 'issue');
    expect(body['objectId'], 'b24');
    expect(body['name'], 'Проверить выкладку Pepsi');
    expect(body['assigneeId'], 'ivanov');
    expect(body['deadline'], '2026-08-23');
    expect(body['requirePhoto'], isTrue);
    expect(body['description'], 'Сфотографировать нарушения');

    // задача видна в списке сразу — это обычная локальная задача, не «AI-сущность»
    final task = repo.tasks.where((t) => t.task.clientId == _dialogId);
    expect(task, hasLength(1));
    expect(task.first.task.assigneeId, 'ivanov');

    await repo.db.close();
  });

  test('черновик с бланком не открывает бланк у автора', () async {
    final repo = TaskRepository(
        api: server.api, settings: settings, session: server.session);
    await repo.updateSettings(settings);

    final withTemplate = AiDraft.fromJson({
      ...jsonDecode(_draftJson) as Map<String, dynamic>,
      'typeId': 'form',
      'templateCode': 'pepsi',
      'usesTemplate': true,
    });
    final uuid = await repo.createFromAiDraft(withTemplate);

    // очередь старта пуста: заполнять бланк будет исполнитель, а не автор поручения
    expect(await repo.db.hasStart(uuid), isFalse);
    await repo.drainLocalTasks();
    expect(server.lastBodyOf('apiCreateTask')['templateId'], 'pepsi');

    await repo.db.close();
  });

  // --- лента разговора ---

  testWidgets('разговор виден целиком: фраза, вопрос, выбор и черновик', (tester) async {
    final repo = await repoFor(tester);

    server.draftBody = jsonEncode({
      'dialogId': _dialogId,
      'step': 1,
      'outcome': 'clarify',
      'question': 'Уточните объект — подходит несколько',
      'optionsFor': 'object',
      'name': 'Проверить выкладку',
      'typeId': 'issue',
      'typeName': 'Поручение',
      'objectOptions': [
        {'id': '1002', 'name': 'С - 2 г. Брест', 'note': 'ул.Мицкевича, 19'},
        {'id': '1003', 'name': 'С - 3 г. Брест', 'note': 'ул. Карбышева, 17'},
      ],
    });

    await tester.pumpWidget(ChangeNotifierProvider<TaskRepository>.value(
      value: repo,
      child: const MaterialApp(home: AiTaskScreen()),
    ));

    await tester.enterText(
        find.byType(TextField).first, 'Проверить выкладку в магазине С');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send));
    await _settle(tester);

    // и сказанное, и переспрошенное остаются на экране — в этом весь смысл ленты
    expect(find.text('Проверить выкладку в магазине С'), findsOneWidget);
    expect(find.text('Уточните объект — подходит несколько'), findsOneWidget);
    expect(find.text('С - 3 г. Брест'), findsOneWidget);

    await tester.tap(find.text('С - 3 г. Брест'));
    await _settle(tester);

    // выбор встал в ленту ответом человека, а следом — карточка задачи
    expect(find.text('С - 3 г. Брест'), findsOneWidget, reason: 'теперь это реплика');
    expect(find.text('Создать задачу'), findsOneWidget);

    // разговор никуда не делся — он просто уехал вверх: прокручиваем и находим и
    // первую фразу, и заданный вопрос. Ради этого лента и затевалась.
    await tester.drag(find.byType(ListView), const Offset(0, 600));
    await tester.pump();
    expect(find.text('Проверить выкладку в магазине С'), findsOneWidget);
    expect(find.text('Уточните объект — подходит несколько'), findsOneWidget);

    await tester.runAsync(() => repo.db.close());
  });

  testWidgets('второй вопрос продолжает тот же разговор, а не начинает новый',
      (tester) async {
    final repo = await repoFor(tester);

    server.draftBody = jsonEncode({
      'dialogId': _dialogId,
      'step': 1,
      'outcome': 'clarify',
      'question': 'В каком магазине?',
    });

    await tester.pumpWidget(ChangeNotifierProvider<TaskRepository>.value(
      value: repo,
      child: const MaterialApp(home: AiTaskScreen()),
    ));

    await tester.enterText(find.byType(TextField).first, 'Проверить ценники');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send));
    await _settle(tester);

    server.draftBody = jsonEncode({
      'dialogId': _dialogId,
      'step': 2,
      'outcome': 'clarify',
      'question': 'К какому сроку?',
    });
    await tester.enterText(find.byType(TextField).first, 'В Уручье');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send));
    await _settle(tester);

    // оба вопроса и оба ответа на экране, и ключ разговора у шагов один
    expect(find.text('В каком магазине?'), findsOneWidget);
    expect(find.text('В Уручье'), findsOneWidget);
    expect(find.text('К какому сроку?'), findsOneWidget);
    final steps = [for (final (a, b) in server.bodies) if (a == 'apiAiDraft') jsonDecode(b)];
    expect(steps, hasLength(2));
    expect(steps.every((b) => b['dialogId'] == steps.first['dialogId']), isTrue);

    await tester.runAsync(() => repo.db.close());
  });
}
