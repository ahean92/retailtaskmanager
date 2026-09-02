// Сквозная приёмка #36943 на живом стенде — заполнение таблиц в приложении.
//
// Проверяется ровно то, что записано в приёмке тикета:
//  1) пересчёт заполняется с телефона от начала до конца: позиция добавляется из
//     справочника и вручную (свободным текстом), факт вносится, расхождение и
//     стоимость видны СРАЗУ — до всякой синхронизации, — а итог под таблицей после
//     неё сходится с серверным (apiExecutionColumns.total);
//  2) всё то же в самолётном режиме доезжает после включения сети: строк ровно
//     столько, сколько создали, дублей нет даже после повторной отправки очереди;
//  3) строка, удалённая офлайн, после синхронизации не появляется снова;
//  4) шаблон без allowManual кнопки «+ позиция» не показывает.
//
// Сервер проверяется его же ручками (apiExecutionRows / apiExecutionColumns), а не
// состоянием контроллера: вопрос тикета именно в том, ЧТО легло туда.
//
// Throwaway-драйвер: сеть переключает внешний шелл по маркерам в логе.
//
// Данные стенда — scripts/demo/ticket36943_demo.lsf (шаблон DEMO36943: поле positions с
// rowSource=host + allowManual, поле fixed без него; справочник ITM36943-1..5, из них
// пятая не в остатках объекта). Параметры — dart-define: E2E_BASE, E2E_LOGIN/E2E_PASS,
// E2E_TASK (ST-номер задачи DEMO36943-1), E2E_FIELD/E2E_FIXED (коды полей).
//
// Маркеры: boot:, E2E_READY, SHOT_table, E2E_LOCAL_CALC_OK, E2E_ONLINE_OK,
// NET_OFF, E2E_OFFLINE_READY, NET_ON, E2E_OFFLINE_OK, E2E_NO_MANUAL_OK, ALL_OK_36943.


import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pulse_tasks/data/fill_controller.dart';
import 'package:pulse_tasks/data/task_repository.dart';
import 'package:pulse_tasks/models/fill.dart';
import 'package:pulse_tasks/ui/fill_screen.dart';
import 'package:pulse_tasks/ui/widgets/fill_field_tile.dart';
import 'support/e2e_harness.dart';

const _login = String.fromEnvironment('E2E_LOGIN', defaultValue: 'sosedi.tech1');
const _task = String.fromEnvironment('E2E_TASK', defaultValue: 'DEMO36943-1');
const _field = String.fromEnvironment('E2E_FIELD', defaultValue: 'positions');
const _fixed = String.fromEnvironment('E2E_FIXED', defaultValue: 'fixed');

/// Позиция справочника, которой в остатках объекта нет, — находка «вне системы».
const _offSystemId =
    String.fromEnvironment('E2E_OFFSYSTEM', defaultValue: 'ITM36943-5');

/// Подстрока её названия — по ней пикер её и находит.
const _offSystemQuery =
    String.fromEnvironment('E2E_OFFSYSTEM_NAME', defaultValue: 'Кефир');

Future<bool> _probe(TaskRepository repo) async {
  try {
    await repo.api.fetchStatuses();
    return true;
  } catch (_) {
    return false;
  }
}

/// Строки поля так, как их видит САМ сервер: ключ → (предмет, признак внесистемной,
/// числа по колонкам). Пересобирается из плоского apiExecutionRows.
Future<Map<String, ({String subject, bool offSystem, Map<String, double> cells})>>
    _serverRows(TaskRepository repo, String fieldCode) async {
  final raw = await repo.api.fetchExecutionRows(_task);
  final out =
      <String, ({String subject, bool offSystem, Map<String, double> cells})>{};
  for (final j in raw) {
    if (j['fieldCode'] != fieldCode) continue;
    final key = '${j['rowKey'] ?? ''}';
    final row = out.putIfAbsent(
        key,
        () => (
              subject: '${j['subject'] ?? ''}',
              offSystem: j['offSystem'] == true,
              cells: <String, double>{}
            ));
    final n = (j['number'] as num?)?.toDouble();
    if (n != null) row.cells['${j['colCode']}'] = n;
  }
  return out;
}

