// Сквозной набор: настоящий клиент приложения против настоящего сервера.
//
// Заглушки в test/ написаны вручную и расходятся с сервером там, где форма ответа или
// порядок вызовов не такие, как думал автор заглушки. Здесь клиент говорит с живым
// сервером (по умолчанию своя база 6.2 на 7681): экраны и контроллеры те же, что на
// телефоне, sqlite настоящий, сеть настоящая. Обычный `flutter test` этот каталог не
// трогает — сервер нужен поднятый. Запуск и окружение — mobile/pulse_tasks/README.md,
// раздел «Сквозной набор с сервером», и support/e2e.dart.
//
// Сценарий, который упал, — либо дефект клиента или сервера, либо расхождение их
// договорённостей: смотреть журнал ручек (Phone.client.log) в выводе упавшего теста.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_tasks/data/fill_controller.dart';
import 'package:pulse_tasks/data/simple_controller.dart';
import 'package:pulse_tasks/models/fill.dart';
import 'package:pulse_tasks/ui/fill_screen.dart';
import 'package:pulse_tasks/ui/task_detail_screen.dart';

import 'support/e2e.dart';

FillField _field(FillController c, String code) =>
    c.fields.firstWhere((f) => f.code == code,
        orElse: () => fail('в бланке ${c.taskId} нет поля $code'));

/// Поле ввода примечания у плитки: ближайшая колонка вокруг подписи «Примечание».
Finder _commentField() => find.descendant(
    of: find.ancestor(of: find.text('Примечание'), matching: find.byType(Column)).first,
    matching: find.byType(TextField));

bool _showsText(String s) =>
    find.textContaining(s).evaluate().isNotEmpty ||
    find
        .byWidgetPredicate((w) => w is TextField && w.controller?.text == s)
        .evaluate()
        .isNotEmpty;

