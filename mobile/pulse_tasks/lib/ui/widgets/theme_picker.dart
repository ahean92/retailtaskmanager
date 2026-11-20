import 'dart:async';

import 'package:flutter/material.dart';

import '../theme.dart';

/// Выбор темы «Система / Светлая / Тёмная» с пояснением — в профиле и на экране
/// настроек. Применяется сразу, без «Сохранить»: тему выбирают глазами, глядя на
/// результат. [stretch] — сегмент во всю ширину (экран настроек).
class ThemePicker extends StatelessWidget {
  final bool stretch;
  const ThemePicker({super.key, this.stretch = false});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<ThemeMode>(
        valueListenable: Wms.mode,
        builder: (context, mode, _) => Column(
          crossAxisAlignment:
              stretch ? CrossAxisAlignment.stretch : CrossAxisAlignment.start,
          children: [
            SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(
                    value: ThemeMode.system, label: Text('Система')),
                ButtonSegment(value: ThemeMode.light, label: Text('Светлая')),
                ButtonSegment(value: ThemeMode.dark, label: Text('Тёмная')),
              ],
              selected: {mode},
              showSelectedIcon: false,
              onSelectionChanged: (s) => unawaited(Wms.setMode(s.first)),
            ),
            const SizedBox(height: 10),
            Text(
              '«Система» — как настроен телефон. Тёмная бережёт глаза в '
              'полутёмном зале и на складе; цвета заказчика работают в обеих.',
              style: TextStyle(fontSize: 12, color: Wms.muted),
            ),
          ],
        ),
      );
}
