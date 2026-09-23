import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_tasks/models/fill.dart';
import 'package:pulse_tasks/ui/widgets/fill_field_tile.dart';
import 'package:pulse_tasks/ui/widgets/pickers/ref_picker_sheet.dart';
import 'package:pulse_tasks/ui/widgets/pickers/row_subject_sheet.dart';

/// Ввод позиции по штрихкоду или коду (#37192).
///
/// Проверяются правила тикета на листе «Добавить позицию»: одно точное совпадение
/// закрывает лист сразу, несколько — список на выбор, нет среди доступного на объекте
/// — поиск по всему справочнику, нет нигде — внесение с сохранённым кодом при
/// разрешённом свободном вводе и отказ без него. Плюс сама модель совпадения
/// (RefCandidate.matchesCode — та же проверка, что exactSubject на сервере) и курсор
/// в первой вводимой ячейке только что добавленной строки.
///
/// Кандидатов отдаёт заглушка с правилами сервера; контроллер и очередь проверяются
/// в fill_table_test.dart против фейкового сервера.

const _milk = RefCandidate(
    id: 'ITM-1',
    name: 'Молоко 3,2 %',
    available: true,
    barcodes: ['4810000000011', '4810000000028']);
const _bread = RefCandidate(id: 'ITM-2', name: 'Хлеб', available: true);
const _kefir = RefCandidate(
    id: 'ITM-9', name: 'Кефир 1 %', available: false, barcodes: ['4810000000066']);

/// Второй товар с тем же штрихкодом, что у кефира: два точных совпадения.
const _kefirFat = RefCandidate(
    id: 'ITM-10',
    name: 'Кефир 2,5 %',
    available: false,
    barcodes: ['4810000000066']);

typedef _Search = Future<List<RefCandidate>> Function(String query,
    {bool allItems});

/// Поиск-заглушка с правилами сервера: [near] — доступное на объекте, [all] — весь
/// справочник; подстрока по названию и коду, точно по коду и штрихкоду, точные первыми.
_Search _search(List<RefCandidate> near, List<RefCandidate> all,
    {List<String>? log}) {
  return (String q, {bool allItems = false}) async {
    log?.add('${allItems ? 'all' : 'near'}:$q');
    final src = allItems ? all : near;
    return rankSubjects([
      for (final c in src)
        if (c.matchesQuery(q)) c
    ], q);
  };
}

/// Открывает лист кнопкой, как это делает таблица, и отдаёт результат выбора.
class _Host extends StatefulWidget {
  final bool allowFree;
  final _Search search;
  final Future<String?> Function()? scan;
  const _Host({required this.allowFree, required this.search, this.scan});

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  RefPick? picked;
  bool closed = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: TextButton(
        onPressed: () async {
          picked = await showModalBottomSheet<RefPick>(
            context: context,
            isScrollControlled: true,
            builder: (_) => RowSubjectSheet(
              title: 'Добавить позицию',
              allowFree: widget.allowFree,
              search: widget.search,
              scan: widget.scan,
            ),
          );
          closed = true;
        },
        child: const Text('open'),
      ),
    );
  }
}

Future<_HostState> _open(WidgetTester tester,
    {required bool allowFree,
    required _Search search,
    Future<String?> Function()? scan}) async {
  await tester.pumpWidget(MaterialApp(
      home: _Host(allowFree: allowFree, search: search, scan: scan)));
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  expect(find.byType(RowSubjectSheet), findsOneWidget);
  return tester.state<_HostState>(find.byType(_Host));
}

Finder get _sheetField => find.descendant(
    of: find.byType(RowSubjectSheet), matching: find.byType(TextField));

