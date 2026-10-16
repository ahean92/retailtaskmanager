import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/data/task_file_cache.dart';
import 'support/test_env.dart';

/// Стирание недекодируемого файла из кэша снимков (15.10): «Фото недоступно
/// офлайн» означало и «не скачалось», и «скачалось, но байтами не картинка» — на
/// стенде лежал битый JPEG, и кэш, верящий диску слепо, держал его вечно. evict
/// снимает файл, и следующий заход перекачивает. Текстовая пара «офлайн» /
/// «файл повреждён» в task_photo.dart — константы виджетов; их живая проверка —
/// на экране, здесь — механика кэша. Настоящие файлы на диске.

int _seq = 0;

void main() {
  initTestEnv();

  late Directory docs;
  late TaskFileCache cache;
  late List<String> fetched;

  setUp(() {
    resetMockStores();
    docs = Directory.systemTemp.createTempSync('pulse_broken');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => docs.path);
    fetched = [];
    final settings = Settings(baseUrl: 'http://test.local:9080');
    final session = Session(
      login: 'broken${_seq++}',
      name: 'Битый Б.Б.',
      token: 'token',
      signedIn: true,
      performerId: 'p1',
    );
    final api = ApiClient(settings, session, client: MockClient((request) async {
      fetched.add(request.url.queryParameters['id'] ?? '');
      // 200 с байтами, которые картинкой не являются, — сценарий стены: сервер
      // честно отдал то, что лежит в базе
      return http.Response.bytes('это не картинка'.codeUnits, 200,
          headers: {'content-type': 'application/octet-stream'});
    }));
    cache = TaskFileCache(userKey: 'u1', api: api);
  });

  tearDown(() {
    if (docs.existsSync()) docs.deleteSync(recursive: true);
  });

  Future<String> cachedPath(String id, bool thumb) async => p.join(
      (await TaskFileCache.directory('u1')).path,
      'f_$id${thumb ? '_t' : ''}.jpg');

  test('evict: битое стёрто, следующий заход перекачивает, а не берёт с диска',
      () async {
    // скачать «мусор» — как сервер с битым JPEG
    final f = await cache.file('77', thumb: true);
    expect(f, isNotNull);
    expect(fetched, ['77']);
    // повторный заход — с диска: сети нового запроса нет
    await cache.file('77', thumb: true);
    expect(fetched, ['77'], reason: 'кэш на то и кэш');

    await cache.evict('77');
    expect(File(await cachedPath('77', true)).existsSync(), isFalse,
        reason: 'битая миниатюра не переживает стирание');
    expect(File(await cachedPath('77', false)).existsSync(), isFalse,
        reason: 'и полный размер заодно: половинка не нужна');

    // после стирания — снова в сеть
    await cache.file('77', thumb: true);
    expect(fetched, ['77', '77'],
        reason: 'иначе битый файл запирал снимок «офлайном» навсегда');
  });

  test('evict не трогает соседние файлы', () async {
    await cache.file('78', thumb: true);
    await cache.file('77', thumb: true);
    await cache.evict('77');
    expect(File(await cachedPath('78', true)).existsSync(), isTrue);
  });

  test('evict идемпотентен: чистого повторного стирания достаточно', () async {
    await cache.evict('79');
    await cache.evict('79');
    expect(fetched, isEmpty);
  });
}
