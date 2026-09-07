import '../../../models/fill.dart';
import 'boolean_field.dart';
import 'choice_field.dart';
import 'date_field.dart';
import 'field_editor.dart';
import 'number_field.dart';
import 'objectref_field.dart';
import 'photo_field.dart';
import 'score_field.dart';
import 'table_field.dart';
import 'text_field.dart';

export 'field_editor.dart';

/// Какой редактор какому типу поля положен — единственное место, где тип поля
/// превращается в контрол. Новый тип = свой файл с редактором + строка здесь.
const Map<FillFieldType, FillFieldEditor> fieldEditors = {
  FillFieldType.scale: ChoiceFieldEditor(),
  FillFieldType.choice: ChoiceFieldEditor(),
  FillFieldType.boolean: BooleanFieldEditor(),
  FillFieldType.number: NumberFieldEditor(),
  FillFieldType.score: ScoreFieldEditor(),
  FillFieldType.date: DateFieldEditor(),
  FillFieldType.photo: PhotoFieldEditor(),
  FillFieldType.table: TableFieldEditor(),
  FillFieldType.objectref: ObjectRefFieldEditor(),
  FillFieldType.longtext: TextFieldEditor(multiline: true),
  FillFieldType.scan: TextFieldEditor(scan: true),
  FillFieldType.text: TextFieldEditor(),
};

/// Редактор поля; неизвестный тип уже на разборе стал текстом ([FillFieldType.parse]),
/// запасной вариант здесь — на случай, если карта отстанет от перечисления.
FillFieldEditor editorFor(FillField f) =>
    fieldEditors[f.kind] ?? const TextFieldEditor();
