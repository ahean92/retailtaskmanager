// Общее для сквозного набора: настоящий клиент приложения (контроллеры, sqlite, экраны)
// против настоящего сервера. Адрес и учётка — из окружения:
//   E2E_BASE   адрес сервера, по умолчанию http://localhost:7681 (своя база 6.2);
//   E2E_ADMIN  логин:пароль клиента, по умолчанию «admin:» (admin без пароля);
//   E2E_KEEP   =1 — не убирать синтетику после прогона (разбор упавшего сценария).
// Сид и уборка — seed_e2e.lsf и cleanup_e2e.lsf через POST /eval/action: только для
// тестовых стендов, на боевом хосте /eval закрыт.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:pulse_tasks/app_controllers.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';

import '../../test/support/test_env.dart';

final String e2eBase = (Platform.environment['E2E_BASE'] ?? 'http://localhost:7681')
    .replaceAll(RegExp(r'/+$'), '');
final String _adminAuth = Platform.environment['E2E_ADMIN'] ?? 'admin:';
final bool _keepData = Platform.environment['E2E_KEEP'] == '1';

/// Приёмщик из сида — автор задач с обязательной приёмкой. Логин уникален на прогон
/// (см. шапку seed_e2e.lsf), пароль равен логину.
final String _authorLogin = 'zzz-e2e-author-${DateTime.now().millisecondsSinceEpoch}';
final String authorAuth = '$_authorLogin:$_authorLogin';

String _basic(String auth) => 'Basic ${base64Encode(utf8.encode(auth))}';

/// Клиент телефона: подставляет Basic вместо токена, ведёт журнал ручек с кодом ответа,
/// умеет «потерять связь» и придержать ответ ручки (плитка соберётся из кэша раньше,
/// чем приедет ответ, — как на медленной связи).
class E2eClient extends http.BaseClient {
  E2eClient(this.auth);

  final String auth;
  final _inner = http.Client();

  /// Ручки по порядку вызова: «apiSetField 200».
  final log = <String>[];

  /// Нет связи: запрос не уходит, клиент получает SocketException.
  bool down = false;

  /// Задержка ответа ручки (один раз): ручка → сколько ждать после ответа сервера.
  final delayOnce = <String, Duration>{};

  List<String> get calls => [for (final l in log) l.split(' ').first];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest r) async {
    r.headers.removeWhere((k, _) => k.toLowerCase() == 'authorization');
    r.headers['authorization'] = _basic(auth);
    final action = r.url.path.split('.').last;
    if (down) {
      log.add('$action нет-связи');
      throw const SocketException('нет связи (сквозной набор)');
    }
    final resp = await _inner.send(r);
    log.add('$action ${resp.statusCode}');
    final delay = delayOnce.remove(action);
    if (delay == null) return resp;
    final full = await http.Response.fromStream(resp);
    await Future<void>.delayed(delay);
    return http.StreamedResponse(Stream.value(full.bodyBytes), full.statusCode,
        headers: full.headers, request: r);
  }
}

/// Один «телефон»: своя локальная база (логин уникален), свой клиент, свои контроллеры.
class Phone {
  Phone._(this.app, this.client, this.api);

  final AppControllers app;
  final E2eClient client;
  final ApiClient api;

  static var _seq = 0;

  static Future<Phone> boot({String? auth, String name = 'admin'}) async {
    final settings = Settings(baseUrl: e2eBase);
    final client = E2eClient(auth ?? _adminAuth);
    final session = Session(
        login: 'e2e${DateTime.now().microsecondsSinceEpoch}${_seq++}',
        name: name,
        token: 't',
        signedIn: true);
    final api = ApiClient(settings, session, client: client);
    final app = AppControllers(api: api, settings: settings, session: session);
    await app.account.updateSettings(settings);
    await app.repo.refresh();
    return Phone._(app, client, api);
  }

  void dispose() => app.dispose();
}

/// Подготовка процесса: реальная сеть вместо заглушки тестовой обвязки, каталог
/// приложения для path_provider, сид на сервере. Звать из setUpAll.
Future<void> e2eSetUp() async {
  initTestEnv();
  HttpOverrides.global = null;
  resetMockStores();
  final docs = Directory.systemTemp.createTempSync('e2e_docs');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (c) async => docs.path);
  try {
    await http.get(Uri.parse('$e2eBase/exec/StoreTask.apiCurrentUser'),
        headers: {'authorization': _basic(_adminAuth)}).timeout(const Duration(seconds: 10));
  } catch (e) {
    fail('Сервер $e2eBase не отвечает ($e). Поднять свой 6.2: scripts/e2e62.ps1');
  }
  _expectClean(await evalFile('cleanup_e2e.lsf'), 'уборка перед сидом');
  final seed = await evalScript(_readScript('seed_e2e.lsf')
      .replaceAll("'zzz-e2e-author'", "'$_authorLogin'"));
  expect(seed['failed'], isNot(true), reason: 'сид: ${seed['msg']}');
}

/// Уборка синтетики после набора. Звать из tearDownAll.
Future<void> e2eTearDown() async {
  if (_keepData) return;
  _expectClean(await evalFile('cleanup_e2e.lsf'), 'уборка после набора');
}

void _expectClean(Map<String, dynamic> r, String what) {
  expect(r['failed'], isNot(true), reason: '$what: ${r['msg']}');
  expect([r['leftTasks'], r['leftTemplates'], r['leftUsers']], [null, null, null],
      reason: '$what: синтетика осталась');
}

