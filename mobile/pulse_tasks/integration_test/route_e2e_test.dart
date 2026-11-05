import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:pulse_tasks/app_controllers.dart';
import 'package:pulse_tasks/main.dart' as pulse;
import 'package:pulse_tasks/models/route.dart';
import 'package:pulse_tasks/ui/route_screen.dart';
import 'package:pulse_tasks/ui/task_detail_screen.dart';
import 'support/e2e_harness.dart';

const _login = String.fromEnvironment('E2E_LOGIN', defaultValue: 'e2e.route');
const _base =
    String.fromEnvironment('E2E_BASE', defaultValue: 'http://10.0.2.2:7651');

List<String> _ids(AppControllers app) =>
    [for (final s in app.route.plan?.stops ?? const <RouteStop>[]) s.objectId];

RouteStop? _stop(AppControllers app, String id) {
  for (final s in app.route.plan?.stops ?? const <RouteStop>[]) {
    if (s.objectId == id) return s;
  }
  return null;
}

String _taskAt(AppControllers app, String objectId) =>
    _stop(app, objectId)!.tasks.first.id;

Future<void> _refreshUntil(WidgetTester tester, AppControllers app, String what,
    bool Function() done,
    {int seconds = 120}) async {
  await untilAsync(tester, what, () async {
    await app.route.refresh();
    return done();
  }, seconds: seconds);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('37691: маршрут на день с телефона', (tester) async {
    pulse.main();
    await until(tester, 'первый кадр приложения',
        () => find.byType(MaterialApp).evaluate().isNotEmpty,
        seconds: 90);
    final app = Provider.of<AppControllers>(
        tester.element(find.byType(MaterialApp).first),
        listen: false);
    debugPrint('boot: configured=${app.settings.isConfigured} '
        'active=${app.session.isActive} login="${app.session.login}"');
    if (app.settings.baseUrl != _base) {
      if (app.session.isActive) await app.account.signOut();
      await app.account.updateSettings(app.settings.copy()..baseUrl = _base);
      await settle(tester);
    }
    await signIn(tester, app, login: _login, base: _base);
    await passGeoGate(tester, app);
    debugPrint('E2E_AS $_login');

    await untilAsync(tester, 'маршрут без сборки — пусто', () async {
      await app.sync.syncAndRefresh();
      return app.route.supported && app.route.plan == null;
    });
    pulse.PulseApp.navigatorKey.currentState!.popUntil((r) => r.isFirst);
    await settle(tester);
    final entry = find.byKey(const Key('home-route'));
    await until(tester, 'вход «Маршрут на сегодня» на главной',
        () => entry.evaluate().isNotEmpty);
    expect(find.text('Маршрут на сегодня'), findsOneWidget);
    await shot(tester, 'SHOT_home_route');

    await tester.tap(entry);
    await until(tester, 'экран «Мой маршрут»',
        () => find.byType(RouteScreen).evaluate().isNotEmpty);
    expect(find.text('Маршрута на сегодня нет'), findsOneWidget);
    await shot(tester, 'SHOT_route_empty');

    await tester.tap(find.text('Собрать маршрут'));
    await until(tester, 'маршрут собран', () => app.route.plan != null,
        seconds: 90);
    debugPrint('E2E_BUILT ${_ids(app)}');
    expect(_ids(app), ['p18', 'k31', 'b23', 'l44']);
    expect(find.text('Пройдено 0 из 4'), findsOneWidget);
    expect(find.text('Собран'), findsOneWidget);
    await shot(tester, 'SHOT_route_built');

    final handle = find.byKey(const Key('route-drag-b23'));
    final from = tester.getCenter(handle);
    final to = tester.getCenter(find.byKey(const Key('route-drag-p18')));
    final gesture = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 200));
    for (var i = 1; i <= 10; i++) {
      await gesture.moveTo(Offset(from.dx, from.dy + (to.dy - from.dy - 30) * i / 10));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await gesture.up();
    await settle(tester);
    await _refreshUntil(tester, app, 'Брест первым на сервере',
        () => _ids(app).isNotEmpty && _ids(app).first == 'b23');
    debugPrint('E2E_ORDER ${_ids(app)}');
    expect(_ids(app), ['b23', 'p18', 'k31', 'l44']);
    await shot(tester, 'SHOT_route_reordered');

    final kobrin = _taskAt(app, 'k31');
    await tester.tap(find.text('Санта №31, Кобрин'));
    await until(tester, 'задачи остановки',
        () => find.byType(RouteStopScreen).evaluate().isNotEmpty);
    await shot(tester, 'SHOT_route_stop');
    await tester.tap(find.byKey(Key('route-task-$kobrin')));
    await until(tester, 'карточка задачи с остановки',
        () => find.byType(TaskDetailScreen).evaluate().isNotEmpty,
        seconds: 60);
    await shot(tester, 'SHOT_route_task');
    debugPrint('CLOSE_TASK=$kobrin');
    await tester.pageBack();
    await settle(tester);
    await _refreshUntil(tester, app, 'Кобрин пройден после закрытия задачи',
        () => _stop(app, 'k31')?.passed == true);
    await tester.pageBack();
    await settle(tester);
    expect(find.text('Пройдено 1 из 4'), findsOneWidget);
    expect(find.text('В работе'), findsOneWidget);
    await shot(tester, 'SHOT_route_partial');

    debugPrint('NET_OFF_route');
    await untilAsync(tester, 'телефон без связи', () async {
      await app.route.refresh();
      return !app.repo.online;
    }, seconds: 90);
    await settle(tester);
    expect(find.byKey(const Key('route-offline')), findsOneWidget);
    expect(_ids(app), ['b23', 'p18', 'k31', 'l44']);
    final build = tester.widget<FilledButton>(find.descendant(
        of: find.byKey(const Key('route-build')),
        matching: find.byWidgetPredicate((w) => w is FilledButton)));
    expect(build.onPressed, isNull);
    expect(find.byKey(const Key('route-drag-p18')), findsNothing);
    await shot(tester, 'SHOT_route_offline');
    debugPrint('NET_ON_route');
    await untilAsync(tester, 'связь вернулась', () async {
      await app.route.refresh();
      return app.repo.online;
    }, seconds: 120);

    final rest = [
      for (final s in app.route.plan!.stops)
        for (final t in s.tasks)
          if (!t.done) t.id
    ];
    debugPrint('CLOSE_TASK=${rest.join(',')}');
    await _refreshUntil(tester, app, 'маршрут закрыт',
        () => app.route.plan?.closed == true);
    await settle(tester);
    expect(find.text('Пройдено 4 из 4'), findsOneWidget);
    expect(find.text('Закрыт'), findsOneWidget);
    expect(find.text('Дополнить'), findsOneWidget);
    await shot(tester, 'SHOT_route_closed');
    debugPrint('ALL_OK_37691');
  });
}
