// Общая обвязка сквозных прогонов на живом стенде.
//
// Каждый *_e2e_test.dart раньше носил это с собой: адрес стенда и учётку из
// dart-define, ожидания с дедлайном, паузу под снимок экрана, пролистывание бланка
// и пролог «поднять приложение — войти — пройти гео-гейт». Здесь это один раз.
//
// Сценарии по-прежнему throwaway-драйверы: сеть, геолокацию и снимки делает внешний
// шелл по маркерам в логе (boot:, E2E_READY, SHOT_*, NET_OFF/NET_ON …) — харнес
// маркеры печатает, но сам ничего с устройством не делает.
//
// Параметры — dart-define: E2E_BASE (адрес стенда), E2E_LOGIN/E2E_PASS (учётка).
// Логин у каждого сценария свой по умолчанию (demo.user1 — без геопривязки,
// sosedi.tech1 — с ней), поэтому он передаётся в [bootApp] из самого теста.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:pulse_tasks/data/geo.dart';
import 'package:pulse_tasks/data/task_repository.dart';
import 'package:pulse_tasks/main.dart' as app;

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

/// Долистать бланк до нужного места: КАЖДЫЙ раздел прокручивается сверху донизу и
/// только потом листается следующий — список раздела ленивый, и «не нашли на этой
/// странице» иначе означало бы всего лишь «не долистали» (грабли #36946).
///
/// Если не нашли нигде, в лог уходит E2E_SCREEN со всеми текстами последней
/// страницы — по нему видно, куда долистали.
Future<void> pageTo(WidgetTester tester, Finder finder) async {
  final vertical = find.byWidgetPredicate(
      (w) => w is Scrollable && w.axisDirection == AxisDirection.down);
  for (var page = 0; page < 12 && finder.evaluate().isEmpty; page++) {
    for (var i = 0; i < 20 && finder.evaluate().isEmpty; i++) {
      if (vertical.evaluate().isEmpty) break;
      await tester.drag(vertical.first, const Offset(0, -300));
      await settle(tester, frames: 3);
    }
    if (finder.evaluate().isNotEmpty) break;
    final next = find.widgetWithText(FilledButton, 'Далее');
    if (next.evaluate().isEmpty) break;
    await tester.tap(next.first);
    await settle(tester, frames: 8);
  }
  if (finder.evaluate().isEmpty) {
    final texts = [
      for (final e in find.byType(Text).evaluate())
        (e.widget as Text).data ?? ''
    ];
    debugPrint('E2E_SCREEN ${jsonEncode(texts)}');
  }
}

/// Поднять приложение, войти под [login] и — если учётке нужна геопривязка —
/// пройти гео-гейт. Возвращает репозиторий из дерева приложения.
///
/// [geoGate] = false — для сценариев, которые сами двигают эмулятор
/// (`adb emu geo fix`) и зовут locate() в нужный момент: ранний locate() здесь
/// зафиксировал бы положение до переезда.
Future<TaskRepository> bootApp(WidgetTester tester,
    {required String login,
    String pass = e2ePass,
    String base = e2eBase,
    bool geoGate = true}) async {
  app.main();
  // до runApp приложение успевает поднять Firebase и открыть базу — на свежей
  // установке это дольше двух секунд, ждём само дерево
  await until(tester, 'первый кадр приложения',
      () => find.byType(MaterialApp).evaluate().isNotEmpty,
      seconds: 90);

  final ctx = tester.element(find.byType(MaterialApp).first);
  final repo = Provider.of<TaskRepository>(ctx, listen: false);
  debugPrint('boot: configured=${repo.settings.isConfigured} '
      'active=${repo.session.isActive} login="${repo.session.login}"');

  await signIn(tester, repo, login: login, pass: pass, base: base);
  if (geoGate) await passGeoGate(tester, repo);
  return repo;
}

/// Вход, если переустановка снесла настройки/сессию (Keystore-грабли).
///
/// Android Auto Backup умеет восстановить ЧУЖУЮ сессию (прогон, поднявшийся под
/// sosedi.tech1 после ручного adb install) — из любой другой учётки сперва выходим.
Future<void> signIn(WidgetTester tester, TaskRepository repo,
    {required String login,
    String pass = e2ePass,
    String base = e2eBase}) async {
  if (repo.session.isActive && repo.session.login != login) {
    await repo.signOut();
    await settle(tester);
  }
  if (!repo.settings.isConfigured) {
    await tester.enterText(find.byType(TextField).first, base);
    await settle(tester);
    await tester.tap(find.text('Сохранить'));
    await settle(tester);
  }
  if (!repo.session.isActive) {
    final fields = find.byType(TextField);
    expect(fields, findsWidgets, reason: 'ни сессии, ни формы входа');
    await tester.enterText(fields.at(0), login);
    await tester.enterText(fields.at(1), pass);
    await settle(tester);
    await tester.tap(find.text('Войти'));
    await until(tester, 'вход', () => repo.session.isActive, seconds: 90);
  }
}

/// Гео-гейт: у учётки без геопривязки [TaskRepository.geoReady] уже true и делать
/// нечего. Иначе разрешение выдаёт оркестратор (pm grant по маркеру boot:) — ждём
/// его, потом locate(), иначе locate() виснет на системном диалоге (грабли #36838).
Future<void> passGeoGate(WidgetTester tester, TaskRepository repo) async {
  if (repo.geoReady) return;
  await untilAsync(
      tester,
      'разрешение геолокации',
      () async => await repo.geo.platform.permission() == GeoPermission.granted,
      seconds: 180);
  await repo.locate(fresh: true);
  await until(tester, 'гео-гейт', () => repo.geoReady, seconds: 120);
}
