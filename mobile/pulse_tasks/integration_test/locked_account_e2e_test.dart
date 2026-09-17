// Сквозная приёмка #37179 на живом стенде — журнал приёмки 10.09, вопрос 9 (сценарий
// B2.4): заблокированная учётная запись обрывает доступ с телефона сразу, а не через
// сутки, когда истечёт выданный до блокировки токен.
//
// Throwaway-драйвер: учётку блокирует и разблокирует сам тест — через /eval/action
// под admin (E2E_ADMIN / E2E_ADMIN_PASS; на демо-стенде admin без пароля), и на любом
// исходе разблокирует в finally. Авиарежим переключает внешний шелл по маркерам
// NET_OFF / NET_ON (`adb shell cmd connectivity airplane-mode …`).
//
// Параметры — dart-define: E2E_BASE, E2E_LOGIN (по умолчанию demo.user1 — без
// геопривязки), E2E_PASS, E2E_ADMIN, E2E_ADMIN_PASS.
//
// Сценарий:
//  1) онлайн-вход; список с сервера; у сессии токен, выданный ДО блокировки;
//  2) блокировка на сервере (тест ждёт, пока сервер откажет учётке — в токене или в
//     профиле под новым токеном, см. _lockedOnServer);
//     обновление руками — тот же вход в сеть, что у человека, потянувшего список —
//     возвращает к форме входа: ни одна ручка не ответила 200 под закрытой учёткой,
//     токена у сессии нет;
//  3) разблокировка → онлайн-вход → «Выйти» → блокировка → авиарежим → вход по
//     локальному хэшу проходит (сервера спросить некого) — вместе с #37178;
//  4) сеть вернулась — приложение синхронизируется само и выходит на форму входа, и
//     снова ни одной ручки с ответом 200;
//  5) разблокировка.
//
// Маркеры: boot:, E2E_ONLINE, E2E_LOCKED, E2E_KICKED, E2E_RELOGIN, NET_OFF,
// E2E_OFFLINE_SIGNED_IN, NET_ON, E2E_KICKED_OFFLINE, ALL_OK_37179.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:pulse_tasks/app_controllers.dart';
import 'support/e2e_harness.dart';

const _login = String.fromEnvironment('E2E_LOGIN', defaultValue: 'demo.user1');
const _admin = String.fromEnvironment('E2E_ADMIN', defaultValue: 'admin');
const _adminPass = String.fromEnvironment('E2E_ADMIN_PASS', defaultValue: '');

/// Один обмен с сервером глазами провода: когда ушёл, когда и чем ответили.
class _Seen {
  _Seen(this.action, this.status, this.sentAt, this.gotAt);

  final String action;
  final int status;
  final DateTime sentAt;
  final DateTime gotAt;

  @override
  String toString() => '$action=$status';
}

/// Провод: через этот клиент идут все запросы приложения, созданные в его зоне.
/// Пока взведён, записывает ручки и выдачу токена с моментами отправки и ответа.
/// Телефон выбивает не обязательно жест человека: докачка ленты, снимков, каталога и
/// таймер уведомлений ходят к серверу сами, и первым в 401 упирается кто-то из них —
/// поэтому провод взводится ДО блокировки, а разбор ведётся от первого отказа.
class _Wire extends http.BaseClient {
  _Wire(this._inner);

  final http.Client _inner;
  bool armed = false;
  final seen = <_Seen>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final counted = armed; // по моменту отправки, не ответа
    final sentAt = DateTime.now();
    final resp = await _inner.send(request);
    final segments = request.url.pathSegments;
    final action = segments.isEmpty ? '' : segments.last;
    if (counted &&
        action != 'StoreTask.apiBrand' &&
        (action.startsWith('StoreTask.api') ||
            action == 'Authentication.getAuthToken')) {
      seen.add(_Seen(action, resp.statusCode, sentAt, DateTime.now()));
    }
    return resp;
  }
}

String _basic(String login, String pass) =>
    'Basic ${base64Encode(utf8.encode('$login:$pass'))}';

