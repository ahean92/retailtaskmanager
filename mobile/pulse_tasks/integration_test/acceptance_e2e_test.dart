// Сквозная приёмка #37158 на живом стенде (192.168.42.28:8888): исполнитель и
// принимающий — на одном телефоне, по очереди.
// Throwaway-драйвер: сеть, разрешения и геоточку делает внешний шелл по маркерам в логе;
// он же сеет задачу «ZZZ 37158 выкладка у кассы» (поручение с приёмкой на SOS-103,
// исполнитель sosedi.tech2, автор-принимающий — отдел URU: demo.user1 + sosedi.tech1) и
// устраивает конфликт — возвращает задачу за sosedi.tech1 прямо по API стенда. Номер у
// задачи свой на каждый прогон: кэши телефона ключуются номером, и задача прошлого
// прогона под тем же номером выдавала бы свои снимки за чужие.
//
// Условия готовности тикета по порядку:
//  1) исполнитель сдаёт с фото — задача уходит «На приёмке», из «Моих» и из плитки;
//  2) принимающий получает уведомление, находит задачу в «Ждут моей приёмки», видит
//     результат с фото и в самолётном режиме возвращает с причиной — со связью возврат
//     доезжает;
//  3) исполнитель получает возврат с причиной, задача снова у него; перевыполняет с
//     новым фото — выполнений два, прежнее на месте;
//  4) принимающий принимает без связи, а коллега по подразделению успевает вернуть:
//     телефон показывает, кто успел раньше.
//
// Маркеры для шелла: NET_OFF_* / NET_ON_* — авиарежим; CONFLICT=<id> — вернуть <id> за
// tech1 и включить сеть; SHOT_* — снимок экрана; ALL_OK_37158 — приёмка пройдена.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pulse_tasks/app_controllers.dart';
import 'package:pulse_tasks/data/simple_controller.dart';
import 'package:pulse_tasks/data/unsent.dart';
import 'package:pulse_tasks/main.dart' as pulse;
import 'package:pulse_tasks/models/task_view.dart';
import 'package:pulse_tasks/ui/simple_execution_screen.dart';
import 'package:pulse_tasks/ui/task_detail_screen.dart';
import 'package:pulse_tasks/ui/task_list_screen.dart';
import 'package:pulse_tasks/ui/task_result_screen.dart';
import 'package:pulse_tasks/ui/widgets/task_photo.dart';
import 'support/e2e_harness.dart';

const _taskName = 'ZZZ 37158 выкладка у кассы';
const _executor = 'sosedi.tech2';
const _reviewer = 'demo.user1';
const _reason = 'Ценник не виден — переснять ближе (E2E 37158)';

/// Номер задачи прогона — находится по названию в фазе 1.
String _task = '';

TaskView? _viewOf(AppControllers app) => app.repo.viewOf(_task);

double? _tile(AppControllers app, String code) {
  for (final b in app.home.layout.blocks) {
    for (final m in b.metrics) {
      if (m.code == code) return m.value;
    }
  }
  return null;
}

