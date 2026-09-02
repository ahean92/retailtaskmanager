// Сквозная приёмка #36944 на живом стенде — «на сегодня» и «просрочено» считает сервер.
//
// Проверяется ровно то, что записано в приёмке тикета:
//  1) длина списка «Просроченные» равна цифре плитки «Просрочено», и то же для
//     «На сегодня» — числа снимаются с той самой плитки, тапом по которой открывается
//     список, и с чипа этого списка;
//  2) телефон живёт в чужом часовом поясе (его выставляет оркестратор ДО запуска: tzset
//     процесс читает один раз, менять пояс на живом приложении бессмысленно) и посреди
//     прогона уезжает ещё на сутки вперёд — состав обоих списков не меняется ни из
//     кэша, ни после синхронизации;
//  3) «полночь по серверу»: срок задачи переводится на вчера ЗАПРОСОМ К СЕРВЕРУ, и она
//     становится просроченной и на плитке, и в списке одним обновлением — то есть у
//     всех сразу, а не когда у кого-то на телефоне наступит своя полночь.
//
// Что телефон и правда стоит на другой дате, тест выясняет не со слов оркестратора:
// серверное «сегодня» — это срок задачи, у которой сервер прислал признак dueToday.
//
// Throwaway-драйвер: часы и срок задачи на сервере двигает внешний шелл по маркерам в
// логе — из процесса приложения ни того, ни другого не сделать.
//
// Параметры — dart-define: E2E_BASE, E2E_LOGIN/E2E_PASS, E2E_OBJECT (магазин, в
// котором лежит контрольный набор).
//
// Маркеры: boot:, E2E_READY, E2E_TILES, SHOT_home, SHOT_overdue, SHOT_today,
// E2E_TILES_OK, SHIFT_CLOCK, E2E_SHIFTED, E2E_SHIFT_OK, RESTORE_CLOCK,
// MIDNIGHT=<id>, E2E_MIDNIGHT_OK, SHOT_after_midnight, ALL_OK_36944.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pulse_tasks/data/task_repository.dart';
import 'support/e2e_harness.dart';

const _login = String.fromEnvironment('E2E_LOGIN', defaultValue: 'demo.user1');
const _object = String.fromEnvironment('E2E_OBJECT', defaultValue: 'SOS-103');

String _iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Долистать главную до виджета: плитки сводки лежат ниже блока задач и на невысоком
/// экране в первый кадр не попадают.
Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  final vertical = find.byWidgetPredicate(
      (w) => w is Scrollable && w.axisDirection == AxisDirection.down);
  for (var i = 0; i < 20 && finder.evaluate().isEmpty; i++) {
    await tester.drag(vertical.first, const Offset(0, -260));
    await settle(tester, frames: 3);
  }
  expect(finder, findsWidgets, reason: 'не долистали до нужного виджета');
  await tester.ensureVisible(finder.first);
  await settle(tester, frames: 3);
}

/// Долистать ленту чипов вправо до нужного. Чипы лежат в горизонтальном ListView, а он
/// строит только видимые: «Просроченных» четвёртым в дереве просто нет, пока лента не
/// прокручена, и find.text честно ничего не находит.
///
/// Лента ищется как предок ПЕРВОГО чипа, а не по «первому горизонтальному Scrollable»:
/// таких на экране два, и первый — внутренний скролл строки поиска. Тянуть его можно
/// сколько угодно, чипы при этом стоят на месте.
Future<void> _chipTo(WidgetTester tester, Finder finder) async {
  final bar = find
      .ancestor(
          of: find.textContaining('Все задачи · '),
          matching: find.byType(Scrollable))
      .first;
  expect(bar, findsOneWidget, reason: 'не нашли ленту чипов');
  for (var i = 0; i < 12 && finder.evaluate().isEmpty; i++) {
    await tester.drag(bar, const Offset(-220, 0));
    await settle(tester, frames: 3);
  }
  expect(finder, findsWidgets, reason: 'не долистали ленту чипов до нужного');
}

