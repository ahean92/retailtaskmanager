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
import 'package:pulse_tasks/ui/widgets/task_card.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Разбор списка задач (#36915): поиск по локальной базе, сортировка «срочные и
/// просроченные первыми», фильтры по статусу и приоритету, счётчик найденного,
/// сброс в один тап и разбор, переживающий перезапуск.

int _seq = 0;

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

// без object: заголовок карточки — object ?? name, находить в тестах надо имя
TaskView _mine(Task t, {String? statusId, String? statusName}) =>
    TaskView(t, statusId, statusName, false, group: TaskGroup.mine);

Future<TaskRepository> _open(WidgetTester tester, List<TaskView> tasks,
    {TaskRepository? repo, TaskFilter filter = TaskFilter.all}) async {
  final r = (repo ?? _repo())..tasks = tasks;
  await tester.pumpWidget(ChangeNotifierProvider<TaskRepository>.value(
    value: r,
    child: MaterialApp(home: TaskListScreen(filter: filter)),
  ));
  await tester.pumpAndSettle();
  return r;
}

/// Открыть шторку «Сортировка и фильтры», нажать в ней [label] и закрыть её.
Future<void> _tuneTap(WidgetTester tester, String label) async {
  await tester.tap(find.byIcon(Icons.tune));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
  // тап по затемнению над шторкой — закрыть, не трогая выбранного
  await tester.tapAt(const Offset(10, 10));
  await tester.pumpAndSettle();
}

