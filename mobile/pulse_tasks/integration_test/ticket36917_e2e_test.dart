// Сквозная приёмка #36917 на живом стенде — тёмная тема.
//
// Приёмка тут глазами по определению («нет экрана, где текст сливается с фоном»), так
// что задача драйвера — провести приложение по всем экранам и снять каждый ДВАЖДЫ, в
// светлой и в тёмной. Сами снимки делает внешний шелл (`adb exec-out screencap`) по
// маркерам в логе — как и в прошлых приёмках.
//
// Что проверяется машинно, а не глазами: контраст палитры и сохранение выбора —
// test/theme_dark_test.dart.
//
// Параметры — dart-define: E2E_BASE (адрес стенда), E2E_LOGIN/E2E_PASS, E2E_TASK
// (задача с перепиской), E2E_PHOTO_TASK (задача со снимком), E2E_FILL (задача с
// бланком), E2E_SIMPLE (поручение).
//
// Маркеры: boot:, SHOT_<экран>_light, SHOT_<экран>_dark, E2E_READY, ALL_OK_36917.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:pulse_tasks/data/task_repository.dart';
import 'package:pulse_tasks/main.dart' as app;
import 'package:pulse_tasks/ui/brand.dart';
import 'package:pulse_tasks/ui/fill_screen.dart';
import 'package:pulse_tasks/ui/notifications_screen.dart';
import 'package:pulse_tasks/ui/settings_screen.dart';
import 'package:pulse_tasks/ui/simple_execution_screen.dart';
import 'package:pulse_tasks/ui/task_detail_screen.dart';
import 'package:pulse_tasks/ui/task_list_screen.dart';
import 'package:pulse_tasks/ui/theme.dart';
import 'package:pulse_tasks/ui/widgets/task_photo.dart';

const _base = String.fromEnvironment('E2E_BASE',
    defaultValue: 'http://192.168.42.28:8888');
const _login = String.fromEnvironment('E2E_LOGIN', defaultValue: 'demo.user1');
const _pass = String.fromEnvironment('E2E_PASS', defaultValue: 'demo');
const _task = String.fromEnvironment('E2E_TASK', defaultValue: 'ST000012');
const _fill = String.fromEnvironment('E2E_FILL', defaultValue: 'DEMO36751-1');
const _simple = String.fromEnvironment('E2E_SIMPLE', defaultValue: 'ST000017');
const _photoTask =
    String.fromEnvironment('E2E_PHOTO_TASK', defaultValue: 'ST000029');

Future<void> _settle(WidgetTester tester, {int frames = 12}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 120));
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }
}

Future<void> _until(WidgetTester tester, String what, bool Function() done,
    {int seconds = 120}) async {
  final deadline = DateTime.now().add(Duration(seconds: seconds));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('не дождались: $what');
    await tester.pump(const Duration(milliseconds: 400));
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }
  await _settle(tester);
}

/// Снимок делает шелл по маркеру — здесь только пауза, чтобы кадр был дорисован и
/// шелл успел его снять.
Future<void> _shot(WidgetTester tester, String marker) async {
  await _settle(tester, frames: 6);
  debugPrint(marker);
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
}

/// Один и тот же экран в обеих темах, подряд: только так видно, что тёмная не
/// «просто тёмная», а показывает ровно то же самое.
Future<void> _both(WidgetTester tester, String screen) async {
  await Wms.setMode(ThemeMode.light);
  await _shot(tester, 'SHOT_${screen}_light');
  await Wms.setMode(ThemeMode.dark);
  await _shot(tester, 'SHOT_${screen}_dark');
  await Wms.setMode(ThemeMode.light);
  await _settle(tester, frames: 4);
}

NavigatorState get _nav => app.PulseApp.navigatorKey.currentState!;

Future<void> _open(WidgetTester tester, Widget screen) async {
  unawaited(_nav.push(MaterialPageRoute<void>(builder: (_) => screen)));
  await _settle(tester, frames: 10);
}

