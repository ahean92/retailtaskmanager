// Общая обвязка сквозных прогонов на живом стенде.
//
// Адрес стенда и учётка из dart-define, ожидания с дедлайном, пауза под снимок экрана
// и пролог «поднять приложение — войти — пройти гео-гейт».
//
// Здесь остались сценарии, которым внешний шелл не нужен: сеть и часы они не
// переключают. Маркеры в логе (boot:, E2E_READY, SHOT_*) харнес только печатает —
// снимки экрана по ним снимает тот, кому они нужны (`adb exec-out screencap`).
//
// Параметры — dart-define: E2E_BASE (адрес стенда), E2E_LOGIN/E2E_PASS (учётка).
// Логин у каждого сценария свой по умолчанию (demo.user1 — без геопривязки,
// sosedi.tech1 — с ней), поэтому он передаётся в [bootApp] из самого теста.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:pulse_tasks/app_controllers.dart';
import 'package:pulse_tasks/data/geo.dart';
import 'package:pulse_tasks/main.dart' as pulse;

/// Адрес стенда — E2E_BASE, по умолчанию демо-стенд.
const e2eBase = String.fromEnvironment('E2E_BASE',
    defaultValue: 'http://192.168.42.28:8888');

/// Пароль учётки — E2E_PASS; на демо-стенде у всех один.
const e2ePass = String.fromEnvironment('E2E_PASS', defaultValue: 'demo');

/// Несколько кадров с реальными паузами вместо pumpAndSettle: у приложения есть
/// бесконечные анимации (индикаторы загрузки), на которых pumpAndSettle не
/// возвращается никогда.
Future<void> settle(WidgetTester tester, {int frames = 12}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 120));
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }
}

/// Ждать условия с дедлайном; по истечении — fail с тем, чего не дождались.
Future<void> until(WidgetTester tester, String what, bool Function() done,
    {int seconds = 180}) async {
  final deadline = DateTime.now().add(Duration(seconds: seconds));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('не дождались: $what');
    await tester.pump(const Duration(milliseconds: 400));
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }
  await settle(tester);
}

/// То же для условия, которое надо спрашивать асинхронно (база, плагин).
Future<void> untilAsync(
    WidgetTester tester, String what, Future<bool> Function() done,
    {int seconds = 180}) async {
  final deadline = DateTime.now().add(Duration(seconds: seconds));
  while (!await done()) {
    if (DateTime.now().isAfter(deadline)) fail('не дождались: $what');
    await tester.pump(const Duration(milliseconds: 400));
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }
  await settle(tester);
}

/// Снимок экрана делает шелл (`adb exec-out screencap`) по маркеру — здесь только
/// пауза, чтобы кадр был дорисован и шелл успел.
Future<void> shot(WidgetTester tester, String marker) async {
  await settle(tester, frames: 6);
  debugPrint(marker);
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
}

/// Поднять приложение, войти под [login] и — если учётке нужна геопривязка —
/// пройти гео-гейт. Возвращает контроллеры из дерева приложения.
Future<AppControllers> bootApp(WidgetTester tester,
    {required String login,
    String pass = e2ePass,
    String base = e2eBase}) async {
  pulse.main();
  // до runApp приложение успевает поднять Firebase и открыть базу — на свежей
  // установке это дольше двух секунд, ждём само дерево
  await until(tester, 'первый кадр приложения',
      () => find.byType(MaterialApp).evaluate().isNotEmpty,
      seconds: 90);

  final ctx = tester.element(find.byType(MaterialApp).first);
  final app = Provider.of<AppControllers>(ctx, listen: false);
  debugPrint('boot: configured=${app.settings.isConfigured} '
      'active=${app.session.isActive} login="${app.session.login}"');

  await signIn(tester, app, login: login, pass: pass, base: base);
  await passGeoGate(tester, app);
  return app;
}

/// Вход, если переустановка снесла настройки/сессию (Keystore-грабли).
///
/// Android Auto Backup умеет восстановить ЧУЖУЮ сессию (прогон, поднявшийся под
/// sosedi.tech1 после ручного adb install) — из любой другой учётки сперва выходим.
Future<void> signIn(WidgetTester tester, AppControllers app,
    {required String login,
    String pass = e2ePass,
    String base = e2eBase}) async {
  if (app.session.isActive && app.session.login != login) {
    await app.account.signOut();
    await settle(tester);
  }
  if (!app.settings.isConfigured) {
    await tester.enterText(find.byType(TextField).first, base);
    await settle(tester);
    await tester.tap(find.text('Сохранить'));
    await settle(tester);
  }
  if (!app.session.isActive) {
    final fields = find.byType(TextField);
    expect(fields, findsWidgets, reason: 'ни сессии, ни формы входа');
    await tester.enterText(fields.at(0), login);
    await tester.enterText(fields.at(1), pass);
    await settle(tester);
    await tester.tap(find.text('Войти'));
    await until(tester, 'вход', () => app.session.isActive, seconds: 90);
  }
}

/// Гео-гейт: у учётки без геопривязки LocationController.geoReady уже true и делать
/// нечего. Иначе разрешение выдаёт оркестратор (pm grant по маркеру boot:) — ждём
/// его, потом locate(), иначе locate() виснет на системном диалоге (грабли #36838).
Future<void> passGeoGate(WidgetTester tester, AppControllers app) async {
  if (app.location.geoReady) return;
  await untilAsync(
      tester,
      'разрешение геолокации',
      () async => await app.geo.platform.permission() == GeoPermission.granted,
      seconds: 180);
  await app.location.locate(fresh: true);
  await until(tester, 'гео-гейт', () => app.location.geoReady, seconds: 120);
}
