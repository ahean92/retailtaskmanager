// Сквозная приёмка #36945 на живом стенде — подытоги по разделам в бланке.
//
// Проверяется ровно то, что записано в приёмке тикета:
//  1) у раздела с оценкой в шапке страницы — свой балл и процент («6 из 8 · 75%»),
//     и числа совпадают с тем, что сервер отдаёт десктопной карточке
//     (apiExecutionInfo.sections — те же sectionScore/sectionMax/sectionPercent);
//  2) ответ на пункт меняет подытог его раздела сразу, не выходя с бланка, — по
//     конвейеру #36782: очередь ушла, info перечитан, шапка перерисована;
//  3) раздел без оцениваемых полей («Документы») строки подытога не имеет — шапка
//     выглядит ровно как до задачи.
//
// Данные стенда — scripts/ticket36945_demo.lsf (шаблон DEMO36945: «Зал» = шкала
// «Чистота (демо)» ×3 + число с нормой 2–6 ×2, «Склад» = две шкалы ×4 и ×3,
// «Документы» = текст без оценки; задача DEMO36945-2 создаётся чистой).
//
// Маркеры: boot:, SHOT_sec1_empty, SHOT_sec1_full, SHOT_sec1_norm, SHOT_sec2,
// SHOT_sec3_plain, E2E_SUBTOTAL_*, ALL_OK_36945.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:pulse_tasks/data/task_repository.dart';
import 'package:pulse_tasks/main.dart' as app;
import 'package:pulse_tasks/ui/fill_screen.dart';
import 'package:pulse_tasks/ui/widgets/fill_field_tile.dart';

const _base = String.fromEnvironment('E2E_BASE',
    defaultValue: 'http://192.168.42.28:8888');
const _login = String.fromEnvironment('E2E_LOGIN', defaultValue: 'demo.user1');
const _pass = String.fromEnvironment('E2E_PASS', defaultValue: 'demo');
const _task = String.fromEnvironment('E2E_TASK', defaultValue: 'DEMO36945-2');

const _subtotalKey = ValueKey('sectionSubtotal');

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

/// Текст строки подытога в шапке раздела; null — строки нет.
String? _subtotal(WidgetTester tester) {
  final f = find.byKey(_subtotalKey);
  if (f.evaluate().isEmpty) return null;
  return (tester.widget<Text>(f.first)).data;
}

/// Дождаться, что строка подытога стала ровно такой, — «сразу после ответа»
/// в терминах #36782: очередь ушла, info перечитан, шапка перерисовалась сама,
/// без выхода с бланка и без переоткрытия.
Future<void> _untilSubtotal(WidgetTester tester, String expected) =>
    _until(tester, 'подытог «$expected» (сейчас: «${_subtotal(tester)}»)',
        () => _subtotal(tester) == expected,
        seconds: 90);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('36945: подытоги раздела живут в шапке бланка', (tester) async {
    app.main();
    await _until(tester, 'первый кадр приложения',
        () => find.byType(MaterialApp).evaluate().isNotEmpty,
        seconds: 90);

    final ctx = tester.element(find.byType(MaterialApp).first);
    final repo = Provider.of<TaskRepository>(ctx, listen: false);

    // --- вход, если переустановка снесла настройки/сессию ---
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
    await repo.syncAndRefresh();
    await _settle(tester);

    // ===== бланк чистой задачи: раздел 1 «Зал», подытога ещё нет =====
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    nav.push(
        MaterialPageRoute(builder: (_) => const FillScreen(taskId: _task)));
    await _until(tester, 'экран бланка',
        () => find.byType(FillScreen).evaluate().isNotEmpty, seconds: 90);
    await _until(tester, 'плитки полей',
        () => find.byType(FillFieldTile).evaluate().isNotEmpty, seconds: 90);
    await _settle(tester, frames: 20);

    expect(find.text('Зал'), findsWidgets, reason: 'открыт раздел «Зал»');
    expect(_subtotal(tester), isNull,
        reason: 'ничего не отвечено — у раздела нет оценки и нет строки');
    await _shot(tester, 'SHOT_sec1_empty');

    // ===== ответ на шкалу двигает подытог, не выходя с бланка =====
    await tester.tap(find.text('Чисто').first); // f1: Чисто = 2 × вес 3 = 6
    await _untilSubtotal(tester, '6 из 6 · 100%');
    debugPrint('E2E_SUBTOTAL_SCALE_OK ${_subtotal(tester)}');
    await _shot(tester, 'SHOT_sec1_full');

    // ===== число вне нормы: максимум раздела растёт, балл — нет =====
    final tempTile = find.byWidgetPredicate(
        (w) => w is FillFieldTile && w.field.code == 'f2');
    expect(tempTile, findsOneWidget, reason: 'плитка «Температура витрины»');
    await tester.enterText(
        find.descendant(of: tempTile, matching: find.byType(TextField)).first,
        '8');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _untilSubtotal(tester, '6 из 8 · 75%');
    debugPrint('E2E_SUBTOTAL_NORM_OK ${_subtotal(tester)}');
    await _shot(tester, 'SHOT_sec1_norm');

    // ===== раздел 2 «Склад»: своей оценки ещё нет, ответ приносит свою =====
    await tester.tap(find.widgetWithText(FilledButton, 'Далее').first);
    await _settle(tester, frames: 10);
    expect(find.text('Склад'), findsWidgets, reason: 'открыт раздел «Склад»');
    expect(_subtotal(tester), isNull,
        reason: 'у «Склада» ещё нет ответов — и нет строки');
    await tester.tap(find.text('Принято').first); // f3: Принято = 1 × вес 4 = 4
    await _untilSubtotal(tester, '4 из 4 · 100%');
    debugPrint('E2E_SUBTOTAL_SEC2_OK ${_subtotal(tester)}');
    await _shot(tester, 'SHOT_sec2');

    // подытог «Зала» ответом на «Складе» не тронут — вернувшись, видим прежний
    await tester.tap(find.widgetWithText(OutlinedButton, 'Назад').first);
    await _settle(tester, frames: 10);
    expect(_subtotal(tester), '6 из 8 · 75%',
        reason: 'ответ чужого раздела не двигает чужой подытог');
    await tester.tap(find.widgetWithText(FilledButton, 'Далее').first);
    await _settle(tester, frames: 10);

    // ===== раздел 3 «Документы» — без оценки: шапка ровно как раньше =====
    await tester.tap(find.widgetWithText(FilledButton, 'Далее').first);
    await _settle(tester, frames: 10);
    expect(find.text('Документы'), findsWidgets,
        reason: 'открыт раздел «Документы»');
    expect(_subtotal(tester), isNull,
        reason: 'раздел без оцениваемых полей — строки подытога нет');
    await _shot(tester, 'SHOT_sec3_plain');

    // ===== числа на экране = числа сервера (те же, что в десктопной карточке) ==
    final info = await repo.api.fetchExecutionInfo(_task);
    final sections = {
      for (final s in ((info?['sections'] as List?) ?? const []))
        (s as Map)['index'] as int: s
    };
    expect(sections.keys.toSet(), {1, 2},
        reason: 'сервер отдаёт подытоги ровно оценённых разделов');
    expect((sections[1]!['score'] as num).toDouble(), 6);
    expect((sections[1]!['max'] as num).toDouble(), 8);
    expect((sections[1]!['percent'] as num).toDouble(), 75);
    expect((sections[2]!['score'] as num).toDouble(), 4);
    expect((sections[2]!['max'] as num).toDouble(), 4);
    expect((sections[2]!['percent'] as num).toDouble(), 100);

    debugPrint('ALL_OK_36945');
  });
}
