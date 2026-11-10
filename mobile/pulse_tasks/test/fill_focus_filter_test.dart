import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:pulse_tasks/app_controllers.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/models/place.dart';
import 'package:pulse_tasks/ui/fill_screen.dart';
import 'package:pulse_tasks/ui/widgets/fill_field_tile.dart';
import 'support/fake_server.dart';
import 'support/test_env.dart';

final int _runId = DateTime.now().microsecondsSinceEpoch;
int _seq = 0;

class _Server {
  final calls = <String>[];
  final textByField = <String, String>{};

  final List<Map<String, Object?>> fields = [
    {
      'sectionIndex': 1,
      'section': 'Зал',
      'fieldIndex': 1,
      'code': 'r1',
      'name': 'Обязательное в зале',
      'required': true,
    },
    {
      'sectionIndex': 1,
      'section': 'Зал',
      'fieldIndex': 2,
      'code': 'temp',
      'name': 'Температура витрины',
      'type': 'number',
      'maxNorm': 6,
      'number': 11,
    },
    {
      'sectionIndex': 1,
      'section': 'Зал',
      'fieldIndex': 3,
      'code': 'ok1',
      'name': 'Чистота в зале',
      'text': 'чисто',
    },
    {
      'sectionIndex': 2,
      'section': 'Склад',
      'fieldIndex': 1,
      'code': 'r2',
      'name': 'Обязательное на складе',
      'required': true,
    },
    {
      'sectionIndex': 2,
      'section': 'Склад',
      'fieldIndex': 2,
      'code': 'ok2',
      'name': 'Порядок на складе',
      'text': 'порядок',
    },
    {
      'sectionIndex': 3,
      'section': 'Касса',
      'fieldIndex': 1,
      'code': 'ok3',
      'name': 'Касса открыта',
      'text': 'открыта',
    },
  ];

  late final Session session;
  late final ApiClient api;

  Map<String, Object?> get info => {
    'object': 'Магазин №1',
    'template': 'Чек-лист',
    'hasScored': false,
    'percent': 0.0,
    'passed': false,
    'answered': 4,
    'total': 6,
    'finished': false,
  };

  _Server(Settings settings) {
    session = Session(
      login: 'focus$_runId${_seq++}',
      name: 'Иванов И.И.',
      token: 'token',
      signedIn: true,
      performerId: 'p1',
    );
    api = ApiClient(
      settings,
      session,
      client: MockClient((request) async {
        final action = actionOf(request);
        calls.add(action);
        switch (action) {
          case 'apiTasks':
            return okJson(
              jsonEncode([
                {
                  'id': 'ST1',
                  'name': 'Проверка',
                  'objectId': 'o1',
                  'distance': 40.0,
                  'typeId': 'checklist',
                },
              ]),
            );
          case 'apiExecutionInfo':
            return okJson(jsonEncode([info]));
          case 'apiExecutionBundle':
            return okJson(bundleJson(info: info, fields: fields));
          case 'apiSetField':
            final b = jsonDecode(request.body) as Map<String, dynamic>;
            final t = b['text'] as String?;
            if (t != null) textByField[b['field'] as String] = t;
            return okJson('[]');
          default:
            return okJson('[]');
        }
      }),
    );
  }
}

Place _atObject() => Place(
  objects: const [NearbyObject(id: 'o1', name: 'Магазин №1', distance: 40)],
  objectId: 'o1',
  latitude: 53.9,
  longitude: 27.56,
  answered: true,
);

