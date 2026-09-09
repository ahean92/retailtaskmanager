// Сквозная приёмка #37125 на живом стенде: лента уведомлений — пузыри, заголовки по
// датам, миниатюра фото из комментария и переход в переписку.
//
// Throwaway-драйвер: снимки экрана делает внешний шелл по маркерам в логе.
// Параметры — dart-define: E2E_BASE (адрес стенда), E2E_LOGIN (учётка без
// геопривязки), E2E_TASK (ST-номер задачи, по которой пришло уведомление о
// комментарии с фотографией), E2E_BODY (кусок текста этого уведомления).
//
// Сценарий приёмки («Готово когда»):
//  1) лента разложена по датам — заголовки «Сегодня» и дальше, и считаются они от
//     серверного today (единица разбивки проверена юнит-тестом notification_feed_test);
//  2) непрочитанное видно самим пузырём — заливкой, а не точкой справа, и переживает
//     выход из ленты: прочтение ставит ТАП, а не открытие списка;
//  3) уведомление о комментарии с фотографией несёт миниатюру;
//  4) тап открывает задачу и переписку, а сама запись становится прочитанной;
//  5) «Отметить все прочитанными» гасит остаток.
//
// Маркеры: E2E_READY, SHOT_FEED, SHOT_TASK, ALL_OK_37125.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pulse_tasks/ui/notifications_screen.dart';
import 'package:pulse_tasks/ui/task_detail_screen.dart';
import 'package:pulse_tasks/ui/theme.dart';
import 'package:pulse_tasks/ui/widgets/task_comments.dart';
import 'package:pulse_tasks/ui/widgets/task_photo.dart';
import 'support/e2e_harness.dart';

const _login = String.fromEnvironment('E2E_LOGIN', defaultValue: 'demo.user1');
const _body = String.fromEnvironment('E2E_BODY', defaultValue: 'Фотография');

