// Сквозная приёмка #36916 на живом стенде — очередь отправки: показать состав и
// дать запустить руками.
//
// Throwaway-драйвер: сеть переключает внешний шелл по маркерам в логе (авиарежим
// через `cmd connectivity`), гео-разрешение выдаёт оркестратор по boot:, точка
// эмулятора — поток `adb emu geo fix`.
//
// Сценарий приёмки («Приёмка» тикета):
//  1) три операции, сделанные офлайн (статус, сообщение, фото к задаче), видны
//     списком «Не отправлено» с понятными названиями и временем;
//  2) при ошибке видно, какая операция не прошла и почему («Нет сети» у каждой —
//     после «Отправить сейчас» без связи);
//  3) «Отправить сейчас» при живой сети опустошает очередь; индикатор гаснет;
//  4) повторная синхронизация не создаёт дублей: счётчики сообщений и файлов
//     задачи на сервере растут ровно на единицу и не растут от второго прохода.
//
// Маркеры: boot:, E2E_READY, NET_OFF, SHOT_UNSENT, SHOT_OFFLINE_SEND, NET_ON,
// SHOT_SENT, ALL_OK_36916.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pulse_tasks/data/comment_controller.dart';
import 'package:pulse_tasks/ui/unsent_screen.dart';
import 'support/e2e_harness.dart';

const _login = String.fromEnvironment('E2E_LOGIN', defaultValue: 'sosedi.tech1');

/// Однопиксельный PNG — «фото», которое поедет очередью снимков задачи.
final _png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmM'
    'IQAAAABJRU5ErkJggg==');

/// Индикатор «не отправлено» в шапке — по tooltip: иконка Icons.sync_problem не
/// уникальна (её же носит офлайн-баннер с текстом ошибки).
bool _hasUnsentBadge(WidgetTester tester) => tester
    .widgetList<IconButton>(find.byType(IconButton))
    .any((b) => b.tooltip?.startsWith('Не отправлено') ?? false);

