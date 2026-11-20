import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_tasks/models/fill.dart';
import 'package:pulse_tasks/ui/widgets/fill/field_editor.dart';
import 'package:pulse_tasks/ui/widgets/fill_field_tile.dart';

/// Поля бланка на плитке: балл не выходит за максимум и достигает его, просмотр не
/// пишет «Нет» и «в норме», которых проверяющий не ставил, диалог точного числа
/// закрывается без ошибки, ответ снимается повторным нажатием, неразборчивое число в
/// ячейке не стирает записанное. Колбэки — журналом: что плитка отдала бы экрану.

class _Log {
  final numbers = <double?>[];
  final bools = <bool?>[];
  final options = <String?>[];
  final cells = <double?>[];
  var dateCleared = 0;
}

Widget _bare(Widget child) =>
    MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child)));

FillField _field(String type,
        {double weight = 1,
        double? step,
        double? number,
        bool? boolValue,
        String? optionCode,
        String? date,
        double? minNorm,
        double? maxNorm,
        int serverPhotoCount = 0,
        List<FillOption> options = const [],
        List<FillColumn> columns = const [],
        List<FillRowData> rows = const []}) =>
    FillField(
      sectionIndex: 1,
      fieldIndex: 1,
      code: 'f',
      name: 'Поле',
      type: type,
      weight: weight,
      step: step,
      number: number,
      boolValue: boolValue,
      optionCode: optionCode,
      date: date,
      minNorm: minNorm,
      maxNorm: maxNorm,
      serverPhotoCount: serverPhotoCount,
      options: options,
      columns: columns,
      rows: rows,
    );

FillFieldTile _edit(FillField f, _Log l) => FillFieldTile(
      field: f,
      onComment: (_) {},
      actions: FieldActions(
        onOption: l.options.add,
        onNumber: l.numbers.add,
        onText: (_) {},
        onBool: l.bools.add,
        onDatePick: () {},
        onDateClear: () => l.dateCleared++,
        onScan: () {},
        onPhoto: () {},
        onPhotoSource: (_) {},
        onRemovePhoto: () {},
        onDeleteShot: (_) {},
        onCell: (r, c, v) {
          r.numbers[c.code] = v;
          l.cells.add(v);
        },
        onCellText: (r, c, v) => r.texts[c.code] = v,
        onAddRow: (a, b, {code}) async => null,
        onDeleteRow: (_) {},
        onRowSubjectSearch: (q, {allItems = false}) async => const [],
        onRef: (a, b) {},
        onRefSearch: (q) async => const [],
      ),
    );

FillFieldTile _view(FillField f) => FillFieldTile(
    field: f,
    actions: FieldActions(
      readOnly: true,
      photoLoader: (i, {required thumb}) async => null,
    ),
  );

