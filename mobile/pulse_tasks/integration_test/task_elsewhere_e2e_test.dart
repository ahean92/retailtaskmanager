// Сквозная приёмка #36837 на живом стенде (192.168.42.28:8888, sosedi.tech1).
// Throwaway-драйвер: положение телефона двигает внешний шелл (`adb emu geo fix`)
// по маркерам в логе — эмулятор отдаёт координаты только потоком, поэтому фикс
// шлётся повторяющимися посылками, пока приложение не увидит новое место.
//
// Сценарий приёмки целиком:
//  1) стоя в Уручье, исполнитель с обязательной геолокацией видит ВЕСЬ свой
//     список: задачи Уручья — рабочие и сверху, задачи Немиги и офиса — ниже,
//     по расстоянию и с пометкой «только просмотр»;
//  2) карточка чужой задачи открывается: объект, адрес, расстояние, история —
//     на месте, а заполнение и статусы погашены с явным «вы не на этом объекте»;
//  3) бланк чужой задачи не открывается на заполнение и НЕ начинает выполнение;
//  4) отъезд от объекта переводит задачу Уручья в «только для чтения», а возврат
//     возвращает её в работу — и всё введённое на месте остаётся при ней;
//  5) число «моих» в списке сходится с плиткой главной.
//
// Маркеры для шелла: GEO_MOVE=<lon> <lat> → слать `adb emu geo fix` этой точкой,
// пока не появится GEO_OK; ALL_OK_36837 — приёмка пройдена.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pulse_tasks/data/fill_controller.dart';
import 'package:pulse_tasks/data/task_repository.dart';
import 'package:pulse_tasks/main.dart' as app;
import 'package:pulse_tasks/ui/fill_screen.dart';
import 'package:pulse_tasks/ui/task_detail_screen.dart';
import 'package:pulse_tasks/ui/task_list_screen.dart';
import 'package:pulse_tasks/ui/widgets/task_card.dart';
import 'support/e2e_harness.dart';

const _login = String.fromEnvironment('E2E_LOGIN', defaultValue: 'sosedi.tech1');

/// Объекты стенда, между которыми ездит приёмка. Офис (777) намеренно не входит в
/// маршрут: с ним в одной точке стоит «Склад (демо)» — объект с координатами, но
/// без бизнес-ключа, и до фикса гварда `id(o)` телефон выбирал именно его.
const _uruchie = (id: 'SOS-103', lat: 53.941, lon: 27.672); // «Соседи» в Уручье
const _nemiga = (id: 'SOS-102', lat: 53.9045, lon: 27.551); // ~8,9 км

/// Переехать: шелл шлёт `adb emu geo fix` потоком, приложение переспрашивает
/// местоположение, пока не окажется на ожидаемом объекте.
Future<void> _moveTo(WidgetTester tester, TaskRepository repo,
    ({String id, double lat, double lon}) target) async {
  debugPrint('GEO_MOVE=${target.lon} ${target.lat}');
  final deadline = DateTime.now().add(const Duration(seconds: 240));
  while (repo.place.objectId != target.id) {
    if (DateTime.now().isAfter(deadline)) {
      fail('не доехали до ${target.id}: место=${repo.place.objectId}');
    }
    // fresh — как кнопка «Обновить местоположение»: без него приложение отдаёт
    // запомненную позицию и «переезд» за пять минут просто не случается
    await repo.locate(fresh: true);
    await tester.pump(const Duration(milliseconds: 400));
    await Future<void>.delayed(const Duration(seconds: 2));
  }
  debugPrint('GEO_OK ${target.id}');
  await settle(tester);
}

TaskView? _viewOf(TaskRepository repo, String id) {
  for (final v in repo.tasks) {
    if (v.id == id) return v;
  }
  return null;
}

/// Сам список задач: первый Scrollable экрана — горизонтальная лента чипов
/// фильтров, скроллить надо не её.
Finder _verticalList() => find.byWidgetPredicate(
    (w) => w is Scrollable && w.axisDirection == AxisDirection.down);

