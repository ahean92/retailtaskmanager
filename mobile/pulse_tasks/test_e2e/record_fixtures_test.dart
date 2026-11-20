// Запись настоящих ответов сервера 6.2 в test/fixtures: заглушка модульных тестов
// (test/support/fake_pulse_server.dart) строит ответы из этих файлов, поэтому изменение
// формы ответа на сервере видно обновлением файлов — diff по test/fixtures, — а не
// случайным падением в поле.
//
// Работает только при записи: scripts/record-client-fixtures.ps1 поднимает свой 6.2 и
// передаёт сюда FIXTURES_OUT — каталог test/fixtures. В обычном прогоне сквозного набора
// этот файл пропускается целиком. Данные — сид набора (seed_e2e.lsf), клиент — тот же
// ApiClient, что у телефона. Заодно проверяются правила сервера, которые заглушка
// повторяет: стирание примечания без ключа comment, отказ записи после завершения,
// предел балла.
//
// Ответы нормализуются, чтобы повторная запись меняла файл только вместе с формой:
// даты и время — одни и те же, числовые id объектов — по порядку появления в файле,
// логины прогона — без отметки времени, ключи объектов — по алфавиту.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';

import 'support/e2e.dart';

final String? _out = Platform.environment['FIXTURES_OUT'];
final String _admin = Platform.environment['E2E_ADMIN'] ?? 'admin:';

/// Клиент, который запоминает сырой ответ последнего вызова каждой ручки.
class _Tap extends http.BaseClient {
  final _inner = http.Client();
  final last = <String, http.Response>{};

  @override
  Future<http.StreamedResponse> send(http.BaseRequest r) async {
    r.headers.removeWhere((k, _) => k.toLowerCase() == 'authorization');
    r.headers['authorization'] = 'Basic ${base64Encode(utf8.encode(_admin))}';
    final full = await http.Response.fromStream(await _inner.send(r));
    last[r.url.path.split('.').last] = full;
    return http.StreamedResponse(Stream.value(full.bodyBytes), full.statusCode,
        headers: full.headers, request: r);
  }
}

/// Ключи с числовыми id объектов базы: в новой базе каждого прогона они другие.
const _idKeys = {
  'id', 'performerId', 'assigneeId', 'authorId', 'takenById', 'acceptorId',
  'executorId', 'fileId', 'photoId', 'decidedById', 'userId', 'chatId', 'peerId',
  'objectId', 'placeId', 'unitId', 'cursor', 'messageId', 'replyTo',
};

/// Значения, которые меняются от прогона к прогону сами по себе.
const _volatileKeys = {'catalogVersion', 'appVersion', 'version', 'token'};

final _dateTime = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})(?:([T ])(\d{2}):(\d{2})(?::(\d{2})(\.\d+)?)?)?$');
final _runLogin = RegExp(r'zzz-e2e-(author|second)-\d+');

class _Normalizer {
  final _ids = <String, Object>{};
  var _next = 1001;

  Object? walk(Object? v, [String? key]) {
    if (v is Map) {
      final keys = v.keys.map((k) => '$k').toList()..sort();
      return {for (final k in keys) k: walk(v[k], k)};
    }
    if (v is List) return [for (final e in v) walk(e, key)];
    if (key != null && _volatileKeys.contains(key) && v != null) {
      return v is num ? 1 : 'v';
    }
    if (key != null && _idKeys.contains(key) && v != null) {
      final s = '$v';
      if (RegExp(r'^\d+$').hasMatch(s)) {
        final n = _ids.putIfAbsent(s, () => _next++);
        return v is num ? n : '$n';
      }
    }
    if (v is String) {
      final m = _dateTime.firstMatch(v);
      if (m != null) {
        final sep = m.group(4);
        if (sep == null) return '2026-01-15';
        final sec = m.group(7) == null ? '' : ':00${m.group(8) == null ? '' : '.000'}';
        return '2026-01-15${sep}10:00$sec';
      }
      return v.replaceAllMapped(_runLogin, (m) => 'zzz-e2e-${m.group(1)}');
    }
    return v;
  }
}

String _pretty(Object? v) =>
    '${const JsonEncoder.withIndent('  ').convert(_Normalizer().walk(v))}\n';

void _save(String name, Object? json) =>
    File('$_out${Platform.pathSeparator}$name.json').writeAsStringSync(_pretty(json));

Object? _body(http.Response r) {
  final text = utf8.decode(r.bodyBytes, allowMalformed: true).trim();
  if (text.isEmpty) return null;
  try {
    return jsonDecode(text);
  } on FormatException {
    return text;
  }
}