/// Разрез, в котором плитка показывает своё число, — тот же, что уходит в список по
/// тапу (HomeScreen._openTasks): объект, если блок в разрезе, и вся сеть, если нет.
String? _cut(TaskRepository repo, String code) {
  for (final b in repo.home.blocks) {
    for (final m in b.metrics) {
      if (m.code == code) return b.byObject ? repo.objectId : null;
    }
  }
  fail('на главной нет показателя $code');
}

/// Цифра плитки — ровно та, что человек видит на главной.
int _tile(TaskRepository repo, String code) {
  for (final b in repo.home.blocks) {
    for (final m in b.metrics) {
      if (m.code == code) {
        return (m.valueFor(b.byObject ? repo.objectId : null) ?? 0).round();
      }
    }
  }
  fail('на главной нет показателя $code');
}

/// Состав списка, который откроется тапом по плитке. Отсортирован: сравнивается
/// именно состав, порядок наводит сортировка и к делу не относится.
List<String> _ids(TaskRepository repo, TaskFilter f, String? objectId) {
  final tasks = objectId == null
      ? repo.tasks
      : repo.tasks.where((v) => v.task.objectId == objectId).toList();
  return [for (final v in tasks.where(f.matches)) v.id]..sort();
}

/// Какое «сегодня» у сервера — по его же ответу: срок задачи, которой он прислал
/// признак dueToday. Спрашивать об этом часы телефона в этом тесте нельзя.
String? _serverToday(TaskRepository repo) {
  for (final v in repo.tasks) {
    if (v.task.dueToday == true) return v.task.deadline;
  }
  return null;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('36944: плитка и список от одной даты — серверной', (tester) async {
    final repo = await bootApp(tester, login: _login);

    await repo.syncAndRefresh();
    await settle(tester);
    // магазин, в котором лежит контрольный набор, — тем же выбором, что делает человек
    if (repo.objectId != _object) {
      await repo.selectObject(_object);
      await settle(tester);
    }
    debugPrint('E2E_READY object=${repo.objectId} tasks=${repo.tasks.length}');

    // ===== 1. плитка и список — одно число =====
    final overdueCut = _cut(repo, 'myOverdue');
    final todayCut = _cut(repo, 'myToday');
    final tileOverdue = _tile(repo, 'myOverdue');
    final tileToday = _tile(repo, 'myToday');
    final listOverdue = _ids(repo, TaskFilter.overdue, overdueCut);
    final listToday = _ids(repo, TaskFilter.today, todayCut);
    debugPrint('E2E_TILES overdue=$tileOverdue/${listOverdue.length} '
        'today=$tileToday/${listToday.length} '
        'phone=${_iso(DateTime.now())} tz=${DateTime.now().timeZoneName} '
        'server=${_serverToday(repo)}');
    expect(tileOverdue, greaterThan(0),
        reason: 'на стенде нет ни одной просроченной задачи — приёмке нечего '
            'показывать, сначала данные');
    expect(tileToday, greaterThan(0),
        reason: 'на стенде нет ни одной задачи на сегодня');
    expect(listOverdue.length, tileOverdue);
    expect(listToday.length, tileToday);
    await shot(tester, 'SHOT_home');

    // то же самое глазами человека: тап по плитке и число на чипе списка
    await _scrollTo(tester, find.text('Просрочено'));
    await tester.tap(find.text('Просрочено').first);
    await settle(tester);
    await _chipTo(tester, find.textContaining('Просроченные · '));
    await until(tester, 'список просроченных',
        () => find.textContaining('Просроченные · ').evaluate().isNotEmpty);
    expect(find.text('Просроченные · $tileOverdue'), findsOneWidget,
        reason: 'чип обязан повторить цифру плитки, а не пересчитать её от '
            'даты телефона');
    await shot(tester, 'SHOT_overdue');
    await tester.pageBack();
    await settle(tester);

    await _scrollTo(tester, find.text('На сегодня'));
    await tester.tap(find.text('На сегодня').first);
    await settle(tester);
    await _chipTo(tester, find.textContaining('На сегодня · '));
    await until(tester, 'список на сегодня',
        () => find.textContaining('На сегодня · ').evaluate().isNotEmpty);
    expect(find.text('На сегодня · $tileToday'), findsOneWidget);
    await shot(tester, 'SHOT_today');
    await tester.pageBack();
    await settle(tester);
    debugPrint('E2E_TILES_OK');

    // ===== 2. чужой пояс и дата, сдвинутая на сутки =====
    final serverToday = _serverToday(repo);
    expect(serverToday, isNotNull,
        reason: 'сервер не прислал ни одного dueToday — не с чем сверять дату');
    final before = DateTime.now();
    debugPrint('SHIFT_CLOCK'); // шелл: auto_time 0 и дата на сутки вперёд
    await until(tester, 'часы телефона уехали на сутки',
        () => DateTime.now().difference(before).inHours >= 20, seconds: 300);
    debugPrint('E2E_SHIFTED phone=${_iso(DateTime.now())} '
        'tz=${DateTime.now().timeZoneName} server=$serverToday');
    expect(_iso(DateTime.now()), isNot(serverToday),
        reason: 'телефон обязан стоять на другой дате, иначе проверка вхолостую');

    // из кэша, сети не касаясь: состав держится на признаке в строке, а не на часах
    expect(_ids(repo, TaskFilter.overdue, overdueCut), listOverdue,
        reason: 'состав «Просроченных» поехал за часами телефона');
    expect(_ids(repo, TaskFilter.today, todayCut), listToday,
        reason: 'состав «На сегодня» поехал за часами телефона');

    // и после синхронизации — сервер отвечает от своей даты, она не менялась
    await repo.syncAndRefresh();
    await settle(tester);
    expect(_ids(repo, TaskFilter.overdue, overdueCut), listOverdue);
    expect(_ids(repo, TaskFilter.today, todayCut), listToday);
    expect(_tile(repo, 'myOverdue'), tileOverdue);
    expect(_tile(repo, 'myToday'), tileToday);
    debugPrint('E2E_SHIFT_OK');

    debugPrint('RESTORE_CLOCK');
    await until(tester, 'часы телефона вернулись',
        () => DateTime.now().difference(before).inHours < 20, seconds: 300);

    // ===== 3. «полночь по серверу» =====
    // Ждать настоящей полуночи в приёмке нельзя, а подводить часы телефона — значит
    // проверять ровно то, что этот тикет запрещает. Поэтому полночь имитируется на
    // СЕРВЕРЕ: срок контрольной задачи переводится на вчера, и признак у всех сразу
    // становится «просрочена», пока телефон живёт по своему времени.
    final victim = listToday.first;
    debugPrint('MIDNIGHT=$victim'); // шелл: deadline(задача) <- вчера
    await untilAsync(
        tester,
        'задача $victim стала просроченной по серверу',
        () async {
          await repo.syncAndRefresh();
          return _ids(repo, TaskFilter.overdue, overdueCut).contains(victim);
        },
        seconds: 300);
    await settle(tester);

    expect(_ids(repo, TaskFilter.today, todayCut), isNot(contains(victim)),
        reason: 'задача не может быть и на сегодня, и просроченной');
    expect(_tile(repo, 'myOverdue'), tileOverdue + 1,
        reason: 'плитка обязана сдвинуться тем же обновлением, что и список');
    expect(_tile(repo, 'myToday'), tileToday - 1);
    expect(_ids(repo, TaskFilter.overdue, overdueCut).length,
        _tile(repo, 'myOverdue'),
        reason: 'после сдвига числа обязаны сойтись снова');
    expect(
        _ids(repo, TaskFilter.today, todayCut).length, _tile(repo, 'myToday'));
    debugPrint('E2E_MIDNIGHT_OK');

    await shot(tester, 'SHOT_after_midnight');
    debugPrint('ALL_OK_36944');
  });
}
