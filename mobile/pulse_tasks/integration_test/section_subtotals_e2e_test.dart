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
// Данные стенда — scripts/demo/ticket36945_demo.lsf (шаблон DEMO36945: «Зал» = шкала
// «Чистота (демо)» ×3 + число с нормой 2–6 ×2, «Склад» = две шкалы ×4 и ×3,
// «Документы» = текст без оценки; задача DEMO36945-2 создаётся чистой).
//
// Маркеры: boot:, SHOT_sec1_empty, SHOT_sec1_full, SHOT_sec1_norm, SHOT_sec2,
// SHOT_sec3_plain, E2E_SUBTOTAL_*, ALL_OK_36945.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pulse_tasks/ui/fill_screen.dart';
import 'package:pulse_tasks/ui/widgets/fill_field_tile.dart';
import 'support/e2e_harness.dart';

const _login = String.fromEnvironment('E2E_LOGIN', defaultValue: 'demo.user1');
const _task = String.fromEnvironment('E2E_TASK', defaultValue: 'DEMO36945-2');

const _subtotalKey = ValueKey('sectionSubtotal');

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
    until(tester, 'подытог «$expected» (сейчас: «${_subtotal(tester)}»)',
        () => _subtotal(tester) == expected,
        seconds: 90);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('36945: подытоги раздела живут в шапке бланка', (tester) async {
    final repo = await bootApp(tester, login: _login);
    await repo.syncAndRefresh();
    await settle(tester);

    // ===== бланк чистой задачи: раздел 1 «Зал», подытога ещё нет =====
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    nav.push(
        MaterialPageRoute(builder: (_) => const FillScreen(taskId: _task)));
    await until(tester, 'экран бланка',
        () => find.byType(FillScreen).evaluate().isNotEmpty, seconds: 90);
    await until(tester, 'плитки полей',
        () => find.byType(FillFieldTile).evaluate().isNotEmpty, seconds: 90);
    await settle(tester, frames: 20);

    expect(find.text('Зал'), findsWidgets, reason: 'открыт раздел «Зал»');
    expect(_subtotal(tester), isNull,
        reason: 'ничего не отвечено — у раздела нет оценки и нет строки');
    await shot(tester, 'SHOT_sec1_empty');

    // ===== ответ на шкалу двигает подытог, не выходя с бланка =====
    await tester.tap(find.text('Чисто').first); // f1: Чисто = 2 × вес 3 = 6
    await _untilSubtotal(tester, '6 из 6 · 100%');
    debugPrint('E2E_SUBTOTAL_SCALE_OK ${_subtotal(tester)}');
    await shot(tester, 'SHOT_sec1_full');

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
    await shot(tester, 'SHOT_sec1_norm');

    // ===== раздел 2 «Склад»: своей оценки ещё нет, ответ приносит свою =====
    await tester.tap(find.widgetWithText(FilledButton, 'Далее').first);
    await settle(tester, frames: 10);
    expect(find.text('Склад'), findsWidgets, reason: 'открыт раздел «Склад»');
    expect(_subtotal(tester), isNull,
        reason: 'у «Склада» ещё нет ответов — и нет строки');
    await tester.tap(find.text('Принято').first); // f3: Принято = 1 × вес 4 = 4
    await _untilSubtotal(tester, '4 из 4 · 100%');
    debugPrint('E2E_SUBTOTAL_SEC2_OK ${_subtotal(tester)}');
    await shot(tester, 'SHOT_sec2');

    // подытог «Зала» ответом на «Складе» не тронут — вернувшись, видим прежний
    await tester.tap(find.widgetWithText(OutlinedButton, 'Назад').first);
    await settle(tester, frames: 10);
    expect(_subtotal(tester), '6 из 8 · 75%',
        reason: 'ответ чужого раздела не двигает чужой подытог');
    await tester.tap(find.widgetWithText(FilledButton, 'Далее').first);
    await settle(tester, frames: 10);

    // ===== раздел 3 «Документы» — без оценки: шапка ровно как раньше =====
    await tester.tap(find.widgetWithText(FilledButton, 'Далее').first);
    await settle(tester, frames: 10);
    expect(find.text('Документы'), findsWidgets,
        reason: 'открыт раздел «Документы»');
    expect(_subtotal(tester), isNull,
        reason: 'раздел без оцениваемых полей — строки подытога нет');
    await shot(tester, 'SHOT_sec3_plain');

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
