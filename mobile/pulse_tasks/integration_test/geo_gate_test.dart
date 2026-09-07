import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pulse_tasks/app_controllers.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/geo.dart';
import 'package:pulse_tasks/data/secure_store.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test/fake_phone.dart';

/// Вход целиком: сервер сказал, работает ли эта учётная запись по местоположению, и от
/// этого зависит, пускает ли гейт. То, что нельзя собрать на хосте, — настоящий вход с
/// открытием базы пользователя и с записью сессии в Keychain/Keystore.
///
/// Поведение самого гейта (четыре причины, экран, кнопки) проверяется без устройства —
/// test/geo_test.dart и test/geo_gate_test.dart.
///
///     flutter test integration_test -d <device>
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const server = 'http://test.local:9080';

  setUp(() async {
    await SecureStore.deleteAll();
    await (await SharedPreferences.getInstance()).clear();
  });

  http.Response json(Object? body) => http.Response(
        jsonEncode(body),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

  /// Сервер, отвечающий ровно то, что нужно входу: токен и профиль. lsFusion не
  /// экспортирует NULL-свойства, поэтому «геолокация не обязательна» — это профиль без
  /// ключа `geoRequired`, а не `geoRequired: false`.
  MockClient serverSaying({required bool geoRequired}) =>
      MockClient((request) async => switch (request.url.path.split('.').last) {
            'getAuthToken' => http.Response('jwt', 200),
            'apiCurrentUser' => json([
                {
                  'login': 'ivanov',
                  'name': 'Иванов И.И.',
                  'id': 'p1',
                  if (geoRequired) 'geoRequired': true,
                }
              ]),
            _ => json(const []),
          });

  Future<AppControllers> signIn(
      {required bool geoRequired, required FakePhone phone}) async {
    final settings = Settings(baseUrl: server);
    await settings.save();
    final session = Session();
    final app = AppControllers(
      api: ApiClient(settings, session,
          client: serverSaying(geoRequired: geoRequired)),
      settings: settings,
      session: session,
      geo: Geo(platform: phone),
    );
    await app.account.signIn('ivanov', 'secret');
    expect(app.session.isActive, isTrue, reason: 'вход не состоялся');
    return app;
  }

  testWidgets('вошедшего не пускают внутрь, пока не известно, где он',
      (tester) async {
    final phone = FakePhone(granted: GeoPermission.denied);
    final app = await signIn(geoRequired: true, phone: phone);

    expect(app.session.geoRequired, isTrue);
    expect(app.location.geoReady, isFalse, reason: 'вход состоялся, гейт — нет');

    // разрешение выдали — координаты уходят в сессию и переживают перезапуск
    phone
      ..granted = GeoPermission.granted
      ..measured = fixAt(lat: 53.9006);
    expect(await app.location.locate(), isA<GeoFix>());
    expect(app.location.geoReady, isTrue);
    expect((await Session.load()).latitude, 53.9006);

    await app.account.signOut();
  });

  testWidgets('роли, которой геопривязка не нужна, гейт не выставляют',
      (tester) async {
    // на телефоне при этом всё против: геолокация выключена, доступ запрещён навсегда
    final phone =
        FakePhone(services: false, granted: GeoPermission.deniedForever);
    final app = await signIn(geoRequired: false, phone: phone);

    expect(app.session.geoRequired, isFalse);
    expect(app.location.geoReady, isTrue);
    expect(phone.asked, 0, reason: 'разрешение даже не спрашивали');

    await app.account.signOut();
  });
}
