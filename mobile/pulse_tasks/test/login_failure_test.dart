import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pulse_tasks/app_controllers.dart';
import 'package:pulse_tasks/data/account_controller.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/main.dart';

import 'support/test_env.dart';

/// Экран входа объясняет словами, что по адресу из настроек не тот сервер. Раньше отказ
/// доходил сырым: путь мимо сервера на стенде — «Сервер ответил ошибкой: HTTP ERROR 404
/// Not Found», страница прокси или чужого веб-сервера — «…: <html>» (из тела бралась
/// первая строка разметки). Тела здесь — те, какими отвечают на самом деле: Jetty
/// стенда подбирает страницу ошибки под Accept и выдаче токена отдаёт текст; nginx
/// отвечает разметкой, что бы ни просили; lsFusion на ручку, которой у него нет, —
/// текстом исключения, но с Content-Type text/html.
void main() {
  initTestEnv();

  setUp(resetMockStores);

  const notOurServer =
      'По адресу из настроек отвечает не сервер задач — проверьте адрес';

  http.Response reply(int status, String body, String contentType) =>
      http.Response.bytes(utf8.encode(body), status,
          headers: {'content-type': contentType});

  /// Отказ Jetty стенда на запрос с Accept: text/plain — так просит выдача токена.
  http.Response jetty(int status, String reason, String uri, String servlet) =>
      reply(
          status,
          'HTTP ERROR $status $reason\nURI: $uri\r\nSTATUS: $status\r\n'
          'MESSAGE: $reason\r\nSERVLET: $servlet\r\n',
          'text/plain;charset=iso-8859-1');

  /// Страница nginx: прокси и чужие веб-серверы отвечают разметкой, что бы клиент ни
  /// просил.
  http.Response nginx(int status, String reason) => reply(
      status,
      '<html>\r\n<head><title>$status $reason</title></head>\r\n<body>\r\n'
      '<center><h1>$status $reason</h1></center>\r\n'
      '<hr><center>nginx</center>\r\n</body>\r\n</html>\r\n',
      'text/html');

  /// Отказ lsFusion — текст исключения, и тоже как text/html.
  http.Response lsfusion(int status, String exception) => reply(
      status,
      'lsfusion.interop.base.exception.RemoteInternalException '
      'Внутренняя ошибка сервера: $exception\n\n'
      '\tat lsfusion.server.physics.admin.authentication.controller.remote.'
      'RemoteConnection.lambda\$0',
      'text/html;charset=utf-8');

  /// Приложение, у которого адрес из настроек на выдачу токена отвечает [token], а
  /// на профиль — [profile].
  AppControllers app(http.Response token, {http.Response? profile}) {
    final settings = Settings(baseUrl: 'http://10.0.0.1:9080');
    final session = Session();
    final api = ApiClient(settings, session,
        client: MockClient((request) async =>
            switch (request.url.pathSegments.last) {
              'Authentication.getAuthToken' => token,
              'StoreTask.apiCurrentUser' => profile ?? http.Response('[]', 200),
              _ => http.Response('{}', 200),
            }));
    return AppControllers(api: api, settings: settings, session: session);
  }

  /// Чем кончился вход: текст, который увидит человек.
  Future<String> failure(AppControllers app) async {
    try {
      await app.account.signIn('ivanov', 'secret');
    } on LoginException catch (e) {
      return e.message;
    }
    fail('вход прошёл');
  }

  final wrongPath = jetty(404, 'Not Found',
      '/storetask/exec/Authentication.getAuthToken', 'default');

  group('адрес ведёт не к серверу задач', () {
    test('путь мимо сервера на стенде — в настройки, а не «HTTP ERROR 404»',
        () async {
      expect(await failure(app(wrongPath)), notOurServer);
    });

    test('чужой веб-сервер — страница 404 — туда же', () async {
      expect(await failure(app(nginx(404, 'Not Found'))), notOurServer);
    });

    test('сервер без модуля задач: токен выдал, профиля нет', () async {
      expect(
          await failure(app(http.Response('token', 200),
              profile: lsfusion(
                  404,
                  'lsfusion.server.logics.action.flow.LSFStatusException '
                      'Action StoreTask.apiCurrentUser was not found'))),
          notOurServer);
    });

    test('прокси, за которым сервер лежит, — код вместо разметки', () async {
      expect(await failure(app(nginx(502, 'Bad Gateway'))),
          'Сервер ответил ошибкой: HTTP 502');
    });
  });

  group('прочие отказы не задеты', () {
    test('неверный пароль узнаётся по коду', () async {
      expect(
          await failure(app(jetty(401, 'Unauthorized',
              '/exec/Authentication.getAuthToken', 'externalHandler'))),
          'Неверный логин или пароль');
    });

    test('отказ, написанный сервером для человека, доходит как был', () async {
      // text/html и у него: страница узнаётся по телу, а не по заголовку
      expect(
          await failure(app(lsfusion(
              500,
              'lsfusion.server.logics.action.flow.LSFException '
                  'База данных недоступна'))),
          'Сервер ответил ошибкой: База данных недоступна');
    });
  });

  test('страница отказа не доходит до текста ни одного экрана', () {
    expect(
        () => ApiClient(Settings(), Session()).check(nginx(502, 'Bad Gateway')),
        throwsA(isA<ApiException>()
            .having((e) => e.message, 'message', 'HTTP 502')
            .having((e) => e.status, 'status', 502)));
  });

  testWidgets('на экране входа — слова вместо «HTTP ERROR 404»', (tester) async {
    await tester.pumpWidget(PulseApp(app: app(wrongPath)));
    await tester.pumpAndSettle();
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'ivanov');
    await tester.enterText(fields.at(1), 'secret');
    await tester.tap(find.text('Войти'));
    await tester.pumpAndSettle();

    expect(find.text(notOurServer), findsOneWidget);
    expect(find.textContaining('HTTP ERROR'), findsNothing);
    expect(find.textContaining('Сервер ответил ошибкой'), findsNothing);
  });
}
