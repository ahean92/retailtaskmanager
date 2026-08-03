import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_tasks/models/fill.dart';

FillField _numberField() => FillField(
      sectionIndex: 1,
      fieldIndex: 1,
      code: 'signal',
      type: 'number',
      minNorm: 20,
      maxNorm: 100,
      required: true,
    );

FillField _scanField() =>
    FillField(sectionIndex: 1, fieldIndex: 1, code: 'iccid', type: 'scan');

void main() {
  test('fromJson maps type/norms/required and current values', () {
    final f = FillField.fromJson({
      'sectionIndex': 1,
      'fieldIndex': 2,
      'code': 'signal',
      'type': 'number',
      'minNorm': 20,
      'maxNorm': 100,
      'required': true,
      'number': 65,
      'hasPhoto': true,
    });
    expect(f.type, 'number');
    expect(f.required, isTrue);
    expect(f.number, 65);
    expect(f.hasServerPhoto, isTrue);
    expect(f.answered, isTrue);
  });

  test('number in norm vs out of norm drives nonconformity', () {
    final ok = _numberField()..number = 65;
    final low = _numberField()..number = 5;
    expect(ok.inNorm, isTrue);
    expect(ok.nonconformity, isFalse);
    expect(low.inNorm, isFalse);
    expect(low.nonconformity, isTrue);
  });

  test('a scan field is answered once text is set', () {
    final f = _scanField();
    expect(f.answered, isFalse);
    f.text = '8970101234567890001';
    expect(f.answered, isTrue);
  });

  test('option nonconformity propagates and requires a photo', () {
    final f = FillField(
      sectionIndex: 1,
      fieldIndex: 1,
      code: 'q',
      type: 'scale',
      requirePhoto: true,
      options: const [
        FillOption(fieldCode: 'q', code: 'yes'),
        FillOption(fieldCode: 'q', code: 'no', nonconformity: true),
      ],
    )..optionCode = 'no';
    expect(f.nonconformity, isTrue);
    expect(f.needsPhoto, isTrue);
    f.photoPath = '/tmp/x.jpg';
    expect(f.hasPhoto, isTrue);
    expect(f.needsPhoto, isFalse);
  });

  test('resolution label lookup', () {
    expect(ResolutionOption.labelOf('done'), 'Выполнено');
    expect(ResolutionOption.labelOf('revisit'), 'Требуется повторный визит');
  });

  test('a table field is answered once an editable cell is filled', () {
    final f = FillField(
      sectionIndex: 1,
      fieldIndex: 1,
      code: 'positions',
      type: 'table',
      required: true,
      columns: const [
        FillColumn(fieldCode: 'positions', code: 'item', type: 'text', readonly: true),
        FillColumn(fieldCode: 'positions', code: 'qty', type: 'number', unit: 'шт'),
      ],
      rows: [FillRowData(1)..texts['item'] = 'Товар 1'],
    );
    // only a read-only cell is set → not answered yet
    expect(f.answered, isFalse);
    // enter the editable qty → answered
    f.rows.first.numbers['qty'] = 5;
    expect(f.answered, isTrue);
    expect(f.rows.first.hasValue('qty'), isTrue);
  });
}