void main() {
  initTestEnv();

  late Settings settings;
  late _Server server;

  setUp(() {
    resetMockStores();
    settings = Settings(baseUrl: 'http://test.local:9080');
    server = _Server(settings);
  });

  Future<AppControllers> openForm() async {
    final app = AppControllers(
      api: server.api,
      settings: settings,
      session: server.session,
    );
    await app.account.updateSettings(settings);
    app.location.place = _atObject();
    await app.repo.refresh();
    return app;
  }

  Future<void> until(bool Function() done, WidgetTester tester) async {
    for (var i = 0; i < 100 && !done(); i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<void> closeForm(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump();
  }

  Finder tileOf(String label) => find.ancestor(
    of: find.textContaining(label),
    matching: find.byType(FillFieldTile),
  );

  bool shown(String label) => tileOf(label).evaluate().isNotEmpty;

  String focus(WidgetTester tester) =>
      (((tester.widget(find.byKey(const ValueKey('fillFocus'))) as dynamic)
                          .selected
                      as Set)
                  .single
              as Enum)
          .name;

  Future<void> pumpForm(WidgetTester tester, AppControllers app) {
    tester.view.physicalSize = const Size(1080, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    return tester.pumpWidget(
      MultiProvider(
        providers: app.providers,
        child: MaterialApp(
          home: Navigator(
            onGenerateRoute:
                (_) => MaterialPageRoute(
                  builder: (_) => const FillScreen(taskId: 'ST1'),
                ),
          ),
        ),
      ),
    );
  }

  Future<void> openSettled(WidgetTester tester) async {
    await until(() => shown('Обязательное в зале'), tester);
    await until(() => find.text('Далее').evaluate().isNotEmpty, tester);
  }

  Future<void> pick(WidgetTester tester, String label) async {
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('fillFocus')),
        matching: find.text(label),
      ),
    );
    await tester.pump();
  }

  Future<void> turn(
    WidgetTester tester,
    String button,
    bool Function() arrived,
  ) async {
    await tester.tap(find.text(button));
    await until(arrived, tester);
    await tester.pump(const Duration(milliseconds: 400));
  }

  bool text(String s) => find.text(s).evaluate().isNotEmpty;

  testWidgets(
    'экран открывается на «Все», отбор идёт по признакам бейджа и чипа',
    (tester) async {
      await tester.runAsync(() async {
        final app = await openForm();
        await pumpForm(tester, app);
        await openSettled(tester);

        expect(focus(tester), 'all');
        expect(shown('Обязательное в зале'), isTrue);
        expect(shown('Температура витрины'), isTrue);
        expect(shown('Чистота в зале'), isTrue);

        await pick(tester, 'Несоответствия');
        expect(focus(tester), 'nonconformity');
        expect(shown('Температура витрины'), isTrue);
        expect(shown('Обязательное в зале'), isFalse);
        expect(shown('Чистота в зале'), isFalse);

        await pick(tester, 'Незаполненные');
        expect(shown('Обязательное в зале'), isTrue);
        expect(shown('Температура витрины'), isFalse);
        expect(shown('Чистота в зале'), isFalse);

        await pick(tester, 'Все');
        expect(shown('Обязательное в зале'), isTrue);
        expect(shown('Температура витрины'), isTrue);
        expect(shown('Чистота в зале'), isTrue);

        await closeForm(tester);
      });
    },
  );

  testWidgets('пустая страница говорит, почему пуста; чипы разделов прежние', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final app = await openForm();
      await pumpForm(tester, app);
      await openSettled(tester);

      await pick(tester, 'Несоответствия');
      await turn(tester, 'Далее', () => text('В разделе нет несоответствий'));
      expect(find.text('В разделе нет несоответствий'), findsOneWidget);
      for (final s in ['Зал', 'Склад', 'Касса']) {
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('sectionChipStrip')),
            matching: find.text(s),
          ),
          findsOneWidget,
        );
      }

      await pick(tester, 'Незаполненные');
      expect(shown('Обязательное на складе'), isTrue);
      expect(shown('Порядок на складе'), isFalse);

      await turn(tester, 'Далее', () => text('В разделе всё заполнено'));
      expect(find.text('В разделе всё заполнено'), findsOneWidget);

      await closeForm(tester);
    });
  });

  testWidgets('отвеченный в «Незаполненных» остаётся до ухода со страницы', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final app = await openForm();
      await pumpForm(tester, app);
      await openSettled(tester);

      await pick(tester, 'Незаполненные');
      await tester.enterText(
        find.descendant(
          of: tileOf('Обязательное в зале'),
          matching: find.byType(TextField),
        ),
        'есть',
      );
      await tester.pump();
      FocusManager.instance.primaryFocus?.unfocus();
      await until(() => server.textByField['r1'] != null, tester);
      expect(server.textByField['r1'], 'есть');
      await tester.pump();
      expect(shown('Обязательное в зале'), isTrue);

      await turn(tester, 'Далее', () => shown('Обязательное на складе'));
      await turn(tester, 'Назад', () => text('В разделе всё заполнено'));
      expect(shown('Обязательное в зале'), isFalse);
      expect(find.text('В разделе всё заполнено'), findsOneWidget);

      await closeForm(tester);
    });
  });

  testWidgets(
    'отказ под «Несоответствиями» переводит на «Все» и ведёт к дыре',
    (tester) async {
      await tester.runAsync(() async {
        final app = await openForm();
        await pumpForm(tester, app);
        await openSettled(tester);

        await pick(tester, 'Несоответствия');
        await turn(tester, 'Далее', () => text('В разделе нет несоответствий'));
        await turn(tester, 'Далее', () => text('Завершить'));
        await tester.tap(find.text('Завершить'));
        await until(
          () =>
              find
                  .text('Заполните обязательные поля (2)')
                  .evaluate()
                  .isNotEmpty,
          tester,
        );
        expect(server.calls, isNot(contains('apiFinishExecution')));

        await until(
          () =>
              find.text('1/2').evaluate().isNotEmpty &&
              shown('Обязательное в зале'),
          tester,
        );
        expect(focus(tester), 'all');
        expect(
          tester.widget<FillFieldTile>(tileOf('Обязательное в зале')).flash,
          isTrue,
        );

        await tester.tap(find.byKey(const ValueKey('requiredJumpButton')));
        await until(
          () =>
              find.text('2/2').evaluate().isNotEmpty &&
              shown('Обязательное на складе'),
          tester,
        );
        expect(
          tester.widget<FillFieldTile>(tileOf('Обязательное на складе')).flash,
          isTrue,
        );

        await closeForm(tester);
      });
    },
  );

  testWidgets('отказ под «Незаполненными» оставляет переключатель как был', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final app = await openForm();
      await pumpForm(tester, app);
      await openSettled(tester);

      await pick(tester, 'Незаполненные');
      await turn(tester, 'Далее', () => shown('Обязательное на складе'));
      await turn(tester, 'Далее', () => text('Завершить'));
      await tester.tap(find.text('Завершить'));
      await until(
        () =>
            find.text('Заполните обязательные поля (2)').evaluate().isNotEmpty,
        tester,
      );
      await until(
        () =>
            find.text('1/2').evaluate().isNotEmpty &&
            shown('Обязательное в зале'),
        tester,
      );
      expect(focus(tester), 'missing');
      expect(shown('Чистота в зале'), isFalse);
      expect(
        tester.widget<FillFieldTile>(tileOf('Обязательное в зале')).flash,
        isTrue,
      );

      await closeForm(tester);
    });
  });
}
