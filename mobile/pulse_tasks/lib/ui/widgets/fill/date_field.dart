import 'package:flutter/material.dart';

import '../../../models/fill.dart';
import '../../../models/task.dart';
import 'field_editor.dart';

/// Дата: кнопка, открывающая системный выбор даты (сам диалог — у экрана бланка), и
/// «очистить» у поставленной (вопрос 37): календарь умеет только выбрать другой
/// день. Дата — ДД.ММ.ГГГГ, как сроки в списке и карточке, а не машинная строка.
class DateFieldEditor extends FillFieldEditor {
  const DateFieldEditor();

  @override
  Widget value(BuildContext context, FillField f, FieldActions actions) =>
      fieldValue(formatDate(f.date) ?? '');

  @override
  Widget input(BuildContext context, FillField f, FieldActions actions) {
    return Row(
      children: [
        OutlinedButton.icon(
          onPressed: actions.onDatePick,
          icon: const Icon(Icons.event, size: 18),
          label: Text(formatDate(f.date) ?? 'Выбрать дату'),
        ),
        if (f.date != null && actions.onDateClear != null)
          TextButton(
            onPressed: actions.onDateClear,
            child: const Text('Очистить'),
          ),
      ],
    );
  }
}
