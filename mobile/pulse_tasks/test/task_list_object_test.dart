import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:pulse_tasks/app_controllers.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/geo.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/models/task_view.dart';
import 'package:pulse_tasks/models/home.dart';
import 'package:pulse_tasks/models/task.dart';
import 'package:pulse_tasks/ui/task_list_screen.dart';

import 'fake_phone.dart';
import 'support/fake_server.dart';
import 'support/test_env.dart';

/// Список, открытый с плитки сводки, сужен до её магазина: плитка и список обязаны
/// отвечать на один вопрос. Человек, увидевший «1 здесь» и открывший шесть строк,
/// перестаёт верить обеим цифрам.

/// [slice] — чем сервер отвечает на срез объекта (apiTasks scope=object). Так список с
/// плитки открывали сборки до 1.0.3 включительно, и сервер тогда отдавал в срезе объект со
/// всем вложенным, включая вложенные места, а задачи — на момент запроса, а не плитки.
AppControllers _repo(
    {bool geoRequired = false, List<Map<String, Object?>> slice = const []}) {
  final settings = Settings(baseUrl: 'http://test.local:9080');
  final session = Session(
    login: 'ivanov',
    name: 'Иванов И.И.',
    token: 'token',
    signedIn: true,
    geoRequired: geoRequired,
  );
  final client = MockClient((request) async {
    final path = request.url.path;
    final body = path.endsWith('apiNearbyObjects')
        ? jsonEncode([
            {'id': 'o1', 'name': 'Магазин №1', 'distance': 120}
          ])
        : path.endsWith('apiTasks') &&
                request.url.queryParameters['scope'] == 'object'
            ? jsonEncode(slice)
            : '[]';
    return okJson(body);
  });
  return AppControllers(
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

Future<AppControllers> _open(WidgetTester tester, {String? objectId}) async {
  final app = _repo()
    ..repo.tasks = _sixShops()
    ..home.layout = HomeLayout(objects: [
      for (var i = 1; i <= 6; i++) HomeObject(id: 's$i', name: 'Санта №$i'),
    ]);
  await tester.pumpWidget(MultiProvider(
    providers: app.providers,
    child: MaterialApp(home: TaskListScreen(objectId: objectId)),
  ));
  await tester.pumpAndSettle();
  return app;
}

void main() {
  initTestEnv();

  setUp(resetMockStores);

  /// База вошедшего открыта, как у телефона после входа: без неё репозиторий к серверу не
  /// ходит вовсе, и список с плитки нечем было бы проверить. Кэш — тот, что задан тестом.
  Future<void> openBase(WidgetTester tester, AppControllers app,
      List<TaskView> cached) async {
    await tester.runAsync(() => app.base.rebind());
    app.repo.tasks = cached;
  }

  testWidgets('список с плитки — только задачи её магазина', (tester) async {
    await _open(tester, objectId: 's3');

    expect(find.text('Задача 3'), findsOneWidget);
    expect(find.text('Задача 1'), findsNothing);
    // счётчик на чипе группы — про этот же магазин, а не про всю сеть
    expect(find.text('Мои'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
  });

  // Плитка «На сегодня» показывала 0, а список под ней — две задачи: их назначили после
  // последней синхронизации, и список при открытии дотягивал их с сервера, а плитка оставалась
  // прежней. Плитка и список — один снимок; новое приезжает в оба разом, синхронизацией.
  testWidgets('список с плитки — тот же снимок, что плитка: новое с сервера не дотягивается',
      (tester) async {
    final today = DateTime.now().toIso8601String().substring(0, 10);
    final app = _repo(slice: [
      for (final id in ['N1', 'N2'])
        {
          'id': id,
          'name': 'Задача $id',
          'object': 'Санта №3',
          'objectId': 's3',
          'placeId': 's3',
          'deadline': today,
          'dueToday': 1,
          'overdue': 0,
          'mine': true,
          'assigned': true,
        }
    ])
      ..home.layout = HomeLayout(objects: [
        for (var i = 1; i <= 6; i++) HomeObject(id: 's$i', name: 'Санта №$i'),
      ]);
    await openBase(tester, app, _sixShops());
    await tester.pumpWidget(MultiProvider(
      providers: app.providers,
      child: const MaterialApp(
          home: TaskListScreen(filter: TaskFilter.today, objectId: 's3')),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Задача N1'), findsNothing);
    expect(find.text('Задача N2'), findsNothing);
    await tester.runAsync(() => app.account.signOut()); // закрыть базу за собой
  });

  // «Здесь» на плитке — место и то, что стоит в нём без своих координат (касса, весы).
  // Отдел со своими координатами — своё место со своей плиткой, и в списке магазина его
  // задачи считались бы второй раз.
  testWidgets('список с плитки магазина — без задач вложенного места', (tester) async {
    Task task(String id, String objectId, String placeId) => Task(
        id: id,
        name: 'Задача $id',
        object: objectId,
        objectId: objectId,
        placeId: placeId);
    final cached = [task('A', 's1', 's1'), task('B', 'eq1', 's1'), task('C', 'sub1', 'sub1')];
    final app = _repo(slice: [
      for (final t in cached)
        {
          'id': t.id,
          'name': t.name,
          'object': t.object,
          'objectId': t.objectId,
          'placeId': t.placeId,
          'mine': true,
          'assigned': true,
        }
    ])
      ..home.layout = const HomeLayout(objects: [
        HomeObject(id: 's1', name: 'Санта №1'),
        HomeObject(id: 'sub1', name: 'Санта №1, отдел'),
      ]);
    await openBase(
        tester, app, [for (final t in cached) TaskView(t, null, null, false)]);
    await tester.pumpWidget(MultiProvider(
      providers: app.providers,
      child: const MaterialApp(home: TaskListScreen(objectId: 's1')),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Задача A'), findsOneWidget);
    expect(find.text('Задача B'), findsOneWidget, reason: 'весы стоят в магазине');
    expect(find.text('Задача C'), findsNothing, reason: 'у отдела своё место');
    await tester.runAsync(() => app.account.signOut()); // закрыть базу за собой
  });

  testWidgets('без магазина список остаётся полным', (tester) async {
    await _open(tester);

    // счётчик чипа «Мои» — про всю сеть; карточки ленивые, до шестой листать
    expect(find.text('Мои'), findsOneWidget);
    expect(find.text('6'), findsOneWidget);
    expect(find.text('Задача 1'), findsOneWidget);
  });

  testWidgets('пустой суженный список называет магазин', (tester) async {
    final app = _repo()
      ..home.layout = const HomeLayout(
          objects: [HomeObject(id: 's7', name: 'Санта №7, Пинск')]);
    await tester.pumpWidget(MultiProvider(
      providers: app.providers,
      child: const MaterialApp(home: TaskListScreen(objectId: 's7')),
    ));
    await tester.pumpAndSettle();

    expect(find.text('На объекте «Санта №7, Пинск» задач нет'), findsOneWidget);
  });

  // «Здесь» на плитке для работающего по геолокации — магазин, на котором он стоит,
  // а не первый присланный по алфавиту: список под тапом — того же магазина.
  test('выбранный объект: свой выбор, потом место, потом первый присланный',
      () async {
    final app = _repo(geoRequired: true)
      ..home.layout = const HomeLayout(objects: [
        HomeObject(id: 'a0', name: 'А-первый по алфавиту'),
        HomeObject(id: 'o1', name: 'Магазин №1'),
      ]);
    expect(app.home.objectId, 'a0', reason: 'место ещё не определено');

    await app.location.locate();
    expect(app.home.objectId, 'o1', reason: 'человек стоит на «Магазине №1»');

    app.settings.objectId = 'a0';
    expect(app.home.objectId, 'a0', reason: 'свой выбор старше места');
  });
}
