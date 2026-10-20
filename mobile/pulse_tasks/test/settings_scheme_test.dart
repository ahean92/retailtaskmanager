import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pulse_tasks/app_controllers.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/ui/settings_screen.dart';

import 'support/fake_server.dart';
import 'support/test_env.dart';

/// Протокол сервера — выбор сегмента на экране настроек, а не догадка по адресу
/// (https-сервер получал подставленный http:// и не отвечал). Здесь записано:
/// сегмент доезжает и до пробы «Проверить подключение», и до сохранённого адреса;
/// схема, напечатанная в поле по привычке старой версии, уезжает в сегмент, а не
/// теряется и не удваивается.
void main() {
  initTestEnv();

  setUp(resetMockStores);

  Future<AppControllers> boot(WidgetTester tester, Settings settings) async {
    final session = Session(
        login: 'ivanov',
        name: 'Иванов И.И.',
        token: 'jwt',
        performerId: 'p1',
        signedIn: true,
        lastContact: DateTime.now());
    final app = AppControllers(
        api: ApiClient(settings, session),
        settings: settings,
        session: session);
    await tester.pumpWidget(MultiProvider(
        providers: app.providers,
        child: const MaterialApp(home: SettingsScreen())));
    return app;
  }

  /// Проба, запоминающая, куда её звонили.
  http.Client probe(List<http.Request> seen) => MockClient((request) async {
        seen.add(request);
        return okJson('[{"name":"Демо"}]');
      });

  testWidgets('сегмент https доезжает и до пробы, и до сохранённого адреса',
      (tester) async {
    final settings = Settings(baseUrl: 'http://test.local:9080');
    final app = await boot(tester, settings);

    await tester.enterText(find.byType(TextFormField), 'demo.example.com');
    await tester.tap(find.text('https'));
    await tester.pump();

    final seen = <http.Request>[];
    await http.runWithClient(() async {
      await tester.tap(find.text('Проверить подключение'));
      await tester.pumpAndSettle();
    }, () => probe(seen));

    expect(seen.single.url.toString(),
        'https://demo.example.com/exec/StoreTask.apiBrand');
    expect(find.text('Сервер отвечает: Демо'), findsOneWidget);

    await http.runWithClient(() async {
      await tester.tap(find.text('Сохранить'));
      await tester.pumpAndSettle();
    }, () => probe(seen));

    final sp = await SharedPreferences.getInstance();
    expect(sp.getString('baseUrl'), 'https://demo.example.com');
    expect(app.settings.baseUrl, 'https://demo.example.com',
        reason: 'живой объект настроек переезжает на новый адрес');
  });

  testWidgets('дефолт — http: голый host:port звонится по http', (tester) async {
    final settings = Settings(baseUrl: 'http://test.local:9080');
    await boot(tester, settings);

    await tester.enterText(find.byType(TextFormField), 'demo.example.com:9080');

    final seen = <http.Request>[];
    await http.runWithClient(() async {
      await tester.tap(find.text('Проверить подключение'));
      await tester.pumpAndSettle();
    }, () => probe(seen));

    expect(seen.single.url.toString(),
        'http://demo.example.com:9080/exec/StoreTask.apiBrand');
  });

  testWidgets('схема, напечатанная в поле по привычке, уезжает в сегмент',
      (tester) async {
    final settings = Settings(baseUrl: 'http://test.local:9080');
    await boot(tester, settings);

    await tester.enterText(
        find.byType(TextFormField), 'https://demo.example.com');

    final seen = <http.Request>[];
    await http.runWithClient(() async {
      await tester.tap(find.text('Проверить подключение'));
      await tester.pumpAndSettle();
    }, () => probe(seen));

    expect(seen.single.url.toString(),
        'https://demo.example.com/exec/StoreTask.apiBrand');
    expect(find.widgetWithText(TextFormField, 'demo.example.com'), findsOneWidget,
        reason: 'в поле после проверки остаётся только host:port');
  });

  testWidgets('сохранённый https открывает экран с включённым сегментом',
      (tester) async {
    final settings = Settings(baseUrl: 'https://pulse.example.com');
    await boot(tester, settings);

    expect(find.widgetWithText(TextFormField, 'pulse.example.com'), findsOneWidget,
        reason: 'схему из сохранённого адреса поле не показывает');

    final seen = <http.Request>[];
    await http.runWithClient(() async {
      await tester.tap(find.text('Проверить подключение'));
      await tester.pumpAndSettle();
    }, () => probe(seen));

    expect(seen.single.url.toString(),
        'https://pulse.example.com/exec/StoreTask.apiBrand');
  });
}