/// Снимок «с места» — 64×64 PNG, собранный на устройстве без ассетов и камеры (камера
/// эмулятора не снимает): приёмке важен факт снимка и его дорога, а не кадр.
Future<String> _makePhoto(String name, int tint) async {
  const w = 64, h = 64;
  final raw = BytesBuilder();
  for (var y = 0; y < h; y++) {
    raw.addByte(0);
    for (var x = 0; x < w; x++) {
      raw.add([x * 4, tint, y * 4]);
    }
  }
  final idat = ZLibCodec(level: 6).encode(raw.toBytes());
  Uint8List chunk(String type, List<int> data) {
    final b = BytesBuilder();
    b.add(_be32(data.length));
    final td = [...type.codeUnits, ...data];
    b.add(td);
    b.add(_be32(_crc32(td)));
    return b.toBytes();
  }

  final png = BytesBuilder()
    ..add([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    ..add(chunk('IHDR', [..._be32(w), ..._be32(h), 8, 2, 0, 0, 0]))
    ..add(chunk('IDAT', idat))
    ..add(chunk('IEND', []));
  final dir = await getTemporaryDirectory();
  final f = File('${dir.path}/$name.png');
  await f.writeAsBytes(png.toBytes());
  return f.path;
}

List<int> _be32(int v) =>
    [(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff];

int _crc32(List<int> data) {
  var crc = 0xFFFFFFFF;
  for (final b in data) {
    crc ^= b;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

Finder _verticalList() => find.byWidgetPredicate(
    (w) => w is Scrollable && w.axisDirection == AxisDirection.down);

Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 30 && finder.evaluate().isEmpty; i++) {
    await tester.drag(_verticalList().first, const Offset(0, -300));
    await settle(tester, frames: 3);
  }
  expect(finder, findsWidgets);
  await tester.ensureVisible(finder.first);
  await settle(tester, frames: 3);
}

NavigatorState get _nav => pulse.PulseApp.navigatorKey.currentState!;

Future<void> _toRoot(WidgetTester tester) async {
  _nav.popUntil((r) => r.isFirst);
  await settle(tester);
}

/// Сменить учётку: закрыть всё поверх главной, выйти и войти под [login].
Future<void> _switchTo(
    WidgetTester tester, AppControllers app, String login) async {
  await _toRoot(tester);
  await signIn(tester, app, login: login);
  await passGeoGate(tester, app);
  debugPrint('E2E_AS $login');
}

/// Обновлять, пока [done] не станет правдой: список, главная и лента приходят одним
/// циклом синхронизации.
Future<void> _syncUntil(WidgetTester tester, AppControllers app, String what,
    bool Function() done,
    {int seconds = 180}) async {
  await untilAsync(tester, what, () async {
    await app.sync.syncAndRefresh();
    return done();
  }, seconds: seconds);
}

/// Открыть экран выполнения задачи с карточки — настоящей кнопкой.
Future<void> _openExecution(WidgetTester tester) async {
  _nav.push(
      MaterialPageRoute(builder: (_) => TaskDetailScreen(taskId: _task)));
  await until(tester, 'карточка задачи',
      () => find.byType(TaskDetailScreen).evaluate().isNotEmpty);
  final run = find.textContaining('Выполнить');
  await _scrollTo(tester, run);
  await tester.tap(run.first);
  await until(tester, 'экран выполнения',
      () => find.byType(SimpleExecutionScreen).evaluate().isNotEmpty,
      seconds: 90);
  await settle(tester, frames: 20);
}

/// Снять кадр отчёта (контроллером — камеру на эмуляторе не нажать; очередь у него и у
/// экрана одна) и переоткрыть экран, чтобы тот его увидел; сдать настоящей кнопкой.
Future<void> _shootAndSubmit(WidgetTester tester, AppControllers app,
    {required String photo, required int tint, required String comment}) async {
  final c = SimpleExecutionController(
      db: app.repo.db, api: app.api, taskId: _task);
  await c.addPhoto(await _makePhoto(photo, tint));
  await c.syncAll();
  c.dispose();
  await tester.pageBack(); // на карточку
  await settle(tester);
  await tester.pageBack(); // на главную
  await settle(tester);
  await _openExecution(tester);
  await tester.enterText(find.byType(TextField).first, comment);
  await settle(tester);
  FocusManager.instance.primaryFocus?.unfocus();
  final submit = find.widgetWithText(FilledButton, 'Сдать на приёмку');
  await until(tester, 'кнопка «Сдать на приёмку» (с приёмкой — не «Выполнено»)',
      () => submit.evaluate().isNotEmpty,
      seconds: 60);
  await shot(tester, 'SHOT_EXEC_BEFORE_SUBMIT');
  await tester.tap(submit.first);
  await settle(tester);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('37158: сдача, возврат с причиной и приёмка с телефона',
      (tester) async {
    final stamp = DateTime.now().millisecondsSinceEpoch;

    // ===== 1. исполнитель сдаёт: «На приёмке», из «Моих» и из плитки =====
    final app = await bootApp(tester, login: _executor);
    debugPrint('E2E_AS $_executor');
    await _syncUntil(tester, app, 'поручение в «Моих» с приёмкой', () {
      for (final v in app.repo.tasks) {
        if (v.task.name == _taskName) _task = v.id;
      }
      return _viewOf(app)?.group == TaskGroup.mine &&
          _viewOf(app)!.task.needsAcceptance == true;
    });
    debugPrint('E2E_TASK $_task');
    final openBefore = _tile(app, 'myOpen');

    await _openExecution(tester);
    await until(tester, 'чистый отчёт: снимков ещё нет',
        () => find.text('Нужно фото выполненной работы').evaluate().isNotEmpty,
        seconds: 90);
    await _shootAndSubmit(tester, app,
        photo: 'e2e37158a', tint: 60, comment: 'Выложил у кассы (E2E $stamp)');
    await _syncUntil(tester, app, 'сервер: задача «На приёмке»',
        () => _viewOf(app)?.task.onAcceptance == true);
    var v = _viewOf(app)!;
    expect(v.group, TaskGroup.submitted, reason: 'сданная — не в «Моих»');
    expect(TaskFilter.open.matches(v), isFalse);
    expect(v.readOnly, isTrue);
    final openAfter = _tile(app, 'myOpen');
    debugPrint('E2E_TILE myOpen $openBefore -> $openAfter');
    if (openBefore != null && openAfter != null) {
      expect(openAfter, openBefore - 1, reason: 'плитка «Открытых» её не считает');
    }
    await _toRoot(tester);
    _nav.push(MaterialPageRoute(builder: (_) => const TaskListScreen()));
    await settle(tester, frames: 20);
    await _scrollTo(tester, find.text('На приёмке'));
    await shot(tester, 'SHOT_EXEC_SUBMITTED');

    // ===== 2. принимающий: уведомление, группа, результат, возврат без связи =====
    await _switchTo(tester, app, _reviewer);
    await _syncUntil(tester, app, 'задача ждёт решения принимающего',
        () => _viewOf(app)?.awaitingDecision == true);
    expect(_viewOf(app)!.group, TaskGroup.awaiting);
    expect(
        app.notifications.items
            .any((n) => n.event == 'acceptancePending' && n.taskId == _task),
        isTrue,
        reason: 'уведомление «ожидает приёмки» в ленте');
    debugPrint('E2E_TILE myAcceptance ${_tile(app, 'myAcceptance')}');

    _nav.push(MaterialPageRoute(
        builder: (_) => const TaskListScreen(filter: TaskFilter.acceptance)));
    await settle(tester, frames: 20);
    expect(find.text('Ждут приёмки'), findsWidgets);
    await shot(tester, 'SHOT_REVIEWER_LIST');

    _nav.push(taskResultRoute(_viewOf(app)!));
    await until(tester, 'результат: комментарий исполнителя',
        () => find.textContaining('E2E $stamp').evaluate().isNotEmpty);
    await until(tester, 'результат: снимок «стало»',
        () => find.byType(TaskPhotoThumb).evaluate().isNotEmpty);
    await shot(tester, 'SHOT_RESULT');

    debugPrint('NET_OFF_RETURN');
    await untilAsync(tester, 'телефон без связи', () async {
      await app.sync.syncAndRefresh();
      return !app.repo.online;
    }, seconds: 120);
    await tester.tap(find.byKey(const ValueKey('returnTask')));
    await settle(tester);
    await tester.enterText(find.byKey(const ValueKey('returnReason')), _reason);
    await settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Вернуть'));
    await settle(tester, frames: 20);
    v = _viewOf(app)!;
    expect(v.awaitingDecision, isFalse,
        reason: 'возвращённая офлайн уходит из «Ждут моей приёмки» сразу');
    expect(v.decisionPending, isTrue);
    expect(v.returned, isTrue);
    expect(
        app.repo.unsentOps.any((o) =>
            o.kind == UnsentKind.decision && o.detail == 'Вернуть на доработку'),
        isTrue);
    await _toRoot(tester);
    _nav.push(MaterialPageRoute(builder: (_) => const TaskListScreen()));
    await settle(tester, frames: 20);
    await shot(tester, 'SHOT_OFFLINE_RETURN');

    debugPrint('NET_ON_RETURN');
    await _syncUntil(tester, app, 'возврат доехал до сервера',
        () =>
            _viewOf(app)?.decisionPending == false &&
            _viewOf(app)?.task.returned == true &&
            (_viewOf(app)?.task.returnReason ?? '').contains('E2E 37158'),
        seconds: 240);

    // ===== 3. исполнитель: возврат с причиной, перевыполнение, прежнее на месте =====
    await _switchTo(tester, app, _executor);
    await _syncUntil(tester, app, 'возвращённая снова в «Моих» с причиной',
        () =>
            _viewOf(app)?.group == TaskGroup.mine &&
            _viewOf(app)?.returned == true &&
            (_viewOf(app)?.returnReason ?? '').contains('E2E 37158'));
    expect(
        app.notifications.items
            .any((n) => n.event == 'taskReturned' && n.taskId == _task),
        isTrue,
        reason: 'уведомление «возвращено» в ленте');
    _nav.push(
        MaterialPageRoute(builder: (_) => TaskDetailScreen(taskId: _task)));
    await until(tester, 'причина на карточке',
        () => find.text(_reason).evaluate().isNotEmpty);
    await shot(tester, 'SHOT_EXEC_RETURNED');
    await tester.pageBack();
    await settle(tester);

    await _openExecution(tester);
    // перевыполнение: сервер завёл новое выполнение, отчёт на экране — чистый
    final fresh = find.widgetWithText(FilledButton, 'Сдать на приёмку');
    await until(tester, 'новый раунд: «Сдать на приёмку», а не «Сдано»',
        () => fresh.evaluate().isNotEmpty,
        seconds: 90);
    expect(find.text('Нужно фото выполненной работы'), findsOneWidget,
        reason: 'снимки прошлого раунда остаются на сервере и не выдаются за новые');
    await shot(tester, 'SHOT_EXEC_NEW_ROUND');
    await _shootAndSubmit(tester, app,
        photo: 'e2e37158b', tint: 200, comment: 'Переснял ближе (E2E $stamp)');
    await _syncUntil(tester, app, 'повторная сдача — снова «На приёмке»',
        () => _viewOf(app)?.task.onAcceptance == true);
    v = _viewOf(app)!;
    expect(v.task.executions, hasLength(2),
        reason: 'повторная сдача прежний результат не стирает');
    expect(v.task.executions.every((e) => e.finished), isTrue);
    expect(v.task.executions.every((e) => e.photoId != null), isTrue,
        reason: 'у каждого раунда — свой снимок');
    expect(v.returned, isFalse, reason: 'сдача снимает признак возврата');
    debugPrint('E2E_EXECUTIONS ${v.task.executions.map((e) => e.id).join(',')}');

    // ===== 4. принимающий принимает без связи — коллега успел вернуть =====
    await _switchTo(tester, app, _reviewer);
    await _syncUntil(tester, app, 'задача снова ждёт решения',
        () => _viewOf(app)?.awaitingDecision == true);
    debugPrint('NET_OFF_CONFLICT');
    await untilAsync(tester, 'телефон без связи', () async {
      await app.sync.syncAndRefresh();
      return !app.repo.online;
    }, seconds: 120);
    _nav.push(
        MaterialPageRoute(builder: (_) => TaskDetailScreen(taskId: _task)));
    await until(tester, 'плашка решения на карточке',
        () => find.text('Ждёт вашего решения').evaluate().isNotEmpty);
    await tester.tap(find.byKey(const ValueKey('acceptTask')));
    await settle(tester, frames: 20);
    expect(_viewOf(app), isNull,
        reason: 'принятая офлайн уходит из списка сразу');
    expect(
        app.repo.unsentOps.any((o) =>
            o.kind == UnsentKind.decision && o.detail == 'Принять результат'),
        isTrue);

    debugPrint('CONFLICT=$_task');
    await _syncUntil(tester, app, 'полоса «кто успел раньше»',
        () => (app.repo.takeNotice ?? '').contains('уже возвращено на доработку'),
        seconds: 240);
    expect(app.repo.takeNotice, contains('Панкратов'),
        reason: 'имя того, кто успел');
    debugPrint('E2E_NOTICE ${app.repo.takeNotice}');
    expect(
        app.repo.unsentOps.where((o) => o.kind == UnsentKind.decision),
        isEmpty,
        reason: 'проигранный спор не ретраится');
    await _toRoot(tester);
    _nav.push(MaterialPageRoute(builder: (_) => const TaskListScreen()));
    await settle(tester, frames: 20);
    await shot(tester, 'SHOT_CONFLICT');

    debugPrint('ALL_OK_37158');
  });
}
