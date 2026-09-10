// Сквозная приёмка #37136 на живом стенде (192.168.42.28:8888, demo.user1): наблюдение
// за задачей с телефона — уведомления, группа «Наблюдаю», «Следить» / «Не следить».
//
// Throwaway-драйвер: авиарежим переключает внешний шелл по маркерам NET_OFF / NET_ON
// (`adb shell cmd connectivity airplane-mode …`), снимки экрана — по SHOT_*. Уведомление
// наблюдателю рождает вторая учётка — исполнитель задач (E2E_ASSIGNEE), комментарием в
// переписке: своим http-клиентом и своим токеном, сессию приложения это не трогает.
//
// Подготовка на стенде (bash + /eval под admin): demo.user1 лично подписан на E2E_A и
// E2E_B — задачи исполнителя, в которых сам он не участвует; сегодня по ним у него ещё
// нет записи «комментарий» (ключ дедупликации ядра — человек, событие, задача, день).
// E2E_C — открытая задача, которую demo.user1 поставил сам, и за которой не следит.
//
// Сценарий («Готово когда»):
//  1) A и B — в «Наблюдаю», не в «Моих» и не в фильтрах-двойниках; плитка «Мои задачи»
//     сходится со списком;
//  2) карточка A открывается на чтение с перепиской: баннер наблюдателя, «Не следить»,
//     ни выполнения, ни статусов, ни взятия;
//  3) исполнитель пишет в переписку A — у наблюдателя запись в ленте с пометкой
//     «наблюдаю»; тап по ней открывает задачу, а не «задачи нет в списке»;
//  4) в самолётном режиме «Не следить» у B убирает её из списка сразу, «Следить» у C
//     меняет кнопку и ставит пометку на строку — тоже сразу;
//  5) при связи обе уезжают; повтор очереди подписки второй подписки не создаёт;
//  6) исполнитель пишет в переписку B — наблюдателю, который отписался, не приходит ничего.
//
// Маркеры: boot:, E2E_READY, SHOT_list, SHOT_card, SHOT_feed, SHOT_open, NET_OFF,
// SHOT_offline, NET_ON, ALL_OK_37136.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:pulse_tasks/app_controllers.dart';
import 'package:pulse_tasks/data/client_id.dart';
import 'package:pulse_tasks/data/unsent.dart';
import 'package:pulse_tasks/main.dart';
import 'package:pulse_tasks/models/task_view.dart';
import 'package:pulse_tasks/ui/notifications_screen.dart';
import 'package:pulse_tasks/ui/task_detail_screen.dart';
import 'package:pulse_tasks/ui/widgets/task_card.dart';
import 'support/e2e_harness.dart';

const _login = String.fromEnvironment('E2E_LOGIN', defaultValue: 'demo.user1');
const _assignee =
    String.fromEnvironment('E2E_ASSIGNEE', defaultValue: 'sosedi.tech1');
const _a = String.fromEnvironment('E2E_A', defaultValue: 'DEMO36842-1');
const _b = String.fromEnvironment('E2E_B', defaultValue: 'DEMO36842-2');
const _c = String.fromEnvironment('E2E_C', defaultValue: 'ST000014');

TaskView? _viewOf(AppControllers app, String id) {
  for (final v in app.repo.tasks) {
    if (v.id == id) return v;
  }
  return null;
}

/// Цифра плитки — ровно та, что человек видит на главной (см. task_watcher_e2e_test).
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

String? _cut(AppControllers app, String code) {
  for (final b in app.home.layout.blocks) {
    for (final m in b.metrics) {
      if (m.code == code) return b.byObject ? app.home.objectId : null;
    }
  }
  fail('на главной нет показателя $code');
}

/// Сообщение в переписку задачи от имени второй учётки — так у наблюдателя рождается
/// уведомление. Своим клиентом и своим токеном: общий ApiClient писал бы в сессию
/// приложения.
Future<void> _commentAs(String login, String taskId, String text) async {
  final base = e2eBase.trim().replaceAll(RegExp(r'/+$'), '');
  final t = await http.get(
    Uri.parse('$base/exec/Authentication.getAuthToken'),
    headers: {
      'Accept': 'text/plain',
      'Authorization': 'Basic ${base64Encode(utf8.encode('$login:$e2ePass'))}',
    },
  ).timeout(const Duration(seconds: 20));
  expect(t.statusCode, 200, reason: 'токен второй учётки');
  final token = utf8.decode(t.bodyBytes).trim();
  final r = await http
      .post(
        Uri.parse('$base/exec/StoreTask.apiAddTaskComment'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(
            {'id': taskId, 'clientId': newClientId(), 'text': text}),
      )
      .timeout(const Duration(seconds: 20));
  expect(r.statusCode, 200,
      reason: 'сообщение исполнителя: ${utf8.decode(r.bodyBytes)}');
}

/// Долистать вертикальный список до [finder]: карточки ниже экрана не построены, и
/// scrollUntilVisible на живом списке спотыкается о ленту чипов (грабли #36836).
Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  final vertical = find.byWidgetPredicate(
      (w) => w is Scrollable && w.axisDirection == AxisDirection.down);
  for (var i = 0; i < 40 && finder.evaluate().isEmpty; i++) {
    if (vertical.evaluate().isEmpty) return;
    await tester.drag(vertical.last, const Offset(0, -350));
    await settle(tester, frames: 3);
  }
}

