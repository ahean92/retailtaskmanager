// Сквозная приёмка #37192 на живом стенде — ввод позиций таблицы по штрихкоду или коду.
//
// Проверяется ровно то, что записано в приёмке тикета:
//  1) позиция добавляется без какого-либо предварительного ввода текста — онлайн и
//     офлайн (лист «Добавить позицию» показывает кандидатов сразу, тап добавляет);
//  2) скан штрихкода товара, который числится на объекте, добавляет строку сразу и
//     ставит курсор в «Факт»;
//  3) ввод кода товара находит и добавляет позицию так же;
//  4) штрихкод товара, которого нет в остатках объекта, но есть в справочнике,
//     добавляет строку с пометкой «вне системы»;
//  5) неизвестный штрихкод: при разрешённом свободном вводе — строка с сохранённым
//     кодом, без него — понятный отказ;
//  6) без связи всё перечисленное работает по кэшу бланка, а после возврата сети
//     строки доезжают на сервер с кодами и без дублей.
//
// Камера эмулятора штрихкоды не читает, поэтому «скан» — сканер-заглушка, подставленная
// в экран бланка (FillScreen.scanner): дальше тот же путь листа, что и у камеры
// (row_subject_sheet.dart, _scan). Ввод кода — с клавиатуры, как у человека.
// Сервер проверяется его же ручкой (apiExecutionRows), а не состоянием контроллера.
//
// Throwaway-драйвер: сеть переключает внешний шелл по маркерам в логе.
//
// Данные стенда — scripts/demo/ticket37192_demo.lsf ПОВЕРХ ticket36943_demo.lsf
// (шаблон DEMO37192: поле positions с rowSource=host, allowManual и свободным вводом,
// поле strict без свободного ввода; штрихкоды ITM36943-1 — 4810000000011 и
// 4810000000028, ITM36943-2 — …35, -3 — …42, -4 — …59, -5 «Кефир», не в остатках —
// …66; 4810000000998 никому не принадлежит). Параметры — dart-define: E2E_BASE,
// E2E_LOGIN/E2E_PASS, E2E_TASK (DEMO37192-1), E2E_FIELD/E2E_STRICT (коды полей).
//
// Маркеры: boot:, E2E_READY, E2E_NO_TEXT_OK, SHOT_scan_row, E2E_SCAN_OK, E2E_CODE_OK,
// E2E_OFFSYSTEM_OK, SHOT_free_dialog, E2E_FREE_OK, SHOT_refuse, E2E_REFUSE_OK,
// E2E_SERVER_OK, NET_OFF, E2E_OFFLINE_READY, SHOT_offline_row, E2E_OFFLINE_OK, NET_ON,
// E2E_OFFLINE_SYNC_OK, ALL_OK_37192.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pulse_tasks/app_controllers.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/fill_controller.dart';
import 'package:pulse_tasks/models/fill.dart';
import 'package:pulse_tasks/ui/fill_screen.dart';
import 'package:pulse_tasks/ui/widgets/fill_field_tile.dart';
import 'package:pulse_tasks/ui/widgets/pickers/row_subject_sheet.dart';
import 'support/e2e_harness.dart';

const _login = String.fromEnvironment('E2E_LOGIN', defaultValue: 'sosedi.tech1');
const _task = String.fromEnvironment('E2E_TASK', defaultValue: 'DEMO37192-1');
const _field = String.fromEnvironment('E2E_FIELD', defaultValue: 'positions');
const _strict = String.fromEnvironment('E2E_STRICT', defaultValue: 'strict');

/// Штрихкоды и коды фактуры (см. шапку).
const _milkPack = '4810000000028'; // ITM36943-1, в остатках
const _breadCode = 'itm36943-2'; // код в другом регистре
const _butterBarcode = '4810000000059'; // ITM36943-4, в остатках
const _kefirBarcode = '4810000000066'; // ITM36943-5, НЕ в остатках, есть в справочнике
const _unknown = '4810000000998'; // никому не принадлежит

typedef _ServerRow = ({
  String subject,
  String subjectId,
  String code,
  bool offSystem,
  Map<String, double> cells
});

