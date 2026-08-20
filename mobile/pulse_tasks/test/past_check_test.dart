import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_tasks/models/fill.dart';

// Просмотр прошлой проверки (#36778): что приезжает с сервера и как из этого
// складывается шапка. Сам экран — только чтение, поэтому проверяется модель:
// разбор новых полей, сборка полей общим ассемблером и строка «прошлая проверка».
void main() {
  test('prevNonconformity и новые поля шапки разбираются из JSON', () {
    final f = FillField.fromJson({
      'sectionIndex': 1,
      'fieldIndex': 2,
      'code': 'q1',
      'type': 'scale',
      'prevNonconformity': true,
    });
    expect(f.prevNonconformity, isTrue);

    final s = FillSummary.fromJson({
      'date': '2026-07-12T14:00:00',
      'executor': 'Иванова А.',
      'remarks': 3,
      'prevDate': '2026-06-01T09:30:00',
      'prevPercent': 78,
      'prevRemarks': 3,
    });
    expect(s.date, isNotNull);
    expect(s.executor, 'Иванова А.');
    expect(s.remarks, 3);
    expect(s.prevPercent, 78);
  });

  test('индексы фото: честный список сервера, дыры не теряют снимки', () {
    // после удаления снимка индексы не уплотняются — сервер шлёт «2,3»
    final f = FillField.fromJson({
      'sectionIndex': 1,
      'fieldIndex': 1,
      'code': 'clean',
      'type': 'scale',
      'photoCount': 2,
      'photoIndexes': '2,3',
    });
    expect(f.photoGalleryIndexes, [2, 3]);

    // старый сервер поля не шлёт — плотная нумерация от 1
    final old = FillField.fromJson({
      'sectionIndex': 1,
      'fieldIndex': 1,
      'code': 'clean',
      'type': 'scale',
      'photoCount': 2,
    });
    expect(old.photoGalleryIndexes, [1, 2]);
  });

  test('объект без прошлых проверок не несёт ни признака, ни итога', () {
    final f = FillField.fromJson({
      'sectionIndex': 1,
      'fieldIndex': 1,
      'code': 'q1',
      'type': 'scale',
    });
    expect(f.prevNonconformity, isFalse);
    final s = FillSummary.fromJson(const {});
    expect(s.prevDate, isNull);
    expect(s.prevRemarks, 0);
  });

  test('pastLine: дата обязательна, процент опционален, замечания склоняются', () {
    expect(FillSummary.pastLine('2026-07-12T14:00:00', 78, 3),
        contains('12.07'));
    // формат процента один на все экраны — см. FillSummary.formatPercent
    expect(FillSummary.pastLine('2026-07-12T14:00:00', 78, 3),
        contains('78%'));
    expect(FillSummary.pastLine('2026-07-12T14:00:00', 78, 1),
        endsWith('1 замечание'));
    expect(FillSummary.pastLine('2026-07-12T14:00:00', 78, 3),
        endsWith('3 замечания'));
    expect(FillSummary.pastLine('2026-07-12T14:00:00', 78, 11),
        endsWith('11 замечаний'));
    expect(FillSummary.pastLine('2026-07-12T14:00:00', null, 0),
        endsWith('без замечаний'));
    // прошлый год в дате виден: «полгода назад» и «вчера» — разные выводы
    expect(FillSummary.pastLine('2025-07-12T14:00:00', null, 0),
        contains('12.07.2025'));
  });

  test('assembleFillFields собирает поля с вариантами, колонками и строками', () {
    final fields = assembleFillFields(
      [
        {
          'sectionIndex': 2,
          'fieldIndex': 1,
          'code': 'b',
          'type': 'scale',
          'optionCode': 'no',
          'prevNonconformity': true,
        },
        {
          'sectionIndex': 1,
          'fieldIndex': 1,
          'code': 'a',
          'type': 'table',
        },
      ],
      [
        {'fieldCode': 'b', 'code': 'no', 'nonconformity': true},
        {'fieldCode': 'b', 'code': 'yes'},
      ],
      [
        {'fieldCode': 'a', 'colCode': 'qty', 'type': 'number', 'colIndex': 1},
      ],
      [
        {'fieldCode': 'a', 'rowIndex': 1, 'colCode': 'qty', 'number': 5},
      ],
    );
    // сортировка по секции и индексу: таблица из первой секции идёт первой
    expect(fields.map((f) => f.code).toList(), ['a', 'b']);
    expect(fields[0].columns.single.code, 'qty');
    expect(fields[0].rows.single.numbers['qty'], 5);
    expect(fields[1].selectedOption?.nonconformity, isTrue);
    expect(fields[1].prevNonconformity, isTrue);
  });
}
