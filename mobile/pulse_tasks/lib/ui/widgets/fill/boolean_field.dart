import 'package:flutter/material.dart';

import '../../../models/fill.dart';
import '../../theme.dart';
import 'field_editor.dart';

/// «Да / Нет» (#37411, п. 6): две большие кнопки вровень с кнопками панелей —
/// высота 52, радиус 14. Выбранная залита ЦВЕТОМ ОТВЕТА: «да» — пара «готово»,
/// «нет» — пара «опасно»; неотвеченное поле — две нейтральные подложки.
/// Повторное нажатие выбранной снимает ответ (вопрос 37).
class BooleanFieldEditor extends FillFieldEditor {
  const BooleanFieldEditor();

  // `answered` истинно и от одного снимка: без значения просмотр не пишет «Нет»,
  // которого проверяющий не ставил
  @override
  Widget value(BuildContext context, FillField f, FieldActions actions) {
    final b = f.boolValue;
    if (b == null) return const SizedBox.shrink();
    return fieldValue(b ? 'Да' : 'Нет');
  }

  @override
  Widget input(BuildContext context, FillField f, FieldActions actions) {
    return Row(
      children: [
        Expanded(
          child: _AnswerButton(
            label: 'Да',
            selected: f.boolValue == true,
            fill: Wms.done,
            onTap: () => actions.onBool!(f.boolValue == true ? null : true),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _AnswerButton(
            label: 'Нет',
            selected: f.boolValue == false,
            fill: Wms.danger,
            onTap: () => actions.onBool!(f.boolValue == false ? null : false),
          ),
        ),
      ],
    );
  }
}

class _AnswerButton extends StatelessWidget {
  final String label;
  final bool selected;
  final Color fill;
  final VoidCallback onTap;
  const _AnswerButton({
    required this.label,
    required this.selected,
    required this.fill,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        height: 52,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? fill : Wms.chipBg,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: selected ? Wms.on(fill) : Wms.text2,
          ),
        ),
      ),
    );
  }
}
