import 'package:flutter/material.dart';

import '../../../models/fill.dart';
import '../../theme.dart';
import 'field_editor.dart';

/// Шкала и выбор из вариантов (#37411, п. 6): варианты — чипы-пилюли, выбранный
/// залит подложкой бренда с рамкой фирменным, вариант с несоответствием —
/// парой «опасно».
class ChoiceFieldEditor extends FillFieldEditor {
  const ChoiceFieldEditor();

  @override
  Widget value(BuildContext context, FillField f, FieldActions actions) {
    final o = f.selectedOption;
    return fieldValue(o?.name ?? o?.code ?? f.optionCode ?? '',
        warn: o?.nonconformity ?? false);
  }

  @override
  Widget input(BuildContext context, FillField f, FieldActions actions) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final o in f.options)
          OptionButton(
            label: o.name ?? o.code,
            selected: f.optionCode == o.code,
            nonconformity: o.nonconformity,
            onTap: () => actions.onOption!(o.code),
          ),
      ],
    );
  }
}

/// Чип-вариант: шкала, выбор.
class OptionButton extends StatelessWidget {
  final String label;
  final bool selected;
  final bool nonconformity;
  final VoidCallback onTap;
  const OptionButton({
    super.key,
    required this.label,
    required this.selected,
    required this.nonconformity,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final Color bg, fg, border;
    if (selected && nonconformity) {
      bg = Wms.dangerTint;
      fg = Wms.danger;
      border = Wms.danger;
    } else if (selected) {
      bg = Wms.brandTint;
      fg = Wms.primary;
      border = Wms.primary;
    } else {
      bg = Colors.transparent;
      fg = Wms.text2;
      border = Wms.line;
    }
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: border, width: selected ? 1.5 : 1),
        ),
        child: Text(label,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: fg,
                fontSize: 13,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500)),
      ),
    );
  }
}
