import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_tasks/models/fill.dart';
import 'package:pulse_tasks/ui/widgets/fill_field_tile.dart';

/// Настройки и значения полей бланка: снимок — ответ только у «Фото», обязательная
/// колонка, итоги и расчёт как на сервере, ячейки «выбор» и «да/нет», записанное
/// несоответствие на просмотре. Сервер проверяет то же в fill_settings_check.lsf.

FillField _field(String type,
        {bool required = false,
        int serverPhotos = 0,
        String? optionCode,
        List<FillOption> options = const []}) =>
    FillField(
      sectionIndex: 1,
      fieldIndex: 1,
      code: 'f',
      name: 'Поле',
      type: type,
      required: required,
      serverPhotoCount: serverPhotos,
      optionCode: optionCode,
      options: options,
    );

FillRowData _row(String key,
    {Map<String, double?> numbers = const {},
    Map<String, String?> texts = const {}}) {
  final r = FillRowData(1, rowKey: key);
  r.numbers.addAll(numbers);
  r.texts.addAll(texts);
  return r;
}

FillField _table(List<FillColumn> columns, List<FillRowData> rows,
        {bool required = false}) =>
    FillField(
      sectionIndex: 1,
      fieldIndex: 1,
      code: 'tb',
      name: 'Позиции',
      type: 'table',
      required: required,
      columns: columns,
      rows: rows,
    );

const _qty = FillColumn(fieldCode: 'tb', code: 'qty', type: 'number');
const _price = FillColumn(fieldCode: 'tb', code: 'price', type: 'number');
const _cost = FillColumn(
    fieldCode: 'tb',
    code: 'cost',
    type: 'number',
    calcKind: 'product',
    operandA: 'qty',
    operandB: 'price',
    totalMode: 'avg');
const _choiceOptions = [
  FillColumnOption('good', 'Хорошо'),
  FillColumnOption('bad', 'Плохо')
];

