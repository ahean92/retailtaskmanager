import 'package:flutter/material.dart';

import '../theme.dart';

/// Кирпичики формы создания задачи — карточка, подпись секции, плашка-признак и строка-
/// предупреждение. Общие для экрана создания по пресету и предпросмотра шаблона.

class FormCard extends StatelessWidget {
  final List<Widget> children;
  const FormCard({super.key, required this.children});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Material(
          color: Wms.card,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: children),
          ),
        ),
      );
}


class FormLabel extends StatelessWidget {
  final String text;
  const FormLabel(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text.toUpperCase(),
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: Wms.muted,
                letterSpacing: 0.6)),
      );
}


class FormChip extends StatelessWidget {
  final String text;
  final IconData? icon;
  final Color? color;
  const FormChip(this.text, {super.key, this.icon, this.color});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: (color ?? Wms.muted).withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: color ?? Wms.muted),
            const SizedBox(width: 4),
          ],
          Text(text,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: color ?? Wms.text)),
        ]),
      );
}


class FormWarnRow extends StatelessWidget {
  final String text;
  const FormWarnRow(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Row(children: [
        Icon(Icons.error_outline, size: 18, color: Wms.warn),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: TextStyle(color: Wms.warn))),
      ]);
}
