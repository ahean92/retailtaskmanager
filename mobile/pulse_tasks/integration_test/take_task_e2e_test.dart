// Сквозная приёмка #36836 на живом стенде (192.168.42.28:8888, demo.user1).
// Throwaway-драйвер: сеть переключает внешний шелл (adb svc) по маркерам в логе;
// конфликт устраивает он же — берёт задачу за sosedi.tech1 прямо по API стенда.
//
// Сценарий приёмки целиком:
//  1) свободные задачи подразделения видны отдельной группой, «Взять» переносит
//     одну в «мои» — онлайн, кнопкой на карточке;
//  2) в авиарежиме взятие проходит с пометкой «ожидает подтверждения», и ответ
//     бланка, заполненный там же, ложится в очередь;
//  3) пока телефон офлайн, задачу успевает взять коллега; с возвратом связи задача
//     переезжает в «взяты коллегами» с его именем, человек получает заметное
//     сообщение — а заполненный офлайн ответ бланка остаётся при нём и доезжает
//     до сервера;
//  4) «Снять с себя» из деталки возвращает онлайн-взятую в «свободные».
//
// Маркеры для шелла: READY_FOR_AIRPLANE → выключить сеть; CONFLICT_TASK=<id> →
// взять <id> за tech1 и включить сеть; ALL_OK_36836 — приёмка пройдена.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pulse_tasks/data/fill_controller.dart';
import 'package:pulse_tasks/data/task_repository.dart';
import 'package:pulse_tasks/main.dart' as app;
import 'package:pulse_tasks/ui/task_list_screen.dart';
import 'package:pulse_tasks/ui/widgets/task_card.dart';
import 'support/e2e_harness.dart';

const _login = String.fromEnvironment('E2E_LOGIN', defaultValue: 'demo.user1');

TaskView? _viewOf(TaskRepository repo, String id) {
  for (final v in repo.tasks) {
    if (v.id == id) return v;
  }
  return null;
}

/// Сам список задач: первый Scrollable экрана — горизонтальная лента чипов
/// фильтров, скроллить надо не её.
Finder _verticalList() => find.byWidgetPredicate(
    (w) => w is Scrollable && w.axisDirection == AxisDirection.down);