void main() {
  group('снимок — ответ только у «Фото»', () {
    test('обязательная шкала со снимком, но без выбора, не отвечена', () {
      final f = _field('scale', required: true, serverPhotos: 1);
      expect(f.answered, isFalse);
      expect(f.missingRequiredValue, isTrue);
    });

    test('поле «Фото» со снимком отвечено', () {
      expect(_field('photo', required: true, serverPhotos: 1).answered, isTrue);
    });

    test('табличное поле со снимком, но без строк, не отвечено', () {
      final f = _table(const [_qty], const []);
      f.serverPhotoCount = 1;
      expect(f.answered, isFalse);
    });
  });

  group('обязательная колонка', () {
    const req = FillColumn(
        fieldCode: 'tb', code: 'req', type: 'number', required: true);

    test('пустая ячейка в любой строке держит завершение', () {
      final f = _table([_qty, req], [
        _row('k1', numbers: {'qty': 1, 'req': 5}),
        _row('k2', numbers: {'qty': 2}),
      ]);
      expect(f.answered, isTrue);
      expect(f.tableIncomplete, isTrue);
      expect(f.missingRequiredValue, isTrue);
    });

    test('заполненная во всех строках — отпускает', () {
      final f = _table([_qty, req], [
        _row('k1', numbers: {'qty': 1, 'req': 5}),
        _row('k2', numbers: {'qty': 2, 'req': 0}),
      ]);
      expect(f.tableIncomplete, isFalse);
      expect(f.missingRequiredValue, isFalse);
    });

    test('обязательной не бывает колонка только для чтения и расчётная', () {
      const ro = FillColumn(
          fieldCode: 'tb',
          code: 'ro',
          type: 'number',
          readonly: true,
          required: true);
      const calc = FillColumn(
          fieldCode: 'tb',
          code: 'c',
          type: 'number',
          calcKind: 'sum',
          operandA: 'qty',
          constB: 1,
          required: true);
      final f = _table([_qty, ro, calc], [
        _row('k1', numbers: {'qty': 1})
      ]);
      expect(f.tableIncomplete, isFalse);
    });
  });

  group('итоги и расчёт как на сервере (таблица находки 11.4)', () {
    test('расчёт 1,1 × 3 округляется до четырёх знаков — 3,3', () {
      final r = _row('k1', numbers: {'qty': 1.1, 'price': 3});
      expect(r.cellValue(_cost), 3.3);
    });

    test('count считает текст, выбор, дату и «да/нет», а не только числа', () {
      for (final col in const [
        FillColumn(fieldCode: 'tb', code: 'x', type: 'text', totalMode: 'count'),
        FillColumn(fieldCode: 'tb', code: 'x', type: 'choice', totalMode: 'count'),
        FillColumn(fieldCode: 'tb', code: 'x', type: 'date', totalMode: 'count'),
      ]) {
        final f = _table([col], [
          _row('k1', texts: {'x': 'a'}),
          _row('k2', texts: {'x': '2026-11-18'}),
          _row('k3'),
        ]);
        expect(f.columnTotal(col), 2, reason: col.type);
      }
      const ok = FillColumn(
          fieldCode: 'tb', code: 'ok', type: 'boolean', totalMode: 'count');
      final f = _table([ok], [
        _row('k1', numbers: {'ok': 1}),
        _row('k2', numbers: {'ok': 0}),
        _row('k3'),
      ]);
      expect(f.columnTotal(ok), 2, reason: '«нет» — тоже значение');
    });

    test('count и avg расчётной колонки — по посчитанному', () {
      const cnt = FillColumn(
          fieldCode: 'tb',
          code: 'cost',
          type: 'number',
          calcKind: 'product',
          operandA: 'qty',
          operandB: 'price',
          totalMode: 'count');
      final rows = [
        _row('k1', numbers: {'qty': 1.1, 'price': 3}),
        _row('k2', numbers: {'qty': 2, 'price': 1}),
        _row('k3', numbers: {'qty': 5}),
      ];
      expect(_table([_qty, _price, cnt], rows).columnTotal(cnt), 2);
      expect(_table([_qty, _price, _cost], rows).columnTotal(_cost), 2.65);
    });
  });

  group('разбор ответа сервера', () {
    test('поле: «Макс. длина», уникальный предмет, записанное несоответствие', () {
      final list = assembleFillFields([
        {
          'sectionIndex': 1,
          'fieldIndex': 1,
          'code': 'tx',
          'type': 'text',
          'maxLen': 5,
        },
        {
          'sectionIndex': 1,
          'fieldIndex': 2,
          'code': 'sc',
          'type': 'scale',
          'optionCode': 'bad',
          'nonconformity': true,
        },
        {
          'sectionIndex': 1,
          'fieldIndex': 3,
          'code': 'tb',
          'type': 'table',
          'uniqueSubject': true,
        },
      ], [
        // вариант «Плохо» после завершения потерял отметку несоответствия
        {'fieldCode': 'sc', 'code': 'bad', 'name': 'Плохо', 'nonconformity': false},
      ], [], []);
      final tx = list[0], sc = list[1], tb = list[2];
      expect(tx.maxLen, 5);
      expect(tx.textLimit, 5);
      expect(_field('text').textLimit, 500);
      expect(tb.uniqueSubject, isTrue);
      expect(sc.nonconformity, isFalse, reason: 'пересчёт по текущим вариантам');
      expect(sc.shownNonconformity, isTrue, reason: 'просмотр — записанным');
    });

    test('колонка: обязательность и варианты; ячейка: код, подпись, «да/нет»', () {
      final list = assembleFillFields([
        {'sectionIndex': 1, 'fieldIndex': 1, 'code': 'tb', 'type': 'table'},
      ], [], [
        {
          'fieldCode': 'tb',
          'colCode': 'kind',
          'type': 'choice',
          'required': true,
          'options': [
            {'code': 'good', 'name': 'Хорошо'},
            {'code': 'bad', 'name': 'Плохо'},
          ],
        },
        {'fieldCode': 'tb', 'colCode': 'ok', 'type': 'boolean', 'colIndex': 1},
      ], [
        {
          'fieldCode': 'tb',
          'rowIndex': 1,
          'rowKey': 'k1',
          'colCode': 'kind',
          'optionCode': 'bad',
          'optionName': 'Плохо',
        },
        {
          'fieldCode': 'tb',
          'rowIndex': 1,
          'rowKey': 'k1',
          'colCode': 'ok',
          'bool': false,
        },
      ]);
      final f = list.single;
      final kind = f.columns.firstWhere((c) => c.code == 'kind');
      final ok = f.columns.firstWhere((c) => c.code == 'ok');
      expect(kind.required, isTrue);
      expect(kind.isChoice && kind.editable, isTrue);
      expect(kind.optionName('bad'), 'Плохо');
      expect(ok.isBool && ok.editable, isTrue);
      final row = f.rows.single;
      expect(row.texts['kind'], 'bad');
      expect(row.optionNames['kind'], 'Плохо');
      expect(row.numbers['ok'], 0);
      expect(f.answered, isTrue, reason: 'выбор и «да/нет» — значения ячеек');
    });

    test('выбор без вариантов (старый сервер) показывается, но не редактируется', () {
      const col = FillColumn(fieldCode: 'tb', code: 'kind', type: 'choice');
      expect(col.editable, isFalse);
    });
  });

  group('экран таблицы', () {
    const kind = FillColumn(
        fieldCode: 'tb',
        code: 'kind',
        name: 'Оценка',
        type: 'choice',
        required: true,
        options: _choiceOptions);
    const ok = FillColumn(
        fieldCode: 'tb', code: 'ok', name: 'Ценник', type: 'boolean');

    Future<List<String>> pump(WidgetTester tester, FillField f,
        {bool readOnly = false}) async {
      final calls = <String>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: FillFieldTile(
            field: f,
            onComment: (_) {},
            actions: FieldActions(
              readOnly: readOnly,
              onOption: (_) {},
              onNumber: (_) {},
              onText: (_) {},
              onBool: (_) {},
              onDatePick: () {},
              onScan: () {},
              onPhoto: () {},
              onRemovePhoto: () {},
              onDeleteShot: (_) {},
              onCell: (r, c, v) => calls.add('${c.code}=$v'),
              onCellText: (r, c, v) => calls.add('${c.code}=$v'),
              onAddRow: (_, __, {code}) async => null,
              onDeleteRow: (_) {},
              onRowSubjectSearch: (_, {allItems = false}) async => const [],
              onRef: (_, __) {},
              onRefSearch: (_) async => const [],
            ),
          ),
        ),
      ));
      await tester.pump();
      return calls;
    }

    testWidgets('просмотр: подпись варианта и «Нет», обязательная — со звёздочкой',
        (tester) async {
      final f = _table([kind, ok], [
        _row('k1', numbers: {'ok': 0}, texts: {'kind': 'bad'})
      ]);
      await pump(tester, f, readOnly: true);
      expect(find.text('Плохо'), findsOneWidget);
      expect(find.text('Нет'), findsOneWidget);
      expect(find.text('Оценка *'), findsOneWidget);
    });

    testWidgets('ввод касанием: «да/нет» переключается, вариант выбирается списком',
        (tester) async {
      final f = _table([kind, ok], [_row('k1')]);
      final calls = await pump(tester, f);
      // две пустые ячейки — прочерками
      await tester.tap(find.text('—').last);
      await tester.pump();
      expect(calls, ['ok=1.0']);
      await tester.tap(find.text('—').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Хорошо'));
      await tester.pumpAndSettle();
      expect(calls, ['ok=1.0', 'kind=good']);
    });
  });
}
