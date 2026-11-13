import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:pulse_tasks/app_controllers.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/fill_controller.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/models/place.dart';
import 'package:pulse_tasks/ui/fill_screen.dart';
import 'support/fake_server.dart';
import 'support/test_env.dart';

/// «Завершить» учитывает набранное. Ответ попадает в модель и очередь, когда поле
/// отдаёт фокус, а нажатие кнопки фокус у поля не отнимает: клавиатуры на экране
/// нет (ТСД с аппаратной клавиатурой, Android после системного «назад»), и вместо
/// панели «Готово» видна «Завершить». Тогда завершение уходило первым, а ответ —
/// следом при выходе, и сервер отвечал ему «Execution already finished»: ответа на
/// сервере нет, строка в «Не отправлено» навсегда. Обязательное поле с видимым
/// ответом при этом отказывало с первого нажатия.
///
/// Здесь клавиатуры тоже нет — ровно тот случай. Плюс: пока бланк не загружен,
/// завершать нечего, и кнопка погашена.

final int _runId = DateTime.now().microsecondsSinceEpoch;
int _seq = 0;

class _Server {
  /// Пишущие вызовы по порядку: имя ручки и тело.
  final writes = <(String, Map<String, dynamic>)>[];
  final calls = <String>[];
  bool finished = false;
  Completer<void>? holdBundle;

  List<Map<String, Object?>> fields = [];
  List<Map<String, Object?>> columns = [];
  List<Map<String, Object?>> rows = [];

  late final Session session;
  late final ApiClient api;

  Map<String, Object?> get info => {
        'object': 'Магазин №1',
        'template': 'Чек-лист',
        'percent': 0.0,
        'answered': 0,
        'total': fields.length,
        'finished': finished,
      };

  _Server(Settings settings) {
    session = Session(
      login: 'sidorov$_runId${_seq++}', // логин уникален: имя базы содержит его
      name: 'Сидоров С.С.',
      token: 'token',
      signedIn: true,
      performerId: 'p1',
    );
    api = ApiClient(settings, session, client: MockClient((request) async {
      final action = actionOf(request);
      calls.add(action);
      switch (action) {
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
        case 'apiExecutionInfo':
          return okJson(jsonEncode([info]));
        case 'apiExecutionBundle':
          if (holdBundle != null) await holdBundle!.future;
          return okJson(bundleJson(
              info: info, fields: fields, columns: columns, rows: rows));
        case 'apiSetField':
        case 'apiSetCell':
          // как сервер: в завершённый бланк писать нельзя
          if (finished) {
            return http.Response.bytes(
                utf8.encode('Execution already finished'), 500);
          }
          writes.add((action, jsonDecode(request.body) as Map<String, dynamic>));
          return okJson('[]');
        case 'apiFinishExecution':
          writes.add((action, jsonDecode(request.body) as Map<String, dynamic>));
          finished = true;
          return okJson('[]');
        default:
          return okJson('[]');
      }
    }));
  }

  /// Порядок пишущих вызовов именами ручек.
  List<String> get order => [for (final w in writes) w.$1];
}

Place _atObject() => Place(
      objects: const [
        NearbyObject(id: 'o1', name: 'Магазин №1', distance: 40),
      ],
      objectId: 'o1',
      latitude: 53.9,
      longitude: 27.56,
      answered: true,
    );

Map<String, Object?> _text(String code, String name,
        {bool required = false, int section = 1}) =>
    {
      'sectionIndex': section,
      'section': section == 1 ? 'Зал' : 'Склад',
      'fieldIndex': 1,
      'code': code,
      'name': name,
      'type': 'text',
      if (required) 'required': true,
    };

