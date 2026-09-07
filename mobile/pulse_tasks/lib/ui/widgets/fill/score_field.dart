import 'package:flutter/material.dart';

import '../../../models/fill.dart';
import '../../theme.dart';
import 'field_editor.dart';

/// Балл из максимума пункта — степпер, а не поле ввода (см. [input]).
class ScoreFieldEditor extends FillFieldEditor {
  const ScoreFieldEditor();

  @override
  Widget value(BuildContext context, FillField f, FieldActions actions) {
    final v = f.number;
    if (v == null) return const SizedBox.shrink();
    return fieldValue('${trimNum(v)} из ${trimNum(f.weight)}', warn: v <= 0);
  }

  /// A `score` field: the inspector awards points out of the item's maximum.
  /// Deliberately a stepper and not a text field — this is filled in standing on
  /// the shop floor with a phone in one hand, and a free numeric input would also
  /// let a value through that the server then rejects for being over the maximum.
  @override
  Widget input(BuildContext context, FillField f, FieldActions actions) {
    final max = f.weight;
    final step = (f.step != null && f.step! > 0) ? f.step! : 0.5;
    final v = f.number;

    void award(double raw) {
      final clamped = raw < 0 ? 0.0 : (raw > max ? max : raw);
      // snap to the step so the value always matches what the buttons can produce
      final snapped = (clamped / step).round() * step;
      actions.onNumber!(double.parse(snapped.toStringAsFixed(2)));
    }

    final full = v != null && v >= max;

    // Wms.warn is the palette's red — a zero on a checklist item is a loss, not a
    // warning, so it gets the red; a partial award is merely informational.
    final Color valueColor = v == null
        ? Wms.muted
        : (full ? Wms.ok : (v <= 0 ? Wms.warn : Wms.primary));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            IconButton(
              iconSize: 34,
              onPressed: (v ?? 0) <= 0 && v != null
                  ? null
                  : () => award((v ?? 0) - step),
              icon: const Icon(Icons.remove_circle_outline),
              color: Wms.muted,
            ),
            Expanded(
              child: Column(
                children: [
                  Text(
                    v == null ? '—' : '${trimNum(v)} из ${trimNum(max)}',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: valueColor,
                    ),
                  ),
                  Text('максимум ${trimNum(max)}',
                      style: TextStyle(fontSize: 11, color: Wms.muted)),
                ],
              ),
            ),
            IconButton(
              iconSize: 34,
              onPressed: full ? null : () => award((v ?? 0) + step),
              icon: const Icon(Icons.add_circle_outline),
              color: Wms.muted,
            ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            TextButton(
              onPressed: () => award(0),
              child: const Text('0'),
            ),
            TextButton(
              onPressed: () => award(max),
              child: const Text('Полный балл'),
            ),
          ],
        ),
      ],
    );
  }
}