/// Докрутить список до [target]: dy < 0 — вниз по списку, dy > 0 — вверх.
Future<void> _dragUntil(WidgetTester tester, Finder target, double dy,
    {required String what}) async {
  for (var i = 0; i < 60 && target.evaluate().isEmpty; i++) {
    await tester.drag(_verticalList().first, Offset(0, dy),
        warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 60));
  }
  await tester.pumpAndSettle();
  expect(target, findsWidgets, reason: 'не доскроллились: $what');
  await tester.ensureVisible(target.first);
  await tester.pumpAndSettle();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('36836: пул подразделения, взятие офлайн и проигранная гонка',
      (tester) async {
    final repo = await bootApp(tester, login: _login);

    // --- список задач; пул подразделения приезжает свободным ---
    app.PulseApp.navigatorKey.currentState!
        .push(MaterialPageRoute(builder: (_) => const TaskListScreen()));
    await tester.pumpAndSettle();
    await until(
        tester,
        'три свободных задачи пула (DEMO36835, после посева и очистки стенда)',
        () =>
            repo.tasks
                .where((v) =>
                    v.id.startsWith('DEMO36835') &&
                    v.group == TaskGroup.free &&
                    v.canTake)
                .length ==
            3,
        seconds: 120);
    debugPrint('pool: ${repo.tasks.where((v) => v.id.startsWith('DEMO36835')).length} задач, '
        'мои=${repo.tasks.where((v) => v.group == TaskGroup.mine).length}');

    // ===== сценарий 1: онлайн-взятие кнопкой на карточке =====
    // группа «Свободные» — ниже «моих», кнопку сперва надо доскроллить
    debugPrint('scrollables: ${tester.widgetList(find.byType(Scrollable)).map((w) => (w as Scrollable).axisDirection).toList()}, '
        'cards=${tester.widgetList(find.byType(TaskCard)).length}');
    await _dragUntil(tester, find.text('Взять'), -400,
        what: 'кнопка «Взять» в группе «Свободные»');
    debugPrint('after drags: btns=${find.text('Взять').evaluate().length}, '
        'cards=${tester.widgetList(find.byType(TaskCard)).length}');
    await tester.tap(find.text('Взять').first, warnIfMissed: false);
    await tester.pump();

    await until(
        tester,
        'взятая онлайн подтверждена и в «моих»',
        () => repo.tasks.any((v) =>
            v.id.startsWith('DEMO36835') &&
            v.group == TaskGroup.mine &&
            !v.takePending &&
            v.releasable),
        seconds: 90);
    final onlineTaken = repo.tasks.firstWhere((v) =>
        v.id.startsWith('DEMO36835') && v.group == TaskGroup.mine);
    debugPrint('ONLINE_TAKEN=${onlineTaken.id}');

    // конфликтную выбираем из видимых tech1 (клининг и магазин: -1 и -2)
    final conflictId = ['DEMO36835-1', 'DEMO36835-2']
        .firstWhere((id) => id != onlineTaken.id);

    // бланк конфликтной открывается при связи — кэш, из которого он потом
    // откроется офлайн (шаблон «Уборка (демо 36835)» сеет ticket36835_demo.lsf)
    final warm = FillController(db: repo.db, api: repo.api, taskId: conflictId);
    await warm.load();
    expect(warm.fields, isNotEmpty, reason: 'бланк пула должен открываться');
    warm.dispose();

    // --- внешний шелл выключает сеть ---
    debugPrint('READY_FOR_AIRPLANE');
    await until(tester, 'авиарежим', () => !repo.online, seconds: 240);

    // ===== сценарий 2: взятие офлайн — с явной пометкой =====
    await repo.takeTask(conflictId);
    await tester.pumpAndSettle();
    var conflictView = _viewOf(repo, conflictId)!;
    expect(conflictView.group, TaskGroup.mine);
    expect(conflictView.takePending, isTrue);
    // пометка видна человеку, не только репозиторию: карточка уже в «моих»
    final pendingCard = find.byWidgetPredicate(
        (w) => w is TaskCard && w.view.id == conflictId);
    await _dragUntil(tester, pendingCard, 400,
        what: 'карточка взятой офлайн в «моих»');
    expect(
        find.descendant(
            of: pendingCard,
            matching: find.text('взята — ожидает подтверждения')),
        findsOneWidget);

    // и там же, офлайн, человек начинает заполнять бланк — из кэша, разогретого
    // при связи; ответ ложится в очередь заполнения
    final fill = FillController(db: repo.db, api: repo.api, taskId: conflictId);
    await fill.load();
    expect(fill.fields, isNotEmpty, reason: 'бланк обязан открыться из кэша');
    expect(fill.online, isFalse);
    final clean = fill.fields.firstWhere((f) => f.code == 'clean');
    expect(clean.options, isNotEmpty);
    await fill.setOption(clean, clean.options.first.code);
    await fill.setText(
        fill.fields.firstWhere((f) => f.code == 'note'), 'офлайн-ответ 36836');
    fill.dispose();
    final queuedAnswers = (await repo.db.getFieldOutbox(conflictId)).length;
    debugPrint('queued answers offline: $queuedAnswers');
    expect(queuedAnswers, 2);

    // --- шелл: взять conflictId за tech1 и вернуть сеть ---
    debugPrint('CONFLICT_TASK=$conflictId');
    await until(tester, 'конфликт доехал и замечен',
        () => repo.online && repo.takeNotice != null,
        seconds: 300);

    // ===== сценарий 3: проигранная гонка — переезд с именем, не потеря =====
    conflictView = _viewOf(repo, conflictId)!;
    expect(conflictView.group, TaskGroup.taken,
        reason: 'строка не исчезла, а переехала к коллеге');
    expect(conflictView.takePending, isFalse);
    expect(conflictView.takenBy, isNotNull);
    debugPrint('conflict taken by: ${conflictView.takenBy}; '
        'notice: ${repo.takeNotice}');
    expect(repo.takeNotice, contains(conflictView.takenBy!));
    // заметное сообщение висит на экране, пока его не закроют
    expect(find.textContaining('уже взял'), findsOneWidget);
    expect(await repo.db.getTakeOutbox(), isEmpty);

    // заполненное осталось при человеке: гонка не тронула очередь ответов...
    expect(await repo.db.getFieldOutbox(conflictId), hasLength(2),
        reason: 'ответы, заполненные офлайн, не выброшены из-за конфликта');
    // ...и при следующем открытии бланка они доезжают до сервера — «взял» на
    // сервере координация, а не блокировка, ответ чужой взятой принимается
    final after = FillController(db: repo.db, api: repo.api, taskId: conflictId);
    await after.load();
    expect(after.online, isTrue);
    expect(await repo.db.getFieldOutbox(conflictId), isEmpty,
        reason: 'ответы, заполненные офлайн, обязаны доехать');
    expect(after.answeredCount, 2, reason: 'сервер видит заполненное');
    after.dispose();

    // ===== сценарий 4: «Снять с себя» из деталки возвращает в пул =====
    final ownCard = find.byWidgetPredicate(
        (w) => w is TaskCard && w.view.id == onlineTaken.id);
    await _dragUntil(tester, ownCard, 400,
        what: 'карточка онлайн-взятой в «моих»');
    await tester.tap(ownCard);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Снять с себя'));
    await tester.pump();
    await until(
        tester,
        'снятая вернулась в «свободные»',
        () {
          final v = _viewOf(repo, onlineTaken.id);
          return v != null && v.group == TaskGroup.free && !v.releasable;
        },
        seconds: 90);
    await tester.pageBack();
    await tester.pumpAndSettle();

    debugPrint('ALL_OK_36836');
  });
}
