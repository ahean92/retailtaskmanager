import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/geo.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/data/task_repository.dart';
import 'package:pulse_tasks/main.dart';
import 'package:pulse_tasks/ui/geo_gate_screen.dart';
import 'package:pulse_tasks/ui/home_screen.dart';

import 'fake_phone.dart';

/// Гейт геолокации: вошедшего дальше не пускают, пока не известно, где он.
///
/// Что проверяется — то, ради чего гейт делался: без разрешения внутрь не попасть, с
/// разрешением координаты оказываются в сессии, а роль, которой геопривязка не нужна,
/// проходит вход вообще без вопросов. Сам поиск координат (порядок вопросов к телефону,
/// послабление про последнюю известную позицию) проверяется в geo_test.dart.

TaskRepository _repo({
  required bool geoRequired,
  required FakePhone phone,
}) {
  final settings = Settings(baseUrl: 'http://test.local:9080');
  final session = Session(
    login: 'ivanov',
    name: 'Иванов И.И.',
    signedIn: true,
    geoRequired: geoRequired,
  );
  return TaskRepository(
    api: ApiClient(settings, session),
    settings: settings,
    session: session,
    geo: Geo(platform: phone),
  );
}

/// Приложение целиком — с маршрутом запуска, который и решает, что человек увидит.
Future<void> _launch(WidgetTester tester, TaskRepository repo) async {
  await tester.pumpWidget(PulseApp(repo: repo));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('при отказе в разрешении в приложение не попасть',
      (tester) async {
    final repo = _repo(
        geoRequired: true, phone: FakePhone(granted: GeoPermission.denied));
    await _launch(tester, repo);

    expect(find.byType(GeoGateScreen), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
    expect(repo.geoReady, isFalse);
    // и уйти с экрана «Повторить» некуда — пропускающей кнопки на нём нет
    expect(find.text('Пропустить'), findsNothing);
  });

  testWidgets('с выданным разрешением координаты попадают в сессию, и это вход',
      (tester) async {
    final repo = _repo(
      geoRequired: true,
      phone: FakePhone(
        granted: GeoPermission.denied,
        afterAsking: GeoPermission.granted,
        measured: fixAt(lat: 53.9),
      ),
    );
    await _launch(tester, repo);

    expect(repo.session.latitude, 53.9);
    expect(repo.session.longitude, 27.56);
    expect(repo.session.locatedAt, isNotNull);
    expect(repo.geoReady, isTrue);
    expect(find.byType(GeoGateScreen), findsNothing);
  });

  testWidgets('роль, которой геопривязка не нужна, проходит без геолокации',
      (tester) async {
    // геолокация выключена, разрешения нет — и всё равно ничего не спрашивают
    final phone =
        FakePhone(services: false, granted: GeoPermission.deniedForever);
    final repo = _repo(geoRequired: false, phone: phone);
    await _launch(tester, repo);

    expect(find.byType(GeoGateScreen), findsNothing);
    expect(repo.geoReady, isTrue);
    expect(phone.asked, 0);
    expect(phone.measurements, 0);
  });

  // Одна беда — один экран: человеку в любом случае надо поправить настройки и повторить.
  group('экран объясняет, что случилось, и даёт две кнопки', () {
    final cases = {
      GeoFailure.servicesOff: 'Геолокация выключена',
      GeoFailure.denied: 'Нет доступа к местоположению',
      GeoFailure.deniedForever: 'Доступ к местоположению запрещён',
      GeoFailure.noFix: 'Не удалось определить местоположение',
    };

    FakePhone phoneFor(GeoFailure failure) => switch (failure) {
          GeoFailure.servicesOff => FakePhone(services: false),
          GeoFailure.denied => FakePhone(granted: GeoPermission.denied),
          GeoFailure.deniedForever =>
            FakePhone(granted: GeoPermission.deniedForever),
          GeoFailure.noFix => FakePhone(measured: null),
        };

    for (final entry in cases.entries) {
      testWidgets(entry.value.toLowerCase(), (tester) async {
        await _launch(
            tester, _repo(geoRequired: true, phone: phoneFor(entry.key)));

        expect(find.text(entry.value), findsOneWidget);
        expect(find.text('Повторить'), findsOneWidget);
        expect(find.text('Открыть настройки'), findsOneWidget);
      });
    }
  });

  testWidgets('«Повторить» пускает внутрь, как только разрешение выдали',
      (tester) async {
    final phone = FakePhone(granted: GeoPermission.deniedForever);
    final repo = _repo(geoRequired: true, phone: phone);
    await _launch(tester, repo);
    expect(repo.geoReady, isFalse);

    // человек сходил в настройки и разрешил
    phone
      ..granted = GeoPermission.granted
      ..measured = fixAt();
    await tester.tap(find.text('Повторить'));
    await tester.pumpAndSettle();

    expect(repo.geoReady, isTrue);
    expect(find.byType(GeoGateScreen), findsNothing);
  });

  testWidgets('«Открыть настройки» ведёт туда, где эту беду и правят',
      (tester) async {
    final phone = FakePhone(services: false);
    await _launch(tester, _repo(geoRequired: true, phone: phone));

    await tester.tap(find.text('Открыть настройки'));
    await tester.pumpAndSettle();
    expect(phone.openedLocationSettings, isTrue,
        reason: 'выключена сама геолокация — настройки устройства, не приложения');
  });
}
