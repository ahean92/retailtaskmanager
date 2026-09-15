// Сквозная приёмка #37178 на живом стенде — дефект 26 журнала приёмки (сценарий B2.3):
// вход без сети после «Выйти» и возврат сети.
//
// Throwaway-драйвер: авиарежим переключает внешний шелл по маркерам NET_OFF / NET_ON
// (`adb shell cmd connectivity airplane-mode …`); что записал сервер — журнал
// координат, автора комментария, реестр устройств — шелл сверяет после прогона.
//
// Параметры — dart-define: E2E_BASE, E2E_LOGIN (по умолчанию demo.user1), E2E_PASS,
// E2E_TASK (задача вошедшего, к которой пишется комментарий без сети).
//
// Сценарий:
//  1) онлайн-вход; список с сервера — эталон «свои задачи»;
//  2) «Выйти» → авиарежим → вход по локальному хэшу: токена у сессии нет;
//  3) без сети — комментарий к своей задаче, он ложится в очередь;
//  4) сеть вернулась — приложение синхронизируется само: список тот же, что при
//     онлайн-входе, комментарий уехал, у сессии снова токен, и ни один запрос к ручкам
//     StoreTask.api* (кроме apiBrand — она без авторизации) не ушёл без Authorization;
//  5) шестерёнка главной → «Проверить подключение»: на проверяемый адрес уходит один
//     apiBrand, и без токена вошедшего.
//
// Маркеры: boot:, E2E_ONLINE, NET_OFF, E2E_OFFLINE_SIGNED_IN, E2E_COMMENT=<clientId>,
// NET_ON, E2E_NOAUTH <ручка> (на каждый запрос без Authorization), E2E_RESULT,
// E2E_FCM=<токен>, E2E_PROBE, ALL_OK_37178.

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:pulse_tasks/data/comment_controller.dart';
import 'support/e2e_harness.dart';

const _login = String.fromEnvironment('E2E_LOGIN', defaultValue: 'demo.user1');
const _task = String.fromEnvironment('E2E_TASK', defaultValue: 'DEMO36751-2');

/// Провод: через этот клиент идут все запросы, созданные в его зоне. Запрос к ручке без
/// Authorization — ровно то, что приёмка запрещает, а видно это только здесь: стенд в
/// dev-режиме такой запрос не отвергает, а молча исполняет под admin.
class _Wire extends http.BaseClient {
  _Wire(this._inner);

  final http.Client _inner;
  final seen = <http.BaseRequest>[];
  final anonymous = <String>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    seen.add(request);
    final segments = request.url.pathSegments;
    final action = segments.isEmpty ? '' : segments.last;
    if (action.startsWith('StoreTask.api') &&
        action != 'StoreTask.apiBrand' &&
        !request.headers.containsKey('Authorization')) {
      anonymous.add(action);
      debugPrint('E2E_NOAUTH $action');
    }
    return _inner.send(request);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('37178: после входа без сети телефон работает под своей учёткой',
      (tester) async {
    // клиент для провода создаётся снаружи зоны: внутри неё http.Client() вернул бы
    // сам провод
    final wire = _Wire(http.Client());
    final app = await http.runWithClient(
        () => bootApp(tester, login: _login), () => wire);

    // ===== 1. онлайн: эталон списка =====
    await app.sync.syncAndRefresh();
    expect(app.repo.error, isNull);
    final online = {for (final v in app.repo.tasks) v.id};
    expect(online, contains(_task),
        reason: 'задача для комментария должна быть в списке вошедшего');
    debugPrint('E2E_ONLINE n=${online.length}');

    // ===== 2. «Выйти» → без сети → вход по локальному хэшу =====
    await app.account.signOut();
    await settle(tester);
    debugPrint('NET_OFF');
    await until(tester, 'авиарежим', () => !app.repo.online, seconds: 240);
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), _login);
    await tester.enterText(fields.at(1), e2ePass);
    await settle(tester);
    await tester.tap(find.text('Войти'));
    await until(tester, 'вход без сети', () => app.session.isActive,
        seconds: 90);
    expect(app.session.token, isEmpty, reason: 'вход без сети токена не берёт');
    debugPrint('E2E_OFFLINE_SIGNED_IN');

