import 'package:flutter/material.dart';

import '../../../models/fill.dart';
import '../../theme.dart';
import 'field_editor.dart';

/// Число с нормой: поле ввода, подпись «Норма: от … до …» и пометка «в норме /
/// вне нормы» по введённому.
class NumberFieldEditor extends FillFieldEditor {
  const NumberFieldEditor();

  // `answered` истинно и от одного фото, так что number здесь бывает null —
  // например, значение стёрли, а обязательный снимок остался (ревью #36778)
  @override
  Widget value(BuildContext context, FillField f, FieldActions actions) {
    final n = f.number;
    if (n == null) return const SizedBox.shrink();
    final unit = f.unit == null ? '' : ' ${f.unit}';
    return Row(children: [
      fieldValue('${trimNum(n)}$unit', warn: !f.inNorm),
      const SizedBox(width: 10),
      FieldBadge(
          f.inNorm ? 'в норме' : 'вне нормы', f.inNorm ? Wms.ok : Wms.warn),
    ]);
  }

  @override
  Widget input(BuildContext context, FillField f, FieldActions actions) =>
      _NumberInput(field: f, actions: actions);
}

/// Контроллер поля ввода живёт со своим State: значение набирается, а на сервер
/// уезжает по подтверждению (onEditingComplete), как и раньше в плитке.
class _NumberInput extends StatefulWidget {
  final FillField field;
  final FieldActions actions;
  const _NumberInput({required this.field, required this.actions});

  @override
  State<_NumberInput> createState() => _NumberInputState();
}

class _NumberInputState extends State<_NumberInput> {
  late final TextEditingController _number;

  @override
  void initState() {
    super.initState();
    _number = TextEditingController(
        text: widget.field.number == null
            ? ''
            : trimNum(widget.field.number!));
  }

  @override
  void dispose() {
    _number.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.field;
    final norm = [
      if (f.minNorm != null) 'от ${trimNum(f.minNorm!)}',
      if (f.maxNorm != null) 'до ${trimNum(f.maxNorm!)}',
    ].join(' ');
    return Row(
      children: [
        SizedBox(
          width: 120,
          child: TextField(
            controller: _number,
            keyboardType: const TextInputType.numberWithOptions(
                decimal: true, signed: true),
            textAlign: TextAlign.center,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              isDense: true,
              suffixText: f.unit,
            ),
            onEditingComplete: () {
              FocusScope.of(context).unfocus();
              widget.actions.onNumber!(
                  double.tryParse(_number.text.replaceAll(',', '.')));
            },
          ),
        ),
        const SizedBox(width: 10),
        if (norm.isNotEmpty)
          Text('Норма: $norm',
              style: TextStyle(fontSize: 12, color: Wms.muted)),
        const Spacer(),
        if (f.number != null)
          FieldBadge(f.inNorm ? 'в норме' : 'вне нормы',
              f.inNorm ? Wms.ok : Wms.warn),
      ],
    );
  }
}
