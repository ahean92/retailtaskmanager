// Сквозная приёмка #36716 на живом стенде (192.168.42.28:8888, demo.user1).
// Throwaway-драйвер: сеть переключает внешний шелл (adb svc) по маркерам в логе —
// READY_FOR_AIRPLANE / READY_FOR_NETWORK; тест ждёт последствий по состоянию репо.
//
// Сценарий приёмки целиком:
//  1) в авиарежиме создаётся поручение — карточка сразу в списке;
//  2) там же создаётся внезапная проверка — бланк открывается из посеянного шаблона;
//     поля, фото несоответствия и завершение уходят в очереди;
//  3) появляется связь — всё уезжает само (create → start → поля → фото → finish),
//     дубль не появляется, очереди пустеют.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:pulse_tasks/data/fill_controller.dart';
import 'package:pulse_tasks/data/task_repository.dart';
import 'package:pulse_tasks/main.dart' as app;

// 1×1 непрозрачный PNG — минимальное настоящее фото для очереди.
const _png = [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xDE, 0x00, 0x00, 0x00, //
  0x0C, 0x49, 0x44, 0x41, 0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00, //
  0x00, 0x00, 0x03, 0x00, 0x01, 0x9A, 0x60, 0xE1, 0xD5, 0x00, 0x00, 0x00, //
  0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
];

Future<void> _until(WidgetTester tester, String what, bool Function() done,
    {int seconds = 180}) async {
  final deadline = DateTime.now().add(Duration(seconds: seconds));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('не дождались: $what');
    }
    await tester.pump(const Duration(milliseconds: 400));
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }
  await tester.pumpAndSettle();
}

