import 'package:flutter/material.dart';

import '../../../models/fill.dart';
import '../../theme.dart';
import 'field_editor.dart';

/// Число с нормой (#37411, п. 6): степпер «− N +» — минус и плюс по квадратным
/// кнопкам, значение крупно посередине, тап по нему открывает поле ввода для
/// дробных и больших чисел, которые степпером не набрать. Под нормой — подпись
/// «Норма: от … до …» и пометка «в норме / вне нормы» по введённому.
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

class _NumberInput extends StatefulWidget {
  final FillField field;
  final FieldActions actions;
  const _NumberInput({required this.field, required this.actions});

  @override
  State<_NumberInput> createState() => _NumberInputState();
}

class _NumberInputState extends State<_NumberInput> {
  /// Значение поля ввода живёт в диалоге точного ввода, а не здесь: степпер
  /// пишет ответ сразу (onNumber на каждом тапе), и второй, «черновой» экземпляр
  /// значения рядом с ним только расходился бы с настоящим.
  Future<void> _typeExact() async {
    final f = widget.field;
    final controller = TextEditingController(
        text: f.number == null ? '' : trimNum(f.number!));
    final messenger = ScaffoldMessenger.of(context);
    final typed = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(f.name ?? 'Число'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType:
              const TextInputType.numberWithOptions(decimal: true, signed: true),
          decoration: InputDecoration(
            suffixText: f.unit,
            hintText: f.minNorm == null && f.maxNorm == null
                ? null
                : 'норма: ${[
                    if (f.minNorm != null) 'от ${trimNum(f.minNorm!)}',
                    if (f.maxNorm != null) 'до ${trimNum(f.maxNorm!)}',
                  ].join(' ')}',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('Готово'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (typed == null) return;
    final parsed = double.tryParse(typed.replaceAll(',', '.'));
    if (parsed != null) {
      widget.actions.onNumber!(parsed);
    } else if (typed.isEmpty) {
      widget.actions.onNumber!(null);
    } else {
      messenger.showSnackBar(
          const SnackBar(content: Text('Это не число')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.field;
    final norm = [
      if (f.minNorm != null) 'от ${trimNum(f.minNorm!)}',
      if (f.maxNorm != null) 'до ${trimNum(f.maxNorm!)}',
    ].join(' ');
    final value = f.number;

    double step(double from) => from == from.roundToDouble() ? 1.0 : 0.5;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _StepButton(
              icon: Icons.remove,
              onTap: value == null
                  ? null
                  : () => widget.actions
                      .onNumber!(value - step(value)),
            ),
            Expanded(
              child: InkWell(
                onTap: _typeExact,
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    children: [
                      Text(
                        value == null ? '—' : trimNum(value),
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          color: value == null ? Wms.muted : Wms.text,
                        ),
                      ),
                      if (f.unit != null)
                        Text(f.unit!,
                            style:
                                TextStyle(fontSize: 12, color: Wms.muted)),
                    ],
                  ),
                ),
              ),
            ),
            _StepButton(
              icon: Icons.add,
              onTap: () => widget.actions
                  .onNumber!((value ?? 0) + step(value ?? 0)),
            ),
          ],
        ),
        if (norm.isNotEmpty || value != null) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              if (norm.isNotEmpty)
                Text('Норма: $norm',
                    style: TextStyle(fontSize: 12, color: Wms.muted)),
              const Spacer(),
              if (value != null)
                FieldBadge(f.inNorm ? 'в норме' : 'вне нормы',
                    f.inNorm ? Wms.ok : Wms.warn),
            ],
          ),
        ],
      ],
    );
  }
}

/// Квадратная кнопка степпера: 44×44, контурная; погашена, когда менять нечего.
class _StepButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  const _StepButton({required this.icon, this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 44,
      height: 44,
      child: OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          padding: EdgeInsets.zero,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        child: Icon(icon, size: 20),
      ),
    );
  }
}
