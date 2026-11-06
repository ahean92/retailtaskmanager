import 'package:flutter/material.dart';

import '../../models/quick_create.dart';
import '../theme.dart';

/// Строка пресета в листе выбора: значок, название и [QuickPreset.details]. Лист «+»
/// на главной и мост «задача из сообщения» (#37441) показывают пресеты одинаково.
class PresetTile extends StatelessWidget {
  final QuickPreset preset;
  final VoidCallback onTap;

  const PresetTile({super.key, required this.preset, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            Text(preset.icon ?? '➕', style: const TextStyle(fontSize: 22)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(preset.title,
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: Wms.text)),
                  Text(preset.details,
                      style: TextStyle(fontSize: 13, color: Wms.muted)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
