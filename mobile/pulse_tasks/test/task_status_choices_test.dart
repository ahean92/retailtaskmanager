import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:pulse_tasks/app_controllers.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/models/task.dart';
import 'package:pulse_tasks/models/task_status.dart';
import 'package:pulse_tasks/models/task_view.dart';
import 'package:pulse_tasks/ui/task_detail_screen.dart';
import 'support/test_env.dart';
import 'support/fake_server.dart';

/// Куда задачу можно перевести, говорит сервер (`nextStatuses` в apiTasks): правила
/// переходов по ролям, статусы типа задачи, «Новый» при начатом выполнении. Телефон
/// предлагал весь справочник, и запрещённый переход уезжал в очередь и оседал в «Не
/// отправлено» отказом сервера. Теперь переключатель — только из слова сервера, а
/// старая выдача без ключа работает, как раньше.

const _all = [
  TaskStatus(id: 'new', name: 'Новая', sortingOrder: 1),
  TaskStatus(id: 'in progress', name: 'В работе', sortingOrder: 2),
  TaskStatus(id: 'done', name: 'Выполнено', closed: true, sortingOrder: 3),
  TaskStatus(id: 'canceled', name: 'Отменена', closed: true, sortingOrder: 4),
];

List<String> _ids(List<TaskStatus> l) => [for (final s in l) s.id];

TaskView _view(Task t,
        {String? statusId,
        bool authoredOnly = false,
        bool watchedOnly = false}) =>
    TaskView(t, statusId ?? t.statusId, null, statusId != null,
        authoredOnly: authoredOnly, watchedOnly: watchedOnly);

int _seq = 0;

class _Server {
  final calls = <String>[];
  final posts = <String>[];
  List<Map<String, Object?>> tasks = [];

  late final Session session;
  late final ApiClient api;

  _Server(Settings settings) {
    session = Session(
      login: 'ivanova${DateTime.now().microsecondsSinceEpoch}_${_seq++}',
      name: 'Иванова И.И.',
      token: 'token',
      signedIn: true,
      performerId: 'p1',
    );
    api = ApiClient(settings, session, client: MockClient((request) async {
      final action = actionOf(request);
      calls.add(action);
      if (request.method == 'POST') {
        posts.add('$action ${request.body}');
      }
      final body = switch (action) {
        'apiTasks' => jsonEncode(tasks),
        'apiStatuses' => jsonEncode([
            for (final s in _all)
              {
                'id': s.id,
                'name': s.name,
                if (s.closed) 'closed': true,
                'sortingOrder': s.sortingOrder,
              }
          ]),
        _ => '[]',
      };
      return okJson(body);
    }));
  }
}

Map<String, Object?> _task({
  String id = 'ST1',
  String statusId = 'in progress',
  Object? next,
  bool assigned = true,
  bool authored = false,
}) =>
    {
      'id': id,
      'name': 'Выкладка молочки',
      'object': 'Магазин №1',
      'objectId': 'o1',
      'typeId': 'issue',
      'statusId': statusId,
      'status': statusId,
      if (assigned) 'assigned': true,
      if (authored) 'authored': true,
      if (next != null) 'nextStatuses': next,
    };

