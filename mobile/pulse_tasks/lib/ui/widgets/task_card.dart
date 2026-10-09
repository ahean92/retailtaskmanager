import 'package:flutter/material.dart';

import '../../models/task.dart';
import '../../models/task_view.dart';
import '../theme.dart';
import 'ds.dart';

/// Карточка задачи в списке — редизайн #37411 (mobile-redesign-A-v2.pdf, стр. 2,
/// экран 1): три яруса.
///
/// 1. Иконка и название типа слева, чип статуса в правом верхнем углу.
/// 2. Заголовок — НАЗВАНИЕ задачи (объект был заголовком раньше и прятал суть в
///    серой строке); объект показывается, только если задача с другого объекта.
///    Под заголовком — тонкая полоса прогресса и, для возвращённой, причина.
/// 3. Подвал за разделителем: срок-чип (просрочка — только он, без рамок и полос),
///    второстепенные пометки мелко, комментарии, взявший, «Взять».
///
/// Ни одна пометка прежней карточки не пропала: ждёт решения, возвращена,
/// взял / взяли вы, ожидает подтверждения взятия, ожидает синхронизации,
/// наблюдаю, исполнитель, приоритет — всё на месте, второстепенное уехало в
/// подвал.
class TaskCard extends StatelessWidget {
  final TaskView view;
  final VoidCallback onTap;
  final VoidCallback? onTake;
  const TaskCard(
      {super.key, required this.view, required this.onTap, this.onTake});

