// Общий фейковый сервер модульных тестов клиента.
//
// Ответы — из test/fixtures: их записывает с настоящего 6.2 скрипт
// scripts/record-client-fixtures.ps1. Когда сервер меняет форму ответа, это видно
// diff'ом по test/fixtures при обновлении файлов, а не случайным падением в поле: тесты
// на этом сервере читают ту форму, которую сервер отдаёт на самом деле, а не ту, что
// автор теста помнил.
//
// Поверх записанных ответов — состояние и те правила сервера, на которые клиент
// обязан рассчитывать (каждое проверено записью, см. test_e2e/record_fixtures_test.dart):
// - бланк до старта: агрегат отвечает только шапкой, без полей;
// - apiSetField пишет слот по типу поля, и ключа нет — слот стирается, примечание тоже;
// - балл выше веса поля и запись после завершения — отказ (HTTP 500 с текстом
//   исключения, как у 6.2);
// - пустое значение, NULL и BOOLEAN false сервер не выгружает — ключа нет.
//
// Старые тесты держат свои class _Server: переводить их сюда — при правке файла.

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';

import 'fake_server.dart';

/// Записанный ответ сервера из test/fixtures — каждый раз свежей копией: состояние
/// сервера правится на месте, а файл остаётся тем, что прислал 6.2.
Object? fixture(String name) =>
    jsonDecode(File('test/fixtures/$name.json').readAsStringSync());

Map<String, dynamic> fixtureMap(String name) =>
    (fixture(name) as Map).cast<String, dynamic>();

List<Map<String, dynamic>> fixtureList(String name) => [
      for (final e in fixture(name) as List) (e as Map).cast<String, dynamic>()
    ];

/// Слот ответа в строке поля агрегата по типу поля и ключ тела apiSetField, который
/// его пишет: тот же разбор по типу, что у apiSetField на сервере.
const _slotOfType = <String, (String, String)>{
  'scale': ('optionCode', 'optCode'),
  'choice': ('optionCode', 'optCode'),
  'number': ('number', 'number'),
  'score': ('number', 'number'),
  'boolean': ('bool', 'bool'),
  'text': ('text', 'text'),
  'longtext': ('text', 'text'),
  'scan': ('text', 'text'),
  'date': ('date', 'date'),
};

/// Ключи ответа в строке поля: бланк «до первого ответа» — поля без них.
const _answerKeys = {
  'optionCode', 'number', 'bool', 'text', 'date', 'comment', 'refId', 'ref',
  'photoCount', 'photoIndexes',
};

/// Бланк одной задачи на сервере: шаблон и заполнение.
class FakeFill {
  FakeFill({
    required this.fields,
    this.options = const [],
    this.columns = const [],
    List<Map<String, dynamic>>? rows,
    Map<String, dynamic>? info,
    this.started = false,
    this.finished = false,
  })  : rows = rows ?? [],
        info = info ?? fixtureMap('apiExecutionInfo');

  /// Бланк, как его отдал 6.2 ([name] — файл агрегата в test/fixtures). [blank] —
  /// те же поля без ответов и без строк таблиц: задача, в которой ещё не отвечали.
  factory FakeFill.recorded(String name,
      {bool blank = false, bool started = true}) {
    final b = fixtureMap(name);
    List<Map<String, dynamic>> list(String k) => [
          for (final e in (b[k] as List?) ?? const [])
            (e as Map).cast<String, dynamic>()
        ];
    final fields = list('fields');
    if (blank) {
      for (final f in fields) {
        f.removeWhere((k, _) => _answerKeys.contains(k));
      }
    }
    return FakeFill(
      fields: fields,
      options: list('options'),
      columns: list('columns'),
      rows: blank ? [] : list('rows'),
      info: (b['info'] as Map?)?.cast<String, dynamic>(),
      started: started,
    );
  }

  final List<Map<String, dynamic>> fields;
  final List<Map<String, dynamic>> options;
  final List<Map<String, dynamic>> columns;
  final List<Map<String, dynamic>> rows;
  Map<String, dynamic> info;
  bool started;
  bool finished;

  Map<String, dynamic> field(String code) =>
      fields.firstWhere((f) => f['code'] == code);
}

/// Сервер с состоянием поверх записанных ответов. По умолчанию — то, что записано:
/// список задач сида, главная, справочники; бланки и поручения тест заводит сам
/// ([fills], [simple]).
class FakePulseServer {
  FakePulseServer({String baseUrl = 'http://test.local:9080'})
      : settings = Settings(baseUrl: baseUrl) {
    final me = fixtureMap('apiCurrentUser');
    session = Session(
      login: 'fake${_seq++}',
      name: 'Тестовый исполнитель',
      token: 'token',
      signedIn: true,
      performerId: '${me['id']}',
    );
    api = ApiClient(settings, session, client: MockClient(_handle));
  }

  static int _seq = 0;

  final Settings settings;
  late final Session session;
  late final ApiClient api;

  /// Каждый запрос по порядку — имя ручки, в том числе не дошедший без сети.
  final calls = <String>[];

  /// Принятые сервером тела POST по ручкам.
  final posted = <String, List<Map<String, dynamic>>>{};

  /// Сети нет: любой запрос падает обрывом.
  bool offline = false;

  /// Ответ ручки целиком вместо правил: (статус, тело).
  final replies = <String, (int, Object?)>{};

  List<Map<String, dynamic>> tasks = fixtureList('apiTasks');
  Map<String, dynamic> home = fixtureMap('apiHome');
  final fills = <String, FakeFill>{};

