import 'package:flutter/material.dart';

import '../../../models/fill.dart';
import 'choice_field.dart';
import 'field_editor.dart';

/// «Да / Нет» — две кнопки-варианта на всю ширину.
class BooleanFieldEditor extends FillFieldEditor {
  const BooleanFieldEditor();

  @override
  Widget value(BuildContext context, FillField f, FieldActions actions) =>
      fieldValue(f.boolValue == true ? 'Да' : 'Нет');

  @override
  Widget input(BuildContext context, FillField f, FieldActions actions) {
    return Row(
      children: [
        Expanded(
          child: OptionButton(
            label: 'Да',
            selected: f.boolValue == true,
            nonconformity: false,
            onTap: () => actions.onBool!(true),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: OptionButton(
            label: 'Нет',
            selected: f.boolValue == false,
            nonconformity: false,
            onTap: () => actions.onBool!(false),
          ),
        ),
      ],
    );
  }
}
