import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:pulse_tasks/app_controllers.dart';
import 'package:pulse_tasks/ui/task_list_screen.dart';
import 'package:pulse_tasks/ui/widgets/task_card.dart';
import 'support/e2e_harness.dart';

const _login = String.fromEnvironment('E2E_LOGIN', defaultValue: 'lead_exec');
const _shop = String.fromEnvironment('E2E_OBJECT', defaultValue: 'ZZZ51-S1');
const _here = String.fromEnvironment('E2E_HERE', defaultValue: 'ZZZ51-S2');
const _inShop = ['ZZZ51-T1', 'ZZZ51-T2', 'ZZZ51-T3'];
const _exact = ['ZZZ51-T1'];
const _otherShop = 'ZZZ51-T4';

class _Wire extends http.BaseClient {
  _Wire(this._inner);

  final http.Client _inner;
  final calls = <Map<String, String>>[];
  bool breakSlice = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request.url.path.endsWith('StoreTask.apiTasks')) {
      final q = request.url.queryParameters;
      calls.add(q);
      if (breakSlice && q['scope'] == 'object') {
        throw http.ClientException('E2E: срез оборван', request.url);
      }
    }
    return _inner.send(request);
  }
}

Future<List<String>> _openShop(
    WidgetTester tester, AppControllers app, _Wire wire) async {
  wire.calls.clear();
  final screens = find.byType(TaskListScreen, skipOffstage: false);
  final before = screens.evaluate().length;
  final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
  nav.push(MaterialPageRoute(
      builder: (_) => const TaskListScreen(objectId: _shop)));
  await until(tester, 'экран задач объекта',
      () => screens.evaluate().length > before);
  await until(tester, 'запрос среза',
      () => wire.calls.any((q) => q['scope'] == 'object'));
  await settle(tester, frames: 20);
  final mine = find.byWidgetPredicate(
      (w) => w is TaskListScreen && w.objectId == _shop,
      skipOffstage: false);
  final cards = tester
      .widgetList<TaskCard>(find.descendant(
          of: mine, matching: find.byType(TaskCard), skipOffstage: false))
      .toList();
  for (final c in cards) {
    debugPrint('E2E_ROW ${c.view.id} object=${c.view.task.objectId} '
        'elsewhere=${c.view.elsewhere}');
    expect(c.view.elsewhere, isTrue,
        reason: 'задача ${c.view.id} не на текущем объекте — только просмотр');
  }
  return [for (final c in cards) c.view.id]..sort();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('37851: задачи объекта с объекта и вложенных, где бы ни стоял',
      (tester) async {
    final inner = http.Client();
    final wire = _Wire(inner);
    final app = await http.runWithClient(
        () => bootApp(tester, login: _login, pass: e2ePass), () => wire);
    expect(app.session.geoRequired, isTrue,
        reason: 'сценарию нужна учётка с обязательной геолокацией');
    final deadline = DateTime.now().add(const Duration(seconds: 240));
    while (app.location.place.objectId != _here) {
      if (DateTime.now().isAfter(deadline)) {
        fail('не доехали до $_here: место=${app.location.place.objectId}');
      }
      await app.location.locate(fresh: true);
      await tester.pump(const Duration(milliseconds: 400));
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    await settle(tester);
    await until(tester, 'первая синхронизация', () => !app.repo.loading);
    await app.sync.syncAndRefresh();
    expect(app.repo.error, isNull);

    final main = wire.calls.where((q) => q['scope'] == null).toList();
    expect(main, isNotEmpty);
    expect(main.every((q) => !q.containsKey('scope')), isTrue,
        reason: 'основная синхронизация scope не шлёт');
    final mainBefore = [for (final v in app.repo.tasks) v.id];
    final cacheBefore = {
      for (final t in await app.repo.db.tasks.getTasks()) t.id
    };
    debugPrint('E2E_MAIN rows=${mainBefore.length} place=${app.location.place.objectId}');
    for (final id in [..._inShop, _otherShop]) {
      expect(mainBefore, contains(id));
    }

    final shown = await _openShop(tester, app, wire);
    debugPrint('E2E_SLICE ${shown.join(',')}');
    final slice = wire.calls.firstWhere((q) => q['scope'] == 'object');
    expect(slice['objectId'], _shop);
    expect(slice['limit'], isNotNull);
    expect(shown, _inShop, reason: 'магазин, касса в нём и сканер в кассе');
    expect(find.textContaining('только просмотр'), findsWidgets);
    await shot(tester, 'SHOT_object_slice');

    expect([for (final v in app.repo.tasks) v.id], mainBefore,
        reason: 'основной список «Мои» срез не трогает');
    expect({for (final t in await app.repo.db.tasks.getTasks()) t.id},
        cacheBefore,
        reason: 'кэш основного списка срезом не заменяется');

    Navigator.of(tester.element(find.byWidgetPredicate(
            (w) => w is TaskListScreen && w.objectId == _shop))).pop();
    await settle(tester);

    wire.breakSlice = true;
    final offline = await _openShop(tester, app, wire);
    debugPrint('E2E_FALLBACK ${offline.join(',')}');
    expect(offline, _exact, reason: 'без среза — прежний локальный отбор');
    Navigator.of(tester.element(find.byWidgetPredicate(
            (w) => w is TaskListScreen && w.objectId == _shop))).pop();
    await settle(tester);
    wire.breakSlice = false;

    debugPrint('ALL_OK_37851');
  });
}