double _y(WidgetTester tester, String text) =>
    tester.getTopLeft(find.text(text)).dy;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  group('модель', () {
    test('priorityId: json → sqlite → обратно', () {
      final t = Task.fromJson({
        'id': 'ST1',
        'priority': 'Срочный',
        'priorityId': 'urgent',
      });
      expect(t.priorityId, 'urgent');
      final back = Task.fromMap(t.toMap());
      expect(back.priorityId, 'urgent');
      expect(back.priority, 'Срочный');
    });

    test('priorityRank: id главнее названия, незнакомый — после известных', () {
      int rank({String? id, String? name}) =>
          Task(id: 'x', priority: name, priorityId: id).priorityRank;
      expect(rank(id: 'urgent'), 0);
      expect(rank(id: 'high'), 1);
      expect(rank(id: 'normal'), 2);
      expect(rank(id: 'low'), 3);
      // старый сервер id не шлёт — ранг по названию сида
      expect(rank(name: 'Срочный'), 0);
      expect(rank(name: 'низкий'), 3);
      // заказчикский «особый» — после известных, но раньше «без приоритета»
      expect(rank(id: 'custom', name: 'Особый'), 4);
      expect(rank(name: 'Особый'), 4);
      expect(rank(), 5);
    });

    test('ListPrefs: json туда-обратно, мусор читается как «по умолчанию»', () {
      const p = ListPrefs(
        chip: TaskFilter.overdue,
        sort: TaskSort.deadline,
        statusIds: {'s1', 's2'},
        priorityKeys: {'urgent'},
      );
      final back = ListPrefs.fromJson(
          (jsonDecode(jsonEncode(p.toJson())) as Map).cast<String, dynamic>());
      expect(back.chip, TaskFilter.overdue);
      expect(back.sort, TaskSort.deadline);
      expect(back.statusIds, {'s1', 's2'});
      expect(back.priorityKeys, {'urgent'});

      final junk = ListPrefs.fromJson({'chip': 'nonsense', 'sort': 42});
      expect(junk.chip, TaskFilter.all);
      expect(junk.sort, TaskSort.route);
      expect(junk.statusIds, isEmpty);
    });
  });

  group('компараторы', () {
    TaskView v(Task t) => TaskView(t, null, null, false);

    test('по сроку: просроченные первыми, без срока — последние', () {
      final cmp = TaskSort.deadline.comparator!;
      final overdue = v(const Task(id: 'A', deadline: '2020-01-01'));
      final future = v(const Task(id: 'B', deadline: '2030-01-01'));
      final none = v(const Task(id: 'C'));
      expect(cmp(overdue, future), lessThan(0));
      expect(cmp(future, none), lessThan(0));
      expect(cmp(none, overdue), greaterThan(0));
    });

    test('по приоритету: срочные первыми', () {
      final cmp = TaskSort.priority.comparator!;
      final urgent = v(const Task(id: 'A', priorityId: 'urgent'));
      final low = v(const Task(id: 'B', priorityId: 'low'));
      final none = v(const Task(id: 'C'));
      expect(cmp(urgent, low), lessThan(0));
      expect(cmp(low, none), lessThan(0));
    });

    test('по дате создания: новые первыми, без даты — последние', () {
      final cmp = TaskSort.created.comparator!;
      final old = v(const Task(id: 'A', postedAt: '2026-08-01T10:00:00'));
      final fresh = v(const Task(id: 'B', postedAt: '2026-08-25T10:00:00'));
      final none = v(const Task(id: 'C'));
      expect(cmp(fresh, old), lessThan(0));
      expect(cmp(old, none), lessThan(0));
    });
  });

  group('экран', () {
    testWidgets('поиск: по части слова, по любому из четырёх полей, со счётчиком',
        (tester) async {
      await _open(tester, [
        _mine(const Task(id: 'ST100', name: 'Выкладка молока')),
        _mine(const Task(id: 'ST200', name: 'Пересчёт', object: 'Санта №7')),
        _mine(const Task(id: 'ST300', name: 'Ценники', assignedTo: 'Петров')),
      ]);

      // по части слова в названии
      await tester.enterText(find.byType(TextField), 'молок');
      await tester.pump();
      expect(find.text('Выкладка молока'), findsOneWidget);
      expect(find.text('Ценники'), findsNothing);
      expect(find.text('Найдено: 1'), findsOneWidget);

      // по объекту (заголовок карточки — сам объект)
      await tester.enterText(find.byType(TextField), 'санта');
      await tester.pump();
      expect(find.text('Санта №7'), findsOneWidget);
      expect(find.text('Выкладка молока'), findsNothing);

      // по исполнителю
      await tester.enterText(find.byType(TextField), 'петров');
      await tester.pump();
      expect(find.text('Ценники'), findsOneWidget);
      expect(find.text('Санта №7'), findsNothing);

      // по номеру
      await tester.enterText(find.byType(TextField), 'st100');
      await tester.pump();
      expect(find.text('Выкладка молока'), findsOneWidget);
      expect(find.text('Найдено: 1'), findsOneWidget);

      // мимо всего — пусто, но с объяснением про разбор, а не про геолокацию
      await tester.enterText(find.byType(TextField), 'нет такого');
      await tester.pump();
      expect(find.text('Ничего не нашлось'), findsOneWidget);
      expect(find.text('Найдено: 0'), findsOneWidget);
    });

    testWidgets('«Показать все» сбрасывает поиск и фильтры одним тапом',
        (tester) async {
      await _open(tester, [
        _mine(const Task(id: 'ST1', name: 'Молоко')),
        _mine(const Task(id: 'ST2', name: 'Хлеб')),
      ]);

      await tester.enterText(find.byType(TextField), 'молоко');
      await tester.pump();
      expect(find.text('Хлеб'), findsNothing);

      await tester.tap(find.text('Показать все'));
      await tester.pumpAndSettle();
      expect(find.text('Молоко'), findsOneWidget);
      expect(find.text('Хлеб'), findsOneWidget);
      expect(find.text('Найдено: 2'), findsNothing,
          reason: 'без разбора строке счётчика нечего объяснять');
    });

    testWidgets('сортировка по сроку: просроченные наверх', (tester) async {
      await _open(tester, [
        _mine(const Task(id: 'A', name: 'Будущая', deadline: '2100-01-01')),
        _mine(const Task(id: 'B', name: 'Просроченная', deadline: '2020-01-01')),
        _mine(const Task(id: 'C', name: 'Без срока')),
      ]);

      // до сортировки — маршрутный порядок, как задачи легли
      expect(_y(tester, 'Будущая'), lessThan(_y(tester, 'Просроченная')));

      await _tuneTap(tester, 'По сроку');
      expect(_y(tester, 'Просроченная'), lessThan(_y(tester, 'Будущая')));
      expect(_y(tester, 'Будущая'), lessThan(_y(tester, 'Без срока')));
    });

    testWidgets('сортировка по приоритету: срочные первыми', (tester) async {
      await _open(tester, [
        _mine(const Task(
            id: 'A', name: 'Низкая', priority: 'Низкий', priorityId: 'low')),
        _mine(const Task(
            id: 'B', name: 'Срочная', priority: 'Срочный', priorityId: 'urgent')),
      ]);

      await _tuneTap(tester, 'По приоритету');
      expect(_y(tester, 'Срочная'), lessThan(_y(tester, 'Низкая')));
    });

    testWidgets('фильтр по статусу — из шторки, с числом', (tester) async {
      await _open(tester, [
        _mine(const Task(id: 'A', name: 'Новая задача'),
            statusId: 'new', statusName: 'Новый'),
        _mine(const Task(id: 'B', name: 'Рабочая задача'),
            statusId: 'in progress', statusName: 'В работе'),
      ]);

      await _tuneTap(tester, 'В работе · 1');
      expect(find.text('Рабочая задача'), findsOneWidget);
      expect(find.text('Новая задача'), findsNothing);
      expect(find.text('Найдено: 1'), findsOneWidget);
    });

    testWidgets('фильтр по приоритету — из шторки', (tester) async {
      await _open(tester, [
        _mine(const Task(
            id: 'A', name: 'Срочная', priority: 'Срочный', priorityId: 'urgent')),
        _mine(const Task(
            id: 'B', name: 'Обычная', priority: 'Обычный', priorityId: 'normal')),
        _mine(const Task(id: 'C', name: 'Без приоритета')),
      ]);

      await _tuneTap(tester, 'Срочный · 1');
      expect(find.text('Срочная'), findsOneWidget);
      expect(find.text('Обычная'), findsNothing);
      expect(find.text('Без приоритета'), findsNothing);
    });

    testWidgets('сохранённый разбор восстанавливается на «Моих задачах»',
        (tester) async {
      final repo = _repo()
        ..listPrefs = const ListPrefs(statusIds: {'in progress'});
      await _open(tester, [
        _mine(const Task(id: 'A', name: 'Новая задача'),
            statusId: 'new', statusName: 'Новый'),
        _mine(const Task(id: 'B', name: 'Рабочая задача'),
            statusId: 'in progress', statusName: 'В работе'),
      ], repo: repo);

      expect(find.text('Рабочая задача'), findsOneWidget);
      expect(find.text('Новая задача'), findsNothing);
      expect(find.text('Найдено: 1'), findsOneWidget);
    });

    testWidgets('список с плитки главной сохранённый разбор не трогает',
        (tester) async {
      final repo = _repo()
        ..listPrefs = const ListPrefs(statusIds: {'in progress'});
      await _open(tester, [
        _mine(const Task(id: 'A', name: 'Новая задача'),
            statusId: 'new', statusName: 'Новый'),
        _mine(const Task(id: 'B', name: 'Рабочая задача'),
            statusId: 'in progress', statusName: 'В работе'),
      ], repo: repo, filter: TaskFilter.open);

      expect(find.text('Новая задача'), findsOneWidget);
      expect(find.text('Рабочая задача'), findsOneWidget);
    });

    testWidgets('тысяча задач: карточки строятся лениво, поиск не перебирает всё',
        (tester) async {
      await _open(tester, [
        for (var i = 0; i < 1000; i++)
          _mine(Task(id: 'ST$i', name: 'Задача $i')),
      ]);

      // ListView.builder: на экране — дюжина карточек, а не тысяча
      expect(tester.widgetList(find.byType(TaskCard)).length, lessThan(30));

      await tester.enterText(find.byType(TextField), 'задача 999');
      await tester.pump();
      expect(find.text('Задача 999'), findsOneWidget);
      expect(find.text('Найдено: 1'), findsOneWidget);
    });
  });

  group('база', () {
    test('разбор переживает перезапуск: хранится в базе пользователя', () async {
      final settings = Settings(baseUrl: 'http://test.local:9080');
      final session = Session(
        login: 'prefs${_seq++}', // логин уникален: имя базы содержит его
        name: 'Иванов И.И.',
        token: 'token',
        signedIn: true,
        performerId: 'p1',
      );
      final client = MockClient((request) async => http.Response.bytes(
          utf8.encode('[]'), 200,
          headers: {'content-type': 'application/json; charset=utf-8'}));
      final api = ApiClient(settings, session, client: client);

      final repo =
          TaskRepository(api: api, settings: settings, session: session);
      await repo.updateSettings(settings); // открывает базу этого логина
      await repo.saveListPrefs(const ListPrefs(
        chip: TaskFilter.open,
        sort: TaskSort.deadline,
        statusIds: {'in progress'},
        priorityKeys: {'urgent'},
      ));
      await repo.localDb!.close(); // «перезапуск»: приложение убито

      final again =
          TaskRepository(api: api, settings: settings, session: session);
      await again.updateSettings(settings);
      expect(again.listPrefs.chip, TaskFilter.open);
      expect(again.listPrefs.sort, TaskSort.deadline);
      expect(again.listPrefs.statusIds, {'in progress'});
      expect(again.listPrefs.priorityKeys, {'urgent'});
      await again.localDb!.close();
    });
  });
}