Future<void> _back(WidgetTester tester) async {
  _nav.pop();
  await _settle(tester, frames: 6);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('36917: каждый экран в светлой и тёмной теме', (tester) async {
    app.main();
    await _until(tester, 'первый кадр приложения',
        () => find.byType(MaterialApp).evaluate().isNotEmpty,
        seconds: 90);

    final ctx = tester.element(find.byType(MaterialApp).first);
    final repo = Provider.of<TaskRepository>(ctx, listen: false);
    debugPrint('boot: configured=${repo.settings.isConfigured} '
        'active=${repo.session.isActive} login="${repo.session.login}"');

    // --- экран настроек: он же первый после переустановки, и на нём живёт выбор темы.
    // Здесь тема переключается НАСТОЯЩИМ переключателем — остальные экраны снимаются
    // через Wms.setMode, чтобы прогон не превратился в хождение туда-сюда.
    if (!repo.settings.isConfigured) {
      expect(find.byType(SettingsScreen), findsOneWidget);
      await tester.tap(find.text('Тёмная'));
      await _shot(tester, 'SHOT_settings_dark');
      await tester.tap(find.text('Светлая'));
      await _shot(tester, 'SHOT_settings_light');

      await tester.enterText(find.byType(TextField).first, _base);
      await _settle(tester);
      await tester.tap(find.text('Сохранить'));
      await _settle(tester, frames: 20);
    }

    if (!repo.session.isActive) {
      final fields = find.byType(TextField);
      expect(fields, findsWidgets, reason: 'ни сессии, ни формы входа');
      await tester.enterText(fields.at(0), _login);
      await tester.enterText(fields.at(1), _pass);
      await _settle(tester);
      await _both(tester, 'login');
      await tester.tap(find.text('Войти'));
      await _until(tester, 'вход', () => repo.session.isActive, seconds: 90);
    }
    await _until(tester, 'геогейт', () => repo.geoReady, seconds: 120);
    await repo.syncAndRefresh();
    await _until(tester, 'задачи приехали', () => repo.tasks.isNotEmpty,
        seconds: 120);
    debugPrint('E2E_READY tasks=${repo.tasks.length}');

    // --- главная: KPI с серверным цветом, текстовый блок, новости, задачи
    await _both(tester, 'home');

    // --- настройки из живого приложения (не первый запуск)
    await _open(tester, const SettingsScreen());
    await _both(tester, 'settings');
    await _back(tester);

    // --- список задач: карточки, чипы фильтров, просроченные красной рамкой
    await _open(tester, const TaskListScreen());
    await _both(tester, 'tasks');
    await _back(tester);

    // --- карточка задачи: описание, статусы, вложения, переписка
    await _open(tester, const TaskDetailScreen(taskId: _task));
    await _settle(tester, frames: 20);
    await _both(tester, 'card');
    await _back(tester);

    // --- фото-превью и снимок на весь экран: отдельной задачей, потому что снимок
    // нужен настоящий — на карточке с перепиской его может не быть
    await _open(tester, const TaskDetailScreen(taskId: _photoTask));
    await _settle(tester, frames: 30);
    final thumb = find.byType(TaskPhotoThumb);
    if (thumb.evaluate().isNotEmpty) {
      await _both(tester, 'thumb');
      await tester.tap(thumb.first);
      await _settle(tester, frames: 30);
      await _both(tester, 'photo');
      await _back(tester);
    } else {
      debugPrint('E2E_NOTE: на задаче $_photoTask нет снимка — просмотр пропущен');
    }
    await _back(tester);

    // --- заполнение бланка: шапка с оценкой, поля всех типов, полоса «офлайн»
    await _open(tester, const FillScreen(taskId: _fill));
    await _settle(tester, frames: 40);
    await _both(tester, 'fill');
    await _back(tester);

    // --- поручение: фотоотчёт и комментарий
    await _open(tester, const SimpleExecutionScreen(taskId: _simple));
    await _settle(tester, frames: 30);
    await _both(tester, 'simple');
    await _back(tester);

    // --- лента уведомлений
    await _open(tester, const NotificationsScreen());
    await _settle(tester, frames: 20);
    await _both(tester, 'feed');
    await _back(tester);

    // --- брендирование заказчика в обеих темах. На стенде оформление не заведено
    // (apiBrand отвечает пустым), поэтому чужая палитра подставляется тем же путём,
    // которым её кладёт синхронизация: Brand.fromJson → Wms.brand. Тёмный вариант
    // считается из неё сам — это и есть то, что проверяется.
    Wms.brand = Brand.fromJson(const {
      'name': 'Санта',
      'tagline': 'Задачи',
      'primary': '#8B1E3F',
      'primaryDark': '#6E1832',
    });
    await _settle(tester, frames: 10);
    await _both(tester, 'brand');
    Wms.brand = Brand.pulse;
    await _settle(tester, frames: 6);

    debugPrint('ALL_OK_36917');
  });
}