/// Заливка пузыря непрочитанного — тот же токен, что рисует экран.
int _unreadBubbles(WidgetTester tester) {
  var n = 0;
  for (final e in find.byType(Container).evaluate()) {
    final d = (e.widget as Container).decoration;
    if (d is BoxDecoration && d.color == Wms.active && d.borderRadius != null) {
      n++;
    }
  }
  return n;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('#37125: пузыри, даты, миниатюра, переход в переписку',
      (tester) async {
    final app = await bootApp(tester, login: _login);
    await until(tester, 'задачи с сервера', () => app.repo.tasks.isNotEmpty,
        seconds: 120);
    await until(tester, 'лента уведомлений',
        () => app.notifications.items.isNotEmpty, seconds: 120);
    debugPrint('E2E_READY items=${app.notifications.items.length}');

    // --- 1. открыть ленту с главной ---
    await tester.tap(find.byTooltip('Уведомления'));
    await settle(tester, frames: 20);
    expect(find.byType(NotificationsScreen), findsOneWidget);

    // --- 2. заголовки по датам ---
    // Собираются пролистыванием: лента ленивая (ListView.builder), и заголовок за
    // нижним краем экрана не построен вовсе. Сама разбивка — юнит-тестом
    // (notification_feed_test), здесь важно, что человек эти заголовки видит.
    final list = find.byType(Scrollable).first;
    final headers = <String>{};
    for (var page = 0; page < 10; page++) {
      for (final t in const [
        'Сегодня',
        'Вчера',
        'На этой неделе',
        'На прошлой неделе',
        'Ранее'
      ]) {
        if (find.text(t).evaluate().isNotEmpty) headers.add(t);
      }
      if (headers.length > 1) break;
      await tester.drag(list, const Offset(0, -500));
      await settle(tester, frames: 6);
    }
    debugPrint('E2E_HEADERS $headers');
    expect(headers, contains('Сегодня'),
        reason: 'сегодняшние уведомления должны стоять под своим заголовком');
    expect(headers.length, greaterThan(1),
        reason: 'журнал за 30 дней обязан развалиться больше чем на одну секцию');
    // назад к началу — там свежие записи, и по ним же снимок
    tester.state<ScrollableState>(list).position.jumpTo(0);
    await settle(tester, frames: 6);

    // --- 3. непрочитанное — заливкой пузыря ---
    final unreadAtEntry = app.notifications.unreadCount;
    debugPrint('E2E_UNREAD $unreadAtEntry');
    expect(unreadAtEntry, greaterThan(0),
        reason: 'сценарию нужна непрочитанная запись — шелл шлёт её перед прогоном');
    expect(_unreadBubbles(tester), greaterThan(0),
        reason: 'непрочитанное видно самим пузырём, а не точкой справа');

    // --- 3a. вышел, вернулся — по-прежнему непрочитано (#37125) ---
    await tester.pageBack();
    await settle(tester, frames: 12);
    await tester.tap(find.byTooltip('Уведомления'));
    await settle(tester, frames: 20);
    expect(app.notifications.unreadCount, unreadAtEntry,
        reason: 'открытие ленты — не прочтение: пометку ставит тап');
    expect(_unreadBubbles(tester), greaterThan(0),
        reason: 'заливка обязана пережить выход из ленты');

    // --- 4. миниатюра приехавшего фото ---
    expect(find.byType(TaskPhotoThumb), findsWidgets,
        reason: 'уведомление о комментарии с фотографией несёт миниатюру');
    await until(
        tester,
        'миниатюра скачалась',
        () => find
            .descendant(
                of: find.byType(TaskPhotoThumb), matching: find.byType(Image))
            .evaluate()
            .isNotEmpty,
        seconds: 90);
    await shot(tester, 'SHOT_FEED');

    // --- 5. тап открывает задачу и переписку ---
    final bubble = find.textContaining(_body);
    expect(bubble, findsWidgets, reason: 'уведомление о фото без подписи в ленте');
    await tester.tap(bubble.first);
    await settle(tester, frames: 25);
    expect(find.byType(TaskDetailScreen), findsOneWidget);
    expect(find.byType(TaskCommentsSection), findsOneWidget);
    final top = tester.getTopLeft(find.byType(TaskCommentsSection)).dy;
    final height = tester.view.physicalSize.height / tester.view.devicePixelRatio;
    final pos = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    debugPrint('E2E_COMMENTS top=$top height=$height '
        'scrolled=${pos.pixels} max=${pos.maxScrollExtent}');
    expect(top, greaterThanOrEqualTo(0.0));
    expect(top, lessThan(height),
        reason: 'переписка должна быть на экране, а не за его нижним краем');
    // Короткая карточка помещается целиком, и крутить нечего; длинную showComments
    // обязан открыть прямо на переписке.
    if (pos.maxScrollExtent > height * 0.5) {
      expect(top, lessThan(height * 0.5),
          reason: 'длинная карточка открывается на переписке, а не на шапке');
    }
    await shot(tester, 'SHOT_TASK');

    // --- 6. тап и есть прочтение: вернулись — запись погасла ---
    await tester.pageBack();
    await settle(tester, frames: 15);
    expect(app.notifications.unreadCount, unreadAtEntry - 1,
        reason: 'прочитанной стала ровно одна запись — та, по которой тапнули');
    expect(_unreadBubbles(tester), lessThan(unreadAtEntry),
        reason: 'её заливка ушла');

    // --- 7. «Отметить все прочитанными» гасит остаток ---
    if (unreadAtEntry > 1) {
      await tester.tap(find.byTooltip('Отметить все прочитанными'));
      await until(tester, 'пометка всех',
          () => app.notifications.unreadCount == 0, seconds: 60);
    }
    expect(_unreadBubbles(tester), 0, reason: 'залитых пузырей не осталось');
    expect(find.byTooltip('Отметить все прочитанными'), findsNothing,
        reason: 'гасить больше нечего — кнопке в шапке делать нечего');

    debugPrint('ALL_OK_37125');
  });
}
