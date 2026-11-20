// Обвязка виджет-тестов на настоящих контроллерах: приложение на фейковом сервере,
// экран под провайдерами приложения и ожидание кадрами.
//
// Настоящие sqlite и MockClient внутри runAsync живут своим временем, и pumpAndSettle
// его не даёт: экран ждут кадрами — до условия ([until]) или фиксированное число
// кадров ([settle]), когда ждать нечего определённого.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:pulse_tasks/app_controllers.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/models/place.dart';

/// Приложение с открытой базой этого логина и первым списком задач с сервера.
Future<AppControllers> appOf(
    ApiClient api, Settings settings, Session session) async {
  final app = AppControllers(api: api, settings: settings, session: session);
  await app.account.updateSettings(settings); // открывает базу этого логина
  await app.repo.refresh();
  return app;
}

/// Экран под провайдерами приложения, как в main.dart.
Widget host(AppControllers app, Widget home) =>
    MultiProvider(providers: app.providers, child: MaterialApp(home: home));

/// Человек стоит на объекте [objectId]: бланк не ждёт геопозицию.
Place atObject(String objectId, {String name = 'Объект'}) => Place(
      objects: [NearbyObject(id: objectId, name: name, distance: 40)],
      objectId: objectId,
      latitude: 53.9,
      longitude: 27.56,
      answered: true,
    );

/// [n] кадров с паузой между ними — когда ждать нечего определённого.
Future<void> settle(WidgetTester t, [int n = 12]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 50));
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// Кадры, пока не выполнится [done]; не дождались — тест падает с [reason], а не
/// идёт дальше на недостроенном экране. Хотя бы один кадр — всегда: условие о
/// состоянии контроллера бывает верно раньше, чем экран его нарисовал.
Future<void> until(WidgetTester t, bool Function() done,
    {String reason = 'условие не наступило', int frames = 150}) async {
  for (var i = 0; i < frames; i++) {
    await t.pump(const Duration(milliseconds: 50));
    if (done()) break;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  expect(done(), isTrue, reason: reason);
}

/// То же без кадров — для тестов контроллеров: фоновая синхронизация идёт через
/// настоящий sqlite, и одной очереди микрозадач ей мало.
Future<void> eventually(bool Function() done,
    {String reason = 'условие не наступило', int tries = 300}) async {
  for (var i = 0; i < tries && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(done(), isTrue, reason: reason);
}

/// Прокрутить вертикальный список экрана, пока [target] не построится: списки
/// строят только то, что рядом с видимым.
Future<void> scrollTo(WidgetTester t, Finder target) => t.dragUntilVisible(
    target,
    find
        .byWidgetPredicate(
            (w) => w is Scrollable && w.axisDirection == AxisDirection.down)
        .first,
    const Offset(0, -200));

/// Снять экран внутри теста, а не teardown'ом: dispose экранов пересчитывает «не
/// отправлено», и запросу надо дожить до ответа — иначе тест падает по pending
/// timers.
Future<void> closeScreen(WidgetTester t) async {
  await t.pumpWidget(const SizedBox());
  await Future<void>.delayed(const Duration(milliseconds: 100));
  await t.pump();
}

/// Каталог документов приложения во временной папке: снимки и кэш фото живут
/// файлами, а на настольной машине path_provider его не подставляет.
Directory useTempDocs() {
  final docs = Directory.systemTemp.createTempSync('pulse_docs');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => docs.path);
  addTearDown(() {
    try {
      docs.deleteSync(recursive: true);
    } catch (_) {
      // файл ещё держит закрывающаяся база — уберёт система
    }
  });
  return docs;
}