void main() {
  initTestEnv();

  late Settings settings;
  late _Server server;

  setUp(() {
    resetMockStores();
    settings = Settings(baseUrl: 'http://test.local:9080');
    server = _Server(settings);
  });

  Future<AppControllers> openApp() async {
    final app = AppControllers(
        api: server.api, settings: settings, session: server.session);
    await app.account.updateSettings(settings);
    app.location.place = _atObject();
    await app.repo.refresh();
    return app;
  }

  /// Крутит кадры, пока не выполнится условие: настоящие sqlite и MockClient
  /// внутри runAsync живут своим временем, pumpAndSettle его не даёт.
  Future<void> until(bool Function() done, WidgetTester tester) async {
    for (var i = 0; i < 150 && !done(); i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<void> pumpForm(WidgetTester tester, AppControllers app) =>
      tester.pumpWidget(MultiProvider(
        providers: app.providers,
        // финиш делает pop: свой Navigator, чтобы корневой маршрут не трогать
        child: MaterialApp(
          home: Navigator(
            onGenerateRoute: (_) => MaterialPageRoute(
                builder: (_) => const FillScreen(taskId: 'ST1')),
          ),
        ),
      ));

  Future<void> closeForm(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump();
  }

  /// Главная кнопка нижней панели с этой подписью.
  ButtonStyleButton primary(WidgetTester tester, String label) =>
      tester.widget<ButtonStyleButton>(find.ancestor(
          of: find.text(label),
          matching: find.byWidgetPredicate((w) => w is ButtonStyleButton)));

  /// Набрать в поле и НЕ отдавать фокус, затем «Завершить», дождаться ответа.
  Future<void> typeAndFinish(
      WidgetTester tester, Finder input, String text) async {
    // поле на экране раньше, чем бланк готов: «Завершить» погашена, пока он в пути
    // (FillController.ready), и под нагрузкой полного прогона тап ушёл бы в пустоту
    await until(
        () =>
            find.text('Завершить').evaluate().isNotEmpty &&
            primary(tester, 'Завершить').onPressed != null,
        tester);
    await tester.enterText(input, text);
    await tester.pump();
    expect(
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<EditableText>(),
        isNotNull,
        reason: 'курсор остаётся в поле — ровно тот случай');
    await tester.tap(find.text('Завершить'));
    await until(() => server.finished && find.byType(FillScreen).evaluate().isEmpty,
        tester);
  }

  testWidgets('необязательный ответ уходит раньше завершения, очередь пуста',
      (tester) async {
    server.fields = [_text('note', 'Заметка')];
    await tester.runAsync(() async {
      final app = await openApp();
      await pumpForm(tester, app);
      await until(() => find.byType(TextField).evaluate().isNotEmpty, tester);

      await typeAndFinish(tester, find.byType(TextField).first, 'ответ в фокусе');

      expect(server.order, ['apiSetField', 'apiFinishExecution']);
      expect(server.writes.first.$2['text'], 'ответ в фокусе');
      expect(await app.repo.db.fill.getFieldOutbox('ST1'), isEmpty);
      await closeForm(tester);
    });
  });

  testWidgets('обязательное поле с набранным ответом не отказывает',
      (tester) async {
    server.fields = [_text('req', 'Обязательное', required: true)];
    await tester.runAsync(() async {
      final app = await openApp();
      await pumpForm(tester, app);
      await until(() => find.byType(TextField).evaluate().isNotEmpty, tester);

      await typeAndFinish(tester, find.byType(TextField).first, 'есть');

      expect(find.textContaining('Заполните обязательные'), findsNothing);
      expect(server.order, ['apiSetField', 'apiFinishExecution']);
      await closeForm(tester);
    });
  });

  testWidgets('примечание, набранное перед «Завершить», уходит раньше',
      (tester) async {
    server.fields = [_text('note', 'Заметка')];
    await tester.runAsync(() async {
      final app = await openApp();
      await pumpForm(tester, app);
      await until(() => find.byType(TextField).evaluate().isNotEmpty, tester);
      await tester.tap(find.text('Примечание'));
      await tester.pump();

      await typeAndFinish(tester, find.byType(TextField).last, 'сколот угол');

      expect(server.order, ['apiSetField', 'apiFinishExecution']);
      expect(server.writes.first.$2['comment'], 'сколот угол');
      await closeForm(tester);
    });
  });

  testWidgets('текст ячейки таблицы уходит раньше завершения', (tester) async {
    server.fields = [
      {
        'sectionIndex': 1,
        'section': 'Зал',
        'fieldIndex': 1,
        'code': 'tab',
        'name': 'Остатки',
        'type': 'table',
      }
    ];
    server.columns = [
      {'fieldCode': 'tab', 'colCode': 'series', 'name': 'Серия', 'type': 'text'},
    ];
    server.rows = [
      {
        'fieldCode': 'tab',
        'rowIndex': 1,
        'rowKey': 'k1',
        'colCode': 'series',
        'subject': 'Молоко',
      }
    ];
    await tester.runAsync(() async {
      final app = await openApp();
      await pumpForm(tester, app);
      await until(() => find.byType(TextField).evaluate().isNotEmpty, tester);

      await typeAndFinish(tester, find.byType(TextField).first, 'А-17');

      expect(server.order, ['apiSetCell', 'apiFinishExecution']);
      expect(server.writes.first.$2['text'], 'А-17');
      expect(await app.repo.db.fill.getCellOutbox('ST1'), isEmpty);
      await closeForm(tester);
    });
  });

  testWidgets('«Далее» отдаёт набранное до перелистывания', (tester) async {
    server.fields = [
      _text('t1', 'Заметка о зале'),
      _text('t2', 'Заметка о складе', section: 2),
    ];
    await tester.runAsync(() async {
      final app = await openApp();
      await pumpForm(tester, app);
      await until(() => find.text('Далее').evaluate().isNotEmpty, tester);
      await tester.enterText(find.byType(TextField).first, 'у витрины');
      await tester.pump();

      await tester.tap(find.text('Далее'));
      await until(() => server.writes.isNotEmpty, tester);
      expect(server.order, ['apiSetField']);
      expect(server.writes.first.$2['text'], 'у витрины');
      await closeForm(tester);
    });
  });

  testWidgets('пока бланк грузится и когда полей нет, завершить нельзя',
      (tester) async {
    server.fields = [];
    server.holdBundle = Completer<void>();
    await tester.runAsync(() async {
      final app = await openApp();
      await pumpForm(tester, app);
      await until(
          () => find.byType(CircularProgressIndicator).evaluate().isNotEmpty,
          tester);
      expect(primary(tester, 'Завершить').enabled, isFalse,
          reason: 'бланк ещё в пути');

      server.holdBundle!.complete();
      await until(() => find.text('Полей нет').evaluate().isNotEmpty, tester);
      expect(primary(tester, 'Завершить').enabled, isFalse,
          reason: 'завершать нечего');
      expect(server.calls, isNot(contains('apiFinishExecution')));
      await closeForm(tester);
    });
  });

  testWidgets('бланк из кэша, ответ ещё в пути: кнопка погашена до ответа',
      (tester) async {
    server.fields = [_text('note', 'Заметка')];
    await tester.runAsync(() async {
      final app = await openApp();
      final first =
          FillController(db: app.repo.db, api: app.repo.api, taskId: 'ST1');
      await first.load(); // кэш бланка
      first.dispose();

      server.holdBundle = Completer<void>();
      await pumpForm(tester, app);
      await until(() => find.byType(TextField).evaluate().isNotEmpty, tester);
      expect(primary(tester, 'Завершить').enabled, isFalse);

      server.holdBundle!.complete();
      await until(() => primary(tester, 'Завершить').enabled, tester);
      expect(primary(tester, 'Завершить').enabled, isTrue);
      await closeForm(tester);
    });
  });
}