Future<void> _dragUntil(WidgetTester tester, Finder target, double dy,
    {required String what}) async {
  for (var i = 0; i < 60 && target.evaluate().isEmpty; i++) {
    await tester.drag(_verticalList().first, Offset(0, dy),
        warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 60));
  }
  await settle(tester);
  expect(target, findsWidgets, reason: 'не доскроллились: $what');
  await tester.ensureVisible(target.first);
  await settle(tester);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('36837: задачи других объектов видны и только для чтения',
      (tester) async {
    final repo = await bootApp(tester, login: _login, geoGate: false);
    expect(repo.session.geoRequired, isTrue,
        reason: 'сценарий писан под исполнителя с обязательной геолокацией');

    // ===== сценарий 1: стоя в Уручье, видно ВСЁ назначенное =====
    await _moveTo(tester, repo, _uruchie);
    await repo.syncAndRefresh();
    await until(tester, 'список с задачами других объектов',
        () => repo.tasks.any((v) => v.elsewhere), seconds: 120);

    app.PulseApp.navigatorKey.currentState!
        .push(MaterialPageRoute(builder: (_) => const TaskListScreen()));
    await settle(tester);

    final here = repo.tasks.where((v) => !v.elsewhere).toList();
    final away = repo.tasks.where((v) => v.elsewhere).toList();
    debugPrint('в Уручье: здесь=${here.length}, не здесь=${away.length} '
        '(${away.map((v) => '${v.id}@${v.task.objectId}:${v.task.distance?.round()}м').join(', ')})');
    expect(here, isNotEmpty, reason: 'задачи объекта, где человек стоит');
    expect(away, isNotEmpty,
        reason: 'ради этого и заводился тикет: чужие объекты больше не прячутся');
    expect(here.every((v) => v.task.objectId == _uruchie.id), isTrue);

    // порядок — маршрутом: сначала «здесь», дальше по возрастанию расстояния
    final ids = repo.tasks.map((v) => v.id).toList();
    expect(ids.sublist(0, here.length).toSet(), here.map((v) => v.id).toSet(),
        reason: 'задачи текущего объекта — сверху');
    final distances = [
      for (final v in away)
        if (v.task.distance != null) v.task.distance!
    ];
    expect(distances, orderedEquals([...distances]..sort()),
        reason: 'остальные — по расстоянию');

    // пометка видна человеку, а не только репозиторию
    final awayCard = find.byWidgetPredicate(
        (w) => w is TaskCard && w.view.id == away.first.id);
    await _dragUntil(tester, awayCard, -400, what: 'карточка чужого объекта');
    expect(
        find.descendant(
            of: awayCard, matching: find.textContaining('только просмотр')),
        findsOneWidget);

    // ===== сценарий 2: карточка чужой задачи — просмотр без работы =====
    final awayId = away.first.id;
    app.PulseApp.navigatorKey.currentState!.push(
        MaterialPageRoute(builder: (_) => TaskDetailScreen(taskId: awayId)));
    await settle(tester);

    expect(find.textContaining('Вы не на этом объекте'), findsOneWidget);
    // объект, адрес и расстояние — на месте: это и есть «видно, куда ехать»
    expect(find.text('Расстояние'), findsOneWidget);
    for (final chip in tester.widgetList<ChoiceChip>(find.byType(ChoiceChip))) {
      expect(chip.onSelected, isNull,
          reason: 'статус чужой задачи не переключается');
    }
    final fillButtons = find.byWidgetPredicate((w) =>
        w is FilledButton &&
        w.child is Text &&
        (w.child! as Text).data!.startsWith('Заполнить'));
    if (fillButtons.evaluate().isNotEmpty) {
      expect(tester.widget<FilledButton>(fillButtons.first).onPressed, isNull,
          reason: 'заполнение чужой задачи погашено');
      expect(find.text('Прошлая проверка'), findsOneWidget,
          reason: 'история — не работа, вход в неё остаётся');
    }
    app.PulseApp.navigatorKey.currentState!.pop();
    await settle(tester);

    // ===== сценарий 3: бланк чужой задачи не открывается и не стартует =====
    // Задача Уручья с ЖИВЫМ бланком — её же откроем после отъезда. Тип задачи
    // сам по себе бланка не обещает: на стенде есть «бланочные» задачи без
    // шаблона (ST000043), у которых полей ноль, — годность проверяется открытием.
    TaskView? fillableHere;
    int answeredOnSite = 0;
    for (final v in here.where((v) => const {
          'checklist',
          'form',
          'recount',
          'pricing'
        }.contains(v.task.typeId))) {
      final probe = FillController(
          db: repo.db, api: repo.api, taskId: v.task.clientId ?? v.id);
      await probe.load();
      final usable = probe.fields.isNotEmpty && !probe.confirmedFinished;
      debugPrint('кандидат ${v.id}: полей=${probe.fields.length} '
          'завершена=${probe.confirmedFinished}');
      if (usable) {
        // на месте бланк принимает ответ — это то «введённое на месте», которое
        // обязано пережить отъезд
        final field = probe.fields.firstWhere((f) => f.options.isNotEmpty,
            orElse: () => probe.fields.first);
        if (field.options.isNotEmpty) {
          await probe.setOption(field, field.options.first.code);
        } else {
          await probe.setText(field, 'ответ на месте 36837');
        }
        answeredOnSite = probe.answeredCount;
        fillableHere = v;
      }
      probe.dispose();
      if (fillableHere != null) break;
    }
    expect(fillableHere, isNotNull,
        reason: 'на объекте нет задачи с живым бланком — нечего проверять');
    final fillable = fillableHere!;
    debugPrint("бланочная задача Уручья: ${fillable.id}, "
        "заполнено на месте: $answeredOnSite");
    expect(answeredOnSite, greaterThan(0));

    // ===== сценарий 4: отъезд → «только для чтения», возврат → снова в работу =====
    await _moveTo(tester, repo, _nemiga);
    await settle(tester);

    final movedAway = _viewOf(repo, fillable.id)!;
    expect(movedAway.elsewhere, isTrue,
        reason: 'отъехал — задача перешла в «только для чтения»');
    // и симметрично: задачи объекта, куда он приехал, стали рабочими
    final atNemiga = repo.tasks.where((v) => !v.elsewhere).toList();
    debugPrint('на Немиге: здесь=${atNemiga.length}, всего=${repo.tasks.length}');
    expect(atNemiga, isNotEmpty, reason: 'задачи Немиги стали рабочими');
    expect(atNemiga.every((v) => v.task.objectId == _nemiga.id), isTrue);

    // бланк уехавшей задачи закрыт, и открытие его не начинает выполнение
    app.PulseApp.navigatorKey.currentState!.push(MaterialPageRoute(
        builder: (_) =>
            FillScreen(taskId: fillable.task.clientId ?? fillable.id)));
    await settle(tester);
    expect(find.text('Вы не на этом объекте'), findsOneWidget);
    expect(find.textContaining('сохранено и синхронизируется'), findsOneWidget,
        reason: 'введённое на месте не отбирают — об этом говорят прямо');
    app.PulseApp.navigatorKey.currentState!.pop();
    await settle(tester);

    // вернулся — снова рабочая, и всё введённое на месте при ней
    await _moveTo(tester, repo, _uruchie);
    await repo.syncAndRefresh();
    await settle(tester);

    final backHome = _viewOf(repo, fillable.id)!;
    expect(backHome.elsewhere, isFalse, reason: 'вернулся — задача снова рабочая');

    final again = FillController(
        db: repo.db, api: repo.api, taskId: fillable.task.clientId ?? fillable.id);
    await again.load();
    expect(again.answeredCount, greaterThanOrEqualTo(answeredOnSite),
        reason: 'введённое на месте осталось и доехало');
    again.dispose();

    // ===== сценарий 5: список сходится с цифрой главной =====
    await repo.refreshHome();
    await settle(tester);
    final mine = repo.tasks.where((v) => v.group == TaskGroup.mine).length;
    int? tile;
    for (final b in repo.home.blocks) {
      for (final m in b.metrics) {
        if (m.code == 'myOpen') tile = m.value?.round();
      }
    }
    debugPrint('мои в списке=$mine, плитка myOpen=$tile');
    expect(tile, isNotNull, reason: 'на главной должна быть плитка «мои задачи»');
    expect(mine, tile,
        reason: 'число задач в списке сходится с цифрой на главной');

    debugPrint('ALL_OK_36837');
  });
}
