import 'package:flutter/material.dart';

import '../theme.dart';

/// Строка срока создаваемой задачи — экран создания по пресету и черновик AI: «Срок:
/// дата» или «Срок не задан», тап открывает календарь, крестик снимает срок.
class DeadlineRow extends StatelessWidget {
  final DateTime? date;
  final VoidCallback onPick;
  final VoidCallback onClear;

  const DeadlineRow(
      {super.key,
      required this.date,
      required this.onPick,
      required this.onClear});

  @override
  Widget build(BuildContext context) {
    final d = date;
    return InkWell(
      onTap: onPick,
      child: Row(children: [
        Icon(Icons.schedule, size: 20, color: Wms.primary),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            d == null
                ? 'Срок не задан'
                : 'Срок: ${d.day.toString().padLeft(2, '0')}.'
                    '${d.month.toString().padLeft(2, '0')}.${d.year}',
            style: TextStyle(
                fontWeight: FontWeight.w600,
                color: d == null ? Wms.muted : Wms.text),
          ),
        ),
        if (d != null)
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Без срока',
            icon: Icon(Icons.close, size: 18, color: Wms.muted),
            onPressed: onClear,
          )
        else
          Icon(Icons.unfold_more, size: 18, color: Wms.primary),
      ]),
    );
  }
}

/// Календарь срока: с сегодняшнего дня на два года вперёд, открывается на [current].
/// Срок вне этого окна (модель вернула прошедшую дату — сервер помечает это
/// предупреждением) календарь открыть не даёт — тогда он открывается на сегодня.
/// null — человек передумал.
Future<DateTime?> pickDeadline(BuildContext context, DateTime? current) {
  final now = DateTime.now();
  final first = DateTime(now.year, now.month, now.day);
  final last = DateTime(now.year + 2);
  return showDatePicker(
    context: context,
    initialDate:
        current != null && !current.isBefore(first) && !current.isAfter(last)
            ? current
            : first,
    firstDate: first,
    lastDate: last,
  );
}