void main() {
  setUpAll(e2eSetUp);
  tearDownAll(e2eTearDown);

  testWidgets('карточка, затем бланк: первый вход заводит выполнение, поля на экране',
      (t) async {
    await t.runAsync(() async {
      const task = 'ZZZ-E2E-OPEN';
      final p = await Phone.boot();
      // основной путь: список → карточка → «Заполнить». Карточка читает бланк задачи,
      // по которой выполнения ещё нет, — и не должна помешать бланку его завести
      await t.pumpWidget(host(p, const TaskDetailScreen(taskId: task)));
      await until(t, () => p.client.calls.contains('apiExecutionBundle'));
      await settle(t);
      expect(p.client.calls, isNot(contains('apiStartExecution')),
          reason: 'карточка выполнение не заводит');

      await t.pumpWidget(host(p, const FillScreen(taskId: task)));
      await until(t, () => find.textContaining('ZZZ f1').evaluate().isNotEmpty);

      expect(find.textContaining('ZZZ f1'), findsOneWidget, reason: '${p.client.log}');
      expect(find.text('Полей нет'), findsNothing);
      expect(p.client.calls, contains('apiStartExecution'),
          reason: 'первый вход заводит выполнение');
      expect(((await serverBundle(task))['info'] as Map)['date'], isNotNull,
          reason: 'на сервере выполнение есть');
      expect(await serverStatus(task), 'in progress');

      await shutdown(t, p);
    });
  });

  test('значения простых типов уходят на сервер и читаются обратно', () async {
    const task = 'ZZZ-E2E-TYPES';
    final p = await Phone.boot();
    final c = FillController(db: p.app.repo.db, api: p.api, taskId: task);
    await c.load();
    await c.setText(_field(c, 't1'), 'Строка');
    await c.setText(_field(c, 'l1'), 'Первая\nвторая');
    await c.setNumber(_field(c, 'n1'), 12.5);
    await c.setBool(_field(c, 'b1'), true);
    await c.setOption(_field(c, 'c1'), 'good');
    await c.setDate(_field(c, 'd1'), '2026-11-12');
    await c.setNumber(_field(c, 's1'), 4);
    await c.setText(_field(c, 'k1'), '4810000000017');
    await c.syncAll();
    c.dispose();

    expect(await p.app.repo.db.fill.getFieldOutbox(task), isEmpty,
        reason: 'всё уехало: ${p.client.log}');
    final f = {
      for (final code in ['t1', 'l1', 'n1', 'b1', 'c1', 'd1', 's1', 'k1'])
        code: await serverField(task, code)
    };
    expect(f['t1']!['text'], 'Строка');
    expect(f['l1']!['text'], 'Первая\nвторая');
    expect(f['n1']!['number'], 12.5);
    expect(f['b1']!['bool'], true);
    expect(f['c1']!['optionCode'], 'good');
    expect('${f['d1']!['date']}', startsWith('2026-11-12'));
    expect(f['s1']!['number'], 4);
    expect(f['k1']!['text'], '4810000000017');

    // другой телефон открывает тот же бланк: значения разобраны из ответа сервера
    final other = await Phone.boot();
    final r = FillController(db: other.app.repo.db, api: other.api, taskId: task);
    await r.load();
    expect(_field(r, 't1').text, 'Строка');
    expect(_field(r, 'l1').text, 'Первая\nвторая');
    expect(_field(r, 'n1').number, 12.5);
    expect(_field(r, 'b1').boolValue, true);
    expect(_field(r, 'c1').optionCode, 'good');
    expect(_field(r, 'd1').date, startsWith('2026-11-12'));
    expect(_field(r, 's1').number, 4);
    expect(_field(r, 'k1').text, '4810000000017');
    r.dispose();
    other.dispose();
    p.dispose();
  });

  testWidgets('примечание: второй заход без правки его не стирает', (t) async {
    await t.runAsync(() async {
      const task = 'ZZZ-E2E-NOTE';
      final p = await Phone.boot();

      // заход 1: написать примечание к первому пункту
      await t.pumpWidget(host(p, const FillScreen(taskId: task)));
      await until(t, () => find.textContaining('ZZZ f1').evaluate().isNotEmpty);
      await t.tap(find.text('Примечание').first);
      await t.pump();
      await t.enterText(_commentField(), 'моё примечание');
      await t.pump();
      FocusManager.instance.primaryFocus?.unfocus();
      await settle(t);
      await closeScreen(t);
      expect((await serverField(task, 'f1'))['comment'], 'моё примечание',
          reason: '${p.client.log}');

      // заход 2: только открыть и закрыть. Ответ агрегата придержан — плитка
      // заведомо собирается из кэша, где примечания ещё нет, и получает его с ответом
      p.client.log.clear();
      p.client.delayOnce['apiExecutionBundle'] = const Duration(milliseconds: 1500);
      await t.pumpWidget(host(p, const FillScreen(taskId: task)));
      await until(t, () => _showsText('моё примечание'));
      expect(_showsText('моё примечание'), isTrue,
          reason: 'примечание из ответа видно на экране');
      await shutdown(t, p);

      expect(p.client.calls, isNot(contains('apiSetField')),
          reason: 'заход без правки ничего не пишет: ${p.client.log}');
      expect((await serverField(task, 'f1'))['comment'], 'моё примечание');
    });
  });

  testWidgets('набрал ответ и сразу «Завершить»: ответ уходит раньше завершения',
      (t) async {
    await t.runAsync(() async {
      const task = 'ZZZ-E2E-TYPEFIN';
      final p = await Phone.boot();
      await t.pumpWidget(host(p, const FillScreen(taskId: task)));
      await until(t, () => find.textContaining('ZZZ f1').evaluate().isNotEmpty);
      p.client.log.clear();

      // обязательное поле набрано, курсор остался в нём
      await t.enterText(find.byType(TextField).first, 'ответ в фокусе');
      await t.pump();
      await t.tap(find.widgetWithText(FilledButton, 'Завершить'));
      await until(t, () => p.client.calls.contains('apiFinishExecution'));
      await settle(t);

      expect(find.textContaining('Заполните обязательные'), findsNothing);
      final calls = p.client.calls;
      expect(calls, containsAllInOrder(['apiSetField', 'apiFinishExecution']),
          reason: '${p.client.log}');
      expect((await serverField(task, 'f1'))['text'], 'ответ в фокусе');
      expect(await serverStatus(task), 'done');

      await shutdown(t, p);
    });
  });

  test('таблица: строка, число, текст и дата в ячейках', () async {
    const task = 'ZZZ-E2E-TABLE';
    final p = await Phone.boot();
    final c = FillController(db: p.app.repo.db, api: p.api, taskId: task);
    await c.load();
    final tab = _field(c, 'tab');
    FillColumn col(String code) => tab.columns.firstWhere((x) => x.code == code);
    final row = await c.addRow(tab);
    await c.setCellNumber(tab, row, col('qty'), 7);
    await c.setCellText(tab, row, col('ser'), 'А-17');
    await c.setCellText(tab, row, col('dt'), '2027-01-31');
    await c.syncAll();
    c.dispose();

    final cells = await serverCells(task, row.rowKey);
    expect(cells['qty']?['number'], 7, reason: '${p.client.log}');
    expect(cells['ser']?['text'], 'А-17');
    expect('${cells['dt']?['date']}', startsWith('2027-01-31'));

    final other = await Phone.boot();
    final r = FillController(db: other.app.repo.db, api: other.api, taskId: task);
    await r.load();
    final back = _field(r, 'tab').rows.single;
    expect(back.rowKey, row.rowKey);
    expect(back.numbers['qty'], 7);
    expect(back.texts['ser'], 'А-17');
    expect(back.texts['dt'], startsWith('2027-01-31'));
    r.dispose();
    other.dispose();
    p.dispose();
  });

  testWidgets('завершение и просмотр завершённого бланка', (t) async {
    await t.runAsync(() async {
      const task = 'ZZZ-E2E-FIN';
      final p = await Phone.boot();
      final c = FillController(db: p.app.repo.db, api: p.api, taskId: task);
      await c.load();
      await c.setText(_field(c, 'f1'), 'готово');
      expect(await c.finish(), isTrue, reason: '${c.error} ${p.client.log}');
      c.dispose();
      expect(await serverStatus(task), 'done');

      // просмотр с другого телефона: бланк только для чтения, ответ на месте
      final other = await Phone.boot();
      await t.pumpWidget(host(other, const FillScreen(taskId: task)));
      await until(t, () => _showsText('готово'));
      expect(_showsText('готово'), isTrue, reason: '${other.client.log}');
      expect(find.text('Завершено'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Завершить'), findsNothing);
      await shutdown(t, other);
      expect(other.client.calls, isNot(contains('apiSetField')));
      expect(await serverStatus(task), 'done');
      p.dispose();
    });
  });

  test('приёмка: сдать, принять; сдать, вернуть и сдать заново', () async {
    final exec = await Phone.boot();
    final author = await Phone.boot(auth: authorAuth, name: 'ZZZ Приёмщик');

    Future<void> submit(String task, String answer, {bool restart = false}) async {
      final c = FillController(
          db: exec.app.repo.db, api: exec.api, taskId: task, restartHint: restart);
      await c.load();
      await c.setText(_field(c, 'f1'), answer);
      expect(await c.finish(), isTrue, reason: '${c.error} ${exec.client.log}');
      c.dispose();
    }

    // принять
    await submit('ZZZ-E2E-ACC1', 'сдаю');
    expect(await serverStatus('ZZZ-E2E-ACC1'), 'acceptance');
    await author.app.repo.refresh();
    expect(author.app.repo.viewOf('ZZZ-E2E-ACC1')?.awaitingDecision, isTrue,
        reason: 'у приёмщика задача ждёт решения');
    await author.app.repo.acceptTask('ZZZ-E2E-ACC1');
    await author.app.repo.syncDecisions();
    expect(await serverStatus('ZZZ-E2E-ACC1'), 'done', reason: '${author.client.log}');

    // вернуть
    await submit('ZZZ-E2E-ACC2', 'первый вариант');
    final firstDate = ((await serverBundle('ZZZ-E2E-ACC2'))['info'] as Map)['date'];
    await author.app.repo.refresh();
    await author.app.repo.returnTask('ZZZ-E2E-ACC2', 'ZZZ переделать');
    await author.app.repo.syncDecisions();
    expect(await serverStatus('ZZZ-E2E-ACC2'), isNot('acceptance'),
        reason: '${author.client.log}');

    // исполнитель видит возврат, бланк заводит новое выполнение, сдаёт снова
    await exec.app.repo.refresh();
    final view = exec.app.repo.viewOf('ZZZ-E2E-ACC2');
    expect(view?.restartsExecution, isTrue, reason: 'возврат открывает новое выполнение');
    exec.client.log.clear();
    await submit('ZZZ-E2E-ACC2', 'исправил', restart: true);
    expect(exec.client.calls, contains('apiStartExecution'));
    final info = (await serverBundle('ZZZ-E2E-ACC2'))['info'] as Map;
    expect(info['date'], isNot(firstDate), reason: 'новое выполнение, а не прежнее');
    expect((await serverField('ZZZ-E2E-ACC2', 'f1'))['text'], 'исправил');
    expect(await serverStatus('ZZZ-E2E-ACC2'), 'acceptance');
    author.dispose();
    exec.dispose();
  });

  test('поручение: старт, снимок, комментарий, завершение', () async {
    const task = 'ZZZ-E2E-ISSUE';
    final p = await Phone.boot();
    final s = SimpleExecutionController(db: p.app.repo.db, api: p.api, taskId: task);
    await s.load();
    expect(p.client.calls, contains('apiStartSimple'), reason: '${p.client.log}');
    await s.addPhoto(pngFile().path);
    await s.setComment('ZZZ сделано');
    expect(await s.finish(), isTrue, reason: '${p.client.log}');
    await s.syncAll();
    s.dispose();

    final info = await serverSimple(task);
    expect(info['finished'], isTrue, reason: '$info ${p.client.log}');
    expect(info['comment'], 'ZZZ сделано');
    expect(info['photoCount'], 1);
    expect(await serverStatus(task), 'done');
    p.dispose();
  });

  test('без связи ответ и завершение ждут в очереди и доезжают с возвратом связи',
      () async {
    const task = 'ZZZ-E2E-OFF';
    final p = await Phone.boot();
    final c = FillController(db: p.app.repo.db, api: p.api, taskId: task);
    await c.load(); // при связи: выполнение заведено, бланк в кэше

    p.client.down = true;
    await c.setText(_field(c, 'f1'), 'офлайн');
    expect(await c.finish(), isTrue, reason: 'без связи завершение встаёт в очередь');
    c.dispose();
    expect(await p.app.repo.db.fill.getFieldOutbox(task), hasLength(1));
    expect((await serverField(task, 'f1'))['text'], isNull);
    expect(await serverStatus(task), 'in progress');

    // связь вернулась: тот же путь, что у приложения при появлении сети
    p.client.down = false;
    await p.app.sync.syncAndRefresh();
    expect((await serverField(task, 'f1'))['text'], 'офлайн', reason: '${p.client.log}');
    expect(await serverStatus(task), 'done');
    expect(await p.app.repo.db.fill.getFieldOutbox(task), isEmpty);
    p.dispose();
  });

  test('«всегда фото»: завершить нельзя до снимка, вердикт раздела виден сразу',
      () async {
    const task = 'ZZZ-E2E-ALWAYS';
    final p = await Phone.boot();
    final c = FillController(db: p.app.repo.db, api: p.api, taskId: task);
    await c.load();
    expect(_field(c, 'a1').requirePhotoAlways, isTrue,
        reason: 'флаг приходит при открытии бланка: ${p.client.log}');
    await c.setOption(_field(c, 'a1'), 'good');
    await c.syncAll();

    // ответ есть, снимка нет: телефон и сервер одинаково требуют свидетельство
    expect(c.missingEvidence, 1);
    expect(c.canFinish, isFalse);
    expect(((await serverBundle(task))['info'] as Map)['missingEvidence'], 1);
    expect(await c.finish(), isFalse, reason: 'отказ на телефоне, а не после завершения');
    expect(c.error, contains('фото'));
    expect(await serverStatus(task), 'in progress');
    c.dispose();

    // другой телефон открывает бланк: вердикт раздела — из того же ответа, сразу
    final other = await Phone.boot();
    final r = FillController(db: other.app.repo.db, api: other.api, taskId: task);
    await r.load();
    expect(r.summary.sections.values.map((s) => s.verdict), ['Пройдено'],
        reason: '${other.client.log}');
    expect(r.canFinish, isFalse);

    await r.addPhoto(_field(r, 'a1'), pngFile().path);
    await r.syncAll();
    expect(r.missingEvidence, 0);
    expect(((await serverBundle(task))['info'] as Map)['missingEvidence'], isNull,
        reason: 'на сервере свидетельство тоже есть');
    expect(await r.finish(), isTrue, reason: '${r.error} ${other.client.log}');
    expect(await serverStatus(task), 'done');
    r.dispose();
    other.dispose();
    p.dispose();
  });

  test('задача по пресету без связи: расчётная колонка не редактируется, расчёт и итог видны',
      () async {
    final p = await Phone.boot();
    await p.app.home.refreshQuickCreate();
    final data = p.app.home.quickCreate;
    final preset = data.actions.firstWhere((a) => a.code == 'zzze2e',
        orElse: () => fail('пресет zzze2e не приехал: ${p.client.log}'));
    final template = data.templateOf(preset);
    expect(template, isNotNull, reason: 'шаблон пресета приехал');
    final objectId = p.app.repo.viewOf('ZZZ-E2E-OPEN')!.task.objectId!;

    // без связи: задача и бланк — на телефоне, из шаблона пресета
    p.client.down = true;
    final id = await p.app.repo.createTask(
      typeId: preset.typeId!,
      templateCode: preset.templateCode,
      template: template,
      executionKind: preset.executionKind,
      objectId: objectId,
      name: 'ZZZ E2E по пресету',
      quickActionCode: preset.code,
    );
    final c = FillController(db: p.app.repo.db, api: p.api, taskId: id);
    await c.load();
    final tab = _field(c, 'tab');
    FillColumn col(String code) => tab.columns.firstWhere((x) => x.code == code);
    expect(col('sum').computed, isTrue, reason: 'шаблон описывает расчёт колонки');
    expect(col('sum').editable, isFalse, reason: 'в расчётную колонку не вводят');
    final row = await c.addRow(tab);
    await c.setCellNumber(tab, row, col('qty'), 2);
    await c.setCellNumber(tab, row, col('price'), 3);
    final shown = _field(c, 'tab');
    expect(shown.rows.single.cellValue(col('sum')), 6, reason: 'расчёт виден без связи');
    expect(shown.columnTotal(col('sum')), 6, reason: 'итог колонки виден без связи');
    c.dispose();

    // связь вернулась: задача, бланк и ячейки доезжают, сервер считает то же
    p.client.down = false;
    await p.app.sync.syncAndRefresh();
    final cells = await serverCells(id, row.rowKey);
    expect(cells['qty']?['number'], 2, reason: '${p.client.log}');
    expect(cells['sum']?['value'], 6, reason: 'расчёт сервера совпал с телефоном');
    expect(await p.app.repo.db.fill.getCellOutbox(id), isEmpty,
        reason: 'ни одна ячейка не застряла отказом');
    p.dispose();
  });
}