  /// Последняя завершённая проверка объекта (адресация `objectId`) и прошлая проверка
  /// к задаче (`prev`): тот же агрегат, что у бланка.
  final pastByObject = <String, FakeFill>{};
  final pastByTask = <String, FakeFill>{};
  final simple = <String, Map<String, dynamic>>{};
  final comments = <String, List<Map<String, dynamic>>>{};

  List<Map<String, dynamic>> postsOf(String action) => posted[action] ?? const [];

  Map<String, dynamic> task(String id) => tasks.firstWhere((t) => t['id'] == id);

  Future<http.Response> _handle(http.Request r) async {
    final a = actionOf(r);
    calls.add(a);
    if (offline) throw const SocketException('нет сети');
    final canned = replies[a];
    if (canned != null) return _reply(canned.$1, canned.$2);
    if (r.method == 'POST') {
      final body = r.body.isEmpty
          ? <String, dynamic>{}
          : (jsonDecode(r.body) as Map).cast<String, dynamic>();
      final refusal = _write(a, body);
      if (refusal != null) return refusal;
      (posted[a] ??= []).add(body);
      return http.Response('', 200);
    }
    return _reply(200, _read(a, r.url.queryParameters));
  }

  /// Заполнение по тройке адресации читающих ручек бланка: задача, прошлая к ней,
  /// объект.
  FakeFill? _addressed(Map<String, String> q) => q['objectId'] != null
      ? pastByObject[q['objectId']]
      : q['prev'] != null
          ? pastByTask[q['id']]
          : fills[q['id']];

  Object? _read(String a, Map<String, String> q) {
    final id = q['id'];
    switch (a) {
      case 'apiTasks':
        if (q['archive'] != null) return const [];
        final one = q['taskId'];
        return one == null ? tasks : [for (final t in tasks) if (t['id'] == one) t];
      case 'apiHome':
        return home;
      case 'apiExecutionBundle':
        final f = _addressed(q);
        // выполнения нет — 6.2 отвечает одной шапкой
        if (f == null || !f.started) return fixture('apiExecutionBundle_unstarted');
        return {
          'info': f.info,
          'fields': f.fields,
          'options': f.options,
          'columns': f.columns,
          'rows': f.rows,
        };
      case 'apiExecutionInfo':
        final f = _addressed(q);
        if (f == null || !f.started) {
          return fixtureMap('apiExecutionBundle_unstarted')['info'];
        }
        return f.info;
      case 'apiSimpleInfo':
        return simple[id] ?? const {};
      case 'apiTaskComments':
        return comments[id] ?? const [];
      case 'apiCurrentUser':
      case 'apiStatuses':
      case 'apiQuickActions':
      case 'apiTemplates':
      case 'apiPerformers':
      case 'apiNotifications':
      case 'apiRowSubjects':
        return fixture(a);
      default:
        return const [];
    }
  }

  /// Мутация по правилам сервера; отказ — ответом, принятая — null.
  http.Response? _write(String a, Map<String, dynamic> b) {
    final id = '${b['id']}';
    switch (a) {
      case 'apiStartExecution':
        final f = fills[id];
        if (f != null && !f.finished) f.started = true;
      case 'apiFinishExecution':
        final f = fills[id];
        if (f != null) {
          if (f.finished) return _refusal('refusal_after_finish');
          f.finished = true;
        }
      case 'apiSetField':
        return _setField(id, b);
      case 'apiStartSimple':
        (simple[id] ??= {})['started'] = true;
      case 'apiSetSimpleComment':
        (simple[id] ??= {})['comment'] = b['comment'];
      case 'apiFinishSimple':
        (simple[id] ??= {})['finished'] = true;
      case 'apiAddTaskComment':
        final list = comments[id] ??= [];
        list.add({
          'id': 2001 + list.length,
          'clientId': b['clientId'],
          'text': b['text'],
          'dateTime': DateTime.now().toIso8601String().substring(0, 19),
          'mine': true,
        });
    }
    return null;
  }

  http.Response? _setField(String id, Map<String, dynamic> b) {
    final fill = fills[id];
    if (fill == null) return null;
    if (fill.finished) return _refusal('refusal_after_finish');
    // выполнения нет — писать некуда: сервер молча ничего не делает
    if (!fill.started) return null;
    final f = fill.field('${b['field']}');
    final type = '${f['type']}';
    final number = b['number'] as num?;
    if (type == 'score' &&
        number != null &&
        (number < 0 || number > ((f['weight'] as num?) ?? 0))) {
      return _refusal('refusal_score_over_max');
    }
    final slot = _slotOfType[type];
    if (slot != null) f[slot.$1] = b[slot.$2];
    // поле-ссылка: ссылка по id кандидата и снимок имени — в ответе ключ ref
    if (type == 'objectref') {
      f['refId'] = b['refId'];
      f['ref'] = b['refName'];
    }
    // примечание пишется каждой записью: нет ключа — нет примечания
    f['comment'] = b['comment'];
    return null;
  }

  http.Response _refusal(String name) {
    final r = fixtureMap(name);
    return _reply(r['status'] as int, r['body']);
  }

  /// Тело — как у lsFusion: JSON в UTF-8, без NULL, пустых строк и false.
  http.Response _reply(int status, Object? body) => http.Response.bytes(
      utf8.encode(body is String ? body : jsonEncode(_exported(body))), status,
      headers: {'content-type': 'application/json; charset=utf-8'});
}

/// Что сервер выгрузил бы из этого значения: NULL, пустая строка и BOOLEAN false
/// ключа не дают.
Object? _exported(Object? v) {
  if (v is Map) {
    return {
      for (final e in v.entries)
        if (_kept(e.value)) '${e.key}': _exported(e.value)
    };
  }
  if (v is List) return [for (final e in v) _exported(e)];
  return v;
}

bool _kept(Object? v) => v != null && v != false && v != '';
