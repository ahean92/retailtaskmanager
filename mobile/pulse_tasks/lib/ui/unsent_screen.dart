import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/sync_coordinator.dart';
import '../data/task_repository.dart';
import '../data/unsent.dart';
import 'theme.dart';
import 'widgets/ds.dart';

/// Экран «Не отправлено» (#36916, редизайн #37411 п. 12): что накопилось в
/// очередях офлайна, по-людски — «Бланк: 12 ответов, 3 фото» — с временем
/// постановки и причиной последней неудачи. И кнопка «Отправить сейчас» с
/// видимым результатом: человек в поле должен сам ответить себе на вопрос
/// «я заполнил — оно ушло или нет?», не гадая по спиннерам.
///
/// Чистый рендер repo.unsentOps: список собирает репозиторий при каждом _reload,
/// поэтому строки тают на глазах по мере дожима — и ровно те же операции считает
/// бейдж «Профиль» вкладки, с которого сюда пришли.
class UnsentScreen extends StatefulWidget {
  const UnsentScreen({super.key});

  @override
  State<UnsentScreen> createState() => _UnsentScreenState();
}

class _UnsentScreenState extends State<UnsentScreen> {
  bool _sending = false;

  /// Итог последней отправки с этого экрана — плашкой, а не снекбаром на три
  /// секунды: «отправилось или нет» перечитывают, а не успевают прочесть.
  /// null — отправки ещё не было, и выдумывать нечего.
  ({bool ok, String text})? _lastResult;

  Future<void> _sendNow(TaskRepository repo) async {
    setState(() => _sending = true);
    final before = repo.pendingCount;
    try {
      await context.read<SyncCoordinator>().syncAndRefresh();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
    if (!mounted) return;
    // видимый результат: сколько ушло и что осталось — не молчание и не спиннер
    final left = repo.pendingCount;
    final ({bool ok, String text}) result;
    if (left == 0) {
      result = (ok: true, text: 'Всё отправлено');
    } else if (left < before) {
      result = (
        ok: false,
        text: 'Отправлено ${before - left} из $before — '
            'остальное не прошло, причины в списке'
      );
    } else {
      result = (ok: false, text: 'Отправить не удалось — причины в списке');
    }
    setState(() => _lastResult = result);
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<TaskRepository>(
      builder: (context, repo, _) {
        final ops = repo.unsentOps;
        return Scaffold(
          appBar: AppBar(
            // заголовок — крупным в теле; здесь только путь назад
            leading: const BackButton(),
          ),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DsScreenTitle(
                'Не отправлено',
                subtitle: ops.isEmpty
                    ? null
                    : _summaryLine(ops.length),
              ),
              if (_lastResult != null)
                DsBanner(
                  _lastResult!.ok
                      ? Icons.cloud_done_outlined
                      : Icons.sync_problem,
                  _lastResult!.text,
                  tone: _lastResult!.ok ? DsTone.done : DsTone.danger,
                ),
              Expanded(
                child: ops.isEmpty
                    ? ListView(children: [
                        SizedBox(
                            height: MediaQuery.of(context).size.height * 0.12),
                        _empty(),
                      ])
                    : _list(ops),
              ),
            ],
          ),
          bottomNavigationBar: ops.isEmpty
              ? null
              : DsBottomActionBar(
                  primaryLabel:
                      _sending ? 'Отправка…' : 'Отправить сейчас',
                  primaryIcon: Icons.send_outlined,
                  onPrimary: _sending ? null : () => _sendNow(repo),
                ),
        );
      },
    );
  }

  static String _summaryLine(int n) {
    final m = n % 100;
    if (m >= 11 && m <= 14) return '$n действий ждут связи с сервером';
    return switch (n % 10) {
      1 => '$n действие ждёт связи с сервером',
      2 || 3 || 4 => '$n действия ждут связи с сервером',
      _ => '$n действий ждут связи с сервером',
    };
  }

  Widget _empty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_done_outlined, size: 48, color: Wms.done),
          const SizedBox(height: 12),
          Text('Всё отправлено',
              style: TextStyle(fontSize: 16, color: Wms.muted)),
        ],
      ),
    );
  }

  Widget _list(List<UnsentOp> ops) {
    return SingleChildScrollView(
      child: DsCard(
        margin: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        children: [
          for (final op in ops) ...[
            _row(op),
            if (op != ops.last)
              const Divider(height: 1, thickness: 1),
          ],
        ],
      ),
    );
  }

  /// Строка действия: вид, задача, «в очереди с …», причина. Отказ сервера —
  /// красным: «задачу уже взял другой» — это ответ, а не шум.
  Widget _row(UnsentOp op) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(_icon(op.kind), size: 20, color: Wms.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(op.detail,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Wms.text)),
                const SizedBox(height: 2),
                Text(op.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: Wms.muted)),
                if (op.queuedAt != null)
                  Text('В очереди с ${_fmtWhen(op.queuedAt!)}',
                      style: TextStyle(fontSize: 12, color: Wms.muted)),
                if (op.error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(op.error!,
                        style:
                            TextStyle(fontSize: 12, color: Wms.danger)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  IconData _icon(String kind) {
    switch (kind) {
      case UnsentKind.create:
        return Icons.add_task;
      case UnsentKind.fill:
        return Icons.checklist_outlined;
      case UnsentKind.simple:
        return Icons.task_alt;
      case UnsentKind.status:
        return Icons.swap_horiz;
      case UnsentKind.take:
        return Icons.front_hand_outlined;
      case UnsentKind.watch:
        return Icons.visibility_outlined;
      case UnsentKind.decision:
        return Icons.fact_check_outlined;
      case UnsentKind.comment:
        return Icons.chat_bubble_outline;
      case UnsentKind.file:
        return Icons.photo_outlined;
      default:
        return Icons.cloud_upload_outlined;
    }
  }

  /// «сегодня 10:42», «вчера 18:03», «21.08 09:15» — как в ленте уведомлений.
  String _fmtWhen(DateTime t) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(t.year, t.month, t.day);
    String two(int v) => v.toString().padLeft(2, '0');
    final hm = '${two(t.hour)}:${two(t.minute)}';
    if (day == today) return 'сегодня $hm';
    if (day == today.subtract(const Duration(days: 1))) return 'вчера $hm';
    return '${two(t.day)}.${two(t.month)} $hm';
  }
}
