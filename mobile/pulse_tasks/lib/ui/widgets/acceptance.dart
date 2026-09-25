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
Future<String?> askReturnReason(BuildContext context) {
  return showDialog<String>(
    context: context,
    builder: (_) => const _ReturnDialog(),
  );
}

class _ReturnDialog extends StatefulWidget {
  const _ReturnDialog();

  @override
  State<_ReturnDialog> createState() => _ReturnDialogState();
}

class _ReturnDialogState extends State<_ReturnDialog> {
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  bool get _ready => _reason.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Вернуть на доработку'),
      content: TextField(
        key: const ValueKey('returnReason'),
        controller: _reason,
        autofocus: true,
        minLines: 2,
        maxLines: 5,
        maxLength: 500,
        textCapitalization: TextCapitalization.sentences,
        onChanged: (_) => setState(() {}),
        decoration: const InputDecoration(
          border: OutlineInputBorder(),
          labelText: 'Причина',
          hintText: 'Что переделать — исполнитель увидит это на карточке',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed:
              _ready ? () => Navigator.of(context).pop(_reason.text.trim()) : null,
          child: const Text('Вернуть'),
        ),
      ],
    );
  }
}

/// «Принять» и «Вернуть» — решение принимающего. Решение ложится в очередь и работает
/// в самолётном режиме; строка уходит из «Ждут моей приёмки» сразу, а кто успел раньше
/// при споре — скажет полоса над списком. [popAfter] — экран, который после решения
/// закрывается (экран результата); карточка закрывается сама, когда принятая задача
/// уходит из списка.
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
      reason = await askReturnReason(context);
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
              foregroundColor: Wms.warn,
              side: BorderSide(color: Wms.warn),
              minimumSize: const Size(0, 46),
            ),
            onPressed: () => _decide(context, accept: false),
            icon: const Icon(Icons.undo),
            label: const Text('Вернуть'),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: FilledButton.icon(
            key: const ValueKey('acceptTask'),
            style: FilledButton.styleFrom(
              backgroundColor: Wms.ok,
              foregroundColor: Wms.on(Wms.ok),
              minimumSize: const Size(0, 46),
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