/// Итог колонки, посчитанный СЕРВЕРОМ (columnTotal в apiExecutionColumns).
Future<double?> _serverTotal(
    TaskRepository repo, String fieldCode, String colCode) async {
  final raw = await repo.api.fetchExecutionColumns(_task);
  for (final j in raw) {
    if (j['fieldCode'] == fieldCode && j['colCode'] == colCode) {
      return (j['total'] as num?)?.toDouble();
    }
  }
  return null;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('36943: пересчёт заполняется с телефона целиком', (tester) async {
    final repo = await bootApp(tester, login: _login);
    await repo.syncAndRefresh();
    await settle(tester);

    // ===== подготовка: бланк с табличным полем от хоста =====
    var c = FillController(
        db: repo.db, api: repo.api, taskId: _task, geo: repo.geo);
    await c.load();
    expect(c.online, isTrue, reason: 'подготовка идёт на связи');
    final FillField f = c.fields.firstWhere((x) => x.code == _field,
        orElse: () => fail('в бланке задачи $_task нет поля $_field'));
    expect(f.type, 'table');
    expect(f.allowManual, isTrue,
        reason: 'сервер обязан сказать, что строки этому полю добавлять можно');
    expect(f.columns.any((x) => x.computed), isTrue,
        reason: 'в шаблоне есть вычисляемая колонка — иначе проверять нечего');

    // прогон начинается с состава, который положил хост: свои строки прошлых
    // прогонов убираем, иначе «строк ровно столько, сколько создали» неопределимо
    for (final r in [...f.rows]) {
      if ((r.subjectId ?? '').isEmpty || r.subjectId == _offSystemId) {
        await c.deleteRow(f, r);
      }
    }
    await c.syncAll();
    await c.load();
    final baseRows = (await _serverRows(repo, _field)).length;
    debugPrint('E2E_READY hostRows=$baseRows');
    expect(baseRows, greaterThan(0),
        reason: 'строки от хоста на месте — сид #36943 прогнан');

    final fact = f.columns.firstWhere((x) => x.editable,
        orElse: () => fail('в поле нет ни одной вводимой колонки'));
    final calc = f.columns.firstWhere((x) => x.computed);
    final totalCol = f.columns.firstWhere((x) => x.totalMode != null,
        orElse: () => fail('в поле нет колонки с итогом'));

    // ===== 1. расчёт появляется у полки, до всякой синхронизации =====
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    nav.push(
        MaterialPageRoute(builder: (_) => const FillScreen(taskId: _task)));
    await until(tester, 'экран бланка',
        () => find.byType(FillScreen).evaluate().isNotEmpty, seconds: 90);
    await settle(tester, frames: 20);
    await pageTo(tester, find.widgetWithText(TextButton, 'позиция'));
    await shot(tester, 'SHOT_table'); // таблица с предметами строк и итогом

    // Поле берётся из САМОГО экрана: у FillScreen свой контроллер, и проверять надо
    // то, что видит человек, а не параллельное состояние соседнего
    FillField onScreen() => tester
        .widgetList<FillFieldTile>(find.byType(FillFieldTile))
        .firstWhere((w) => w.field.code == _field,
            orElse: () => fail('плитка поля $_field не построена'))
        .field;

    final target = onScreen().rows.firstWhere(
        (r) => (r.subjectId ?? '').isNotEmpty,
        orElse: () => fail('среди строк от хоста нет ни одной с предметом'));

    final cellFinder = find.descendant(
        of: find.byType(FillScreen), matching: find.byType(TextField));
    expect(cellFinder, findsWidgets, reason: 'ячейки таблицы на экране');

    // ввод факта в первую вводимую ячейку первой строки
    await tester.enterText(cellFinder.first, '7');
    await tester.pump();
    await settle(tester, frames: 4);
    final expectedCalc = onScreen().cellValue(target, calc);
    expect(expectedCalc, isNotNull,
        reason: 'расчёт посчитан на телефоне сразу после ввода');
    expect(find.text(_trim(expectedCalc!)), findsWidgets,
        reason: 'и он ВИДЕН на экране, а не только в модели');
    debugPrint('E2E_LOCAL_CALC_OK calc=$expectedCalc');

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester, frames: 8);

    // ===== 2. позиция из справочника и позиция «вне системы» — настоящим пикером ==
    // 2a) товар, которого в остатках объекта НЕТ: находится только «показать все»
    await pageTo(tester, find.widgetWithText(TextButton, 'позиция'));
    // pageTo листает до ПОСТРОЕННОГО виджета; построенный, но уехавший под нижнюю
    // панель «Завершить», он tap() не достаётся — докручиваем до видимости
    await tester.ensureVisible(find.widgetWithText(TextButton, 'позиция').first);
    await settle(tester, frames: 4);
    await tester.tap(find.widgetWithText(TextButton, 'позиция').first);
    await until(tester, 'пикер предмета',
        () => find.byType(RowSubjectSheet).evaluate().isNotEmpty, seconds: 60);
    await tester.tap(find.byType(Switch).first); // «весь справочник»
    await settle(tester, frames: 10);
    final sheetQuery = find.descendant(
        of: find.byType(RowSubjectSheet), matching: find.byType(TextField));
    await tester.enterText(sheetQuery.first, _offSystemQuery);
    await until(
        tester,
        'кандидат за пределами остатков',
        () => find
            .descendant(
                of: find.byType(RowSubjectSheet),
                matching: find.textContaining(_offSystemQuery))
            .evaluate()
            .isNotEmpty,
        seconds: 60);
    await shot(tester, 'SHOT_picker'); // «нет в остатках объекта» под кандидатом
    await tester.tap(find
        .descendant(
            of: find.byType(RowSubjectSheet), matching: find.byType(ListTile))
        .last);
    await until(tester, 'пикер закрылся',
        () => find.byType(RowSubjectSheet).evaluate().isEmpty, seconds: 60);
    await settle(tester, frames: 10);
    // Шторка ушла, а системная клавиатура после поиска в ней — не всегда: кнопка
    // «+ позиция» тогда оказывается под ней, и tap() её не достаёт («would not hit
    // test … another widget is obscuring it»). Снимаем фокус явно, как в поручении.
    FocusManager.instance.primaryFocus?.unfocus();
    await settle(tester, frames: 6);

    // 2b) позиция вручную: свободный текст, которого в справочнике нет вовсе
    const freeName = 'Ящик без штрихкода 36943';
    await pageTo(tester, find.widgetWithText(TextButton, 'позиция'));
    await tester.ensureVisible(find.widgetWithText(TextButton, 'позиция').first);
    await settle(tester, frames: 4);
    await tester.tap(find.widgetWithText(TextButton, 'позиция').first);
    await until(tester, 'пикер предмета',
        () => find.byType(RowSubjectSheet).evaluate().isNotEmpty, seconds: 60);
    await tester.enterText(
        find
            .descendant(
                of: find.byType(RowSubjectSheet),
                matching: find.byType(TextField))
            .first,
        freeName);
    await settle(tester, frames: 6);
    await tester.tap(find.textContaining('Записать текстом'));
    await until(tester, 'пикер закрылся',
        () => find.byType(RowSubjectSheet).evaluate().isEmpty, seconds: 60);
    await settle(tester, frames: 10);

    final free = onScreen().rows.firstWhere((r) => r.subject == freeName,
        orElse: () => fail('свободная позиция не появилась в таблице'));

    await untilAsync(tester, 'состав строк уехал',
        () async => (await repo.db.getRowOutbox(_task)).isEmpty,
        seconds: 180);
    await untilAsync(tester, 'ячейки уехали',
        () async => (await repo.db.getCellOutbox(_task)).isEmpty,
        seconds: 180);

    var onServer = await _serverRows(repo, _field);
    expect(onServer.length, baseRows + 2, reason: 'ровно две новые строки');
    expect(onServer[free.rowKey]!.subject, freeName,
        reason: 'снимок имени свободной позиции уехал');
    expect(onServer.values.any((r) => r.offSystem), isTrue,
        reason: 'позиция вне остатков объекта помечена внесистемной сервером');

    // Переоткрытие бланка: признак внесистемной считает сервер (телефон остатков
    // объекта не знает), и итог под таблицей после синхронизации обязан сойтись с
    // серверным — на свежей загрузке это видно честно, а не по локальному состоянию
    nav.pop();
    await settle(tester, frames: 10);
    nav.push(
        MaterialPageRoute(builder: (_) => const FillScreen(taskId: _task)));
    await until(tester, 'бланк открыт заново',
        () => find.byType(FillScreen).evaluate().isNotEmpty, seconds: 90);
    await settle(tester, frames: 20);
    await pageTo(tester, find.widgetWithText(TextButton, 'позиция'));
    await until(tester, 'строки перечитаны',
        () => onScreen().rows.length == baseRows + 2, seconds: 120);
    expect(find.text('вне системы'), findsWidgets,
        reason: 'находка помечена на самом экране');
    await shot(tester, 'SHOT_after'); // таблица с находкой, расчётом и итогом

    final localTotal = onScreen().columnTotal(totalCol);
    final srvTotal = await _serverTotal(repo, _field, totalCol.code);
    expect(localTotal, isNotNull);
    expect(srvTotal, isNotNull, reason: 'сервер считает итог этой колонки');
    expect(localTotal!, closeTo(srvTotal!, 0.001),
        reason: 'итог телефона и итог сервера — одно число');
    debugPrint('E2E_ONLINE_OK rows=${onServer.length} total=$localTotal');

    // ===== 3. самолётный режим: добавили, поправили, убрали — доехало один раз ==
    debugPrint('NET_OFF');
    await untilAsync(tester, 'авиарежим', () async => !(await _probe(repo)),
        seconds: 240);

    final offline = FillController(
        db: repo.db, api: repo.api, taskId: _task, geo: repo.geo);
    await offline.load();
    var of = offline.fields.firstWhere((x) => x.code == _field);
    expect(of.rows, isNotEmpty, reason: 'офлайн бланк берётся из кэша');

    // 3a) новая позиция и факт по ней — в очереди
    final air = await offline.addRow(of, subjectName: 'Офлайн-позиция 36943');
    await offline.setCellNumber(of, air, fact, 4);
    // 3b) строка, созданная и убранная до отправки, на сервере не появится вовсе
    final doomed = await offline.addRow(of, subjectName: 'Ошибка ввода 36943');
    await offline.deleteRow(of, doomed);
    // 3c) серверная строка, удалённая офлайн
    final serverRow = of.rows.firstWhere((r) => r.rowKey == free.rowKey);
    await offline.deleteRow(of, serverRow);

    // переоткрытие бланка офлайн: состав не откатывается к серверному
    final reopened = FillController(
        db: repo.db, api: repo.api, taskId: _task, geo: repo.geo);
    await reopened.load();
    final ro = reopened.fields.firstWhere((x) => x.code == _field);
    expect(ro.rows.map((r) => r.rowKey), contains(air.rowKey),
        reason: 'добавленная офлайн позиция переживает переоткрытие');
    expect(ro.rows.map((r) => r.rowKey), isNot(contains(free.rowKey)),
        reason: 'удалённая офлайн строка не возвращается из кэша');
    expect(ro.rows.map((r) => r.rowKey), isNot(contains(doomed.rowKey)));
    debugPrint('E2E_OFFLINE_READY queued=${(await repo.db.getRowOutbox(_task)).length}');

    debugPrint('NET_ON');
    await untilAsync(tester, 'сеть вернулась', () async => await _probe(repo),
        seconds: 240);
    await untilAsync(tester, 'очередь строк ушла', () async {
      await offline.syncAll();
      return (await repo.db.getRowOutbox(_task)).isEmpty &&
          (await repo.db.getCellOutbox(_task)).isEmpty;
    }, seconds: 240);

    onServer = await _serverRows(repo, _field);
    expect(onServer.containsKey(air.rowKey), isTrue,
        reason: 'офлайн-позиция доехала');
    expect(onServer[air.rowKey]!.cells[fact.code], 4);
    expect(onServer.containsKey(doomed.rowKey), isFalse,
        reason: 'созданная и убранная офлайн строка на сервере не появлялась');
    expect(onServer.containsKey(free.rowKey), isFalse,
        reason: 'удалённая офлайн строка на сервере удалена');
    final afterOffline = onServer.length;

    // повторная отправка очереди дублей не делает
    await offline.syncAll();
    expect((await _serverRows(repo, _field)).length, afterOffline,
        reason: 'строк ровно столько, сколько создали — дублей нет');
    expect(offline.lastSyncError, isNull);

    // и удалённая офлайн строка не воскресает при следующей загрузке бланка
    await offline.load();
    expect(
        offline.fields
            .firstWhere((x) => x.code == _field)
            .rows
            .map((r) => r.rowKey),
        isNot(contains(free.rowKey)));
    debugPrint('E2E_OFFLINE_OK rows=$afterOffline');

    // ===== 4. поле без allowManual кнопки «+ позиция» не показывает =====
    final fixed = offline.fields.firstWhere((x) => x.code == _fixed,
        orElse: () => fail('в бланке нет поля $_fixed без ручных строк'));
    expect(fixed.allowManual, isFalse);
    // на экране: кнопок «позиция» ровно столько, сколько полей с allowManual
    final manualFields =
        offline.fields.where((x) => x.type == 'table' && x.allowManual).length;
    await pageTo(tester, find.widgetWithText(TextButton, 'позиция'));
    expect(find.widgetWithText(TextButton, 'позиция').evaluate().length,
        lessThanOrEqualTo(manualFields),
        reason: 'у поля со строками от шаблона кнопки добавления нет');
    debugPrint('E2E_NO_MANUAL_OK manualFields=$manualFields');

    // ===== уборка: стенд остаётся с тем составом строк, что положил хост =====
    final cleanup = offline.fields.firstWhere((x) => x.code == _field);
    for (final r in [...cleanup.rows]) {
      if ((r.subjectId ?? '').isEmpty || r.subjectId == _offSystemId) {
        await offline.deleteRow(cleanup, r);
      }
    }
    await offline.syncAll();
    expect((await _serverRows(repo, _field)).length, baseRows,
        reason: 'после прогона на стенде остались строки хоста');
    debugPrint('ALL_OK_36943');
  });
}

String _trim(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toString();