  @override
  Widget build(BuildContext context) {
    final t = view.task;
    final overdue = view.overdue;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      decoration: BoxDecoration(
        color: Wms.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Wms.line),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _typeRow(t),
                const SizedBox(height: 8),
                _title(view, t),
                if (t.progress != null) ...[
                  const SizedBox(height: 8),
                  _Progress(value: t.progress!),
                ],
                if (view.returned) ...[
                  const SizedBox(height: 8),
                  _ReturnReason(view: view),
                ],
                // настоящее последнее сообщение ленты — без пропусков: текст
                // показывается цитатой, фото-вложение без текста — строкой
                // «Фотография». Искали бы текст постарше — показали бы
                // «последним» уже не последнее (правило пользователя #37411)
                if (_hasLastComment(t)) ...[
                  const SizedBox(height: 8),
                  _LastComment(
                    text: t.lastCommentText,
                    files: t.lastCommentFiles,
                    author: t.lastCommentAuthor,
                  ),
                ],
                const Padding(
                  padding: EdgeInsets.only(top: 10),
                  child: Divider(height: 1, thickness: 1),
                ),
                const SizedBox(height: 10),
                _footer(view, t, overdue),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Ярус 1: иконка типа на фирменной подложке и название слева, статус справа
  /// (стр. 2 макета: иконка — квадрат с заливкой оттенка бренда, не голый глиф).
  Widget _typeRow(Task t) {
    final typeLabel = [t.type, t.subtitle].whereType<String>().join(' · ');
    return Row(
      children: [
        Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Wms.brandTint,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(_typeIcon(t.typeId), size: 16, color: Wms.primary),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            typeLabel.isEmpty ? 'Задача' : typeLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 13, fontWeight: FontWeight.w500, color: Wms.text2),
          ),
        ),
        DsChip(
          view.statusName ?? view.statusId ?? '—',
          tone: dsToneOf(view.statusId),
          compact: true,
        ),
      ],
    );
  }

  /// Ярус 2: заголовок — название задачи; объект — только для чужого объекта
  /// (#36837), пометка «только просмотр · N км» при нём же.
  Widget _title(TaskView v, Task t) {
    final name = t.name ?? t.object ?? t.id;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          name,
          style: TextStyle(
              fontSize: 17, fontWeight: FontWeight.w600, color: Wms.text),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        if (v.elsewhere) ...[
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(Icons.near_me_outlined, size: 14, color: Wms.primary),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  t.distanceText == null
                      ? '${t.object ?? 'другой объект'} · только просмотр'
                      : '${t.object ?? 'другой объект'} · только просмотр · ${t.distanceText}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Wms.primary),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  /// Ярус 3: подвал. Срок первым — просрочка читается отсюда и только отсюда.
  /// Дальше второстепенные пометки мелко (11), в конце — переписка, взявший
  /// и «Взять». Wrap: пометок бывает до десятка, и на узком телефоне им
  /// безопаснее переноситься, чем обрезаться.
  Widget _footer(TaskView v, Task t, bool overdue) {
    return Wrap(
      spacing: 10,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (t.deadlineText != null)
          DsDeadlineChip(
            _deadlineLabel(v, t),
            overdue: overdue,
            soon: !overdue && v.dueToday == true,
            compact: true,
          ),
        if (v.awaitingDecision)
          const _FootMark(
              icon: Icons.fact_check_outlined,
              text: 'ждёт вашего решения',
              color: _FootColor.primary,
              bold: true),
        if (v.takePending)
          const _FootMark(
              icon: Icons.hourglass_top,
              text: 'взята — ожидает подтверждения',
              color: _FootColor.caution),
        if (v.pending)
          const _FootMark(
              icon: Icons.sync_problem,
              text: 'ожидает синхронизации',
              color: _FootColor.caution),
        if (t.priority != null)
          _FootMark(
              icon: Icons.flag_outlined,
              text: t.priority!,
              // срочный и высокий — красным флагом (стр. 2 макета), прочие — серые
              color: t.priorityRank <= 1 ? _FootColor.danger : _FootColor.muted),
        if (_assigneeMark(v, t) != null)
          _FootMark(
              icon: Icons.badge_outlined, text: _assigneeMark(v, t)!),
        if (v.watched && v.group != TaskGroup.watched)
          _FootMark(
              icon: Icons.visibility_outlined,
              text: v.watchPending ? 'наблюдаю — ожидает отправки' : 'наблюдаю'),
        if (v.commentCount > 0 || v.unreadComments > 0)
          _CommentMark(count: v.commentCount, unread: v.unreadComments),
        if (v.takenBy != null)
          Tooltip(
            message: v.group == TaskGroup.mine ? 'Взята вами' : v.takenBy!,
            child: DsAvatar(v.takenBy!, size: 24),
          ),
        if (onTake != null && v.canTake)
          _TakeButton(onTake: onTake!),
      ],
    );
  }

  /// Есть ли последнее сообщение ленты вообще: сервер присылает либо текст, либо
  /// (у фото-сообщения) автора/время/вложения. Всех ключей нет — сообщений не
  /// было или сервер старый, строки в карточке не будет.
  bool _hasLastComment(Task t) =>
      (t.lastCommentText ?? '').trim().isNotEmpty ||
      t.lastCommentAt != null ||
      (t.lastCommentFiles ?? 0) > 0;

  IconData _typeIcon(String? typeId) => switch (typeId) {
      'checklist' => Icons.fact_check_outlined,
      'recount' => Icons.inventory_2_outlined,
      'pricing' => Icons.sell_outlined,
      _ => Icons.assignment_outlined,
    };

  /// Подпись срок-чипа — как в макете стр. 2: просроченная говорит «на сколько»,
  /// сегодняшняя и завтрашняя — по-человечески, дальше — короткая дата. Сервер
  /// присылает срок датой без времени, поэтому «на 40 минут» неоткуда взять:
  /// глубина просрочки — днями.
  String _deadlineLabel(TaskView v, Task t) {
    final d = t.deadlineDate;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    if (v.overdue) {
      final days = d == null ? 0 : today.difference(d).inDays;
      if (days >= 2) return 'Просрочено на $days дн.';
      if (days == 1) return 'Просрочено на 1 день';
      return 'Просрочено';
    }
    if (d != null) {
      final diff = d.difference(today).inDays;
      if (diff == 0) return 'Сегодня';
      if (diff == 1) return 'Завтра';
    }
    return t.deadlineText ?? '';
  }

/// Кто держит задачу: свою помечает «вы», чужую — именем; задача, приехавшая
  /// ради чтения («поставленные мной», «наблюдаю», у принимающего), показывает
  /// исполнителя — это главное, что о ней надо знать.
  static String? _assigneeMark(TaskView v, Task t) {
    if (v.takenBy != null && !v.takePending) {
      return v.group == TaskGroup.mine ? 'взяли вы' : 'взял: ${v.takenBy}';
    }
    if ((v.authoredOnly || v.watchedOnly || v.reviewingOnly || v.awaitingDecision) &&
        t.assignedTo != null) {
      return 'исполнитель: ${t.assignedTo}';
    }
    return null;
  }
}

// Какую роль цвета взять у темы: const-конструктор пометки не может позвать
// Wms, поэтому цвет выбирается в build по этой метке.
enum _FootColor { primary, caution, danger, muted }

/// Мелкая пометка подвала: иконка 13 и текст 11 — второстепенное по макету.
class _FootMark extends StatelessWidget {
  final IconData icon;
  final String text;
  final _FootColor color;
  final bool bold;
  const _FootMark(
      {required this.icon,
      required this.text,
      this.color = _FootColor.muted,
      this.bold = false});

