// Сквозная приёмка #37135 на живом стенде (192.168.42.28:8888, demo.user1).
//
// Проверяется ровно то, ради чего в выдачу добавлялся признак `watched`: задача, на
// которую человек подписан, приезжает на телефон и открывается — но своей группой
// «Наблюдаю», а не «Моими». Без признака строка без assigned/authored читается
// клиентом как назначенная (совместимость со старым сервером, #36844), и цифра плитки
// «Мои задачи» разошлась бы с длиной группы — дефект доверия #36751.
//
// Сценарий:
//  1) наблюдаемая задача есть в списке, в группе «Наблюдаю», и её нет ни в «Моих»,
//     ни в фильтрах-двойниках плиток;
//  2) цифра плитки «Мои задачи» равна длине группы «Мои» — со списком сходится;
//  3) карточка открывается, говорит «Вы наблюдаете за этой задачей» и не даёт
//     работать: ни выполнения, ни переключателя статусов, ни взятия.
//
// Подготовка на стенде (bash + /eval): задача с объектом демо-организации, назначенная
// на demo.user2, автор sosedi.eng, наблюдатель — demo.user1. Учётка без геопривязки,
// поэтому гео-гейт проходить нечем и нечего.
//
// Параметры — dart-define: E2E_BASE, E2E_LOGIN/E2E_PASS, E2E_TASK (код наблюдаемой).
// Маркеры для шелла: boot:, E2E_READY, SHOT_list, SHOT_card, ALL_OK_37135.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pulse_tasks/app_controllers.dart';
import 'package:pulse_tasks/models/task_view.dart';
import 'package:pulse_tasks/ui/task_detail_screen.dart';
import 'package:pulse_tasks/ui/widgets/task_card.dart';
import 'support/e2e_harness.dart';

const _login = String.fromEnvironment('E2E_LOGIN', defaultValue: 'demo.user1');
const _task = String.fromEnvironment('E2E_TASK', defaultValue: 'ST000114');

/// Объект, на котором у этой учётки есть и своя задача, и наблюдаемая: по нему список
/// сужается до двух строк в РАЗНЫХ группах.
const _object = String.fromEnvironment('E2E_OBJECT', defaultValue: 'Склад (демо)');

Future<void> _openList(WidgetTester tester) async {
  final all = find.textContaining('Все (');
  if (all.evaluate().isEmpty) return; // уже в полном списке
  await tester.tap(all.first);
  await until(tester, 'список задач на экране',
      () => find.byType(TaskCard).evaluate().isNotEmpty);
}

TaskView? _viewOf(AppControllers app, String id) {
  for (final v in app.repo.tasks) {
    if (v.id == id) return v;
  }
  return null;
}

/// Разрез, в котором плитка показывает своё число, — тот же, что уходит в список по
/// тапу (см. due_flags_e2e_test): объект, если блок в разрезе, и вся сеть, если нет.
String? _cut(AppControllers app, String code) {
  for (final b in app.home.layout.blocks) {
    for (final m in b.metrics) {
      if (m.code == code) return b.byObject ? app.home.objectId : null;
    }
  }
  fail('на главной нет показателя $code');
}