/// Набрать код и подтвердить его с клавиатуры (действие «поиск»).
Future<void> _submit(WidgetTester tester, String code) async {
  await tester.enterText(_sheetField, code);
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  group('модель совпадения', () {
    test('штрихкоды приходят строкой через запятую и лежат в кэше так же', () {
      final c = RefCandidate.fromJson({
        'subjectId': 'ITM-1',
        'name': 'Молоко',
        'available': true,
        'barcodes': '4810000000011, 4810000000028',
        'exact': true,
      });
      expect(c.barcodes, ['4810000000011', '4810000000028']);
      expect(c.exact, isTrue);
      expect(RefCandidate.fromJson(c.toJson()).barcodes, c.barcodes);
      // без штрихкодов — пустой список, а не ошибка
      expect(RefCandidate.fromJson({'subjectId': 'x', 'name': 'y'}).barcodes,
          isEmpty);
    });

    test('точное совпадение — по коду или штрихкоду, без учёта регистра', () {
      expect(_milk.matchesCode('4810000000028'), isTrue);
      expect(_milk.matchesCode(' itm-1 '), isTrue);
      expect(_milk.matchesCode('ITM'), isFalse, reason: 'начало кода — не точное');
      expect(_milk.matchesCode('4810000000029'), isFalse);
      expect(_milk.matchesCode(''), isFalse);
      expect(_bread.matchesCode('4810000000028'), isFalse);
      // exact от сервера — сверх местной проверки
      const said = RefCandidate(id: 'SKU-7', name: 'Товар', exact: true);
      expect(said.matchesCode('что угодно'), isTrue);
    });

    test('подстрока — по названию и по коду', () {
      expect(_milk.matchesQuery('молоко'), isTrue);
      expect(_milk.matchesQuery('itm-'), isTrue);
      expect(_milk.matchesQuery('4810000000011'), isTrue);
      expect(_milk.matchesQuery('хлеб'), isFalse);
      expect(_milk.matchesQuery(''), isTrue);
    });

    test('точные совпадения первыми, остальные в прежнем порядке', () {
      final ranked = rankSubjects([_bread, _kefir, _milk], 'ITM-1');
      expect(ranked.map((c) => c.id), ['ITM-1', 'ITM-2', 'ITM-9']);
      expect(rankSubjects([_bread, _milk], '').map((c) => c.id),
          ['ITM-2', 'ITM-1']);
    });
  });

  group('поиск по коду', () {
    test('одно точное среди доступного на объекте', () async {
      final log = <String>[];
      final res = await lookupByCode(
          '4810000000028', _search([_milk, _bread], [_milk, _bread, _kefir], log: log));
      expect(res.single, isTrue);
      expect(res.matches.single.id, 'ITM-1');
      expect(res.fromAll, isFalse);
      expect(log, ['near:4810000000028'], reason: 'во весь справочник не ходили');
    });

    test('нет на объекте — сразу во всём справочнике', () async {
      final log = <String>[];
      final res = await lookupByCode(
          '4810000000066', _search([_milk, _bread], [_milk, _bread, _kefir], log: log));
      expect(res.single, isTrue);
      expect(res.matches.single.id, 'ITM-9');
      expect(res.fromAll, isTrue);
      expect(log, ['near:4810000000066', 'all:4810000000066']);
    });

    test('несколько совпадений и ни одного', () async {
      final several = await lookupByCode('4810000000066',
          _search([_milk], [_milk, _kefir, _kefirFat]));
      expect(several.matches.map((c) => c.id), ['ITM-9', 'ITM-10']);
      final none = await lookupByCode('4810000000998', _search([_milk], [_milk]));
      expect(none.none, isTrue);
    });
  });

  group('лист «Добавить позицию»', () {
    testWidgets('список показан без набора текста — позиция добавляется тапом',
        (tester) async {
      final host = await _open(tester,
          allowFree: true, search: _search([_milk, _bread], [_milk, _bread]));
      expect(find.text('Молоко 3,2 %'), findsOneWidget);
      expect(find.text('Хлеб'), findsOneWidget);
      expect(find.textContaining('Записать текстом'), findsNothing);
      await tester.tap(find.text('Хлеб'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(host.picked?.id, 'ITM-2');
      expect(host.picked?.code, isNull, reason: 'выбран по названию — кода нет');
    });

    testWidgets('точное совпадение по коду закрывает лист сразу, с кодом в ответе',
        (tester) async {
      final host = await _open(tester,
          allowFree: false, search: _search([_milk, _bread], [_milk, _bread]));
      await _submit(tester, '4810000000028');
      expect(host.closed, isTrue);
      expect(host.picked?.id, 'ITM-1');
      expect(host.picked?.name, 'Молоко 3,2 %');
      expect(host.picked?.code, '4810000000028');
    });

    testWidgets('ввод кода товара работает так же, как скан', (tester) async {
      final host = await _open(tester,
          allowFree: false, search: _search([_milk, _bread], [_milk, _bread]));
      await _submit(tester, 'itm-2');
      expect(host.picked?.id, 'ITM-2');
      expect(host.picked?.code, 'itm-2');
    });

    testWidgets('скан кнопкой сканера — тот же путь', (tester) async {
      final host = await _open(tester,
          allowFree: false,
          search: _search([_milk, _bread], [_milk, _bread]),
          scan: () async => '4810000000011');
      await tester.tap(find.byIcon(Icons.qr_code_scanner));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(host.picked?.id, 'ITM-1');
      expect(host.picked?.code, '4810000000011');
    });

    testWidgets('без сканера кнопки сканера нет', (tester) async {
      await _open(tester, allowFree: false, search: _search([_milk], [_milk]));
      expect(find.byIcon(Icons.qr_code_scanner), findsNothing);
    });

    testWidgets('набор текста не добавляет позицию сам — только список',
        (tester) async {
      final host = await _open(tester,
          allowFree: false, search: _search([_milk, _bread], [_milk, _bread]));
      await tester.enterText(_sheetField, 'ITM-1');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 100));
      expect(host.closed, isFalse);
      expect(find.text('Молоко 3,2 %'), findsOneWidget);
      expect(find.text('Хлеб'), findsNothing);
    });

    testWidgets('нет на объекте, есть в справочнике — добавляется из него',
        (tester) async {
      final host = await _open(tester,
          allowFree: false,
          search: _search([_milk, _bread], [_milk, _bread, _kefir]));
      await _submit(tester, '4810000000066');
      expect(host.picked?.id, 'ITM-9');
      expect(host.picked?.code, '4810000000066');
    });

    testWidgets('несколько совпадений — список на выбор, выбор уносит код',
        (tester) async {
      final host = await _open(tester,
          allowFree: false,
          search: _search([_milk], [_milk, _kefir, _kefirFat]));
      await _submit(tester, '4810000000066');
      expect(host.closed, isFalse);
      expect(find.textContaining('Несколько совпадений'), findsOneWidget);
      expect(find.text('Кефир 1 %'), findsOneWidget);
      expect(find.text('Кефир 2,5 %'), findsOneWidget);
      expect(find.text('Молоко 3,2 %'), findsNothing);
      await tester.tap(find.text('Кефир 2,5 %'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(host.picked?.id, 'ITM-10');
      expect(host.picked?.code, '4810000000066');
    });

    testWidgets('неизвестный код при свободном вводе — внесение с сохранённым кодом',
        (tester) async {
      final host = await _open(tester,
          allowFree: true, search: _search([_milk], [_milk]));
      await _submit(tester, '4810000000998');
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.textContaining('4810000000998'), findsWidgets);
      await tester.enterText(
          find.descendant(
              of: find.byType(AlertDialog), matching: find.byType(TextField)),
          'Йогурт неизвестный');
      await tester.tap(find.text('Внести'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(host.closed, isTrue);
      expect(host.picked?.id, isNull);
      expect(host.picked?.name, 'Йогурт неизвестный');
      expect(host.picked?.code, '4810000000998');
    });

    testWidgets('неизвестный код, название не указано — строка только с кодом',
        (tester) async {
      final host = await _open(tester,
          allowFree: true, search: _search([_milk], [_milk]));
      await _submit(tester, '4810000000998');
      await tester.tap(find.text('Внести'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(host.picked?.name, isNull);
      expect(host.picked?.code, '4810000000998');
    });

    testWidgets('отмена внесения оставляет лист открытым с отказом', (tester) async {
      final host = await _open(tester,
          allowFree: true, search: _search([_milk], [_milk]));
      await _submit(tester, '4810000000998');
      await tester.tap(find.text('Отмена'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(host.closed, isFalse);
      expect(find.text('Товар с кодом «4810000000998» не найден'), findsOneWidget);
    });

    testWidgets('неизвестный код без свободного ввода — понятный отказ',
        (tester) async {
      final host = await _open(tester,
          allowFree: false, search: _search([_milk], [_milk]));
      await _submit(tester, '4810000000998');
      expect(host.closed, isFalse);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Товар с кодом «4810000000998» не найден'), findsOneWidget);
      expect(find.textContaining('Записать текстом'), findsNothing);
    });
  });

  group('таблица', () {
    const cols = [
      FillColumn(
          fieldCode: 'positions', code: 'plan', type: 'number', readonly: true),
      FillColumn(fieldCode: 'positions', code: 'fact', type: 'number'),
    ];

    FillField field(List<FillRowData> rows, {bool allowManual = true}) =>
        FillField(
          sectionIndex: 1,
          fieldIndex: 1,
          code: 'positions',
          name: 'Позиции',
          type: 'table',
          allowManual: allowManual,
          columns: cols,
          rows: rows,
        );

    Widget tile(FillField f,
            {Future<FillRowData?> Function(String?, String?, {String? code})?
                onAddRow,
            bool readOnly = false}) =>
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: readOnly
                  ? FillFieldTile(field: f, readOnly: true)
                  : FillFieldTile(
                      field: f,
                      onOption: (_) {},
                      onNumber: (_) {},
                      onText: (_) {},
                      onBool: (_) {},
                      onDatePick: () {},
                      onScan: () {},
                      onComment: (_) {},
                      onPhoto: () {},
                      onRemovePhoto: () {},
                      onDeleteShot: (_) {},
                      onCell: (_, __, ___) {},
                      onAddRow: onAddRow ?? (_, __, {code}) async => null,
                      onDeleteRow: (_) {},
                      onRowSubjectSearch: (_, {allItems = false}) async =>
                          const [],
                      onRef: (_, __) {},
                      onRefSearch: (_) async => const [],
                    ),
            ),
          ),
        );

    testWidgets('после добавления курсор встаёт в первую вводимую ячейку новой строки',
        (tester) async {
      final f = field([FillRowData(1, rowKey: 'k1', subject: 'Молоко')]);
      // поле без канала: «+ позиция» добавляет строку сразу, без листа
      await tester.pumpWidget(tile(f, onAddRow: (id, name, {code}) async {
        final r = FillRowData(2, rowKey: 'k2', subject: 'Хлеб', subjectCode: code);
        f.rows.add(r);
        return r;
      }));
      await tester.pump();
      expect(find.byType(TextField), findsOneWidget, reason: 'вводимая ячейка одна');

      await tester.tap(find.text('позиция'));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final focused = tester
          .widgetList<TextField>(find.byType(TextField))
          .where((t) => t.focusNode?.hasFocus == true)
          .toList();
      expect(focused.length, 1);
      expect(focused.single.focusNode!.debugLabel, 'cell k2 fact',
          reason: 'курсор в «Факт» именно новой строки, не в учёте и не в старой');
    });

    testWidgets('строка без названия подписана кодом, у названной код рядом',
        (tester) async {
      // в просмотре плитка рисует таблицу только у отвеченного поля — факт заполнен
      final f = field([
        FillRowData(1, rowKey: 'k1', subject: 'Молоко', subjectCode: '4810000000028')
          ..numbers['fact'] = 5,
        FillRowData(2, rowKey: 'k2', subjectCode: '4810000000998')
          ..numbers['fact'] = 1,
      ]);
      await tester.pumpWidget(tile(f, readOnly: true));
      await tester.pump();
      expect(find.text('Молоко'), findsOneWidget);
      expect(find.text('4810000000028'), findsOneWidget);
      expect(find.text('4810000000998'), findsOneWidget);
      expect(find.text('Без предмета'), findsNothing);
    });
  });
}
