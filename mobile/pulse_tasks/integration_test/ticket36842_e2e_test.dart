// Сквозная приёмка #36842 на живом стенде — карточка задачи на эмуляторе.
// Throwaway-драйвер: сеть выключает и включает внешний шелл по маркерам в логе
// (`adb shell svc data disable` / `svc wifi disable`), снимки экрана — он же.
//
// Параметры — dart-define: E2E_BASE (адрес стенда), E2E_LOGIN/E2E_PASS (исполнитель,
// на которого назначены демо-задачи), E2E_TASK (id задачи с «было» и «стало»),
// E2E_TASK2 (id задачи без выполнений). Демо-набор заводится скриптом
// scripts/ticket36842_demo.lsf через /eval/action.
//
// Сценарий приёмки («Готово когда»):
//  1) исполнитель открывает поручение и видит: кто поставил, что сделать (описание —
//     текстом, а не HTML), где, к какому сроку и фотографию проблемы;
//  2) фотография открывается в полный экран и подписана «Было»;
//  3) «было» и «стало» видны порознь и подписаны: снимок результата — в блоке
//     выполнений, с исполнителем и временем;
//  4) в самолётном режиме карточка открывается со всем этим же — текст из кэша,
//     миниатюры с диска.
//
// Исполнитель на стенде — sosedi.tech1: демо-задачи стоят на точке SOS-103, а mite-хост
// требует, чтобы исполнитель и объект были одной организации. Учётка с геопривязкой,
// поэтому оркестратор выдаёт разрешение (pm grant) и льёт эмулятору gps-fix потоком:
// выключение сети через svc сбивает fix, а гейт к тому моменту уже пройден (#36838).
//
// Маркеры: E2E_READY, E2E_CARD_TOP, E2E_CARD_OK, E2E_FULLSCREEN_OK, NET_OFF,
// E2E_OFFLINE_OK, NET_ON, ALL_OK_36842.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:pulse_tasks/data/geo.dart';
import 'package:pulse_tasks/data/task_repository.dart';
import 'package:pulse_tasks/main.dart' as app;
import 'package:pulse_tasks/ui/task_detail_screen.dart';
import 'package:pulse_tasks/ui/widgets/task_card.dart';
import 'package:pulse_tasks/ui/widgets/task_photo.dart';

const _base = String.fromEnvironment('E2E_BASE',
    defaultValue: 'http://192.168.42.28:8888');
const _login =
    String.fromEnvironment('E2E_LOGIN', defaultValue: 'sosedi.tech1');
const _pass = String.fromEnvironment('E2E_PASS', defaultValue: 'demo');
const _task = String.fromEnvironment('E2E_TASK', defaultValue: 'DEMO36842-1');
const _task2 = String.fromEnvironment('E2E_TASK2', defaultValue: 'DEMO36842-2');

Future<void> _settle(WidgetTester tester, {int frames = 12}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 120));
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }
}

Future<void> _until(WidgetTester tester, String what, bool Function() done,
    {int seconds = 180}) async {
  final deadline = DateTime.now().add(Duration(seconds: seconds));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('не дождались: $what');
    await tester.pump(const Duration(milliseconds: 400));
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }
  await _settle(tester);
}

Future<void> _untilAsync(
    WidgetTester tester, String what, Future<bool> Function() done,
    {int seconds = 180}) async {
  final deadline = DateTime.now().add(Duration(seconds: seconds));
  while (!await done()) {
    if (DateTime.now().isAfter(deadline)) fail('не дождались: $what');
    await tester.pump(const Duration(milliseconds: 400));
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }
  await _settle(tester);
}

/// Снимок экрана делает шелл (`adb exec-out screencap`) по маркеру — здесь только
/// пауза, чтобы кадр был дорисован и шелл успел.
Future<void> _shot(WidgetTester tester, String marker) async {
  await _settle(tester, frames: 6);
  debugPrint(marker);
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
}

/// Вертикальный список экрана: `find.byType(Scrollable).first` на списке задач — это
/// горизонтальная лента чипов-фильтров (грабли #36836), поэтому — по направлению.
Finder _verticalList() => find.byWidgetPredicate(
    (w) => w is Scrollable && w.axisDirection == AxisDirection.down);

