import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pulse_tasks/app_controllers.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/connection_failure.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/main.dart';

import 'support/test_env.dart';

/// «Проверить подключение» объясняет недоступный сервер словами, а не строкой
/// исполняющей среды: на экран выходило «Ошибка: TimeoutException after
/// 0:00:10.000000: Future not completed». Исключения здесь — той формы, в какой они
/// приходят на Android (сняты на эмуляторе настоящим fetchBrand).
void main() {
  initTestEnv();

  setUp(resetMockStores);

  /// Чем упадёт fetchBrand, если сервер ответит [response].
  Future<Object> brandFailure(http.Response response) async {
    final api = ApiClient(Settings(baseUrl: 'http://10.0.0.1:9080'), Session(),
        client: MockClient((_) async => response));
    try {
      await api.fetchBrand();
    } catch (e) {
      return e;
    }
    fail('fetchBrand не упал на ${response.statusCode}');
  }

  group('разбор неудачи', () {
    test('таймаут — «сервер не отвечает» и куда смотреть', () {
      final f = connectionFailure(TimeoutException(
          'Future not completed', const Duration(seconds: 10)));
      expect(f.what, 'Сервер не отвечает');
      expect(f.hint, contains('в одной ли сети'));
    });

    test('в подсети по адресу никого — то же, что таймаут', () {
      final f = connectionFailure(const SocketException('No route to host',
          osError: OSError('No route to host', 113)));
      expect(f.what, 'Сервер не отвечает');
    });

    test('закрытый порт — про порт', () {
      const refused = OSError('Connection refused', 111);
      final f = connectionFailure(
          const SocketException('Connection refused', osError: refused));
      expect(f.what, 'На этом порту сервер не работает');
      expect(f.hint, contains(':9080'));
      // iOS: тот же отказ под своим номером
      expect(
          connectionFailure(const SocketException('Connection refused',
                  osError: OSError('Connection refused', 61)))
              .what,
          f.what);
    });

    test('имя не находится — про опечатку и про сеть', () {
      final f = connectionFailure(const SocketException(
          "Failed host lookup: 'pulse.invalid'",
          osError: OSError('No address associated with hostname', 7)));
      expect(f.what, 'Сервер с таким именем не найден');
      expect(f.hint, allOf(contains('опечатки'), contains('сеть')));
    });

    test('телефон без сети — включить сеть', () {
      final f = connectionFailure(const SocketException('Connection failed',
          osError: OSError('Network is unreachable', 101)));
      expect(f.what, 'Телефон не подключён к сети');
      expect(f.hint, contains('Wi-Fi'));
    });

    test('чужой сервис: страница, 404, сброс, обрыв заголовков', () async {
      final page = await brandFailure(http.Response(
          '<!DOCTYPE HTML>\n<html><body>Router</body></html>', 200));
      final missing = await brandFailure(
          http.Response('Action StoreTask.apiBrand was not found', 404));
      final notFound = await brandFailure(
          http.Response('<!DOCTYPE HTML>\n<html>404</html>', 404));
      for (final e in [
        page,
        missing,
        notFound,
        // не-HTTP-сервис принимает соединение и бросает — голым OSError
        const OSError('Connection reset by peer', 104),
        http.ClientException(
            'Connection closed before full header was received'),
      ]) {
        expect(connectionFailure(e).what,
            'По этому адресу отвечает не сервер задач',
            reason: '$e');
      }
    });

    test('сервер ответил 5xx — адрес верный, дело в сервере', () async {
      final f = connectionFailure(
          await brandFailure(http.Response('Bad gateway', 503)));
      expect(f.what, 'Сервер ответил ошибкой (код 503)');
      expect(f.hint, contains('Адрес верный'));
    });

    test('https на http-порт — про начало адреса', () {
      final f = connectionFailure(
          const HandshakeException('Handshake error in client'));
      expect(f.what, 'Не удалось установить защищённое соединение');
      expect(f.hint, contains('https://'));
    });

    test('неизвестная причина — всё равно по-людски', () {
      final f = connectionFailure(StateError('boom'));
      expect(f.what, 'Не удалось подключиться к серверу');
    });

    test('ни в одном тексте нет строки исполняющей среды', () {
      for (final e in <Object>[
        TimeoutException('Future not completed', const Duration(seconds: 10)),
        const SocketException('x', osError: OSError('y', 111)),
        const SocketException('x', osError: OSError('y', 999)),
        const OSError('Connection reset by peer', 104),
        const FormatException('Unexpected character (at character 1)'),
        ApiException('<!DOCTYPE HTML>', status: 404),
        ApiException('java.lang.NullPointerException', status: 500),
        const HandshakeException('Handshake error in client'),
        ArgumentError('Invalid port 90800'),
      ]) {
        final f = connectionFailure(e);
        for (final text in [f.what, f.hint]) {
          expect(text, isNot(matches(r'Exception|Error|errno|<')),
              reason: '$e');
        }
      }
    });
  });

  group('адрес до запроса', () {
    test('набираемые адреса проходят', () {
      for (final url in [
        'http://192.168.1.10:9080',
        'http://10.0.2.2:9080/',
        'https://pulse.example.com',
      ]) {
        expect(addressFailure(url), isNull, reason: url);
      }
    });

    test('опечатка в адресе ловится без сети', () {
      for (final raw in [
        '192.168.1.10 9080', // пробел вместо двоеточия
        '10.0.2.2:90800', // лишняя цифра в порту
        '192.168.1.10:abc',
        'сервер.local:9080', // кириллица в имени
        ':9080',
        'htp://192.168.1.10:9080',
      ]) {
        expect(addressFailure(Settings.normalizeUrl(raw))?.what,
            'Адрес записан с ошибкой',
            reason: raw);
      }
    });
  });

  group('на экране настроек', () {
    /// Сеть без сервера задач: соединение кончается тем, чем кончится [connect].
    /// Подменяется HttpClient под package:http, так что исключение оборачивает сам
    /// пакет — как на телефоне. Возвращает адреса, куда пытались соединиться.
    List<Uri> noServer(Future<HttpClientRequest> Function() connect) {
      final dialled = <Uri>[];
      final previous = HttpOverrides.current;
      HttpOverrides.global = _Network((url) {
        dialled.add(url);
        return connect();
      });
      addTearDown(() => HttpOverrides.global = previous);
      return dialled;
    }

    /// Первый запуск: адреса нет, приложение открывается на настройках.
    Future<void> check(WidgetTester tester, String address) async {
      await tester.pumpWidget(PulseApp(
          app: AppControllers(
              api: ApiClient(Settings(), Session()),
              settings: Settings(),
              session: Session())));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), address);
      await tester.tap(find.text('Проверить подключение'));
      await tester.pump();
    }

    void expectNoRuntimeText() {
      expect(find.textContaining('Exception'), findsNothing);
      expect(find.textContaining('Ошибка:'), findsNothing);
    }

    testWidgets('сервер молчит 10 секунд — объяснение и подсказка',
        (tester) async {
      final dialled = noServer(() => Completer<HttpClientRequest>().future);
      await check(tester, '10.255.255.1:9080');
      expect(dialled, hasLength(1));
      expect(find.text('Сервер не отвечает'), findsNothing,
          reason: 'до таймаута итога ещё нет');

      await tester.pump(const Duration(seconds: 11));
      await tester.pumpAndSettle();
      expect(find.text('Сервер не отвечает'), findsOneWidget);
      expect(find.textContaining('в одной ли сети'), findsOneWidget);
      expectNoRuntimeText();
    });

    testWidgets('закрытый порт — про порт', (tester) async {
      noServer(() async => throw const SocketException('Connection refused',
          osError: OSError('Connection refused', 111)));
      await check(tester, '10.0.2.2:9999');
      await tester.pumpAndSettle();
      expect(find.text('На этом порту сервер не работает'), findsOneWidget);
      expectNoRuntimeText();
    });

    testWidgets('адрес с опечаткой в сеть не уходит', (tester) async {
      final dialled = noServer(() => Completer<HttpClientRequest>().future);
      await check(tester, '192.168.1.10 9080');
      await tester.pumpAndSettle();
      expect(find.text('Адрес записан с ошибкой'), findsOneWidget);
      expect(dialled, isEmpty);
      expectNoRuntimeText();
    });
  });
}

class _Network extends HttpOverrides {
  _Network(this.connect);
  final Future<HttpClientRequest> Function(Uri url) connect;

  @override
  HttpClient createHttpClient(SecurityContext? context) => _Client(connect);
}

class _Client extends Fake implements HttpClient {
  _Client(this.connect);
  final Future<HttpClientRequest> Function(Uri url) connect;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) => connect(url);

  @override
  void close({bool force = false}) {}
}