void main() {
  setUpAll(() async {
    if (_out != null) await e2eSetUp();
  });
  tearDownAll(() async {
    if (_out != null) await e2eTearDown();
  });

  test('ответы сервера — в test/fixtures', () async {
    final tap = _Tap();
    final api = ApiClient(Settings(baseUrl: e2eBase),
        Session(login: 'fixtures', token: 't', signedIn: true),
        client: tap);
    Future<void> rec(String action, String name, Future<void> Function() call) async {
      await call();
      _save(name, _body(tap.last[action]!));
    }

    /// Отказ по существу: статус и тело — как их увидит телефон.
    Future<void> refusal(String action, String name, Future<void> Function() call) async {
      try {
        await call();
        fail('$action: сервер принял то, что должен был отклонить ($name)');
      } on ApiException {
        final r = tap.last[action]!;
        var body = _body(r);
        // таблица констрейнта в тексте отказа несёт id объектов базы прогона
        if (body is String) {
          body = body.replaceAllMapped(
              RegExp(r'\|(\s*)\d{3,}(?=\|)'), (m) => '|${m.group(1)}1000');
        }
        _save(name, {'status': r.statusCode, 'body': body});
      }
    }

    // справочники и список
    await rec('apiCurrentUser', 'apiCurrentUser', api.fetchCurrentUser);
    await rec('apiStatuses', 'apiStatuses', api.fetchStatuses);
    await rec('apiTasks', 'apiTasks', api.fetchTasks);
    await rec('apiHome', 'apiHome', () => api.fetchHome());
    await rec('apiQuickActions', 'apiQuickActions', api.fetchQuickActionsRaw);
    await rec('apiTemplates', 'apiTemplates', api.fetchTemplatesRaw);
    await rec('apiPerformers', 'apiPerformers', api.fetchPerformersRaw);

    // бланк всех типов: до старта агрегат несёт только шапку
    await rec('apiExecutionBundle', 'apiExecutionBundle_unstarted',
        () => api.fetchExecutionBundle('ZZZ-E2E-TYPES'));
    await api.startExecution('ZZZ-E2E-TYPES');
    await api.setField('ZZZ-E2E-TYPES', 't1', text: 'текст');
    await api.setField('ZZZ-E2E-TYPES', 'l1', text: 'длинный\nтекст');
    await api.setField('ZZZ-E2E-TYPES', 'n1', number: 7.5);
    await api.setField('ZZZ-E2E-TYPES', 'b1', boolVal: true);
    await api.setField('ZZZ-E2E-TYPES', 'c1', optionCode: 'good');
    await api.setField('ZZZ-E2E-TYPES', 'd1', date: '2026-11-20');
    await api.setField('ZZZ-E2E-TYPES', 's1', number: 4, comment: 'примечание');
    await api.setField('ZZZ-E2E-TYPES', 'k1', text: '4810000000001');
    await api.addRow('ZZZ-E2E-TYPES', 'tab', 'row-1', subjectName: 'позиция');
    await api.setCell('ZZZ-E2E-TYPES', 'tab', 'row-1', 'qty', number: 3);
    await api.setCell('ZZZ-E2E-TYPES', 'tab', 'row-1', 'ser', text: 'A1');
    await api.setCell('ZZZ-E2E-TYPES', 'tab', 'row-1', 'dt', date: '2026-12-31');
    await rec('apiExecutionBundle', 'apiExecutionBundle_filled',
        () => api.fetchExecutionBundle('ZZZ-E2E-TYPES'));
    await rec('apiExecutionInfo', 'apiExecutionInfo',
        () => api.fetchExecutionInfo('ZZZ-E2E-TYPES'));

    // правило 1: ключа comment нет — примечание стирается
    await api.setField('ZZZ-E2E-TYPES', 's1', number: 3);
    final s1 = ((await api.fetchExecutionBundle('ZZZ-E2E-TYPES'))!['fields'] as List)
        .cast<Map>()
        .firstWhere((f) => f['code'] == 's1');
    expect(s1['comment'], isNull,
        reason: 'запись без ключа comment стирает примечание');

    // правило 2: балл выше предела поля не принимается
    await refusal('apiSetField', 'refusal_score_over_max',
        () => api.setField('ZZZ-E2E-TYPES', 's1', number: 99));

    // правило 3: после завершения бланк не пишется
    await api.startExecution('ZZZ-E2E-FIN');
    await api.setField('ZZZ-E2E-FIN', 'f1', text: 'готово');
    await api.finishExecution('ZZZ-E2E-FIN');
    await refusal('apiSetField', 'refusal_after_finish',
        () => api.setField('ZZZ-E2E-FIN', 'f2', text: 'поздно'));

    // поручение
    await api.startSimple('ZZZ-E2E-ISSUE');
    await api.setSimpleComment('ZZZ-E2E-ISSUE', 'сделано');
    await rec('apiSimpleInfo', 'apiSimpleInfo',
        () => api.fetchSimpleInfo('ZZZ-E2E-ISSUE'));

    // поле-ссылка: кандидаты канала и выбранный из них предмет
    await api.startExecution('ZZZ-E2E-REF');
    await rec('apiRowSubjects', 'apiRowSubjects',
        () => api.fetchRowSubjects('ZZZ-E2E-REF', 'r1'));
    final pick = (_body(tap.last['apiRowSubjects']!) as List).cast<Map>().first;
    await api.setField('ZZZ-E2E-REF', 'r1',
        refId: '${pick['subjectId']}', refName: '${pick['name']}');
    final ref = ((await api.fetchExecutionBundle('ZZZ-E2E-REF'))!['fields'] as List)
        .cast<Map>()
        .single;
    expect(ref['refId'], pick['subjectId'],
        reason: 'ссылка нашлась по id кандидата, а не только снимок имени');
    await rec('apiExecutionBundle', 'apiExecutionBundle_ref',
        () => api.fetchExecutionBundle('ZZZ-E2E-REF'));

    // переписка и лента
    await api.addTaskComment({
      'id': 'ZZZ-E2E-OPEN',
      'clientId': '00000000-0000-4000-8000-000000000048',
      'text': 'проверьте ценники',
    });
    await rec('apiTaskComments', 'apiTaskComments',
        () => api.fetchTaskComments('ZZZ-E2E-OPEN'));
    await rec('apiNotifications', 'apiNotifications', api.fetchNotifications);
  }, skip: _out == null ? 'только при записи ответов (FIXTURES_OUT)' : false);
}
