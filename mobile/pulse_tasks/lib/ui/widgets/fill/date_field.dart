import 'package:flutter/material.dart';

import '../../../models/fill.dart';
import 'field_editor.dart';

/// Дата: кнопка, открывающая системный выбор даты (сам диалог — у экрана бланка).
class DateFieldEditor extends FillFieldEditor {
  const DateFieldEditor();

  @override
  Widget value(BuildContext context, FillField f, FieldActions actions) =>
      fieldValue(f.date ?? '');

  @override
  Widget input(BuildContext context, FillField f, FieldActions actions) {
    return OutlinedButton.icon(
      onPressed: actions.onDatePick,
      icon: const Icon(Icons.event, size: 18),
      label: Text(f.date ?? 'Выбрать дату'),
    );
  }
}
