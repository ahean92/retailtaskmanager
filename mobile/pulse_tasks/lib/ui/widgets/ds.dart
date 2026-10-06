import 'package:flutter/material.dart';

import '../../models/task.dart';
import '../theme.dart';

/// Дизайн-кит редизайна #37411 (mobile-redesign-A-v2.pdf, стр. 1): карточка,
/// чип-пилюля, плашка, нижняя панель с главным действием, нижний лист и крупный
/// заголовок экрана. Всё, что повторяется на двух и более экранах, живёт здесь,
/// а не в копиях по экранам — иначе «смена радиуса карточки» снова станет
/// задачей на сорок файлов.
///
/// Цвета берутся только из [Wms]: нейтральные роли и сигнальные пары —
/// константы темы, фирменные — от сервера. Хардкода HEX в виджетах нет.

/// Карточка новой темы: белая (в тёмной — своя поверхность), рамка 1 px,
/// радиус 16, без тени. Теней у карточек нет вовсе — «приподнятость» несёт
/// рамка на сером фоне.
class DsCard extends StatelessWidget {
  final EdgeInsetsGeometry margin;
  final EdgeInsetsGeometry padding;
  final List<Widget> children;

  const DsCard({
    super.key,
    this.margin = const EdgeInsets.fromLTRB(16, 0, 16, 12),
    this.padding = const EdgeInsets.all(16),
    required this.children,
  });

  @override
  Widget build(BuildContext context) => Container(
        margin: margin,
        padding: padding,
        decoration: BoxDecoration(
          color: Wms.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Wms.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      );
}

/// Семантические тона чипов и плашек. Пары «сильный цвет + подложка» —
/// из таблицы цветов макета; текст на подложке пишется сильным цветом.
enum DsTone { neutral, brand, brandSoft, danger, caution, done }

DsTone dsToneOf(String? statusId) => switch (statusId) {
      'done' => DsTone.done,
      'in progress' => DsTone.brandSoft,
      Task.acceptanceStatusId => DsTone.brandSoft,
      'canceled' => DsTone.neutral,
      _ => DsTone.neutral,
    };

/// Чип-пилюля. Высота 36 у интерактивных (фильтры, разделы), у статусных
/// пометок в карточках — компактный 26. Текст 12/600 в обоих случаях.
///
/// Тон [DsTone.brand] — «залитый»: светлой темой это фирменный цвет с белым
/// текстом, тёмной — светлая плашка с тёмным текстом (зеркало светлой темы,
/// стр. 7 макета): фирменный цвет хрома в тёмной остаётся тёмным, и залитый
/// им чип слипся бы с панелью.
class DsChip extends StatelessWidget {
  final String label;
  final IconData? icon;
  final DsTone tone;
  final bool compact;
  final VoidCallback? onTap;

  const DsChip(
    this.label, {
    super.key,
    this.icon,
    this.tone = DsTone.neutral,
    this.compact = false,
    this.onTap,
  });

  (Color, Color) get _colors => switch (tone) {
        DsTone.neutral => (Wms.chipBg, Wms.text2),
        DsTone.brand => (
            Wms.isDark ? const Color(0xFFE6EBF1) : Wms.primary,
            Wms.isDark ? const Color(0xFF151B23) : Wms.on(Wms.primary)
          ),
        DsTone.brandSoft => (Wms.brandTint, Wms.primary),
        DsTone.danger => (Wms.dangerTint, Wms.danger),
        DsTone.caution => (Wms.cautionTint, Wms.caution),
        DsTone.done => (Wms.doneTint, Wms.done),
      };

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = _colors;
    final height = compact ? 26.0 : 36.0;
    final chip = Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: compact ? 14 : 16, color: fg),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w600, color: fg),
          ),
        ],
      ),
    );
    if (onTap == null) return chip;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: chip,
    );
  }
}

/// Контурный чип: без заливки, рамка [Wms.line]. Выбранный ([selected]) —
/// подложка бренда и рамка фирменным: так в макете помечают текущий раздел
/// бланка и выбранный вариант «выбора» (стр. 2 и 8).
class DsOutlineChip extends StatelessWidget {
  final String label;
  final IconData? icon;
  final bool selected;
  final VoidCallback? onTap;

  const DsOutlineChip(
    this.label, {
    super.key,
    this.icon,
    this.selected = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fg = selected ? Wms.primary : Wms.text2;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: selected ? Wms.brandTint : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: selected ? Wms.primary : Wms.line),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 16, color: fg),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w600, color: fg),
            ),
          ],
        ),
      ),
    );
  }
}

/// Срок-чип: единственное место, где просрочка обозначается цветом (рамок и
/// полос у карточек больше нет). Обычный срок — нейтральный, просроченный —
/// пара «опасно», близкий — «внимание».
class DsDeadlineChip extends StatelessWidget {
  final String label;
  final bool overdue;
  final bool soon;
  final bool compact;

