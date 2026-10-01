// Сквозная приёмка #37346 на живом сервере — список задач страницами.
//
// Throwaway-драйвер. По-настоящему сценарий проверяет учётка с длинным списком — больше
// страницы (200 задач): на сервере приёмки это 2 000 поручений на одно подразделение.
// С коротким списком он тоже проходит, но страница тогда одна, и это лишь проверка, что
// приложение и сервер со страницами понимают друг друга.
//
// Параметры — dart-define: E2E_BASE (адрес сервера), E2E_LOGIN/E2E_PASS (учётка без
// геопривязки).
//
// Сценарий («Готово когда» тикета):
//  1) синхронизация берёт список страницами: запросы apiTasks идут с limit, каждый
//     следующий — с after, и в кэше оказываются те же задачи, что сервер отдаёт одним
//     ответом без параметров страницы;
//  2) экран списка находит последнюю задачу выдачи — она с последней страницы;
//  3) обрыв связи на последней странице оставляет кэш прежним, следующая синхронизация
//     проходит как обычно.
//
// Маркеры: boot:, E2E_PAGES=<запросов> rows=<строк>, SHOT_list, E2E_BROKEN, ALL_OK_37346.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:pulse_tasks/app_controllers.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/main.dart' as pulse;
import 'package:pulse_tasks/ui/task_list_screen.dart';
import 'support/e2e_harness.dart';

const _login = String.fromEnvironment('E2E_LOGIN', defaultValue: 'zzz.worker');

/// Провод: считает запросы списка и умеет оборвать нужный по счёту.
class _Wire extends http.BaseClient {
  _Wire(this._inner);

  final http.Client _inner;
  final pages = <Map<String, String>>[]; // параметры каждого запроса apiTasks
  int? breakOn; // какой по счёту запрос списка оборвать (с единицы)

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request.url.path.endsWith('StoreTask.apiTasks')) {
      pages.add(request.url.queryParameters);
      if (pages.length == breakOn) {
        throw http.ClientException('E2E: связь оборвана', request.url);
      }
    }
    return _inner.send(request);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('37346: список приходит страницами и совпадает с выдачей целиком',
      (tester) async {
    // клиент для провода создаётся снаружи зоны: внутри неё http.Client() вернул бы
    // сам провод
    final inner = http.Client();
    final wire = _Wire(inner);
    final app = await http.runWithClient(() async {
      pulse.main();
      await until(tester, 'первый кадр приложения',
          () => find.byType(MaterialApp).evaluate().isNotEmpty,
          seconds: 90);
      final ctx = tester.element(find.byType(MaterialApp).first);
      final app = Provider.of<AppControllers>(ctx, listen: false);
      debugPrint('boot: configured=${app.settings.isConfigured} '
          'active=${app.session.isActive} base="${app.settings.baseUrl}"');
      // приложение могло остаться настроенным на другой сервер — сценарий идёт на свой
      if (app.settings.isConfigured && app.settings.baseUrl != e2eBase) {
        if (app.session.isActive) await app.account.signOut();
        await app.account.updateSettings(Settings(baseUrl: e2eBase));
        await settle(tester);
      }
      await signIn(tester, app, login: _login);
      return app;
    }, () => wire);
    expect(app.session.geoRequired, isFalse,
        reason: 'сценарию нужна учётка без геопривязки');
    await until(tester, 'первая синхронизация', () => !app.repo.loading);

    // ===== 1. страницы против выдачи целиком =====
    wire.pages.clear();
    await app.sync.syncAndRefresh();
    expect(app.repo.error, isNull);
    final pages = List.of(wire.pages);
    final cached = {for (final t in await app.repo.db.tasks.getTasks()) t.id};
    debugPrint('E2E_PAGES=${pages.length} rows=${cached.length} '
        'after=${[for (final p in pages) p['after']]}');

    // то же самое одним ответом — как спросило бы приложение без страниц
    final whole = await inner.get(
        Uri.parse('$e2eBase/exec/StoreTask.apiTasks'),
        headers: {'Authorization': 'Bearer ${app.session.token}'});
    expect(whole.statusCode, 200);
    final wholeRows = (json.decode(utf8.decode(whole.bodyBytes)) as List)
        .cast<Map<String, dynamic>>();
    final wholeIds = {for (final r in wholeRows) '${r['id']}'};

    expect(wholeIds, isNotEmpty, reason: 'у учётки нет задач — проверять нечего');
    expect(wholeRows.any((r) => r.containsKey('cursor')), isFalse,
        reason: 'без limit ответ прежний, без cursor');
    expect(pages, hasLength(wholeIds.length ~/ tasksPageSize + 1));
    expect(pages.every((p) => p['limit'] == '$tasksPageSize'), isTrue);
    expect(pages.first.containsKey('after'), isFalse);
    final afters = [for (final p in pages.skip(1)) int.parse(p['after']!)];
    expect([...afters]..sort(), afters, reason: 'курсор только растёт');
    expect(afters.toSet(), hasLength(afters.length));
    expect(cached, wholeIds, reason: 'в кэше те же задачи, что при выдаче целиком');
    expect(app.repo.tasks, hasLength(wholeIds.length));

    // ===== 2. экран списка видит задачу с последней страницы =====
    // выдача упорядочена по курсору, поэтому последняя строка — с последней страницы
    final last = '${wholeRows.last['name']}';
    final allBtn = find.textContaining('Все (');
    await tester
        .tap((allBtn.evaluate().isNotEmpty ? allBtn : find.text('Открыть')).first);
    await until(tester, 'экран списка',
        () => find.byType(TaskListScreen).evaluate().isNotEmpty);
    await tester.enterText(find.byType(TextField).first, last);
    await settle(tester, frames: 4);
    expect(find.text(last), findsWidgets);
    await shot(tester, 'SHOT_list');

    // ===== 3. обрыв на последней странице: кэш прежний =====
    wire.pages.clear();
    wire.breakOn = pages.length;
    await app.repo.refresh();
    debugPrint('E2E_BROKEN requests=${wire.pages.length} error=${app.repo.error}');
    expect(wire.pages, hasLength(pages.length));
    expect(app.repo.error, isNotNull);
    expect({for (final t in await app.repo.db.tasks.getTasks()) t.id}, cached,
        reason: 'пришедшие страницы в кэш не попали');
    expect(app.repo.tasks, hasLength(cached.length));

    wire.breakOn = null;
    wire.pages.clear();
    await app.repo.refresh();
    expect(app.repo.error, isNull);
    expect(wire.pages, hasLength(pages.length));
    expect({for (final t in await app.repo.db.tasks.getTasks()) t.id}, wholeIds);
    debugPrint('ALL_OK_37346');
  });
}
