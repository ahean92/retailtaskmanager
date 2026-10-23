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
import 'support/fake_server.dart';
import 'support/test_env.dart';

/// Клавиатура на бланке (iOS): поднята — панель «Назад/Далее» сменяется одной
/// кнопкой «Готово», потому что у iOS-цифровой клавиатуры нет своей кнопки
/// завершения. Кнопка гасит фокус, ушедшая клавиатура возвращает панель.
///
/// Настоящий sqlite (ffi) — как в fill_required_jump_test: открытие бланка
/// живёт в схеме, моком это не поднять.

/// Уникален и между прогонами: база sqlite (ffi) — реальный файл по имени
/// логина, и кэш бланка от прошлого прогона ломает порядок загрузки в тесте.
final int _runId = DateTime.now().microsecondsSinceEpoch;
int _seq = 0;

class _Server {
  List<Map<String, Object?>> fields = [
    {
      'sectionIndex': 1,
      'section': 'Зал',
      'fieldIndex': 1,
      'code': 'r1',
      'name': 'Обязательное в зале',
      'required': true,
    },
    {
      'sectionIndex': 2,
      'section': 'Склад',
      'fieldIndex': 1,
      'code': 'r2',
      'name': 'Обязательное на складе',
      'required': true,
    },
  ];

  late final Session session;
  late final ApiClient api;

  _Server(Settings settings) {
    session = Session(
      login: 'ivanov$_runId${_seq++}', // логин уникален: имя базы содержит его
      name: 'Иванов И.И.',
      token: 'token',
      signedIn: true,
      performerId: 'p1',
    );
    api = ApiClient(settings, session, client: MockClient((request) async {
      final info = {
        'object': 'Магазин №1',
        'template': 'Чек-лист',
        'hasScored': false,
        'percent': 0.0,
        'passed': false,
        'answered': 0,
        'total': 2,
        'finished': false,
      };
      switch (actionOf(request)) {
        case 'apiTasks':
          return okJson(jsonEncode([
            {
              'id': 'ST1',
              'name': 'Проверка',
              'objectId': 'o1',
              'distance': 40.0,
              'typeId': 'checklist',
            }
          ]));
        case 'apiExecutionBundle':
          return okJson(bundleJson(info: info, fields: fields));
        case 'apiSetField':
          return okJson('[]');
        default:
          return okJson('[]');
      }
    }));
  }
}

/// Человек стоит на объекте задачи; координаты — чтобы refresh было что
/// отправить (как в fill_required_jump_test).
Place _atObject() => Place(
      objects: const [
        NearbyObject(id: 'o1', name: 'Магазин №1', distance: 40),
      ],
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
        api: server.api, settings: settings, session: server.session);
    await app.account.updateSettings(settings); // открывает базу этого логина
    app.location.place = _atObject();
    await app.repo.refresh();
    return app;
  }

  /// Крутит кадры, пока не выполнится условие: настоящие sqlite и MockClient
  /// внутри runAsync живут своим временем, pumpAndSettle его не даёт.
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

  testWidgets('поднятая клавиатура сменяет панель на «Готово», кнопка гасит фокус',
      (tester) async {
    await tester.runAsync(() async {
      final app = await openForm();
      await tester.pumpWidget(MultiProvider(
        providers: app.providers,
        child: MaterialApp(
          home: Navigator(
            onGenerateRoute: (_) => MaterialPageRoute(
                builder: (_) => const FillScreen(taskId: 'ST1')),
          ),
        ),
      ));
      await until(() => find.byType(TextField).evaluate().isNotEmpty, tester);

      // фокус в поле — клавиатура «поднята» (viewInsets выставляем руками:
      // в тесте реальная клавиатура ОС не участвует)
      await tester.tap(find.byType(TextField).first);
      await tester.pump();
      final node = tester
          .widget<EditableText>(find.byType(EditableText).first)
          .focusNode;
      expect(node.hasFocus, isTrue);

      // навигация сменилась одной кнопкой завершения — «Далее» нет
      // (800 device px при dpr 3 теста ≈ 267 logical — клавиатура «поднята»)
      tester.view.viewInsets = const FakeViewPadding(bottom: 800);
      await tester.pump();
      expect(find.text('Далее'), findsNothing);
      expect(find.byKey(const ValueKey('keyboardDoneBar')), findsOneWidget);

      // полоска стоит НАД клавиатурой, а не прижата к полу экрана за ней
      // (экран теста 600 logical, клавиатура 800 device px / dpr 3 ≈ 267 —
      // её верх на ~333); тонкая — не выдавливает страницу (регресс жадного
      // Align), и поле остаётся видным над ней (частично — список доскроллится)
      final field = tester.getRect(find.byType(TextField).first);
      final bar =
          tester.getRect(find.byKey(const ValueKey('keyboardDoneBar')));
      expect(bar.bottom, lessThanOrEqualTo(344));
      expect(bar.height, lessThan(80));
      expect(field.height, greaterThan(40));
      expect(field.top, lessThan(bar.top));

      await tester.tap(find.descendant(
          of: find.byKey(const ValueKey('keyboardDoneBar')),
          matching: find.byType(FilledButton)));
      await tester.pump();
      expect(node.hasFocus, isFalse);

      // клавиатура ушла — панель навигации на месте
      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pump();
      expect(find.text('Далее'), findsOneWidget);

      await closeForm(tester);
    });
  });
}
