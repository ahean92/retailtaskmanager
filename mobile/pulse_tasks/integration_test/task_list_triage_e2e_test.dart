// Сквозная приёмка #36915 на живом стенде — разбор списка задач: поиск, сортировка,
// фильтры по статусу и приоритету, персист разбора и отзывчивость на тысяче строк.
//
// Throwaway-драйвер: сеть переключает внешний шелл по маркерам в логе. Весь разбор
// работает по ЛОКАЛЬНОЙ базе, поэтому проверяется в авиарежиме: в кэш кладётся
// тысяча строк нагрузки плюс контрольные с известными сроком, приоритетом и
// статусом — первая же синхронизация с сетью возвращает серверную выдачу на место.
//
// Параметры — dart-define: E2E_BASE (адрес стенда), E2E_LOGIN/E2E_PASS.
//
// Сценарий приёмки («Приёмка» тикета):
//  1) поиск по части слова находит задачу — при выключенной сети;
//  2) на тысяче задач ввод в строку поиска не подвешивает кадр;
//  3) сортировка по сроку ставит просроченные наверх, по приоритету — срочные;
//  4) выбранный фильтр переживает закрытие списка и лежит в базе пользователя
//     (полный перезапуск приложения покрыт юнит-тестом ticket36915_test.dart);
//  5) «Показать все» сбрасывает разбор одним тапом.
//
// Маркеры: boot:, E2E_READY, NET_OFF, E2E_TYPE_MS=<ms>, SHOT_search, SHOT_sorted,
// SHOT_filter, E2E_PERSIST_OK, NET_ON, ALL_OK_36915.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pulse_tasks/data/task_repository.dart';
import 'package:pulse_tasks/main.dart' as app;
import 'package:pulse_tasks/models/task.dart';
import 'package:pulse_tasks/ui/task_list_screen.dart';
import 'support/e2e_harness.dart';

const _login = String.fromEnvironment('E2E_LOGIN', defaultValue: 'sosedi.tech1');

double _y(WidgetTester tester, String text) =>
    tester.getTopLeft(find.text(text)).dy;

/// Открыть шторку разбора, нажать чип и закрыть её тапом по затемнению.
Future<void> _tuneTap(WidgetTester tester, Finder chip) async {
  await tester.tap(find.byIcon(Icons.tune));
  await settle(tester);
  await tester.tap(chip);
  await settle(tester);
  await tester.tapAt(const Offset(20, 200)); // барьер над шторкой
  await settle(tester);
}