void main() {
  testWidgets('балл: «Полный балл» — ровно максимум, «+» у края не выходит за него',
      (t) async {
    // максимум 5 при шаге 2 давал 6 (сервер — 500), 0,75 без шага — 1, 0,3 — 0,5,
    // а при шаге 0,3 максимум 1 был недостижим (0,9)
    for (final c in const [(5.0, 2.0), (0.75, null), (0.3, null), (1.0, 0.3)]) {
      final l = _Log();
      await t.pumpWidget(_bare(_edit(_field('score', weight: c.$1, step: c.$2), l)));
      await t.tap(find.text('Полный балл'));
      expect(l.numbers, [c.$1], reason: 'максимум ${c.$1}, шаг ${c.$2}');
    }
    for (final c in const [
      (5.0, 2.0, 4.0),
      (0.75, null, 0.5),
      (0.3, null, 0.0),
      (1.0, 0.3, 0.9),
    ]) {
      final l = _Log();
      await t.pumpWidget(_bare(_edit(
          _field('score', weight: c.$1, step: c.$2, number: c.$3), l)));
      await t.tap(find.byIcon(Icons.add_circle_outline));
      expect(l.numbers, [c.$1],
          reason: 'с ${c.$3} шаг вверх упирается в максимум ${c.$1}');
    }
  });

  testWidgets('балл: повторное «Полный балл» и «0» снимают ответ', (t) async {
    final l = _Log();
    await t.pumpWidget(_bare(_edit(_field('score', weight: 5, number: 5), l)));
    await t.tap(find.text('Полный балл'));
    await t.pumpWidget(_bare(_edit(_field('score', weight: 5, number: 0), l)));
    await t.tap(find.text('0'));
    expect(l.numbers, [null, null]);
  });

  testWidgets('да/нет: просмотр без значения не пишет «Нет»; повторное нажатие '
      'снимает ответ', (t) async {
    // ответа нет, а снимок есть — поле «отвечено» снимком
    await t.pumpWidget(
        _bare(_view(_field('boolean', serverPhotoCount: 1))));
    expect(find.text('Нет'), findsNothing,
        reason: '«Нет», которого проверяющий не ставил');
    await t.pumpWidget(_bare(_view(_field('boolean', boolValue: false))));
    expect(find.text('Нет'), findsOneWidget);

    final l = _Log();
    await t.pumpWidget(_bare(_edit(_field('boolean', boolValue: true), l)));
    await t.tap(find.text('Да'));
    await t.tap(find.text('Нет'));
    expect(l.bools, [null, false]);
  });

  testWidgets('число без нормы: «в норме» нет ни в просмотре, ни при вводе; с '
      'нормой — есть', (t) async {
    await t.pumpWidget(_bare(_view(_field('number', number: 12))));
    expect(find.text('12'), findsOneWidget);
    expect(find.text('в норме'), findsNothing);
    await t.pumpWidget(_bare(_edit(_field('number', number: 12), _Log())));
    expect(find.text('в норме'), findsNothing);

    await t.pumpWidget(_bare(_view(_field('number', number: 12, maxNorm: 20))));
    expect(find.text('в норме'), findsOneWidget);
    await t.pumpWidget(
        _bare(_edit(_field('number', number: 25, maxNorm: 20), _Log())));
    expect(find.text('вне нормы'), findsOneWidget);
  });

  testWidgets('диалог точного числа закрывается без ошибки; «1e999» — не число',
      (t) async {
    final l = _Log();
    await t.pumpWidget(_bare(_edit(_field('number'), l)));
    Future<void> type(String s) async {
      await t.tap(find.text('—'));
      await t.pumpAndSettle();
      await t.enterText(
          find.descendant(
              of: find.byType(AlertDialog), matching: find.byType(TextField)),
          s);
      await t.tap(find.text('Готово').last);
      await t.pumpAndSettle();
    }

    await type('10,22');
    expect(t.takeException(), isNull,
        reason: 'контроллер поля жив, пока диалог доигрывает уход');
    expect(l.numbers, [10.22]);

    await type('1e999');
    expect(l.numbers, [10.22], reason: 'бесконечность на сервер не уходит');
    expect(find.text('Это не число'), findsOneWidget);
  });

  testWidgets('степпер: 1,1 − 0,5 — это 0,6 без двоичного хвоста', (t) async {
    final l = _Log();
    await t.pumpWidget(_bare(_edit(_field('number', number: 1.1), l)));
    await t.tap(find.byIcon(Icons.remove));
    expect(l.numbers, [0.6]);
    expect(trimNum(double.infinity), 'Infinity',
        reason: 'вставленное «1e999» не роняет плитку');
  });

  testWidgets('выбор: повторное нажатие выбранного варианта снимает ответ',
      (t) async {
    final l = _Log();
    await t.pumpWidget(_bare(_edit(
        _field('choice', optionCode: 'yes', options: const [
          FillOption(fieldCode: 'f', code: 'yes', name: 'Годен'),
          FillOption(fieldCode: 'f', code: 'no', name: 'Брак'),
        ]),
        l)));
    await t.tap(find.text('Годен'));
    await t.tap(find.text('Брак'));
    expect(l.options, [null, 'no']);
  });

  testWidgets('дата: ДД.ММ.ГГГГ, у поставленной — «Очистить»', (t) async {
    final l = _Log();
    await t.pumpWidget(_bare(_edit(_field('date', date: '2026-11-05'), l)));
    expect(find.text('05.11.2026'), findsOneWidget);
    await t.tap(find.text('Очистить'));
    expect(l.dateCleared, 1);

    await t.pumpWidget(_bare(_edit(_field('date'), l)));
    expect(find.text('Очистить'), findsNothing, reason: 'стирать нечего');

    await t.pumpWidget(_bare(_view(_field('date', date: '2026-11-05'))));
    expect(find.text('05.11.2026'), findsOneWidget);
    expect(find.text('Очистить'), findsNothing, reason: 'просмотр не правит');
  });

  testWidgets('ячейка-число: «1 000» — тысяча; неразборчивое не стирает записанное '
      'и говорит почему; клавиатура со знаком', (t) async {
    final row = FillRowData(1, rowKey: 'k1', subject: 'Товар')..numbers['n'] = 5;
    final l = _Log();
    await t.pumpWidget(_bare(_edit(
        _field('table',
            columns: const [
              FillColumn(fieldCode: 'f', code: 'n', name: 'Факт', type: 'number'),
            ],
            rows: [row]),
        l)));
    final cell = find.byType(TextField).first;
    expect(t.widget<TextField>(cell).keyboardType,
        const TextInputType.numberWithOptions(decimal: true, signed: true));

    await t.enterText(cell, '1 000');
    await t.pump();
    FocusManager.instance.primaryFocus?.unfocus();
    await t.pump();
    expect(l.cells, [1000]);
    expect(row.numbers['n'], 1000);

    // по пути к «12.3.4» модель принимает разборчивое «12.3» — итог возвращается к
    // числу до правки, а не к приставке
    await t.enterText(cell, '12.3');
    await t.pump();
    expect(row.numbers['n'], 12.3, reason: 'расчёт следует за вводом');
    await t.enterText(cell, '12.3.4');
    await t.pump();
    expect(row.numbers['n'], 12.3, reason: 'неразборчивое модель не трогает');
    FocusManager.instance.primaryFocus?.unfocus();
    await t.pump();
    expect(l.cells, [1000], reason: 'в очередь не ушли ни очистка, ни приставка');
    expect(row.numbers['n'], 1000);
    expect(t.widget<TextField>(cell).controller!.text, '1000');
    expect(find.text('Это не число'), findsOneWidget);
  });
}
