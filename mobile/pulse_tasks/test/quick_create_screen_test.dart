import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:pulse_tasks/app_controllers.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/models/home.dart';
import 'package:pulse_tasks/models/quick_create.dart';
import 'package:pulse_tasks/ui/quick_create_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _errand = QuickPreset(
    code: 'errand', title: 'Поручение', typeId: 'issue', assign: 'pick');

const _data = QuickCreateData(actions: [_errand], performers: [
  Performer(id: 'y', name: 'Свой на объекте', roles: [
    PerformerRole(objectId: 'A', roleId: 'duty'),
  ]),
  Performer(id: 'x', name: 'Чужой с другого объекта', roles: [
    PerformerRole(objectId: 'B', roleId: 'duty'),
  ]),
]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Settings settings;
  late Session session;
  late ApiClient api;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    settings = Settings(baseUrl: 'http://test.local:9080');
    session = Session(
        login: 'executor',
        name: 'Исполнитель',
        token: 'token',
        signedIn: true,
        performerId: 'executor');
    api = ApiClient(settings, session,
        client: MockClient((request) async => http.Response.bytes(
            utf8.encode('[]'), 200,
            headers: {'content-type': 'application/json; charset=utf-8'})));
  });

  Future<AppControllers> appOn(WidgetTester tester, String objectId) async {
    late AppControllers app;
    await tester.runAsync(() async {
      app = AppControllers(api: api, settings: settings, session: session);
      await app.account.updateSettings(settings);
    });
    app.home.layout = HomeLayout.fromJson({
      'objects': [
        {'id': objectId, 'name': 'Объект $objectId'},
      ],
    });
    app.home.quickCreate = _data;
    return app;
  }

  testWidgets('в списке только работающие на объекте задачи', (tester) async {
    final app = await appOn(tester, 'A');
    await tester.pumpWidget(MultiProvider(
      providers: app.providers,
      child: const MaterialApp(home: QuickCreateScreen(preset: _errand)),
    ));
    await tester.pump();

    await tester.tap(find.text('Выбрать исполнителя…'));
    await tester.pumpAndSettle();

    expect(find.text('Свой на объекте'), findsOneWidget);
    expect(find.text('Чужой с другого объекта'), findsNothing);
    await tester.runAsync(() => app.repo.db.close());
  });

  testWidgets('на объекте без исполнителей — предупреждение вместо списка',
      (tester) async {
    final app = await appOn(tester, 'C');
    await tester.pumpWidget(MultiProvider(
      providers: app.providers,
      child: const MaterialApp(home: QuickCreateScreen(preset: _errand)),
    ));
    await tester.pump();

    expect(find.text('На этом объекте нет исполнителей'), findsOneWidget);
    expect(find.text('Выбрать исполнителя…'), findsNothing);
    await tester.runAsync(() => app.repo.db.close());
  });
}