Finder _unsentBadge() => find.byWidgetPredicate((w) =>
    w is IconButton && (w.tooltip?.startsWith('Не отправлено') ?? false));

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('36916: состав очереди, причины, «Отправить сейчас», без дублей',
      (tester) async {
    final repo = await bootApp(tester, login: _login);

    await repo.syncAndRefresh();
    await until(tester, 'выдача задач', () => repo.tasks.isNotEmpty,
        seconds: 120);
    debugPrint('E2E_READY object=${repo.objectId} tasks=${repo.tasks.length}');

    // чистый старт: очередь пуста, индикатора в шапке нет
    expect(repo.pendingCount, 0,
        reason: 'на входе очередь обязана быть пустой — стенд и база чистые');
    expect(_hasUnsentBadge(tester), isFalse);

    // две открытые задачи «здесь»: A — статус и фото, B — сообщение
    final open = [
      for (final v in repo.tasks)
        if (!v.closed && !v.elsewhere && !v.authoredOnly) v
    ];
    expect(open.length, greaterThanOrEqualTo(2),
        reason: 'приёмке нужны хотя бы две открытые задачи на объекте');
    final a = open.first, b = open[1];
    final nameA = a.task.name ?? '?', nameB = b.task.name ?? '?';
    final statusA0 = repo.statusById(a.statusId);
    final statusA1 = repo.statuses.firstWhere(
        (s) => s.id != a.statusId && !s.closed,
        orElse: () => fail('нет открытого статуса, отличного от текущего'));
    debugPrint('ops: A=${a.id} «$nameA» ${a.statusId}->${statusA1.id}; '
        'B=${b.id} «$nameB»');

    // серверные базлайны для проверки «без дублей»
    final commentsBase = (await repo.api.fetchTaskComments(b.id)).length;
    final filesBase = a.task.files.length;

    // ===== офлайн: три операции разных видов =====
    debugPrint('NET_OFF');
    await until(tester, 'авиарежим', () => !repo.online, seconds: 240);

    await repo.setStatus(a.id, statusA1);
    final comments =
        TaskCommentsController(db: repo.db, api: repo.api, taskId: b.id);
    await comments.send('Э2Э 36916: не уедет без сети');
    final photo = File(
        '${Directory.systemTemp.path}/e2e36916_${DateTime.now().millisecondsSinceEpoch}.png');
    await photo.writeAsBytes(_png);
    await repo.attachTaskPhoto(a.id, photo.path);

    // ===== 1. индикатор и список: три операции, понятные названия, время =====
    await until(tester, 'три операции в очереди', () => repo.pendingCount == 3);
    await until(tester, 'индикатор в шапке', () => _hasUnsentBadge(tester));
    await tester.tap(_unsentBadge());
    await until(tester, 'экран «Не отправлено»',
        () => find.byType(UnsentScreen).evaluate().isNotEmpty);

    expect(find.text(nameA), findsNWidgets(2),
        reason: 'статус и фото задачи A — две строки с её именем');
    expect(find.text(nameB), findsOneWidget);
    expect(find.text('Статус → «${statusA1.name}»'), findsOneWidget);
    expect(find.text('1 сообщение'), findsOneWidget);
    expect(find.text('1 фото к задаче'), findsOneWidget);
    expect(find.textContaining('В очереди с '), findsNWidgets(3));
    await shot(tester, 'SHOT_UNSENT');

    // ===== 2. «Отправить сейчас» без связи: видимый отказ и причины =====
    await tester.tap(find.text('Отправить сейчас'));
    await until(tester, 'снекбар про неудачу',
        () => find.textContaining('Отправить не удалось').evaluate().isNotEmpty,
        seconds: 120);
    await until(tester, 'причина у каждой операции',
        () => find.text('Нет сети').evaluate().length >= 3);
    expect(repo.pendingCount, 3, reason: 'без сети очередь не тает и не теряется');
    await shot(tester, 'SHOT_OFFLINE_SEND');

    // ===== 3. сеть вернулась: «Отправить сейчас» опустошает, индикатор гаснет =====
    debugPrint('NET_ON');
    // жмём кнопку до опустошения; фоновая синхронизация по возврату сети имеет
    // право успеть первой — тогда кнопка исчезает вместе с очередью, и это тоже
    // принятый исход («опустошает; индикатор гаснет»)
    final deadline = DateTime.now().add(const Duration(seconds: 240));
    while (repo.pendingCount > 0) {
      if (DateTime.now().isAfter(deadline)) {
        fail('очередь не опустела при живой сети');
      }
      final btn = find.text('Отправить сейчас');
      if (btn.evaluate().isNotEmpty) {
        await tester.tap(btn, warnIfMissed: false);
      }
      await tester.pump(const Duration(milliseconds: 500));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    await until(tester, 'пустое состояние экрана',
        () => find.text('Всё отправлено').evaluate().isNotEmpty);
    await shot(tester, 'SHOT_SENT');

    await tester.pageBack();
    await settle(tester);
    expect(_hasUnsentBadge(tester), isFalse, reason: 'индикатор гаснет на нуле');

    // ===== 4. дошло и без дублей: счётчики выросли ровно на единицу =====
    await untilAsync(tester, 'статус задачи A подтверждён сервером', () async {
      await repo.refresh();
      return repo.viewOf(a.id)?.statusId == statusA1.id;
    }, seconds: 120);
    final commentsAfter = (await repo.api.fetchTaskComments(b.id)).length;
    expect(commentsAfter, commentsBase + 1,
        reason: 'сообщение доехало один раз');
    final filesAfter = repo.viewOf(a.id)!.task.files.length;
    expect(filesAfter, filesBase + 1, reason: 'фото доехало один раз');

    // повторная синхронизация — ничего не дублирует
    await repo.syncAndRefresh();
    expect((await repo.api.fetchTaskComments(b.id)).length, commentsAfter);
    expect(repo.viewOf(a.id)!.task.files.length, filesAfter);
    expect(repo.pendingCount, 0);

    // чистоплотность: статус задачи A — обратно
    if (statusA0 != null) {
      await repo.setStatus(a.id, statusA0);
      await untilAsync(tester, 'статус вернулся', () async {
        await repo.syncAndRefresh();
        return repo.pendingCount == 0;
      }, seconds: 120);
    }
    comments.dispose();
    debugPrint('ALL_OK_36916');
  });
}