String _iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('36915: поиск, сортировка, фильтры и персист разбора',
      (tester) async {
    final repo = await bootApp(tester, login: _login);

    await repo.syncAndRefresh();
    // разбор прошлых прогонов не должен красить этот
    await repo.saveListPrefs(const ListPrefs());
    debugPrint('E2E_READY object=${repo.objectId}');

    // ===== офлайн: весь разбор обязан работать без сети =====
    debugPrint('NET_OFF');
    await until(tester, 'авиарежим', () => !repo.online, seconds: 240);

    final obj = repo.place.objectId;
    final today = DateTime.now();
    Task row(String id, String name,
            {String? deadline,
            String? prioId,
            String? prio,
            String status = 'Новый',
            String statusId = 'new'}) =>
        Task.fromJson({
          'id': id,
          'name': name,
          if (obj != null) 'objectId': obj,
          'status': status,
          'statusId': statusId,
          if (deadline != null) 'deadline': deadline,
          if (prioId != null) 'priorityId': prioId,
          if (prio != null) 'priority': prio,
        });
    await repo.db.replaceTasks([
      row('E2E-A', 'Э2Э просроченная',
          deadline: _iso(today.subtract(const Duration(days: 2))),
          prioId: 'high',
          prio: 'Высокий',
          status: 'В работе',
          statusId: 'in progress'),
      row('E2E-B', 'Э2Э срочная сегодня',
          deadline: _iso(today), prioId: 'urgent', prio: 'Срочный'),
      row('E2E-C', 'Э2Э обычная завтра',
          deadline: _iso(today.add(const Duration(days: 1))),
          prioId: 'normal',
          prio: 'Обычный'),
      for (var i = 0; i < 1000; i++) row('E2E-L$i', 'Нагрузка $i'),
    ]);
    await repo.reloadLocal();
    expect(repo.tasks.length, greaterThanOrEqualTo(1003));

    // --- список: «Мои задачи» без параметров (кнопка «Все (N)»/«Открыть») ---
    final allBtn = find.textContaining('Все (');
    await tester
        .tap((allBtn.evaluate().isNotEmpty ? allBtn : find.text('Открыть')).first);
    await until(tester, 'экран списка',
        () => find.byType(TaskListScreen).evaluate().isNotEmpty);

    // ===== 1-2. поиск: по части слова, офлайн, на тысяче строк без подвисания =====
    final search = find.byType(TextField).first;
    final sw = Stopwatch()..start();
    await tester.enterText(search, 'нагрузка 999');
    await tester.pump();
    sw.stop();
    debugPrint('E2E_TYPE_MS=${sw.elapsedMilliseconds}');
    expect(sw.elapsedMilliseconds, lessThan(2000),
        reason: 'на тысяче задач ввод не должен подвешивать кадр');
    await settle(tester, frames: 3);
    expect(find.text('Нагрузка 999'), findsOneWidget);
    expect(find.text('Найдено: 1'), findsOneWidget);

    await tester.enterText(search, 'просроч'); // по части слова
    await settle(tester, frames: 3);
    expect(find.text('Э2Э просроченная'), findsOneWidget);
    expect(find.text('Найдено: 1'), findsOneWidget);
    await shot(tester, 'SHOT_search');

    await tester.enterText(search, '');
    await settle(tester, frames: 3);

    // ===== 3. сортировки =====
    await _tuneTap(tester, find.text('По сроку'));
    expect(_y(tester, 'Э2Э просроченная'),
        lessThan(_y(tester, 'Э2Э срочная сегодня')),
        reason: 'просроченные наверх');
    expect(_y(tester, 'Э2Э срочная сегодня'),
        lessThan(_y(tester, 'Э2Э обычная завтра')));
    await shot(tester, 'SHOT_sorted');

    await _tuneTap(tester, find.text('По приоритету'));
    expect(_y(tester, 'Э2Э срочная сегодня'),
        lessThan(_y(tester, 'Э2Э просроченная')),
        reason: 'срочные первыми');
    expect(_y(tester, 'Э2Э просроченная'),
        lessThan(_y(tester, 'Э2Э обычная завтра')));

    // ===== 4. фильтр по статусу и его персист =====
    // «В работе · 1» — счётчик есть только у чипа шторки, бейджи карточек без него
    await _tuneTap(tester, find.textContaining('В работе · '));
    expect(find.text('Э2Э просроченная'), findsOneWidget);
    expect(find.text('Э2Э срочная сегодня'), findsNothing);
    expect(find.text('Найдено: 1'), findsOneWidget);
    await shot(tester, 'SHOT_filter');

    // закрыть список и открыть заново — разбор на месте
    await tester.pageBack();
    await settle(tester);
    app.PulseApp.navigatorKey.currentState!
        .push(MaterialPageRoute(builder: (_) => const TaskListScreen()));
    await settle(tester);
    expect(find.text('Э2Э просроченная'), findsOneWidget);
    expect(find.text('Э2Э срочная сегодня'), findsNothing);
    expect(find.text('Найдено: 1'), findsOneWidget);
    // и лежит он в базе пользователя — это и переживает перезапуск приложения
    expect(await repo.db.getListPrefs(), contains('in progress'));
    debugPrint('E2E_PERSIST_OK');

    // ===== 5. «Показать все» — сброс одним тапом =====
    await tester.tap(find.text('Показать все'));
    await settle(tester);
    expect(find.text('Э2Э срочная сегодня'), findsOneWidget);
    expect(find.textContaining('Найдено: '), findsNothing);

    // ===== сеть обратно: серверная выдача возвращается на место =====
    debugPrint('NET_ON');
    await untilAsync(tester, 'серверная выдача вернулась', () async {
      await repo.syncAndRefresh();
      return repo.viewOf('E2E-A') == null;
    }, seconds: 300);
    debugPrint('ALL_OK_36915');
  });
}