/// Строки поля так, как их видит САМ сервер: ключ → предмет, ссылка, код, признак
/// внесистемной, числа по колонкам. Пересобирается из плоского apiExecutionRows.
Future<Map<String, _ServerRow>> _serverRows(
    AppControllers app, String fieldCode) async {
  final raw = await app.api.fetchExecutionRows(_task);
  final out = <String, _ServerRow>{};
  for (final j in raw) {
    if (j['fieldCode'] != fieldCode) continue;
    final key = '${j['rowKey'] ?? ''}';
    final row = out.putIfAbsent(
        key,
        () => (
              subject: '${j['subject'] ?? ''}',
              subjectId: '${j['subjectId'] ?? ''}',
              code: '${j['subjectCode'] ?? ''}',
              offSystem: j['offSystem'] == true,
              cells: <String, double>{}
            ));
    final n = (j['number'] as num?)?.toDouble();
    if (n != null) row.cells['${j['colCode']}'] = n;
  }
  return out;
}

Finder _tile(String fieldCode) => find.byWidgetPredicate(
    (w) => w is FillFieldTile && w.field.code == fieldCode);

Finder get _sheet => find.byType(RowSubjectSheet);

Finder get _sheetField =>
    find.descendant(of: _sheet, matching: find.byType(TextField));

Finder get _sheetSpinner =>
    find.descendant(of: _sheet, matching: find.byType(CircularProgressIndicator));

/// Поле берётся из САМОГО экрана: у FillScreen свой контроллер, и проверять надо то,
/// что видит человек, а не параллельное состояние соседнего.
FillField _onScreen(WidgetTester tester, String fieldCode) => tester
    .widgetList<FillFieldTile>(find.byType(FillFieldTile))
    .firstWhere((w) => w.field.code == fieldCode,
        orElse: () => fail('плитка поля $fieldCode не построена'))
    .field;

/// Вводимая ячейка с курсором — та, куда экран поставил фокус после добавления.
TextField? _focusedCell(WidgetTester tester) {
  for (final t in tester.widgetList<TextField>(find.descendant(
      of: find.byType(FillScreen), matching: find.byType(TextField)))) {
    if (t.focusNode?.hasFocus == true) return t;
  }
  return null;
}

Future<void> _openSheet(WidgetTester tester, String fieldCode) async {
  await pageTo(tester, _tile(fieldCode));
  final btn = find.descendant(
      of: _tile(fieldCode), matching: find.widgetWithText(TextButton, 'позиция'));
  // pageTo листает до ПОСТРОЕННОГО виджета; уехавший под нижнюю панель tap() не
  // достаётся — докручиваем до видимости
  await tester.ensureVisible(btn.first);
  await settle(tester, frames: 4);
  await tester.tap(btn.first);
  await until(tester, 'лист «Добавить позицию»',
      () => _sheet.evaluate().isNotEmpty,
      seconds: 60);
  await settle(tester, frames: 6);
  await until(tester, 'кандидаты листа', () => _sheetSpinner.evaluate().isEmpty,
      seconds: 60);
  await settle(tester, frames: 6);
}

Future<void> _closeSheet(WidgetTester tester) async {
  tester.state<NavigatorState>(find.byType(Navigator).first).pop();
  await until(tester, 'лист закрыт', () => _sheet.evaluate().isEmpty,
      seconds: 30);
  await settle(tester, frames: 6);
}

/// Набрать код в поле листа и подтвердить с клавиатуры (действие «поиск»).
Future<void> _submitCode(WidgetTester tester, String code) async {
  await tester.enterText(_sheetField.first, code);
  await settle(tester, frames: 2);
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await settle(tester, frames: 10);
}

/// Дождаться, что лист закрылся сам (одно точное совпадение) и строка построена.
Future<void> _sheetGone(WidgetTester tester) async {
  await until(tester, 'лист закрылся после точного совпадения',
      () => _sheet.evaluate().isEmpty,
      seconds: 60);
  await settle(tester, frames: 10);
}

/// Ввести факт в ячейку с курсором и подтвердить: строка [row] обязана его получить.
Future<void> _typeFact(
    WidgetTester tester, FillRowData row, FillColumn fact, String value) async {
  final cell = _focusedCell(tester);
  expect(cell, isNotNull, reason: 'курсор в ячейке новой строки');
  expect(cell!.focusNode!.debugLabel, 'cell ${row.rowKey} ${fact.code}',
      reason: 'курсор именно в «${fact.name}» новой строки, а не в соседней');
  await tester.enterText(
      find.byWidgetPredicate((w) => w is TextField && w.focusNode == cell.focusNode),
      value);
  await settle(tester, frames: 3);
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await settle(tester, frames: 6);
  expect(row.numbers[fact.code], double.parse(value),
      reason: 'факт записан в новую строку');
}

