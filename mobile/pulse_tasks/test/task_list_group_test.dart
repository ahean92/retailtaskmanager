
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
