import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/sync_coordinator.dart';
import '../../data/task_repository.dart';
import '../../models/task.dart';
import '../../models/task_view.dart';
import '../theme.dart';

// Приёмка результата на телефоне (#37158): строки, которыми карточка и экраны
// выполнения объясняют, где задача в цикле сдачи, и панель решения принимающего —
// одна на карточку и на экран результата.

/// «Возвращено на доработку: фото нечитаемое» — то, что исполнитель читает первым,
/// когда задача снова у него.
String returnedLine(TaskView v) {
  final reason = v.returnReason?.trim();
  return reason == null || reason.isEmpty
      ? 'Возвращено на доработку'
      : 'Возвращено на доработку: $reason';
}

/// «Сдана 25.09 11:00 — принимает Петров П.П.»: когда и кому. До первого ответа
/// сервера (сдача ещё в очереди) ни того ни другого нет — тогда честно «ждёт отправки».
String submittedLine(TaskView v) {
  if (!v.task.onAcceptance) return 'Сдана — уйдёт на приёмку при связи';
  final at = formatDateTime(v.task.submittedAt);
  final who = v.task.acceptor;
  return [
    at == null ? 'Сдана на приёмку' : 'Сдана $at',
    if (who != null) 'принимает $who',
  ].join(' — ');
}

/// Причина возврата — обязательна: пустой возврат кнопка не отправляет (сервер отверг
/// бы его сам, но человек узнал бы об этом уже из очереди). null — передумал.
///
/// Спрашивается нижним листом (#37411, п. 8), а не диалогом: заголовок, задача и
/// исполнитель, поле «Причина» с подсказкой — всё видно до того, как начинать писать.
Future<String?> askReturnReason(BuildContext context, TaskView view) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _ReturnSheet(view: view),
  );
}

class _ReturnSheet extends StatefulWidget {
  final TaskView view;
  const _ReturnSheet({required this.view});

  @override
  State<_ReturnSheet> createState() => _ReturnSheetState();
}

class _ReturnSheetState extends State<_ReturnSheet> {
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  bool get _ready => _reason.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final t = widget.view.task;
    return Padding(
      // клавиатура не должна наезжать на поле, ради которого лист открыт
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Вернуть на доработку',
                  style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: Wms.text)),
              const SizedBox(height: 8),
              Text(t.name ?? t.object ?? t.id,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Wms.text)),
              const SizedBox(height: 2),
              Text('Исполнитель: ${t.assignedTo ?? '—'}',
                  style: TextStyle(fontSize: 13, color: Wms.text2)),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('returnReason'),
                controller: _reason,
                autofocus: true,
                minLines: 2,
                maxLines: 5,
                maxLength: 500,
                textCapitalization: TextCapitalization.sentences,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'Причина',
                  hintText: 'Что переделать — исполнитель увидит это на карточке',
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Отмена'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _ready
                          ? () =>
                              Navigator.of(context).pop(_reason.text.trim())
                          : null,
                      style: FilledButton.styleFrom(
                        backgroundColor: Wms.danger,
                        foregroundColor: Wms.isDark
                            ? const Color(0xFF3B2220)
                            : Colors.white,
                      ),
                      child: const Text('Вернуть'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// «Принять» и «Вернуть» — решение принимающего. Решение ложится в очередь и работает
/// в самолётном режиме; строка уходит из «Ждут моей приёмки» сразу, а кто успел раньше
/// при споре — скажет полоса над списком. [popAfter] — экран, который после решения
/// закрывается (экран результата); карточка закрывается сама, когда принятая задача
/// уходит из списка.
///
/// Редизайн #37411 (п. 8): «Вернуть» — контурная с красным текстом, «Принять» —
/// залитая, обе по 52 вровень с панелями экранов.
class DecisionBar extends StatelessWidget {
  final TaskView view;
  final bool popAfter;
  const DecisionBar({super.key, required this.view, this.popAfter = false});

  Future<void> _decide(BuildContext context, {required bool accept}) async {
    final repo = context.read<TaskRepository>();
    final sync = context.read<SyncCoordinator>();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    String? reason;
    if (!accept) {
      reason = await askReturnReason(context, view);
      if (reason == null) return;
    }
    if (accept) {
      await repo.acceptTask(view.id);
    } else {
      await repo.returnTask(view.id, reason!);
    }
    messenger.showSnackBar(SnackBar(
      content: Text(repo.online
          ? (accept ? 'Результат принят' : 'Задача возвращена на доработку')
          : (accept
              ? 'Принято — уедет на сервер при связи'
              : 'Возврат сохранён — уедет на сервер при связи')),
      duration: const Duration(seconds: 2),
    ));
    // решение уже в очереди и уезжает само; полный цикл следом — чтобы плитка
    // «Ждут приёмки» на главной сошлась со списком, не дожидаясь другого повода
    unawaited(sync.syncAndRefresh());
    if (popAfter && navigator.canPop()) navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            key: const ValueKey('returnTask'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Wms.danger,
              side: BorderSide(color: Wms.danger),
              minimumSize: const Size(0, 52),
            ),
            onPressed: () => _decide(context, accept: false),
            icon: const Icon(Icons.undo),
            label: const Text('Вернуть'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: FilledButton.icon(
            key: const ValueKey('acceptTask'),
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 52),
            ),
            onPressed: () => _decide(context, accept: true),
            icon: const Icon(Icons.check),
            label: const Text('Принять'),
          ),
        ),
      ],
    );
  }
}