/// Заблокировать / разблокировать учётку сценария на сервере — так же, как это делает
/// администратор галкой «Заблокирован» в карточке пользователя, только через eval.
Future<void> _setLocked(http.Client admin, bool locked) async {
  final script = "Authentication.isLocked(Authentication.CustomUser u) <- "
      "${locked ? 'TRUE' : 'NULL'} WHERE Authentication.login(u) = '$_login';\n"
      'APPLY;\n'
      'EXPORT FROM canceled = System.canceled(), msg = System.applyMessage();\n';
  final r = await admin
      .post(Uri.parse('$e2eBase/eval/action'),
          headers: {
            'Authorization': _basic(_admin, _adminPass),
            'Content-Type': 'text/plain; charset=utf-8',
          },
          body: utf8.encode(script))
      .timeout(const Duration(seconds: 30));
  final body = utf8.decode(r.bodyBytes, allowMalformed: true);
  expect(r.statusCode, 200, reason: 'eval блокировки: $body');
  expect(body.contains('canceled'), isFalse, reason: 'APPLY отменён: $body');
}

/// Видит ли сервер учётку заблокированной — глазами телефона: токен по паролю, им —
/// профиль. Платформа стенда выдаёт токен и заблокированной (isLocked при выдаче не
/// смотрит), отказывает уже гвард apiCurrentUser; платформа поновее отказала бы в самом
/// токене (LockedException, 401). Клиент выдерживает оба варианта — здесь так же.
Future<bool> _lockedOnServer(http.Client probe) async {
  final t = await probe.get(
      Uri.parse('$e2eBase/exec/Authentication.getAuthToken'),
      headers: {
        'Accept': 'text/plain',
        'Authorization': _basic(_login, e2ePass),
      }).timeout(const Duration(seconds: 20));
  if (t.statusCode == 401) return true;
  expect(t.statusCode, 200, reason: 'выдача токена: ${t.body}');
  final r = await probe.get(
      Uri.parse('$e2eBase/exec/StoreTask.apiCurrentUser'),
      headers: {
        'Accept': 'application/json',
        'Authorization': 'Bearer ${t.body.trim()}',
      }).timeout(const Duration(seconds: 20));
  return r.statusCode == 401;
}

/// Блокировку выдача токена видит за секунды, а её снятие — с задержкой в минуты,
/// пока идут попытки входа (снято на стенде 2026-09-16; ручки при этом видят флаг
/// сразу). Повторный APPLY задержку снимает, поэтому разблокировка подталкивается
/// повторным eval, а не ждётся вслепую.
Future<void> _lock(WidgetTester tester, http.Client admin, bool locked) async {
  for (var attempt = 1;; attempt++) {
    await _setLocked(admin, locked);
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      if (await _lockedOnServer(admin) == locked) return;
      await tester.pump(const Duration(milliseconds: 500));
      await Future<void>.delayed(const Duration(milliseconds: 1500));
    }
    if (attempt == 6) {
      fail(locked
          ? 'сервер так и не отказал заблокированной учётке'
          : 'сервер так и не принял разблокированную учётку');
    }
    debugPrint('E2E_LOCK_RETRY locked=$locked attempt=$attempt');
  }
}

/// Отказ, которым телефон узнал о блокировке: платформа не выдала токен либо профиль
/// под новым токеном ответил 401. С момента первого отказа сервер видит блокировку
/// (гварды читают флаг на каждом запросе), и ни один запрос, ОТПРАВЛЕННЫЙ после него,
/// не вправе получить 200; запросы, ушедшие раньше, свои 200 довезти могут.
void _expectKicked(List<_Seen> seen, String what) {
  final refusals = seen.where((s) => s.status == 401).toList();
  expect(refusals, isNotEmpty, reason: 'сервер ни разу не отказал ($what): $seen');
  final first = refusals.map((s) => s.gotAt).reduce((a, b) => a.isBefore(b) ? a : b);
  final late200 = seen.where((s) =>
      s.status == 200 &&
      s.action.startsWith('StoreTask.api') &&
      s.sentAt.isAfter(first));
  expect(late200, isEmpty,
      reason: 'после первого отказа ручка ответила 200 ($what): $late200');
  expect(
      seen.any((s) =>
          s.status == 401 &&
          (s.action == 'Authentication.getAuthToken' ||
              s.action == 'StoreTask.apiCurrentUser')),
      isTrue,
      reason: 'отказ в токене или в профиле ($what): $seen');
}