    // ===== 3. без сети — комментарий к своей задаче =====
    final c =
        TaskCommentsController(db: app.repo.db, api: app.api, taskId: _task);
    await c.load();
    await c.send(
        '37178 без сети ${DateTime.now().millisecondsSinceEpoch % 100000}');
    await c.syncAll(); // присоединиться к отправке, упёршейся в «нет сети»
    final pending = c.items.where((x) => x.pending).toList();
    expect(pending, hasLength(1), reason: 'комментарий ждёт сети в очереди');
    debugPrint('E2E_COMMENT=${pending.single.clientId}');
    c.dispose();

    // ===== 4. сеть вернулась =====
    debugPrint('NET_ON');
    await until(tester, 'сеть', () => app.repo.online, seconds: 240);
    // Синхронизацию запускает само приложение (слушатель сети). Ждём мягко, без fail:
    // прогон на коде до исправления должен дойти до итога и показать, что ушло.
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    while (DateTime.now().isBefore(deadline) &&
        (await app.repo.db.comments.getAllCommentOutbox()).isNotEmpty) {
      await tester.pump(const Duration(milliseconds: 500));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    // и обновление руками — тот же вход в сеть, что у человека, потянувшего список
    await app.sync.syncAndRefresh();
    await settle(tester);

    final after = {for (final v in app.repo.tasks) v.id};
    final left = await app.repo.db.comments.getAllCommentOutbox();
    debugPrint('E2E_RESULT anonymous=${wire.anonymous.length} '
        'token=${app.session.token.isNotEmpty} commentLeft=${left.length} '
        'sameList=${after.length == online.length && after.containsAll(online)} '
        'error=${app.repo.error}');
    try {
      debugPrint('E2E_FCM=${await FirebaseMessaging.instance.getToken()}');
    } catch (_) {
      debugPrint('E2E_FCM=');
    }
    // регистрации устройства дать доехать: реестр шелл смотрит после прогона
    await Future<void>.delayed(const Duration(seconds: 8));

    // ===== 5. проверка адреса в настройках =====
    // Клиент проверки создаётся на нажатие — провод для него своя зона вокруг нажатия.
    await tester.tap(find.byTooltip('Настройки'));
    await settle(tester);
    await tester.enterText(find.byType(TextFormField).first, e2eBase);
    final probe = _Wire(http.Client());
    await http.runWithClient(() async {
      await tester.tap(find.text('Проверить подключение'));
      await until(tester, 'итог проверки адреса',
          () => find.textContaining('Сервер отвечает').evaluate().isNotEmpty,
          seconds: 30);
    }, () => probe);
    debugPrint('E2E_PROBE ${[
      for (final r in probe.seen)
        '${r.url.path} auth=${r.headers.containsKey('Authorization')}'
    ]}');
    await tester.pageBack();
    await settle(tester);

    expect(wire.anonymous, isEmpty,
        reason: 'запросы к ручкам без Authorization: ${wire.anonymous}');
    expect(app.session.token, isNotEmpty,
        reason: 'личность подтверждена новым токеном');
    expect(left, isEmpty, reason: 'комментарий, написанный без сети, уехал');
    expect(app.repo.error, isNull);
    expect(after, online, reason: 'список тот же, что при онлайн-входе');
    expect([for (final r in probe.seen) r.url.path],
        ['/exec/StoreTask.apiBrand'],
        reason: 'проверка адреса спросила только бренд');
    expect(probe.seen.single.headers.containsKey('Authorization'), isFalse,
        reason: 'токен вошедшего на проверяемый адрес не уехал');
    debugPrint('ALL_OK_37178');
  });
}