/// Скрипт из test_e2e/ — в POST /eval/action под admin. Ответ — первый объект JSON.
Future<Map<String, dynamic>> evalFile(String name) async =>
    evalScript(_readScript(name));

/// `flutter test` запускается из корня пакета — скрипты лежат рядом с набором.
String _readScript(String name) => File(
        '${Directory.current.path}${Platform.pathSeparator}test_e2e${Platform.pathSeparator}$name')
    .readAsStringSync();

Future<Map<String, dynamic>> evalScript(String script) async {
  final r = await http.post(Uri.parse('$e2eBase/eval/action'),
      headers: {
        'authorization': _basic(_adminAuth),
        'content-type': 'text/plain; charset=utf-8',
      },
      body: utf8.encode(script));
  final text = utf8.decode(r.bodyBytes);
  if (r.statusCode != 200) fail('eval ${r.statusCode}: $text');
  final d = jsonDecode(text);
  final m = d is List ? (d.isEmpty ? const {} : d.first) : d;
  return (m as Map).cast<String, dynamic>();
}

Future<dynamic> _get(String action, Map<String, String> query) async {
  final r = await http.get(
      Uri.parse('$e2eBase/exec/StoreTask.$action').replace(queryParameters: query),
      headers: {'authorization': _basic(_adminAuth)});
  expect(r.statusCode, 200, reason: '$action: ${utf8.decode(r.bodyBytes)}');
  final d = jsonDecode(utf8.decode(r.bodyBytes));
  return d is List && d.isNotEmpty && d.first is Map ? d.first : d;
}

/// Бланк задачи глазами сервера (агрегат, как его читает телефон).
Future<Map<String, dynamic>> serverBundle(String task) async =>
    ((await _get('apiExecutionBundle', {'id': task})) as Map).cast<String, dynamic>();

/// Поле бланка на сервере по коду.
Future<Map<String, dynamic>> serverField(String task, String code) async {
  final fields = (await serverBundle(task))['fields'] as List? ?? const [];
  return (fields.firstWhere((f) => f['code'] == code,
          orElse: () => fail('на сервере нет поля $code у $task')) as Map)
      .cast<String, dynamic>();
}

/// Ячейки строки таблицы на сервере: колонка → запись ответа (number/text/date).
Future<Map<String, Map<String, dynamic>>> serverCells(String task, String rowKey) async {
  final rows = (await serverBundle(task))['rows'] as List? ?? const [];
  return {
    for (final r in rows)
      if (r['rowKey'] == rowKey) r['colCode'] as String: (r as Map).cast<String, dynamic>()
  };
}

/// Отчёт поручения на сервере.
Future<Map<String, dynamic>> serverSimple(String task) async =>
    ((await _get('apiSimpleInfo', {'id': task})) as Map).cast<String, dynamic>();

/// Статус задачи на сервере: id статуса (new, in progress, acceptance, done…).
Future<String?> serverStatus(String task) async {
  final r = await evalScript("EXPORT JSON FROM s = StoreTask.id[StoreTask.TaskStatus]("
      "StoreTask.status((GROUP MAX StoreTask.Task t IF StoreTask.id[StoreTask.Task](t) = '$task')));");
  return r['s'] as String?;
}

// --- экран ---

Widget host(Phone p, Widget home) =>
    MultiProvider(providers: p.app.providers, child: MaterialApp(home: home));

/// Крутить кадры, пока не выполнится условие: настоящие сеть и sqlite внутри runAsync
/// живут своим временем, pumpAndSettle его не даёт.
Future<void> until(WidgetTester t, bool Function() done,
    {Duration timeout = const Duration(seconds: 15)}) async {
  final end = DateTime.now().add(timeout);
  while (!done() && DateTime.now().isBefore(end)) {
    await t.pump(const Duration(milliseconds: 50));
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }
}

/// Дать осесть фоновым кругам, которых ждать нечем.
Future<void> settle(WidgetTester t, [int frames = 20]) async {
  for (var i = 0; i < frames; i++) {
    await t.pump(const Duration(milliseconds: 50));
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }
}

/// Снять экран до dispose телефона: живой экран под закрытой базой роняет тест.
Future<void> closeScreen(WidgetTester t) async {
  await t.pumpWidget(const SizedBox());
  await settle(t, 10);
}

/// Снять экран, дождаться тишины в сети и освободить телефон. Экран после «Завершить»
/// запускает синхронизацию и не ждёт её, а освобождённый посреди неё репозиторий
/// роняет тест уже после конца: тишина в журнале ручек — признак, что она дошла.
Future<void> shutdown(WidgetTester t, Phone p,
    {Duration idle = const Duration(seconds: 1),
    Duration timeout = const Duration(seconds: 20)}) async {
  await closeScreen(t);
  final end = DateTime.now().add(timeout);
  var seen = p.client.log.length;
  var quietSince = DateTime.now();
  while (DateTime.now().isBefore(end)) {
    await t.pump(const Duration(milliseconds: 50));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (p.client.log.length != seen) {
      seen = p.client.log.length;
      quietSince = DateTime.now();
    } else if (DateTime.now().difference(quietSince) >= idle) {
      break;
    }
  }
  p.dispose();
}

/// Однопиксельный PNG для снимков.
File pngFile() {
  final f = File('${Directory.systemTemp.createTempSync('e2e_png').path}'
      '${Platform.pathSeparator}shot.png');
  f.writeAsBytesSync(base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='));
  return f;
}