/// Цифра плитки — ровно та, что человек видит на главной (см. due_flags_e2e_test).
int _tile(AppControllers app, String code) {
  for (final b in app.home.layout.blocks) {
    for (final m in b.metrics) {
      if (m.code == code) {
        return (m.valueFor(b.byObject ? app.home.objectId : null) ?? 0).round();
      }
    }
  }
  fail('на главной нет показателя $code');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('37135: наблюдаемая задача — своя группа, не «мои»',
      (tester) async {
    final app = await bootApp(tester, login: _login);
    // главная приезжает своей ручкой (apiHome), и без неё показателей нет вовсе —
    // ждать одного лишь списка задач недостаточно
    await app.sync.syncAndRefresh();
    await settle(tester);
    await until(tester, 'список задач с сервера',
        () => app.repo.tasks.isNotEmpty, seconds: 120);
    await until(tester, 'главная с показателями',
        () => app.home.layout.blocks.isNotEmpty, seconds: 120);
    debugPrint('E2E_READY задач=${app.repo.tasks.length} '
        'объект=${app.home.objectId}');

    // --- 1. подписка доехала до телефона отдельной группой ---
    final watched = _viewOf(app, _task);
    expect(watched, isNotNull,
        reason: 'наблюдаемая задача обязана приехать в выдаче');
    expect(watched!.task.watched, isTrue, reason: 'сервер прислал признак');
    expect(watched.watchedOnly, isTrue,
        reason: 'ни исполнитель, ни автор — только наблюдатель');
    expect(watched.group, TaskGroup.watched,
        reason: 'не «Мои»: иначе плитка разойдётся со списком (#36751)');
    expect(watched.readOnly, isTrue);
    expect(watched.canTake, isFalse,
        reason: 'взятие идёт по назначению, а не по подписке');

    // --- 2. цифра плитки сходится с длиной группы «Мои» ---
    // Разрез у плитки и у списка обязан быть один: блок «Мои задачи» на этом стенде
    // настроен по объекту, и сравнивать его число со всей сетью значило бы сравнивать
    // разные множества.
    final cut = _cut(app, 'myOpen');
    final mine = app.repo.tasks
        .where((v) =>
            v.group == TaskGroup.mine &&
            (cut == null || v.task.objectId == cut))
        .toList();
    debugPrint('E2E_TILE myOpen=${_tile(app, 'myOpen')} '
        'список=${mine.length} разрез=$cut');
    expect(mine.map((v) => v.id), isNot(contains(_task)));
    // и в «Моих» вообще, без разреза: наблюдаемая может лежать на другом объекте, и
    // проверка «её нет в срезе» сама по себе доказывала бы только это
    expect(
        app.repo.tasks
            .where((v) => v.group == TaskGroup.mine)
            .map((v) => v.id),
        isNot(contains(_task)));
    expect(_tile(app, 'myOpen'), mine.length,
        reason: 'плитка «Мои задачи» и группа «Мои» — одно множество');
    // фильтры-двойники плиток наблюдаемую тоже не считают
    for (final f in [TaskFilter.open, TaskFilter.today, TaskFilter.overdue]) {
      expect(app.repo.tasks.where(f.matches).map((v) => v.id),
          isNot(contains(_task)),
          reason: 'фильтр ${f.title} считает «мои», а наблюдаемая — не моя');
    }
    // «Все задачи» её показывают — иначе уведомление некуда открыть
    expect(app.repo.tasks.where(TaskFilter.all.matches).map((v) => v.id),
        contains(_task));

    // --- 3. группа видна на экране и карточка только для чтения ---
    // Наблюдаемая ищется поиском, а не прокруткой полусотни карточек: на эмуляторе
    // отрисовка всего списка кладёт устройство, а искать задачу в списке человек и
    // так будет поиском.
    await _openList(tester);
    final search = find.byType(TextField).first;
    // Поиск, а не прокрутка полусотни карточек: на эмуляторе отрисовка всего списка
    // кладёт устройство, да и человек ищет задачу тем же полем.
    //
    // Ищем по ОБЪЕКТУ, а не по названию: по названию в списке остаётся одна задача, а
    // единственной группе заголовок намеренно не рисуется (task_list_screen: «деления
    // нет») — проверять было бы нечего. На этом объекте у учётки две задачи, своя и
    // наблюдаемая, и обе группы оказываются на экране рядом.
    await tester.enterText(search, _object);
    await settle(tester, frames: 6);
    expect(find.text(TaskGroup.mine.title), findsWidgets);
    expect(find.text(TaskGroup.watched.title), findsWidgets,
        reason: 'наблюдаемая обязана стоять отдельной группой, а не в «Моих»');
    await shot(tester, 'SHOT_list');

    // теперь сузить до одной карточки и открыть её: заголовок карточки — object ?? name,
    // поэтому ищется она по остатку списка, а не по тексту названия
    await tester.enterText(search, watched.task.name!);
    await settle(tester, frames: 6);
    final card = find.byType(TaskCard);
    expect(card, findsOneWidget, reason: 'поиск обязан оставить одну наблюдаемую');
    await tester.tap(card.first);
    await until(tester, 'карточка наблюдаемой',
        () => find.byType(TaskDetailScreen).evaluate().isNotEmpty);
    await settle(tester, frames: 8);

    expect(find.textContaining('Вы наблюдаете за этой задачей'), findsOneWidget);
    expect(find.textContaining('Вы автор этой задачи'), findsNothing);
    expect(find.text('Выполнить'), findsNothing,
        reason: 'работа по задаче — у исполнителя, сервер её и так отвергает');
    expect(find.text('Взять на себя'), findsNothing);
    await shot(tester, 'SHOT_card');

    debugPrint('ALL_OK_37135');
  });
}