  @override
  Widget build(BuildContext context) {
    final c = switch (color) {
      _FootColor.primary => Wms.primary,
      _FootColor.caution => Wms.caution,
      _FootColor.danger => Wms.danger,
      _FootColor.muted => Wms.muted,
    };
    final style = TextStyle(
        fontSize: 11,
        color: c,
        fontWeight: bold ? FontWeight.w700 : FontWeight.w400);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 13, color: c),
      const SizedBox(width: 3),
      Flexible(
        child: Text(text,
            maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
      ),
    ]);
  }
}

/// Последнее сообщение ленты — строкой-цитатой под заголовком (стр. 2 макета):
/// «о чём сейчас разговор» видно из списка, без открытия задачи. На светлой
/// подложке-плашке, как в макете, — не голым текстом. Фото-вложение без текста —
/// тоже последнее сообщение, и вместо цитаты пишется «Фотография»: подменять его
/// более старым текстом — врать о том, что сейчас в ленте.
class _LastComment extends StatelessWidget {
  final String? text;
  final int? files;
  final String? author;
  const _LastComment({this.text, this.files, this.author});

  @override
  Widget build(BuildContext context) {
    final hasText = (text ?? '').trim().isNotEmpty;
    final isPhoto = !hasText && ((files ?? 0) > 0);
    if (!hasText && !isPhoto) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Wms.chipBg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isPhoto) ...[
            Icon(Icons.photo_outlined, size: 14, color: Wms.muted),
            const SizedBox(width: 5),
          ],
          Expanded(
            child: Text(
              isPhoto
                  ? (author == null || author!.isEmpty
                      ? 'Фотография'
                      : 'Фотография — $author')
                  : (author == null || author!.isEmpty
                      ? '«${text!.trim()}»'
                      : '«${text!.trim()}» — $author'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, height: 1.3, color: Wms.text2),
            ),
          ),
        ],
      ),
    );
  }
}

/// Причина возврата — отдельным блоком под заголовком: цитата и, когда клиент
/// знает автора, кто вернул. Сегодня автор возврата с сервера не приезжает —
/// рисуем цитату без подписи, заводить серверную доработку тикет не велит.
class _ReturnReason extends StatelessWidget {
  final TaskView view;
  const _ReturnReason({required this.view});

  @override
  Widget build(BuildContext context) {
    final reason = view.returnReason?.trim();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.undo, size: 14, color: Wms.danger),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            reason == null || reason.isEmpty
                ? 'Возвращена на доработку'
                : '«$reason»',
            style: TextStyle(fontSize: 13, color: Wms.danger),
          ),
        ),
      ],
    );
  }
}

/// Тонкая полоса прогресса под заголовком: заполнение — фирменным цветом,
/// дорожка — подложка чипа. Значение [value] — проценты 0–100.
class _Progress extends StatelessWidget {
  final int value;
  const _Progress({required this.value});

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: LinearProgressIndicator(
          value: (value.clamp(0, 100)) / 100,
          minHeight: 4,
          backgroundColor: Wms.chipBg,
          color: Wms.primary,
        ),
      );
}

/// Переписка по задаче (#36844): сколько сообщений и есть ли новые. «Есть новые»
/// — точка фирменного цвета, а не только смена иконки: заметность важнее.
class _CommentMark extends StatelessWidget {
  final int count;
  final int unread;
  const _CommentMark({required this.count, required this.unread});

  @override
  Widget build(BuildContext context) {
    final hasNew = unread > 0;
    final c = hasNew ? Wms.primary : Wms.muted;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(hasNew ? Icons.chat_bubble : Icons.chat_bubble_outline,
          size: 14, color: c),
      const SizedBox(width: 3),
      Text('$count', style: TextStyle(fontSize: 11, color: c)),
      if (hasNew) ...[
        const SizedBox(width: 3),
        Container(
          width: 5,
          height: 5,
          decoration: BoxDecoration(color: Wms.primary, shape: BoxShape.circle),
        ),
      ],
    ]);
  }
}

/// «Взять» прямо в строке — тональная (подложка бренда, фирменный текст),
/// по макету стр. 2: работу берут из списка, не заходя в деталку.
class _TakeButton extends StatelessWidget {
  final VoidCallback onTake;
  const _TakeButton({required this.onTake});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 34,
      child: FilledButton(
        onPressed: onTake,
        style: FilledButton.styleFrom(
          backgroundColor: Wms.brandTint,
          foregroundColor: Wms.primary,
          minimumSize: const Size(0, 34),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          visualDensity: VisualDensity.compact,
          textStyle:
              const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
        ),
        child: const Text('Взять'),
      ),
    );
  }
}