  const DsDeadlineChip(
    this.label, {
    super.key,
    this.overdue = false,
    this.soon = false,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) => DsChip(
        label,
        icon: overdue ? Icons.event_busy : Icons.event,
        tone: overdue
            ? DsTone.danger
            : soon
                ? DsTone.caution
                : DsTone.neutral,
        compact: compact,
      );
}

/// Узкая плашка над содержимым («Нет связи · N действий ждут отправки»).
/// Радиус 12, тон по смыслу: ожидание — «внимание», отказ — «опасно».
class DsBanner extends StatelessWidget {
  final IconData icon;
  final String text;
  final DsTone tone;
  final String? actionLabel;
  final VoidCallback? onAction;

  const DsBanner(
    this.icon,
    this.text, {
    super.key,
    this.tone = DsTone.caution,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (tone) {
      DsTone.danger => (Wms.dangerTint, Wms.danger),
      DsTone.caution => (Wms.cautionTint, Wms.caution),
      DsTone.done => (Wms.doneTint, Wms.done),
      DsTone.brandSoft => (Wms.brandTint, Wms.primary),
      _ => (Wms.chipBg, Wms.text2),
    };
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: fg),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w500, color: fg),
            ),
          ),
          if (actionLabel != null)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: TextButton(
                onPressed: onAction,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  foregroundColor: fg,
                  textStyle: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: fg),
                ),
                child: Text(actionLabel!),
              ),
            ),
        ],
      ),
    );
  }
}

/// Крупный заголовок экрана (30/700) с необязательной строкой под ним.
/// Заголовок рисуется телом экрана, а не AppBar'ом: шапка тонкая и светлая,
/// а «Задачи» и «Лента» в макетах стоят на фоне экрана, под чипом объекта.
class DsScreenTitle extends StatelessWidget {
  final String title;
  final String? subtitle;

  const DsScreenTitle(this.title, {super.key, this.subtitle});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w700,
                    color: Wms.text,
                    height: 1.15)),
            if (subtitle != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(subtitle!,
                    style:
                        TextStyle(fontSize: 13, color: Wms.muted)),
              ),
          ],
        ),
      );
}

/// Нижняя панель с одним главным действием: залитая кнопка (52) расширяется,
/// слева может стоять контурная, справа — тональная квадратная кнопка фото
/// (карточка задачи: «Продолжить» + фото). Панель — карточка с верхней
/// рамкой, высота около 80 вместе с SafeArea.
class DsBottomActionBar extends StatelessWidget {
  final String primaryLabel;
  final VoidCallback? onPrimary;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;
  final Widget? trailing;
  final bool dangerPrimary;

  const DsBottomActionBar({
    super.key,
    required this.primaryLabel,
    this.onPrimary,
    this.secondaryLabel,
    this.onSecondary,
    this.trailing,
    this.dangerPrimary = false,
  });

  @override
  Widget build(BuildContext context) {
    final primary = SizedBox(
      height: 52,
      child: FilledButton(
        onPressed: onPrimary,
        style: dangerPrimary
            ? FilledButton.styleFrom(
                backgroundColor: Wms.danger,
                foregroundColor:
                    Wms.isDark ? const Color(0xFF3B2220) : Colors.white,
              )
            : null,
        child: Text(primaryLabel),
      ),
    );
    return Container(
      decoration: BoxDecoration(
        color: Wms.card,
        border: Border(top: BorderSide(color: Wms.line)),
      ),
      child: SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(
          children: [
            if (secondaryLabel != null) ...[
              Expanded(
                child: SizedBox(
                  height: 52,
                  child: OutlinedButton(
                    onPressed: onSecondary,
                    child: Text(secondaryLabel!),
                  ),
                ),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(child: primary),
            if (trailing != null) ...[const SizedBox(width: 12), trailing!],
          ],
        ),
      ),
    );
  }
}

/// Нижний лист в новом стиле: заголовок 20/700, содержимое с отступами.
/// Радиус и фон приезжают из темы (bottomSheetTheme), здесь — только каркас,
/// одинаковый у «Создать», «Вернуть на доработку» и прочих листов.
Future<T?> showDsSheet<T>(
  BuildContext context, {
  required String title,
  required List<Widget> children,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(title,
                  style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: Wms.text)),
            ),
            ...children,
          ],
        ),
      ),
    ),
  );
}

/// Аватар-инициалы на подложке чипа: «взявший» в подвале карточки, авторы
/// комментариев, карточка профиля. Круглый, без рамки.
class DsAvatar extends StatelessWidget {
  final String name;
  final double size;

  const DsAvatar(this.name, {super.key, this.size = 28});

  String get _initials {
    final parts =
        name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '—';
    if (parts.length == 1) return parts.first.characters.first.toUpperCase();
    return (parts.first.characters.first + parts.last.characters.first)
        .toUpperCase();
  }

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: Wms.chipBg, shape: BoxShape.circle),
        child: Text(
          _initials,
          style: TextStyle(
              fontSize: size * 0.38,
              fontWeight: FontWeight.w600,
              color: Wms.text2),
        ),
      );
}