/// Синхронизация руками — как pull-to-refresh у человека; потеря сессии по дороге
/// здесь не ошибка теста, а ожидаемый исход.
Future<void> _refresh(AppControllers app) async {
  try {
    await app.sync.syncAndRefresh();
  } catch (_) {
    // сессия могла умереть посреди синхронизации — это и проверяется
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('37179: блокировка учётной записи обрывает доступ с телефона сразу',
      (tester) async {
    // клиенты сценария создаются снаружи зоны провода: внутри неё http.Client() вернул
    // бы сам провод
    final wire = _Wire(http.Client());
    final admin = http.Client();
    final app = await http.runWithClient(
        () => bootApp(tester, login: _login), () => wire);

    try {
      // ===== 1. онлайн: список и токен, выданный до блокировки =====
      await app.sync.syncAndRefresh();
      expect(app.repo.error, isNull);
      expect(app.session.token, isNotEmpty);
      final online = {for (final v in app.repo.tasks) v.id};
      debugPrint('E2E_ONLINE n=${online.length}');

      // ===== 2. блокировка → следующий запрос → форма входа =====
      wire.armed = true;
      await _lock(tester, admin, true);
      debugPrint('E2E_LOCKED');
      // обновление руками; если фоновый запрос упёрся в отказ раньше, сессии уже нет
      // и отправлять нечего — это и есть «при следующем запросе к серверу»
      await _refresh(app);
      await until(tester, 'форма входа после блокировки',
          () => !app.session.isActive,
          seconds: 60);
      final kicked = List<_Seen>.from(wire.seen);
      wire.armed = false;
      debugPrint('E2E_KICKED error="${app.repo.error}" seen=$kicked');
      expect(find.text('Войти'), findsOneWidget,
          reason: 'на экране форма входа');
      expect(app.session.token, isEmpty,
          reason: 'токен, выданный до блокировки, стёрт вместе с сессией');
      _expectKicked(kicked, 'онлайн');

      // ===== 3. разблокировка → вход → «Выйти» → блокировка → без сети → вход =====
      await _lock(tester, admin, false);
      await signIn(tester, app, login: _login);
      await app.sync.syncAndRefresh();
      expect(app.repo.error, isNull);
      debugPrint('E2E_RELOGIN n=${app.repo.tasks.length}');

      await app.account.signOut();
      await settle(tester);
      await _lock(tester, admin, true);
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

      // ===== 4. сеть вернулась — приложение синхронизируется само =====
      wire.seen.clear();
      wire.armed = true;
      debugPrint('NET_ON');
      await until(tester, 'сеть', () => app.repo.online, seconds: 240);
      await until(tester, 'форма входа после возврата сети',
          () => !app.session.isActive,
          seconds: 120);
      final kickedOffline = List<_Seen>.from(wire.seen);
      wire.armed = false;
      debugPrint('E2E_KICKED_OFFLINE error="${app.repo.error}" '
          'seen=$kickedOffline');
      expect(find.text('Войти'), findsOneWidget,
          reason: 'на экране форма входа');
      _expectKicked(kickedOffline, 'после входа без сети');
      debugPrint('ALL_OK_37179');
    } finally {
      // ===== 5. учётка стенда остаётся рабочей на любом исходе =====
      try {
        await _setLocked(admin, false);
      } catch (e) {
        debugPrint('E2E_UNLOCK_FAILED $e');
      }
      admin.close();
    }
  });
}
