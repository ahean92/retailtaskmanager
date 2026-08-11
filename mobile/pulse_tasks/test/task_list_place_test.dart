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
import 'package:pulse_tasks/ui/task_list_screen.dart';

import 'fake_phone.dart';

/// Шапка списка задач: где человек, по мнению приложения, находится — и почему он видит
/// именно эти задачи.
///
/// Проверяется то, ради чего экран делался: объект и расстояние видны без нажатия, при
/// двух соседях между ними можно переключиться, «Обновить местоположение» честно
/// перестраивает шапку, а три пустоты остаются тремя разными сообщениями. Сам выбор
/// объекта по ответу сервера разобран в place_test.dart.

/// Что вернёт `apiNearbyObjects` в этот раз. Меняется прямо посреди теста — так человек
/// и переезжает в соседний магазин.
late List<Map<String, dynamic>> nearby;

TaskRepository _repo(FakePhone phone) {
  final settings = Settings(baseUrl: 'http://test.local:9080');
  final session = Session(
    login: 'ivanov',
    name: 'Иванов И.И.',
    token: 'token',
    signedIn: true,
    geoRequired: true,
  );
  final client = MockClient((request) async {
    final body = request.url.path.endsWith('apiNearbyObjects')
        ? jsonEncode(nearby)
        : '[]';
    return http.Response.bytes(utf8.encode(body), 200,
        headers: {'content-type': 'application/json; charset=utf-8'});
  });
  return TaskRepository(
    api: ApiClient(settings, session, client: client),
    settings: settings,
    session: session,
    geo: Geo(platform: phone),
  );
}

Map<String, dynamic> _object(String id, String name, double distance,
        {bool nearby = true, String? address}) =>
    {
      'id': id,
      'name': name,
      'distance': distance,
      if (address != null) 'address': address,
      if (nearby) 'nearby': true,
    };

/// Список задач под вошедшим, которого уже определили: гейт свою работу сделал, экран
/// открывается на готовом месте и GPS больше не дёргает.
Future<TaskRepository> _open(WidgetTester tester, {FakePhone? phone}) async {
  final repo = _repo(phone ?? FakePhone(measured: fixAt()));
  await repo.locate();
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
    nearby = [_object('o1', 'Магазин №1', 120)];
  });

  testWidgets('в шапке — объект и расстояние до него', (tester) async {
    await _open(tester);

    expect(find.text('Магазин №1'), findsOneWidget);
    expect(find.textContaining('120 м'), findsOneWidget);
    expect(find.text('Обновить'), findsOneWidget);
  });

  testWidgets('объект один — выбирать не предлагают', (tester) async {
    await _open(tester);

    expect(find.byIcon(Icons.unfold_more), findsNothing);
    await tester.tap(find.text('Магазин №1'));
    await tester.pumpAndSettle();
    expect(find.text('Вы на каком объекте?'), findsNothing);
  });

  testWidgets('при двух объектах рядом можно переключиться между ними',
      (tester) async {
    nearby = [
      _object('o1', 'Магазин №1', 40, address: 'ТЦ «Столица», 1 этаж'),
      _object('o2', 'Магазин №2', 90, address: 'ТЦ «Столица», 2 этаж'),
    ];
    final repo = await _open(tester);

    // по умолчанию ближайший, и никто ничего не спрашивал
    expect(repo.place.objectId, 'o1');
    expect(find.text('Вы на каком объекте?'), findsNothing);

    await tester.tap(find.text('Магазин №1'));
    await tester.pumpAndSettle();

    // остальные — из шапки, с расстоянием у каждого
    expect(find.text('Вы на каком объекте?'), findsOneWidget);
    expect(find.text('40 м'), findsOneWidget);
    expect(find.text('90 м'), findsOneWidget);

    await tester.tap(find.text('Магазин №2'));
    await tester.pumpAndSettle();

    expect(repo.place.objectId, 'o2');
    expect(find.text('Магазин №2'), findsOneWidget);
    expect(find.textContaining('90 м'), findsOneWidget);
  });

  testWidgets('«Обновить местоположение» перестраивает шапку под новое место',
      (tester) async {
    final phone = FakePhone(measured: fixAt());
    await _open(tester, phone: phone);
    expect(find.text('Магазин №1'), findsOneWidget);
    final measured = phone.measurements;

    // человек перешёл в соседний магазин
    nearby = [_object('o7', 'Магазин №7', 60)];
    await tester.tap(find.text('Обновить'));
    await tester.pumpAndSettle();

    expect(phone.measurements, greaterThan(measured),
        reason: 'кнопка спрашивает телефон заново, а не показывает сохранённое');
    expect(find.text('Магазин №7'), findsOneWidget);
    expect(find.text('Магазин №1'), findsNothing);
  });

  testWidgets('открытие списка само по себе GPS не дёргает', (tester) async {
    final phone = FakePhone(measured: fixAt());
    await _open(tester, phone: phone);
    // ровно один замер — тот, что сделал вход; экран открылся на готовом месте
    expect(phone.measurements, 1);
  });

  group('пустой список объясняет, почему он пуст', () {
    testWidgets('задач на этом объекте нет', (tester) async {
      await _open(tester);
      expect(find.text('На объекте «Магазин №1» задач нет'), findsOneWidget);
    });

    testWidgets('рядом нет объектов с координатами', (tester) async {
      nearby = [];
      await _open(tester);
      expect(find.text('Рядом нет объектов с координатами'), findsOneWidget);
      expect(find.text('Обновить местоположение'), findsOneWidget);
    });

    testWidgets('вы в 12 км от ближайшего объекта', (tester) async {
      nearby = [_object('o9', 'Магазин №9', 12300, nearby: false)];
      await _open(tester);

      expect(find.text('Рядом нет объектов'), findsOneWidget);
      expect(find.textContaining('«Магазин №9»'), findsWidgets);
      expect(find.textContaining('12 км'), findsWidgets);
    });

    testWidgets('координат нет вовсе — это тоже отдельная новость',
        (tester) async {
      await _open(tester, phone: FakePhone(measured: null)); // сигнал не поймался
      expect(find.text('Неизвестно, где вы'), findsOneWidget);
    });
  });

  testWidgets('роли без геопривязки шапку про объект не показывают',
      (tester) async {
    final repo = _repo(FakePhone(measured: fixAt()))..session.geoRequired = false;
    await tester.pumpWidget(ChangeNotifierProvider<TaskRepository>.value(
      value: repo,
      child: const MaterialApp(home: TaskListScreen()),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Обновить'), findsNothing);
    expect(find.text('Задач нет'), findsOneWidget);
  });
}