void main() {
  initTestEnv();

  group('ключ nextStatuses', () {
    test('список объектов {id} — ровно эти статусы, в том же порядке', () {
      final t = Task.fromJson(_task(next: [
        {'id': 'done'},
        {'id': 'canceled'},
      ]));
      expect(t.nextStatusIds, ['done', 'canceled']);
    });

    test('ключа нет — «сервер не говорил», а не «никуда»', () {
      expect(Task.fromJson(_task()).nextStatusIds, isNull);
    });

    test('пустой список — «никуда», и он не путается со старой выдачей', () {
      expect(Task.fromJson(_task(next: [])).nextStatusIds, isEmpty);
    });

    test('кэш sqlite держит разницу между null и []', () {
      final none = Task.fromMap(Task.fromJson(_task()).toMap());
      final empty = Task.fromMap(Task.fromJson(_task(next: [])).toMap());
      final some = Task.fromMap(Task.fromJson(_task(next: [
        {'id': 'done'}
      ])).toMap());
      expect(none.nextStatusIds, isNull);
      expect(empty.nextStatusIds, isEmpty);
      expect(some.nextStatusIds, ['done']);
    });
  });

  group('что предложить переключателем', () {
    test('исполнителю — текущий и то, что разрешил сервер', () {
      final t = Task.fromJson(_task(next: [
        {'id': 'done'}
      ]));
      expect(_ids(_view(t).statusChoices(_all)), ['in progress', 'done'],
          reason: '«Новый» и «Отменена» правила не разрешают — их нет');
    });

    test('смена в очереди: видны и серверный статус, и выбранный', () {
      final t = Task.fromJson(_task(next: [
        {'id': 'done'},
      ]));
      final v = _view(t, statusId: 'canceled');
      expect(_ids(v.statusChoices(_all)), ['in progress', 'done', 'canceled'],
          reason: 'серверный — чтобы передумать, выбранный — чтобы было видно, '
              'что выбрано');
    });

    test('старый сервер — весь справочник исполнителю, ничего читающему', () {
      final t = Task.fromJson(_task());
      expect(_ids(_view(t).statusChoices(_all)), _ids(_all));
      expect(_view(t, authoredOnly: true).statusChoices(_all), isEmpty);
      expect(_view(t, watchedOnly: true).statusChoices(_all), isEmpty);
    });

    test('автору — то, что ему разрешают правила', () {
      final t = Task.fromJson(_task(
          assigned: false,
          authored: true,
          next: [
            {'id': 'canceled'}
          ]));
      expect(_ids(_view(t, authoredOnly: true).statusChoices(_all)),
          ['in progress', 'canceled']);
    });

    test('«никуда» — остаётся один текущий', () {
      final t = Task.fromJson(_task(next: []));
      expect(_ids(_view(t).statusChoices(_all)), ['in progress']);
    });
  });

  group('карточка', () {
    late Settings settings;
    late _Server server;

    setUp(() {
      resetMockStores();
      settings = Settings(baseUrl: 'http://test.local:9080');
      server = _Server(settings);
    });

    Future<AppControllers> open(WidgetTester tester) async {
      final app = AppControllers(
          api: server.api, settings: settings, session: server.session);
      await app.account.updateSettings(settings);
      await app.repo.refresh();
      await tester.pumpWidget(MultiProvider(
        providers: app.providers,
        child: const MaterialApp(home: TaskDetailScreen(taskId: 'ST1')),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      return app;
    }

    testWidgets('переключатель — только разрешённые сервером статусы',
        (tester) async {
      await tester.runAsync(() async {
        server.tasks = [
          _task(next: [
            {'id': 'done'}
          ])
        ];
        final app = await open(tester);

        expect(find.widgetWithText(ChoiceChip, 'В работе'), findsOneWidget);
        expect(find.widgetWithText(ChoiceChip, 'Выполнено'), findsOneWidget);
        expect(find.widgetWithText(ChoiceChip, 'Новая'), findsNothing);
        expect(find.widgetWithText(ChoiceChip, 'Отменена'), findsNothing);
        app.dispose();
      });
    });

    testWidgets('переводить некуда — пояснение вместо переключателя',
        (tester) async {
      await tester.runAsync(() async {
        server.tasks = [_task(next: [])];
        final app = await open(tester);

        expect(find.byType(ChoiceChip), findsNothing);
        expect(find.textContaining('в другой статус вам нельзя'), findsOneWidget);
        app.dispose();
      });
    });

    testWidgets('автор переводит статус, если правила разрешают',
        (tester) async {
      await tester.runAsync(() async {
        server.tasks = [
          _task(assigned: false, authored: true, next: [
            {'id': 'canceled'}
          ])
        ];
        final app = await open(tester);

        final chip = find.widgetWithText(ChoiceChip, 'Отменена');
        expect(chip, findsOneWidget);
        expect(tester.widget<ChoiceChip>(chip).onSelected, isNotNull,
            reason: 'автору статус — решение по задаче, а не работа на месте');
        app.dispose();
      });
    });

    testWidgets('принятая смена — следом свежая выдача с новыми переходами',
        (tester) async {
      await tester.runAsync(() async {
        server.tasks = [
          _task(next: [
            {'id': 'done'}
          ])
        ];
        final app = await open(tester);
        server.calls.clear();
        // сервер, приняв смену, считает переходы уже от нового статуса
        server.tasks = [_task(statusId: 'done', next: [])];

        await tester.tap(find.widgetWithText(ChoiceChip, 'Выполнено'));
        for (var i = 0; i < 20 && !server.calls.contains('apiTasks'); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));

        expect(server.posts.single, contains('"statusId":"done"'));
        expect(server.calls.indexOf('apiSetStatus'),
            lessThan(server.calls.indexOf('apiTasks')),
            reason: 'выдача запрошена после того, как смена принята');
        final v = app.repo.viewOf('ST1')!;
        expect(v.statusId, 'done');
        expect(v.task.nextStatusIds, isEmpty,
            reason: 'кэш несёт переходы от нового статуса, а не от прежнего');
        app.dispose();
      });
    });
  });
}
