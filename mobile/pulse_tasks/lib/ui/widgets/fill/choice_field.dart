import 'package:flutter/material.dart';

import '../../../models/fill.dart';
import '../../theme.dart';
import 'field_editor.dart';

/// Шкала и выбор из вариантов: кнопки-варианты, выбранный подсвечен, вариант с
/// несоответствием — красным.
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

/// Кнопка-вариант: шкала, выбор, «Да/Нет».
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
      bg = Wms.warnTint;
      fg = Wms.warn;
      border = Wms.warn;
    } else if (selected) {
      bg = Wms.active;
      fg = Wms.primaryDark;
      border = Wms.primary;
    } else {
      bg = Wms.card;
      fg = Wms.muted;
      border = Wms.line;
    }
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        constraints: const BoxConstraints(minHeight: 44, minWidth: 72),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: border, width: selected ? 1.5 : 0.5),
        ),
        child: Text(label,
            textAlign: TextAlign.center,
            style: TextStyle(
                color: fg,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400)),
      ),
    );
  }
}