Future<void> _pause(WidgetTester tester, int seconds) async {
  for (var i = 0; i < seconds * 2; i++) {
    await tester.pump(const Duration(milliseconds: 250));
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('37192: позиции по штрихкоду и коду — онлайн и офлайн',
      (tester) async {
    final app = await bootApp(tester, login: _login);
    await app.sync.syncAndRefresh();
    await settle(tester);

    // ===== подготовка: строки хоста остаются, свои строки прошлых прогонов — долой =====
    final c = FillController(
        db: app.repo.db, api: app.api, taskId: _task, geo: app.geo);
    await c.load();
    expect(c.online, isTrue, reason: 'подготовка идёт на связи');
    FillField fieldOf(String code) => c.fields.firstWhere((x) => x.code == code,
        orElse: () => fail('в бланке задачи $_task нет поля $code'));
    final f = fieldOf(_field);
    expect(f.allowManual && f.allowFreeSubject, isTrue,
        reason: 'positions: ручное добавление и свободный ввод (сид #37192)');
    final strict = fieldOf(_strict);
    expect(strict.allowManual && !strict.allowFreeSubject, isTrue,
        reason: 'strict: ручное добавление без свободного ввода (сид #37192)');
    final fact = f.columns.firstWhere((x) => x.editable,
        orElse: () => fail('в поле нет ни одной вводимой колонки'));

    // строки хоста живут под ключами stk…; всё остальное — наше
    for (final r in [...f.rows]) {
      if (!r.rowKey.startsWith('stk')) await c.deleteRow(f, r);
    }
    for (final r in [...strict.rows]) {
      await c.deleteRow(strict, r);
    }
    await c.syncAll();
    await c.load();
    final hostRows = await _serverRows(app, _field);
    expect(hostRows.length, greaterThan(0),
        reason: 'строки от хоста на месте — сиды #36943/#37192 прогнаны');
    expect(await _serverRows(app, _strict), isEmpty);
    debugPrint('E2E_READY hostRows=${hostRows.length}');

    // ===== экран бланка со сканером-заглушкой =====
    final scans = <String>[];
    Future<String?> fakeScanner(BuildContext _) async =>
        scans.isEmpty ? null : scans.removeAt(0);
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    nav.push(MaterialPageRoute(
        builder: (_) => FillScreen(taskId: _task, scanner: fakeScanner)));
    await until(tester, 'экран бланка',
        () => find.byType(FillScreen).evaluate().isNotEmpty, seconds: 90);
    await until(tester, 'плитки бланка',
        () => find.byType(FillFieldTile).evaluate().isNotEmpty, seconds: 150);
    await settle(tester, frames: 20);

    Future<void> scan(String code) async {
      scans.add(code);
      await tester.tap(find.descendant(
          of: _sheet, matching: find.byIcon(Icons.qr_code_scanner)));
      await settle(tester, frames: 10);
    }

    FillRowData lastRow(String fieldCode) => _onScreen(tester, fieldCode).rows.last;

    // ===== 1. без предварительного ввода текста: кандидаты есть, тап добавляет =====
    var before = _onScreen(tester, _field).rows.length;
    await _openSheet(tester, _field);
    expect(find.descendant(of: _sheet, matching: find.textContaining('Записать текстом')),
        findsNothing, reason: 'без набора свободного ввода не предлагается');
    final candidate = find.descendant(
        of: _sheet, matching: find.textContaining('Сахар-песок'));
    expect(candidate, findsOneWidget,
        reason: 'кандидат из остатков показан до всякого набора');
    await tester.tap(candidate.first);
    await _sheetGone(tester);
    expect(_onScreen(tester, _field).rows.length, before + 1);
    final tapped = lastRow(_field);
    expect(tapped.subjectId, 'ITM36943-3');
    expect(tapped.subjectCode, isNull, reason: 'выбран тапом — кода нет');
    await _typeFact(tester, tapped, fact, '5');
    debugPrint('E2E_NO_TEXT_OK');

    // ===== 2. скан штрихкода товара из остатков: строка сразу, курсор в «Факт» =====
    before = _onScreen(tester, _field).rows.length;
    await _openSheet(tester, _field);
    await scan(_milkPack);
    await _sheetGone(tester);
    expect(_onScreen(tester, _field).rows.length, before + 1);
    final scanned = lastRow(_field);
    expect(scanned.subjectId, 'ITM36943-1');
    expect(scanned.subjectCode, _milkPack);
    await shot(tester, 'SHOT_scan_row');
    await _typeFact(tester, scanned, fact, '7');
    debugPrint('E2E_SCAN_OK');

    // ===== 3. ввод кода товара — так же =====
    before = _onScreen(tester, _field).rows.length;
    await _openSheet(tester, _field);
    await _submitCode(tester, _breadCode);
    await _sheetGone(tester);
    expect(_onScreen(tester, _field).rows.length, before + 1);
    final coded = lastRow(_field);
    expect(coded.subjectId, 'ITM36943-2');
    expect(coded.subjectCode, _breadCode);
    await _typeFact(tester, coded, fact, '3');
    debugPrint('E2E_CODE_OK');

    // ===== 4. штрихкод товара не из остатков, но из справочника — «вне системы» =====
    before = _onScreen(tester, _field).rows.length;
    await _openSheet(tester, _field);
    await scan(_kefirBarcode);
    await _sheetGone(tester);
    expect(_onScreen(tester, _field).rows.length, before + 1);
    final kefir = lastRow(_field);
    expect(kefir.subjectId, 'ITM36943-5');
    expect(kefir.subjectCode, _kefirBarcode);
    await _typeFact(tester, kefir, fact, '2');
    debugPrint('E2E_OFFSYSTEM_OK');

    // ===== 5а. неизвестный штрихкод при свободном вводе — строка с кодом =====
    before = _onScreen(tester, _field).rows.length;
    await _openSheet(tester, _field);
    await scan(_unknown);
    await until(tester, 'предложение внести позицию',
        () => find.byType(AlertDialog).evaluate().isNotEmpty,
        seconds: 30);
    await shot(tester, 'SHOT_free_dialog');
    await tester.enterText(
        find.descendant(
            of: find.byType(AlertDialog), matching: find.byType(TextField)),
        'Йогурт без карточки');
    await settle(tester, frames: 2);
    await tester.tap(find.widgetWithText(FilledButton, 'Внести'));
    await _sheetGone(tester);
    expect(_onScreen(tester, _field).rows.length, before + 1);
    final free = lastRow(_field);
    expect(free.subjectId, isNull);
    expect(free.subject, 'Йогурт без карточки');
    expect(free.subjectCode, _unknown);
    await _typeFact(tester, free, fact, '1');
    debugPrint('E2E_FREE_OK');

    // ===== 5б. неизвестный код без свободного ввода — понятный отказ =====
    final strictBefore = _onScreen(tester, _strict).rows.length;
    await _openSheet(tester, _strict);
    await _submitCode(tester, _unknown);
    await until(
        tester,
        'отказ по неизвестному коду',
        () => find
            .descendant(
                of: _sheet,
                matching: find.text('Товар с кодом «$_unknown» не найден'))
            .evaluate()
            .isNotEmpty,
        seconds: 30);
    expect(find.byType(AlertDialog), findsNothing,
        reason: 'без свободного ввода внести не предлагается');
    await shot(tester, 'SHOT_refuse');
    await _closeSheet(tester);
    expect(_onScreen(tester, _strict).rows.length, strictBefore);
    debugPrint('E2E_REFUSE_OK');

    // ===== сверка с сервером =====
    await c.syncAll();
    var server = await _serverRows(app, _field);
    expect(server.length, hostRows.length + 5, reason: 'ровно пять новых строк');
    expect(server[scanned.rowKey]!.subjectId, 'ITM36943-1');
    expect(server[scanned.rowKey]!.code, _milkPack);
    expect(server[scanned.rowKey]!.cells[fact.code], 7);
    expect(server[coded.rowKey]!.subjectId, 'ITM36943-2');
    expect(server[coded.rowKey]!.code, _breadCode);
    expect(server[kefir.rowKey]!.subjectId, 'ITM36943-5');
    expect(server[kefir.rowKey]!.offSystem, isTrue,
        reason: 'позиция не из остатков объекта помечена «вне системы»');
    expect(server[free.rowKey]!.subjectId, '', reason: 'неизвестный код — без ссылки');
    expect(server[free.rowKey]!.code, _unknown);
    expect(server[free.rowKey]!.subject, 'Йогурт без карточки');
    expect(server[tapped.rowKey]!.code, '');
    expect(await _serverRows(app, _strict), isEmpty);
    // пометка «вне системы» доезжает на экран при перезагрузке бланка, как при
    // «показать все» (#36780): здесь — на контроллере, тем же apiExecutionRows
    await c.load();
    expect(fieldOf(_field).rows.firstWhere((r) => r.rowKey == kefir.rowKey).offSystem,
        isTrue);
    debugPrint('E2E_SERVER_OK');

    // ===== 6. без связи — те же правила по кэшу бланка =====
    debugPrint('NET_OFF');
    await _pause(tester, 10);
    debugPrint('E2E_OFFLINE_READY');

    // без набора: кандидаты из кэша, тап добавляет
    before = _onScreen(tester, _field).rows.length;
    await _openSheet(tester, _field);
    final cached = find.descendant(of: _sheet, matching: find.textContaining('Хлеб'));
    expect(cached, findsOneWidget, reason: 'кандидаты из кэша показаны без набора');
    await tester.tap(cached.first);
    await _sheetGone(tester);
    expect(_onScreen(tester, _field).rows.length, before + 1);
    final offTapped = lastRow(_field);
    expect(offTapped.subjectId, 'ITM36943-2');
    await _typeFact(tester, offTapped, fact, '4');

    // скан товара из остатков — по штрихкодам кэша, курсор в «Факт»
    before = _onScreen(tester, _field).rows.length;
    await _openSheet(tester, _field);
    await scan(_butterBarcode);
    await _sheetGone(tester);
    expect(_onScreen(tester, _field).rows.length, before + 1);
    final offScanned = lastRow(_field);
    expect(offScanned.subjectId, 'ITM36943-4');
    expect(offScanned.subjectCode, _butterBarcode);
    await shot(tester, 'SHOT_offline_row');
    await _typeFact(tester, offScanned, fact, '6');

    // штрихкод, которого в кэше нет (кэш — доступное на объекте): внести с кодом,
    // название не указываем — строка подписана кодом
    before = _onScreen(tester, _field).rows.length;
    await _openSheet(tester, _field);
    await scan(_kefirBarcode);
    await until(tester, 'предложение внести позицию (офлайн)',
        () => find.byType(AlertDialog).evaluate().isNotEmpty,
        seconds: 30);
    await tester.tap(find.widgetWithText(FilledButton, 'Внести'));
    await _sheetGone(tester);
    expect(_onScreen(tester, _field).rows.length, before + 1);
    final offUnknown = lastRow(_field);
    expect(offUnknown.subjectId, isNull);
    expect(offUnknown.subject, isNull);
    expect(offUnknown.subjectCode, _kefirBarcode);
    expect(offUnknown.title, _kefirBarcode);
    await _typeFact(tester, offUnknown, fact, '1');

    // без свободного ввода — отказ и без связи
    await _openSheet(tester, _strict);
    await _submitCode(tester, _kefirBarcode);
    await until(
        tester,
        'отказ по неизвестному коду (офлайн)',
        () => find
            .descendant(
                of: _sheet,
                matching:
                    find.text('Товар с кодом «$_kefirBarcode» не найден'))
            .evaluate()
            .isNotEmpty,
        seconds: 30);
    await _closeSheet(tester);
    expect(_onScreen(tester, _strict).rows.length, strictBefore);
    debugPrint('E2E_OFFLINE_OK');

    // ===== сеть вернулась: очередь доезжает, дублей нет =====
    debugPrint('NET_ON');
    await _pause(tester, 12);
    c.online = true;
    await c.syncAll();
    expect(c.lastSyncError, isNull, reason: 'очередь ушла без отказов');
    server = await _serverRows(app, _field);
    expect(server.length, hostRows.length + 8,
        reason: 'пять строк онлайн и три офлайн, ровно по одной на добавление');
    expect(server[offScanned.rowKey]!.subjectId, 'ITM36943-4');
    expect(server[offScanned.rowKey]!.code, _butterBarcode);
    expect(server[offScanned.rowKey]!.cells[fact.code], 6);
    expect(server[offUnknown.rowKey]!.subjectId, '');
    expect(server[offUnknown.rowKey]!.code, _kefirBarcode);
    expect(server[offTapped.rowKey]!.subjectId, 'ITM36943-2');
    expect(await _serverRows(app, _strict), isEmpty);
    debugPrint('E2E_OFFLINE_SYNC_OK');

    debugPrint('ALL_OK_37192');
  });
}
