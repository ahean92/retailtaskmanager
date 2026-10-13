
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:pulse_tasks/app_controllers.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/models/task_view.dart';
import 'package:pulse_tasks/models/task.dart';
import 'package:pulse_tasks/ui/task_list_screen.dart';
import 'support/fake_server.dart';

/// Группы списка (#36836; редизайн #37411 — группы стали чипами-фильтрами):
/// «мои» открываются сразу, свободные — своим чипом с кнопкой «Взять», взятые
/// коллегами не исчезают, а стоят за своим чипом; пустая группа чипа не получает.

AppControllers _repo() {
  final settings = Settings(baseUrl: 'http://test.local:9080');
  final session = Session(
    login: 'ivanov',
    name: 'Иванов И.И.',
    token: 'token',
    signedIn: true,
    performerId: 'p1',
  );
  final client = MockClient((request) async => okJson('[]'));
  return AppControllers(
    api: ApiClient(settings, session, client: client),
    settings: settings,
    session: session,
  );
}

TaskView _mine(String id) => TaskView(
    Task(id: id, name: 'Личная $id'), null, null, false,
    group: TaskGroup.mine);

TaskView _free(String id) => TaskView(
    Task(id: id, name: 'Пул $id'), null, null, false,
    group: TaskGroup.free, canTake: true);

TaskView _taken(String id) => TaskView(
    Task(id: id, name: 'Чужая $id'), null, null, false,
    group: TaskGroup.taken, takenBy: 'Петров П.П.', takenById: 'p2');

Future<AppControllers> _open(WidgetTester tester, List<TaskView> tasks) async {
  final app = _repo()..repo.tasks = tasks;
  await tester.pumpWidget(MultiProvider(
    providers: app.providers,
    child: const MaterialApp(home: TaskListScreen()),
  ));
  await tester.pumpAndSettle();
  return app;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('непустые группы — чипы со счётчиками, по порядку', (tester) async {
    await _open(tester, [_taken('T1'), _free('F1'), _mine('M1')]);

    // чипы короткими названиями; «мои» выбраны сразу — их задачи на экране
    expect(find.text('Мои'), findsOneWidget);
    expect(find.text('Свободные'), findsOneWidget);
    expect(find.text('У коллег'), findsOneWidget);
    expect(find.text('Личная M1'), findsOneWidget);

    // порядок чипов фиксирован, как бы ни были перемешаны задачи (полоса
    // горизонтальная — сравниваем координаты по X)
    final mineX = tester.getTopLeft(find.text('Мои')).dx;
    final freeX = tester.getTopLeft(find.text('Свободные')).dx;
    final takenX = tester.getTopLeft(find.text('У коллег')).dx;
    expect(mineX, lessThan(freeX));
    expect(freeX, lessThan(takenX));

    // чужая задача — за своим чипом, состав по нажатию
    expect(find.text('Чужая T1'), findsNothing);
    await tester.tap(find.text('У коллег'));
    await tester.pumpAndSettle();
    expect(find.text('Чужая T1'), findsOneWidget);
    expect(find.text('взял: Петров П.П.'), findsOneWidget);
  });

  // Полоса групп скроллится внутри ширины до кнопки «Сортировка и фильтры»:
  // чипы не наезжают под кнопку и не уезжают за край экрана, а выбранный
  // наполовину спрятанный чип докручивается в полосу целиком.
  testWidgets('выбранный чип докручивается в полосу, кнопка фильтров — на поле',
      (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    TaskView byGroup(TaskGroup g, String id) =>
        TaskView(Task(id: id, name: 'Задача $id'), null, null, false, group: g);
    await _open(tester, [
      byGroup(TaskGroup.mine, 'M1'),
      byGroup(TaskGroup.awaiting, 'A1'),
      byGroup(TaskGroup.free, 'F1'),
      byGroup(TaskGroup.taken, 'T1'),
      byGroup(TaskGroup.submitted, 'S1'),
      byGroup(TaskGroup.rework, 'R1'),
      byGroup(TaskGroup.authored, 'P1'),
      byGroup(TaskGroup.watched, 'W1'),
    ]);

    // кнопка «Сортировка и фильтры» стоит на общем правом поле экрана, а не
    // впритык к краю; полоса чипов кончается перед ней
    final tune = tester.getRect(find.byTooltip('Сортировка и фильтры'));
    expect(tune.right, allOf(greaterThan(320 - 24), lessThan(320)),
        reason: 'правое поле кнопки — 16, внутренний отступ IconButton ±4');

    // полоса обрезается общим левым полем (16), как карточки списка ниже:
    // первый чип стоит на нём, прокрученные скрываются за границей поля
    final strip = tester.getRect(find.byType(ListView).first);
    expect(strip.left, 16.0, reason: 'клип полосы — на левом поле экрана');
    expect(tester.getRect(find.byTooltip('Мои')).left, closeTo(16, 1.0),
        reason: 'первый чип стоит на общем левом поле');

    // прокручиваем полосу мелкими шагами, пока последний чип («Поставленные»)
    // не окажется на экране — ListView с cacheExtent строит детей и за
    // вьюпортом, поэтому меряем прямоугольник, а не наличие в дереве.
    // Частично виден — тап по видимой части выбирает его, и он докручивается
    // в полосу целиком
    var guard = 0;
    while (guard++ < 20) {
      final found = find.text('Поставленные').evaluate();
      if (found.isNotEmpty &&
          tester.getRect(find.text('Поставленные')).right < 320) {
        break;
      }
      await tester.drag(find.byType(ListView).first, const Offset(-120, 0));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.text('Поставленные'), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    final chip = tester.getRect(find.text('Поставленные'));
    expect(chip.left, greaterThan(0), reason: 'чип виден с начала, не за краем');
    expect(chip.right, lessThan(tune.left),
        reason: 'чип целиком до кнопки фильтров, не спрятан под ней');
  });

  testWidgets('пустая группа чипа не получает', (tester) async {
    await _open(tester, [_mine('M1'), _free('F1')]);

    expect(find.text('Мои'), findsOneWidget);
    expect(find.text('Свободные'), findsOneWidget);
    expect(find.text('У коллег'), findsNothing);
  });

  testWidgets('единственная группа — её чип и её задачи', (tester) async {
    await _open(tester, [_mine('M1'), _mine('M2')]);

    expect(find.text('Мои'), findsOneWidget);
    expect(find.text('Личная M1'), findsOneWidget);
    expect(find.text('Личная M2'), findsOneWidget);
  });

  testWidgets('«Взять» — только у свободных, по серверному canTake',
      (tester) async {
    await _open(tester, [_mine('M1'), _free('F1')]);

    // свободные — за своим чипом, у их строк и живёт «Взять»
    await tester.tap(find.text('Свободные'));
    await tester.pumpAndSettle();
    expect(find.text('Взять'), findsOneWidget);
    await tester.tap(find.text('Взять'));
    await tester.pump();
    // репозиторий без базы взятие молча не теряет смысла проверять — здесь
    // важна сама проводка нажатия до снекбара
    expect(find.text('Задача перенесена в «Мои»'), findsOneWidget);
  });

  testWidgets('взятая офлайн несёт явную пометку', (tester) async {
    await _open(tester, [
      const TaskView(Task(id: 'M1', name: 'Взятая'), null, null, false,
          group: TaskGroup.mine,
          takenBy: 'Иванов И.И.',
          takenById: 'p1',
          takePending: true),
      _free('F1'),
    ]);

    expect(find.text('взята — ожидает подтверждения'), findsOneWidget);
  });
}
