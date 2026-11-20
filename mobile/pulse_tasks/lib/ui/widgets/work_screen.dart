import 'package:flutter/material.dart';

import '../../models/task_view.dart';
import '../theme.dart';
import 'ds.dart';

// Общее у двух экранов работы по задаче — бланка (FillScreen) и поручения
// (SimpleExecutionScreen): заглушка вне объекта, значок синхронизации в шапке и
// слова о завершении. Экраны разные, а эти куски у них должны совпадать: разойдясь,
// они говорили бы человеку разное об одном и том же.

/// «Вы не на этом объекте» — вместо экрана работы, а не поверх него (#36837). Полей и
/// кнопок не видно намеренно: живые на вид контролы звали бы работать из дома.
/// Сделанное на месте цело и уедет как обычно — экран говорит это прямо, потому что
/// «нельзя продолжать» без этого читается как «пропало».
class AwayNotice extends StatelessWidget {
  /// Заголовок шапки — «Заполнение», «Выполнение».
  final String title;

  /// Что можно только на месте — «Заполнять», «Выполнять».
  final String action;

  /// Что сохранено — «Всё введённое на месте», «Всё снятое на месте».
  final String kept;

  /// Расстояние до объекта задачи, если известно.
  final String? distance;

  const AwayNotice(
      {super.key,
      required this.title,
      required this.action,
      required this.kept,
      this.distance});

  @override
  Widget build(BuildContext context) {
    final d = distance;
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                alignment: Alignment.center,
                decoration:
                    BoxDecoration(color: Wms.chipBg, shape: BoxShape.circle),
                child: Icon(Icons.near_me_disabled_outlined,
                    size: 32, color: Wms.text2),
              ),
              const SizedBox(height: 16),
              Text(
                'Вы не на этом объекте',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                    color: Wms.text),
              ),
              const SizedBox(height: 10),
              Text(
                '$action можно только на объекте задачи'
                '${d == null ? '' : ' — до него $d'}. '
                '$kept сохранено и синхронизируется как обычно.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, height: 1.4, color: Wms.text2),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.arrow_back, size: 18),
                  label: const Text('К задаче'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Значок синхронизации в шапке экрана работы: крутится, пока идёт отправка; иначе
/// — сколько ещё не уехало; ничего — когда уехало всё.
class SyncBadge extends StatelessWidget {
  final bool syncing;
  final int pending;

  const SyncBadge({super.key, required this.syncing, required this.pending});

  @override
  Widget build(BuildContext context) {
    if (!syncing && pending <= 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(right: 16),
      child: Center(
        child: syncing
            ? SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Wms.text2),
              )
            : DsChip(
                '$pending',
                icon: Icons.sync_problem,
                tone: DsTone.caution,
              ),
      ),
    );
  }
}

/// Слова экрана работы о завершении. У бланка и поручения они свои («Завершить»,
/// «Выполнено»), а правило общее: у задачи с приёмкой (#37158) завершение — это
/// сдача, а не конец, и кнопка с сообщением говорят это прямо.
class FinishWords {
  /// Задача уходит на приёмку.
  final bool submits;

  /// Кнопка до завершения.
  final String _action;

  /// Кнопка после завершения.
  final String _done;

  /// Сообщение о завершении при связи.
  final String _doneMessage;

  /// Начало сообщения о завершении без связи.
  final String _doneQueued;

  /// Бланк: «Завершить» — «Завершено».
  FinishWords.fill(TaskView? view)
      : submits = _submits(view),
        _action = 'Завершить',
        _done = 'Завершено',
        _doneMessage = 'Задача завершена',
        _doneQueued = 'Завершено';

  /// Поручение: «Выполнено» — «Задача выполнена».
  FinishWords.simple(TaskView? view)
      : submits = _submits(view),
        _action = 'Выполнено',
        _done = 'Задача выполнена',
        _doneMessage = 'Задача выполнена',
        _doneQueued = 'Выполнено';

  static bool _submits(TaskView? view) => view?.task.needsAcceptance == true;

  String get button => submits ? 'Сдать на приёмку' : _action;

  String get finishedButton => submits ? 'Сдано на приёмку' : _done;

  String message({required bool online}) => online
      ? (submits ? 'Сдано на приёмку' : _doneMessage)
      : (submits
          ? 'Сдано — уедет на сервер при связи'
          : '$_doneQueued — уедет на сервер при связи');
}
