import 'package:flutter/material.dart';

import '../theme.dart';

/// Полоса-предупреждение под шапкой экрана («офлайн», «не принято сервером»).
/// Одна на бланк и просмотр прошлой проверки: две локальные копии уже успели
/// завестись, и правка контраста/переносов чинила бы их по отдельности.
class WarnBar extends StatelessWidget {
  final IconData icon;
  final String text;
  const WarnBar(this.icon, this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Wms.warn.withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          children: [
            Icon(icon, size: 16, color: Wms.warn),
            const SizedBox(width: 8),
            Expanded(
              child: Text(text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: Wms.warn)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Полоса-событие с кнопкой закрытия — для сообщений, которые нельзя показать тихо
/// и на один кадр: «задачу уже взял Иванов» висит, пока человек её не увидел
/// (#36836). Живёт и на списке, и на главной — где бы ни застала синхронизация.
class NoticeBar extends StatelessWidget {
  final IconData icon;
  final String text;
  final VoidCallback onClose;
  const NoticeBar(this.icon, this.text, {required this.onClose, super.key});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Wms.warn.withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 2, 4, 2),
        child: Row(
          children: [
            Icon(icon, size: 16, color: Wms.warn),
            const SizedBox(width: 8),
            Expanded(
              child: Text(text,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Wms.warn)),
            ),
            IconButton(
              tooltip: 'Понятно',
              onPressed: onClose,
              icon: Icon(Icons.close, size: 18, color: Wms.warn),
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      ),
    );
  }
}
