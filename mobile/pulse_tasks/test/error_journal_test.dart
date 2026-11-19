import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/error_journal.dart';
import 'package:pulse_tasks/data/local_db.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'support/test_env.dart';

/// Журнал ошибок приложения: записи на устройстве и их отправка на сервер
/// (apiClientErrors). Настоящий sqlite (ffi): склейка и предел журнала — запросы
/// к таблице, мок их не проверил бы.

int _seq = 0;

Future<LocalDb> _openDb() async => LocalDb.open('tjournal_${_seq++}');

/// Одна и та же ошибка из одного места — со стеком, как её отдаёт исполняющая среда.
void _same() {
  try {
    throw const FormatException('поле fields — не список');
  } catch (e, stack) {
    ErrorJournal.record(e, stack, kind: ErrorJournal.call, where: 'fill:ST1');
  }
}

void main() {
  initTestEnv();

  setUp(() {
    resetMockStores();
    ErrorJournal.reset();
  });

  test('одна ошибка много раз — одна запись с числом повторов', () async {
    final db = await _openDb();
    await ErrorJournal.attach(db);

    for (var i = 0; i < 3; i++) {
      _same();
    }
    ErrorJournal.record(StateError('другое'), null, kind: ErrorJournal.platform);
    await ErrorJournal.flushed();

    final rows = await db.errors.oldest(10);
    expect(rows, hasLength(2));
    final same = rows.firstWhere((r) => r['kind'] == 'call');
    expect(same['count'], 3);
    expect(same['place'], 'fill:ST1');
    expect(same['message'] as String, contains('поле fields — не список'));
    expect(same['stack'] as String, isNotEmpty);
    expect(same['at'] as String, matches(RegExp(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d$')),
        reason: 'провод серверного DATETIME — без дробной части');
    await db.close();
  });

  test('до входа ошибки ждут в памяти и ложатся в базу вошедшего', () async {
    ErrorJournal.record(StateError('при запуске'), null,
        kind: ErrorJournal.flutter);
    final db = await _openDb();
    expect(await db.errors.count(), 0);

    await ErrorJournal.attach(db);

    expect(await db.errors.count(), 1);
    await db.close();
  });

  test('журнал ограничен: старые записи уходят первыми', () async {
    final db = await _openDb();
    for (var i = 0; i < ErrorsDao.cap + 5; i++) {
      await db.errors.add(
          id: 'e$i',
          sig: 's$i',
          atIso: '2026-11-19T10:${(i ~/ 60).toString().padLeft(2, '0')}:'
              '${(i % 60).toString().padLeft(2, '0')}',
          kind: 'sync',
          message: 'm$i');
    }
    expect(await db.errors.count(), ErrorsDao.cap);
    final oldest = await db.errors.oldest(1);
    expect(oldest.single['id'], 'e5');
    await db.close();
  });

  group('отправка', () {
    late List<http.Request> posts;
    late http.Response Function() answer;

    ApiClient api() => ApiClient(
        Settings(baseUrl: 'http://test.local:9080'),
        Session(
            login: 'ivanov${_seq++}',
            name: 'Иванов',
            token: 'token',
            signedIn: true,
            performerId: 'p1'),
        client: MockClient((request) async {
          posts.add(request);
          return answer();
        }));

    setUp(() {
      posts = [];
      answer = () => http.Response('', 200);
    });

    test('пачка уходит одним запросом и снимается с телефона', () async {
      final db = await _openDb();
      await ErrorJournal.attach(db);
      _same();
      _same();
      ErrorJournal.record(StateError('другое'), null, kind: ErrorJournal.sync);

      await ErrorJournal.upload(api());

      expect(posts, hasLength(1));
      expect(posts.single.url.path, endsWith('/exec/StoreTask.apiClientErrors'));
      final body = (jsonDecode(posts.single.body) as List).cast<Map>();
      expect(body, hasLength(2));
      final same = body.firstWhere((e) => e['kind'] == 'call');
      expect(same['count'], 2);
      expect(same['where'], 'fill:ST1');
      expect(same['id'], isA<String>());
      expect(same['at'], isA<String>());
      expect(same['device'], contains(Platform.operatingSystem));
      expect(await db.errors.count(), 0);

      // пусто — и запроса нет
      await ErrorJournal.upload(api());
      expect(posts, hasLength(1));
      await db.close();
    });

    test('сервер без ручки (404) — записи остаются, больше не спрашиваем', () async {
      final db = await _openDb();
      await ErrorJournal.attach(db);
      _same();
      answer = () => http.Response.bytes(
          utf8.encode('lsfusion.server.logics.action.flow.LSFStatusException '
              'Action StoreTask.apiClientErrors was not found'),
          404);

      await ErrorJournal.upload(api());
      await ErrorJournal.upload(api());

      expect(posts, hasLength(1));
      expect(await db.errors.count(), 1);
      await db.close();
    });

    test('обрыв связи — записи ждут следующей синхронизации', () async {
      final db = await _openDb();
      await ErrorJournal.attach(db);
      _same();
      answer = () => throw const SocketException('нет сети');

      await ErrorJournal.upload(api());
      expect(await db.errors.count(), 1);

      answer = () => http.Response('', 200);
      await ErrorJournal.upload(api());
      expect(posts, hasLength(2));
      expect(await db.errors.count(), 0);
      await db.close();
    });
  });
}