/// Прокрутить вертикальный список до виджета (finder'ы внизу ленивого ListView не
/// существуют, пока не докрутишь).
Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 30 && finder.evaluate().isEmpty; i++) {
    await tester.drag(_verticalList().first, const Offset(0, -300));
    await _settle(tester, frames: 3);
  }
  expect(finder, findsWidgets);
  await tester.ensureVisible(finder.first);
  await _settle(tester, frames: 3);
}

/// Главная — точка входа, а не второй список задач: полный список открывается
/// кнопкой «Все (N)» в блоке задач.
/// Признак главной — кнопка «Все (N)»; наличие TaskCard признаком не служит: на
/// главной есть превью из трёх «моих» задач, и по нему экран не отличить.
Future<void> _openList(WidgetTester tester) async {
  final all = find.textContaining('Все (');
  if (all.evaluate().isEmpty) return; // уже в полном списке
  await tester.tap(all.first);
  await _until(tester, 'список задач на экране',
      () => find.byType(TaskCard).evaluate().isNotEmpty);
}

/// Что сейчас на экране — по текстам: когда карточка не находится, разбирать надо
/// не «0 виджетов», а то, какой экран открыт на самом деле.
void _dumpScreen(String where) {
  final texts = find
      .byType(Text)
      .evaluate()
      .map((e) => (e.widget as Text).data)
      .whereType<String>()
      .take(25)
      .toList();
  debugPrint('screen[$where]: $texts');
}

/// Вернуть список в начало: _scrollTo умеет только вниз, а после возврата из чужой
/// карточки список остаётся там, где его оставили, — и задача, лежащая ВЫШЕ, никогда
/// не находится.
Future<void> _scrollTop(WidgetTester tester) async {
  for (var i = 0; i < 15; i++) {
    await tester.drag(_verticalList().first, const Offset(0, 400));
    await _settle(tester, frames: 2);
  }
}

/// Открыть карточку задачи из списка: демо-задачи различаются названием.
Future<void> _openCard(WidgetTester tester, String title) async {
  await _openList(tester);
  await _scrollTop(tester);
  final card = find.ancestor(
      of: find.textContaining(title), matching: find.byType(TaskCard));
  await _scrollTo(tester, card);
  await tester.tap(card.first);
  await _until(tester, 'карточка $title',
      () => find.byType(TaskDetailScreen).evaluate().isNotEmpty);
}