Future<void> _untilAsync(
    WidgetTester tester, String what, Future<bool> Function() done,
    {int seconds = 240}) async {
  final deadline = DateTime.now().add(Duration(seconds: seconds));
  while (!await done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('не дождались: $what');
    }
    await tester.pump(const Duration(milliseconds: 400));
    await Future<void>.delayed(const Duration(milliseconds: 600));
  }
  await tester.pumpAndSettle();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('36716: поручение и внезапная проверка в авиарежиме',
      (tester) async {
    app.main();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    final ctx = tester.element(find.byType(MaterialApp).first);
    final repo = Provider.of<TaskRepository>(ctx, listen: false);

    // --- вход, если переустановка снесла настройки/сессию (Keystore-грабли) ---
    debugPrint('boot: configured=${repo.settings.isConfigured} '
        'active=${repo.session.isActive} login="${repo.session.login}"');
    if (!repo.settings.isConfigured) {
      await tester.enterText(
          find.byType(TextField).first, 'http://192.168.42.28:8888');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Сохранить'));
      await tester.pumpAndSettle();
    }
    if (!repo.session.isActive) {
      final fields = find.byType(TextField);
      expect(fields, findsWidgets, reason: 'ни сессии, ни формы входа');
      await tester.enterText(fields.at(0), 'demo.user1');
      await tester.enterText(fields.at(1), 'demo');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Войти'));
      await _until(tester, 'вход', () => repo.session.isActive, seconds: 90);
    }

    // пресеты должны лежать в кэше до отключения сети
    await _until(tester, 'пресеты в кэше',
        () => repo.quickCreate.actions.isNotEmpty,
        seconds: 90);
    final errand =
        repo.quickCreate.actions.firstWhere((a) => a.code == 'errand');
    final sudden =
        repo.quickCreate.actions.firstWhere((a) => a.templateCode != null);
    debugPrint('presets: errand="${errand.title}" sudden="${sudden.title}"');

    // --- внешний шелл выключает сеть ---
    debugPrint('READY_FOR_AIRPLANE');
    await _until(tester, 'авиарежим', () => !repo.online, seconds: 240);

    final baseline = repo.tasks.length;

    // ===== сценарий 1: поручение офлайн =====
    await tester.tap(find.byTooltip('Создать'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(errand.title).last);
    await tester.pumpAndSettle();

    // исполнитель из предзагруженного списка
    await tester.tap(find.text('Выбрать исполнителя…'));
    await tester.pumpAndSettle();
    final performer = repo.quickCreate.performers
        .firstWhere((p) => p.name != repo.session.name);
    await tester.tap(find.text(performer.name).last);
    await tester.pumpAndSettle();

    final errandName =
        'Бардак 36716-${DateTime.now().millisecondsSinceEpoch % 100000}';
    await tester.enterText(
        find.widgetWithText(TextField, 'Название').first, errandName);
    await tester.pumpAndSettle();
    // описание — пресет errand может требовать его
    await tester.enterText(
        find.byType(TextField).last, 'Убрать витрину у входа');
    await tester.pumpAndSettle();

    // кнопка внизу ленивого ListView — до неё надо доскроллить, иначе её нет в дереве
    final createBtn = find.widgetWithText(FilledButton, 'Создать задачу');
    await tester.scrollUntilVisible(createBtn, 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(createBtn);
    await tester.pumpAndSettle();

    // «оно сразу видно в своём списке»
    expect(repo.tasks.length, baseline + 1);
    final errandView =
        repo.tasks.firstWhere((t) => t.task.name == errandName);
    expect(errandView.pending, isTrue);
    final errandUuid = errandView.task.clientId!;
    debugPrint('ERRAND_UUID=$errandUuid');

    // ===== сценарий 2: внезапная проверка офлайн =====
    await tester.tap(find.byTooltip('Создать'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(sudden.title).last);
    await tester.pumpAndSettle();

    // предпросмотр бланка длинный — кнопка глубоко за экраном, и после скролла она
    // может остаться у кромки: ensureVisible дотягивает её в зону попадания
    final startBtn = find.widgetWithText(FilledButton, 'Начать проверку');
    await tester.scrollUntilVisible(startBtn, 300,
        scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(startBtn);
    await tester.pumpAndSettle();
    await tester.tap(startBtn);
    await tester.pumpAndSettle();

    // бланк открылся сразу — из посеянного шаблона, сервера рядом нет
    expect(find.text('Заполнение'), findsOneWidget);
    expect(find.textContaining('заполнено 0 из'), findsOneWidget);

    final checkView = repo.tasks
        .firstWhere((t) => t.pending && t.task.clientId != errandUuid);
    final checkUuid = checkView.task.clientId!;
    debugPrint('CHECK_UUID=$checkUuid');

    // с экрана уходим: заполняет headless-контроллер — та же база, те же очереди
    // и тот же код, что у экрана; UI-плитки покрыты своими тестами
    await tester.pageBack();
    await tester.pumpAndSettle();

    final c = FillController(db: repo.db, api: repo.api, taskId: checkUuid);
    await c.load();
    expect(c.fields.length, greaterThanOrEqualTo(3),
        reason: 'бланк должен был посеяться из шаблона');
    expect(c.online, isFalse);

    final clean = c.fields.firstWhere((f) => f.code == 'clean');
    await c.setOption(clean, 'dirty'); // несоответствие — потребует фото
    final dir = await getTemporaryDirectory();
    final photo = File('${dir.path}/evidence36716.png');
    await photo.writeAsBytes(_png);
    await c.addPhoto(clean, photo.path);
    await c.setNumber(c.fields.firstWhere((f) => f.code == 'temp'), 5);
    await c.setText(c.fields.firstWhere((f) => f.code == 'note'),
        'офлайн-проверка 36716');
    if (c.resolutionRequired) await c.setResolution('done');

    expect(await c.finish(), isTrue,
        reason: 'завершение офлайн обязано стать в очередь');
    expect(c.finished, isTrue);
    c.dispose();

    // в списке проверка помечена завершённой, но не отправленной
    await repo.drainLocalTasks(); // только перечитать метки — сети всё равно нет
    await tester.pumpAndSettle();

    final unsent = await repo.db.pendingChanges();
    debugPrint('unsent-before-network=$unsent');
    expect(unsent, greaterThanOrEqualTo(7),
        reason: '2×create + start + 3 поля + фото + finish в очередях');

    // --- внешний шелл возвращает сеть; дренаж должен пройти сам ---
    debugPrint('READY_FOR_NETWORK');
    await _untilAsync(tester, 'очереди опустели',
        () async => await repo.db.pendingChanges() == 0,
        seconds: 300);

    // И после честного refresh дубля нет. Поручение уехало исполнителю — у автора
    // его в списке не осталось. Проверка ниже порога — «Не пройдено», и задача
    // штатно остаётся открытой (Execution.lsf закрывает только succeeded), но строка
    // ровно одна и это серверная: локальная схлопнулась по clientId.
    await repo.syncAndRefresh();
    await tester.pumpAndSettle();
    expect(
        repo.tasks
            .where((t) => t.task.clientId == errandUuid || t.id == errandUuid),
        isEmpty);
    final checkRows = repo.tasks
        .where((t) => t.task.clientId == checkUuid || t.id == checkUuid)
        .toList();
    expect(checkRows, hasLength(1));
    expect(checkRows.single.id, startsWith('ST'));
    expect(checkRows.single.pending, isFalse);
    debugPrint('ALL_SYNCED server_id=${checkRows.single.id}');
  });
}