Future<void> _openList(WidgetTester tester) async {
  final all = find.textContaining('Все (');
  if (all.evaluate().isEmpty) return; // уже в полном списке
  await tester.tap(all.first);
  await until(tester, 'список задач на экране',
      () => find.byType(TaskCard).evaluate().isNotEmpty);
}

Future<void> _openCard(WidgetTester tester, String id) async {
  PulseApp.navigatorKey.currentState!.push(
      MaterialPageRoute(builder: (_) => TaskDetailScreen(taskId: id)));
  await until(tester, 'карточка $id',
      () => find.byType(TaskDetailScreen).evaluate().isNotEmpty);
  await settle(tester, frames: 8);
}

Future<void> _backToRoot(WidgetTester tester) async {
  PulseApp.navigatorKey.currentState!.popUntil((r) => r.isFirst);
  await settle(tester, frames: 8);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('37136: уведомления, «Наблюдаю», «Следить» / «Не следить» офлайн',
      (tester) async {
    final app = await bootApp(tester, login: _login);
    await app.sync.syncAndRefresh();
    await settle(tester);
    await until(tester, 'список задач с сервера',
        () => app.repo.tasks.isNotEmpty, seconds: 120);
    await until(tester, 'главная с показателями',
        () => app.home.layout.blocks.isNotEmpty, seconds: 120);
    debugPrint('E2E_READY задач=${app.repo.tasks.length}');
    expect(app.repo.pendingCount, 0, reason: 'на входе очередь пуста');

    // --- 1. наблюдаемые — своей группой, плитка сходится со списком ---
    for (final id in [_a, _b]) {
      final v = _viewOf(app, id);
      expect(v, isNotNull, reason: 'подписка $id доехала до телефона');
      expect(v!.group, TaskGroup.watched);
      expect(v.watchedOnly, isTrue);
      expect(v.following, isTrue, reason: 'подписка личная — её можно снять');
      expect(v.elsewhere, isFalse, reason: 'гейт наблюдаемую не трогает');
      for (final f in [TaskFilter.open, TaskFilter.today, TaskFilter.overdue]) {
        expect(f.matches(v), isFalse, reason: '${f.title} считает «мои»');
      }
    }
    final cut = _cut(app, 'myOpen');
    final mine = app.repo.tasks
        .where((v) =>
            v.group == TaskGroup.mine &&
            (cut == null || v.task.objectId == cut))
        .length;
    debugPrint('E2E_TILE myOpen=${_tile(app, 'myOpen')} список=$mine');
    expect(_tile(app, 'myOpen'), mine,
        reason: 'плитка «Мои задачи» и группа «Мои» — одно множество');

    final c0 = _viewOf(app, _c);
    expect(c0, isNotNull, reason: 'авторская задача $_c в списке');
    expect(c0!.group, TaskGroup.authored);
    expect(c0.canFollow, isTrue, reason: 'на старте demo.user1 за $_c не следит');

    // группа на экране: список, суженный поиском до объекта A (поиск, а не прокрутка
    // полусотни карточек — см. task_watcher_e2e_test). Заголовок группы рисуется, только
    // когда групп на экране больше одной, — поэтому и проверяется только тогда
    final nameA = _viewOf(app, _a)!.task.name!;
    final objA = _viewOf(app, _a)!.task.object!;
    await _openList(tester);
    await tester.enterText(find.byType(TextField).first, objA);
    await settle(tester, frames: 6);
    final groups = {
      for (final v in app.repo.tasks)
        if (v.task.object == objA) v.group
    };
    debugPrint('E2E_GROUPS $objA: ${groups.map((g) => g.title).join(', ')}');
    if (groups.length > 1) {
      // «Наблюдаю» — внизу списка, а список ленивый: не долистав, заголовка не найти
      await _scrollTo(tester, find.text(TaskGroup.watched.title));
      expect(find.text(TaskGroup.watched.title), findsWidgets,
          reason: 'наблюдаемые — отдельной группой');
    }
    await shot(tester, 'SHOT_list');

    // --- 2. карточка A: чтение и переписка, работы нет ---
    await tester.enterText(find.byType(TextField).first, nameA);
    await settle(tester, frames: 6);
    await tester.tap(find.byType(TaskCard).first);
    await until(tester, 'карточка A',
        () => find.byType(TaskDetailScreen).evaluate().isNotEmpty);
    await settle(tester, frames: 10);
    expect(find.textContaining('Вы наблюдаете за этой задачей'), findsOneWidget);
    expect(find.text('Не следить'), findsOneWidget);
    expect(find.text('Выполнить'), findsNothing);
    expect(find.text('Выполнить с фото'), findsNothing);
    expect(find.text('Взять на себя'), findsNothing);
    expect(find.byType(ChoiceChip), findsNothing, reason: 'статус не переключить');
    await shot(tester, 'SHOT_card');
    await _backToRoot(tester);

    // --- 3. исполнитель пишет в переписку A — у наблюдателя запись с пометкой ---
    await _commentAs(_assignee, _a, 'Э2Э 37136: наблюдателю должно прийти');
    await untilAsync(tester, 'уведомление по A в ленте', () async {
      await app.notifications.refresh();
      return app.notifications.items.any((n) => n.taskId == _a && n.watching);
    }, seconds: 120);
    await tester.tap(find.byTooltip('Уведомления'));
    await until(tester, 'лента',
        () => find.byType(NotificationsScreen).evaluate().isNotEmpty);
    await settle(tester, frames: 10);
    expect(find.text('наблюдаю'), findsWidgets,
        reason: 'пометка «по подписке» на пузыре');
    await shot(tester, 'SHOT_feed');
    final item =
        app.notifications.items.firstWhere((n) => n.taskId == _a && n.watching);
    await tester.tap(find.text(item.title!).first);
    await until(tester, 'тап открыл задачу',
        () => find.byType(TaskDetailScreen).evaluate().isNotEmpty);
    await settle(tester, frames: 10);
    expect(find.textContaining('Задачи нет в вашем списке'), findsNothing);
    await shot(tester, 'SHOT_open');
    await _backToRoot(tester);

    // --- 4. самолётный режим: «Не следить» у B, «Следить» у C — сразу ---
    debugPrint('NET_OFF');
    await untilAsync(tester, 'авиарежим', () async {
      await app.repo.refresh(); // вердикт о сети выносит только поход на сервер
      return !app.repo.online;
    }, seconds: 240);

    await _openCard(tester, _b);
    await tester.tap(find.text('Не следить'));
    await until(tester, 'B ушла из списка сразу',
        () => _viewOf(app, _b) == null);
    await until(tester, 'карточка B закрылась сама',
        () => find.byType(TaskDetailScreen).evaluate().isEmpty);

    await _openCard(tester, _c);
    await tester.tap(find.text('Следить'));
    await until(tester, 'кнопка сменилась офлайн',
        () => find.text('Не следить').evaluate().isNotEmpty);
    final c1 = _viewOf(app, _c)!;
    expect(c1.following, isTrue);
    expect(c1.watchPending, isTrue);
    expect(c1.group, TaskGroup.authored, reason: '«Наблюдаю» — только наблюдаемые');
    await _backToRoot(tester);

    expect(
        app.repo.unsentOps
            .where((o) => o.kind == UnsentKind.watch)
            .map((o) => o.detail)
            .toSet(),
        {'Не следить за задачей', 'Следить за задачей'});
    await _openList(tester);
    await tester.enterText(find.byType(TextField).first, '');
    await settle(tester, frames: 6);
    await shot(tester, 'SHOT_offline');
    await _backToRoot(tester);

    // --- 5. связь вернулась: обе уехали, повтор подписки ничего не задваивает ---
    debugPrint('NET_ON');
    await untilAsync(tester, 'очередь дожата при связи', () async {
      await app.sync.syncAndRefresh();
      return app.repo.online && app.repo.pendingCount == 0;
    }, seconds: 240);
    expect(_viewOf(app, _b), isNull, reason: 'после синхронизации B не вернулась');
    expect((await app.repo.db.tasks.getTasks()).any((t) => t.id == _b), isFalse,
        reason: 'и из кэша ушла');
    expect(_viewOf(app, _c)!.task.following, isTrue,
        reason: 'сервер подтвердил подписку на C');

    // повтор очереди — как ретрай после потерянного ответа: строка снова в очереди
    await app.repo.db.tasks
        .enqueueWatch(_c, 'follow', DateTime.now().toIso8601String());
    await app.sync.syncAndRefresh();
    expect(app.repo.pendingCount, 0);
    expect(_viewOf(app, _c)!.task.following, isTrue);
    debugPrint('E2E_REPLAY_DONE $_c');

    // --- 6. отписался — последующих уведомлений по B нет ---
    await _commentAs(_assignee, _b, 'Э2Э 37136: отписавшемуся не приходит');
    // шанс доехать даём тот же, что уведомлению по A
    for (var i = 0; i < 10; i++) {
      await app.notifications.refresh();
      await tester.pump(const Duration(seconds: 1));
    }
    expect(app.notifications.items.where((n) => n.taskId == _b), isEmpty,
        reason: 'наблюдатель отписался — событие по B его больше не касается');

    // чистоплотность: подписка на C — обратно, как было на старте
    await app.repo.unfollowTask(_c);
    await untilAsync(tester, 'отписка от C уехала', () async {
      await app.sync.syncAndRefresh();
      return app.repo.pendingCount == 0;
    }, seconds: 120);
    debugPrint('ALL_OK_37136');
  });
}
