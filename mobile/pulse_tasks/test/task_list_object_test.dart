import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/geo.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/data/task_repository.dart';
import 'package:pulse_tasks/models/home.dart';
import 'package:pulse_tasks/models/task.dart';
import 'package:pulse_tasks/ui/task_list_screen.dart';

import 'fake_phone.dart';

/// Список, открытый с плитки сводки, сужен до её магазина: плитка и список обязаны
/// отвечать на один вопрос. Человек, увидевший «1 здесь» и открывший шесть строк,
/// перестаёт верить обеим цифрам.

TaskRepository _repo({bool geoRequired = false}) {
  final settings = Settings(baseUrl: 'http://test.local:9080');
  final session = Session(
    login: 'ivanov',
    name: 'Иванов И.И.',
    token: 'token',
    signedIn: true,
    geoRequired: geoRequired,
  );
  final client = MockClient((request) async {
    final body = request.url.path.endsWith('apiNearbyObjects')
        ? jsonEncode([
            {'id': 'o1', 'name': 'Магазин №1', 'distance': 120}
          ])
        : '[]';
    return http.Response.bytes(utf8.encode(body), 200,
        headers: {'content-type': 'application/json; charset=utf-8'});
  });
  return TaskRepository(
    api: ApiClient(settings, session, client: client),
    settings: settings,
    session: session,
    geo: Geo(platform: FakePhone(measured: fixAt())),
  );
}

TaskView _task(String id, String object, String objectId) => TaskView(
    Task(id: id, name: 'Задача $id', object: object, objectId: objectId),
    null,
    null,
    false);

/// Кэш демо-набора: шесть открытых задач по одной на шести объектах.
List<TaskView> _sixShops() => [
      for (var i = 1; i <= 6; i++) _task('$i', 'Санта №$i', 's$i'),
    ];

Future<TaskRepository> _open(WidgetTester tester, {String? objectId}) async {
  final repo = _repo()
    ..tasks = _sixShops()
    ..home = HomeLayout(objects: [
      for (var i = 1; i <= 6; i++) HomeObject(id: 's$i', name: 'Санта №$i'),
    ]);
  await tester.pumpWidget(ChangeNotifierProvider<TaskRepository>.value(
    value: repo,
    child: MaterialApp(home: TaskListScreen(objectId: objectId)),
  ));
  await tester.pumpAndSettle();
  return repo;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('список с плитки — только задачи её магазина', (tester) async {
    await _open(tester, objectId: 's3');

    expect(find.text('Санта №3'), findsOneWidget);
    expect(find.text('Санта №1'), findsNothing);
    // счётчики на фильтрах — про этот же магазин, а не про всю сеть
    expect(find.text('Все задачи · 1'), findsOneWidget);
  });

  testWidgets('без магазина список остаётся полным', (tester) async {
    await _open(tester);

    expect(find.text('Все задачи · 6'), findsOneWidget);
  });

  testWidgets('пустой суженный список называет магазин', (tester) async {
    final repo = _repo()
      ..home = const HomeLayout(
          objects: [HomeObject(id: 's7', name: 'Санта №7, Пинск')]);
    await tester.pumpWidget(ChangeNotifierProvider<TaskRepository>.value(
      value: repo,
      child: const MaterialApp(home: TaskListScreen(objectId: 's7')),
    ));
    await tester.pumpAndSettle();

    expect(find.text('На объекте «Санта №7, Пинск» задач нет'), findsOneWidget);
  });

  // «Здесь» на плитке для работающего по геолокации — магазин, на котором он стоит,
  // а не первый присланный по алфавиту: список под тапом — того же магазина.
  test('выбранный объект: свой выбор, потом место, потом первый присланный',
      () async {
    final repo = _repo(geoRequired: true)
      ..home = const HomeLayout(objects: [
        HomeObject(id: 'a0', name: 'А-первый по алфавиту'),
        HomeObject(id: 'o1', name: 'Магазин №1'),
      ]);
    expect(repo.objectId, 'a0', reason: 'место ещё не определено');

    await repo.locate();
    expect(repo.objectId, 'o1', reason: 'человек стоит на «Магазине №1»');

    repo.settings.objectId = 'a0';
    expect(repo.objectId, 'a0', reason: 'свой выбор старше места');
  });
}
