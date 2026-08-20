import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/data/task_repository.dart';
import 'package:pulse_tasks/models/task.dart';
import 'package:pulse_tasks/ui/task_list_screen.dart';

/// Три группы списка (#36836): «мои» сверху, свободные с кнопкой «Взять», взятые
/// коллегами свёрнуты, но не исчезают; пустая группа не показывается вовсе.

TaskRepository _repo() {
  final settings = Settings(baseUrl: 'http://test.local:9080');
  final session = Session(
    login: 'ivanov',
    name: 'Иванов И.И.',
    token: 'token',
    signedIn: true,
    performerId: 'p1',
  );
  final client = MockClient((request) async => http.Response.bytes(
      utf8.encode('[]'), 200,
      headers: {'content-type': 'application/json; charset=utf-8'}));
  return TaskRepository(
    api: ApiClient(settings, session, client: client),
    settings: settings,
    session: session,
  );
}

// без object: заголовок карточки — object ?? name, а находить в тестах надо имя
TaskView _mine(String id) => TaskView(
    Task(id: id, name: 'Личная $id'), null, null, false,
    group: TaskGroup.mine);

TaskView _free(String id) => TaskView(
    Task(id: id, name: 'Пул $id'), null, null, false,
    group: TaskGroup.free, canTake: true);

TaskView _taken(String id) => TaskView(
    Task(id: id, name: 'Чужая $id'), null, null, false,
    group: TaskGroup.taken, takenBy: 'Петров П.П.', takenById: 'p2');

Future<TaskRepository> _open(WidgetTester tester, List<TaskView> tasks) async {
  final repo = _repo()..tasks = tasks;
  await tester.pumpWidget(ChangeNotifierProvider<TaskRepository>.value(
    value: repo,
    child: const MaterialApp(home: TaskListScreen()),
  ));
  await tester.pumpAndSettle();
  return repo;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('три группы: мои сверху, коллеги свёрнуты, но видны заголовком',
      (tester) async {
    await _open(tester, [_taken('T1'), _free('F1'), _mine('M1')]);

    expect(find.text('Мои'), findsOneWidget);
    expect(find.text('Свободные'), findsOneWidget);
    expect(find.text('Взяты коллегами'), findsOneWidget);

    // порядок групп фиксирован, как бы ни были перемешаны задачи
    final mineY = tester.getTopLeft(find.text('Мои')).dy;
    final freeY = tester.getTopLeft(find.text('Свободные')).dy;
    final takenY = tester.getTopLeft(find.text('Взяты коллегами')).dy;
    expect(mineY, lessThan(freeY));
    expect(freeY, lessThan(takenY));

    // свёрнутая группа — заголовок с числом, состав по нажатию: задача не
    // исчезла, но и не мешает
    expect(find.text('Чужая T1'), findsNothing);
    await tester.tap(find.text('Взяты коллегами'));
    await tester.pumpAndSettle();
    expect(find.text('Чужая T1'), findsOneWidget);
    expect(find.text('взял: Петров П.П.'), findsOneWidget);
  });

  testWidgets('пустая группа не показывается вовсе', (tester) async {
    await _open(tester, [_mine('M1'), _free('F1')]);

    expect(find.text('Мои'), findsOneWidget);
    expect(find.text('Свободные'), findsOneWidget);
    expect(find.text('Взяты коллегами'), findsNothing);
  });

  testWidgets('единственной группе заголовок не нужен', (tester) async {
    await _open(tester, [_mine('M1'), _mine('M2')]);

    expect(find.text('Мои'), findsNothing);
    expect(find.text('Личная M1'), findsOneWidget);
  });

  testWidgets('«Взять» — только у свободных, по серверному canTake',
      (tester) async {
    await _open(tester, [_mine('M1'), _free('F1')]);

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