Future<void> _back(WidgetTester tester) async {
  await tester.pageBack();
  await _settle(tester);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('36842: карточка — описание, автор, «было» и «стало», офлайн',
      (tester) async {
    app.main();
    await _until(tester, 'первый кадр приложения',
        () => find.byType(MaterialApp).evaluate().isNotEmpty,
        seconds: 90);

    final ctx = tester.element(find.byType(MaterialApp).first);
    final repo = Provider.of<TaskRepository>(ctx, listen: false);

    // --- вход, если переустановка снесла настройки/сессию (Keystore-грабли) ---
    debugPrint('boot: configured=${repo.settings.isConfigured} '
        'active=${repo.session.isActive} login="${repo.session.login}"');
    if (repo.session.isActive && repo.session.login != _login) {
      await repo.signOut();
      await _settle(tester);
    }
    if (!repo.settings.isConfigured) {
      await tester.enterText(find.byType(TextField).first, _base);
      await _settle(tester);
      await tester.tap(find.text('Сохранить'));
      await _settle(tester);
    }
    if (!repo.session.isActive) {
      final fields = find.byType(TextField);
      expect(fields, findsWidgets, reason: 'ни сессии, ни формы входа');
      await tester.enterText(fields.at(0), _login);
      await tester.enterText(fields.at(1), _pass);
      await _settle(tester);
      await tester.tap(find.text('Войти'));
      await _until(tester, 'вход', () => repo.session.isActive, seconds: 90);
    }

    // гео-гейт: учётка исполнителя на стенде работает с геопривязкой. Разрешение
    // выдаёт оркестратор (pm grant по маркеру boot:) — дождаться его, иначе locate()
    // повиснет на системном диалоге (грабли #36838)
    if (!repo.geoReady) {
      await _untilAsync(
          tester,
          'разрешение геолокации',
          () async =>
              await repo.geo.platform.permission() == GeoPermission.granted,
          seconds: 180);
      await repo.locate(fresh: true);
      await _until(tester, 'гео-гейт', () => repo.geoReady, seconds: 120);
    }

    await repo.syncAndRefresh();
    await _until(tester, 'список задач', () => repo.tasks.isNotEmpty,
        seconds: 120);
    // миниатюры едут фоном (prefetchTaskPhotos) — дать им доехать до «самолёта»
    await repo.prefetchTaskPhotos();
    debugPrint('E2E_READY');

    // --- 1. что сделать, кто поставил, где и к какому сроку ---
    final ours = repo.tasks.firstWhere((v) => v.id == _task,
        orElse: () => fail('на стенде нет демо-задачи $_task — '
            'прогоните scripts/ticket36842_demo.lsf'));
    final t = ours.task;
    expect(t.description, isNotNull, reason: 'описание должно доехать');
    expect(t.description, isNot(contains('<')),
        reason: 'на телефон едет текст, а не HTML');
    expect(t.author, isNotNull, reason: 'кто поставил');
    expect(t.files.where((f) => f.image), isNotEmpty,
        reason: 'фотография проблемы');
    expect(t.executions.where((e) => e.photoId != null), isNotEmpty,
        reason: 'снимок результата');

    await _openCard(tester, '36842: мусор у витрины');
    expect(find.text(t.description!), findsOneWidget);
    expect(find.text(t.author!), findsOneWidget);
    expect(find.textContaining('Было'), findsWidgets);
    expect(find.textContaining('Стало'), findsWidgets);
    await _shot(tester, 'E2E_CARD_TOP'); // описание и «Было» — первым экраном
    // фотографии — обе: проблема и результат
    await _scrollTo(tester, find.byType(TaskPhotoThumb));
    await _until(tester, 'миниатюры',
        () => find.byType(Image).evaluate().length >= 2);
    await _shot(tester, 'E2E_CARD_OK');

    // --- 2. полный экран и подпись ---
    await tester.tap(find.byType(TaskPhotoThumb).first);
    await _until(tester, 'полный экран',
        () => find.byType(TaskPhotoViewer).evaluate().isNotEmpty);
    expect(find.textContaining('Было'), findsWidgets,
        reason: 'на чёрном фоне «было» и «стало» различает только подпись');
    await _shot(tester, 'E2E_FULLSCREEN_OK');
    await _back(tester);

    // --- 3. задача без выполнений: «было» есть, «стало» нет ---
    await _back(tester);
    await _openCard(tester, '36842: разбит плафон');
    expect(find.textContaining('Было'), findsWidgets);
    expect(find.textContaining('Стало'), findsNothing,
        reason: 'пустой блок выполнений — шум');
    final second = repo.tasks.firstWhere((v) => v.id == _task2);
    expect(second.task.executions, isEmpty);
    await _back(tester);

    // --- 4. самолётный режим ---
    debugPrint('NET_OFF');
    await _until(tester, 'сеть выключена шеллом', () => !repo.online,
        seconds: 180);
    await repo.syncAndRefresh(); // офлайн-проход: кэш обязан выстоять
    await _settle(tester);

    _dumpScreen('офлайн, перед открытием карточки');
    debugPrint('offline: tasks=${repo.tasks.length} online=${repo.online} '
        'error=${repo.error}');
    await _openCard(tester, '36842: мусор у витрины');
    expect(find.text(t.description!), findsOneWidget,
        reason: 'описание — из кэша');
    expect(find.text(t.author!), findsOneWidget);
    expect(find.textContaining('Было'), findsWidgets);
    expect(find.textContaining('Стало'), findsWidgets);
    await _scrollTo(tester, find.byType(TaskPhotoThumb));
    await _until(tester, 'миниатюры с диска',
        () => find.byType(Image).evaluate().length >= 2);
    await _shot(tester, 'E2E_OFFLINE_OK');

    debugPrint('NET_ON');
    final deadline = DateTime.now().add(const Duration(seconds: 180));
    while (true) {
      await repo.refresh();
      if (repo.online) break;
      if (DateTime.now().isAfter(deadline)) fail('сеть не вернулась');
      await tester.pump(const Duration(milliseconds: 500));
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    debugPrint('ALL_OK_36842');
  });
}
