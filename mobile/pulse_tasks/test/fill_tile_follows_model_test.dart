import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:pulse_tasks/app_controllers.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/fill_controller.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/models/fill.dart';
import 'package:pulse_tasks/ui/fill_screen.dart';
import 'package:pulse_tasks/ui/widgets/fill_field_tile.dart';
import 'support/fake_server.dart';
import 'support/test_env.dart';

/// Плитка поля следует за данными, а не за тем, что было при её первой сборке.
///
/// Бланк открывается из кэша, пока ответ сервера в пути; ответ заменяет объекты
/// полей и строк, а состояние плитки живёт дальше (экран держит её по GlobalKey).
/// Плитка, запомнившая значения первой сборки, показывала старое и при выходе
/// записывала его поверх серверного: примечание, сохранённое в прошлый заход,
/// стиралось вторым заходом без единого нажатия. Отсюда правило, которое здесь
/// проверяется: показывается то, что в модели, а пишется только то, что человек
/// набрал сам.

final int _runId = DateTime.now().microsecondsSinceEpoch;
int _seq = 0;

/// Сервер одного бланка. Ответ агрегата можно придержать — тогда плитка
/// собирается из кэша, как на телефоне, пока запрос в пути.
class _Server {
  /// Тела apiSetField — всё, что бланк записал на сервер.
  final written = <Map<String, dynamic>>[];
  Completer<void>? holdBundle;
  List<Map<String, Object?>> fields = [];

  late final Session session;
  late final ApiClient api;

  _Server(Settings settings) {
    session = Session(
      login: 'petrov$_runId${_seq++}', // логин уникален: имя базы содержит его
      name: 'Петров П.П.',
      token: 'token',
      signedIn: true,
      performerId: 'p1',
    );
    api = ApiClient(settings, session, client: MockClient((request) async {
      switch (actionOf(request)) {
        case 'apiTasks':
          return okJson(jsonEncode([
            {
              'id': 'ST1',
              'name': 'Проверка',
              'objectId': 'o1',
              'typeId': 'checklist',
            }
          ]));
        case 'apiExecutionBundle':
          if (holdBundle != null) await holdBundle!.future;
          return okJson(bundleJson(
            info: {
              'object': 'Магазин №1',
              'template': 'Чек-лист',
              'percent': 0.0,
              'answered': 0,
              'total': fields.length,
              'date': '2026-11-05T10:00:00',
            },
            fields: fields,
          ));
        case 'apiSetField':
          written.add(jsonDecode(request.body) as Map<String, dynamic>);
          return okJson('[]');
        default:
          return okJson('[]');
      }
    }));
  }
}

/// Что плитка отдала наружу.
class _Log {
  final texts = <String?>[];
  final comments = <String?>[];
}

/// Плитка-редактор. Ячейки пишутся в строку, как это делает контроллер бланка:
/// по ним видно, В КАКУЮ строку ушло значение.
FillFieldTile _tile(FillField f, _Log log, Key key) => FillFieldTile(
      key: key,
      field: f,
      onOption: (_) {},
      onNumber: (_) {},
      onText: log.texts.add,
      onBool: (_) {},
      onDatePick: () {},
      onScan: () {},
      onComment: log.comments.add,
      onPhoto: () {},
      onRemovePhoto: () {},
      onDeleteShot: (_) {},
      onCell: (row, col, v) => row.numbers[col.code] = v,
      onCellText: (row, col, v) => row.texts[col.code] = v,
      onAddRow: (_, __, {code}) async => null,
      onDeleteRow: (_) {},
      onRowSubjectSearch: (_, {allItems = false}) async => const [],
      onRef: (_, __) {},
      onRefSearch: (_) async => const [],
    );

Widget _host(Widget tile) => MaterialApp(
    home: Scaffold(body: SingleChildScrollView(child: tile)));

FillField _text({String? text, String? comment}) => FillField(
    sectionIndex: 1,
    fieldIndex: 1,
    code: 'f1',
    name: 'Витрина',
    type: 'text',
    text: text,
    comment: comment);

const _fact =
    FillColumn(fieldCode: 't1', code: 'fact', name: 'Факт', type: 'number');
const _series =
    FillColumn(fieldCode: 't1', code: 'series', name: 'Серия', type: 'text');

FillRowData _row(double fact) =>
    FillRowData(1, rowKey: 'k1', subject: 'Молоко')..numbers['fact'] = fact;

FillField _table(FillRowData row) => FillField(
    sectionIndex: 1,
    fieldIndex: 1,
    code: 't1',
    name: 'Остатки',
    type: 'table',
    columns: const [_fact, _series],
    rows: [row]);

void main() {
  initTestEnv();

  group('примечание и текст', () {
    testWidgets('примечание из ответа видно и при уходе не стирается',
        (tester) async {
      final log = _Log();
      final key = GlobalKey();
      // плитка собрана из кэша: примечания в нём ещё нет
      await tester.pumpWidget(_host(_tile(_text(), log, key)));
      // ответ сервера заменил объект поля под той же плиткой
      await tester.pumpWidget(
          _host(_tile(_text(comment: 'витрина треснула'), log, key)));
      expect(find.text('витрина треснула'), findsOneWidget);

      await tester.pumpWidget(const SizedBox()); // выход из бланка
      expect(log.comments, isEmpty,
          reason: 'человек ничего не набирал — писать нечего');
    });

    testWidgets('примечание пришло, пока курсор стоял в поле: уход не стирает',
        (tester) async {
      final log = _Log();
      final key = GlobalKey();
      await tester.pumpWidget(_host(_tile(_text(), log, key)));
      await tester.tap(find.text('Примечание'));
      await tester.pump();
      await tester.tap(find.byType(TextField).last);
      await tester.pump();
      await tester.pumpWidget(
          _host(_tile(_text(comment: 'витрина треснула'), log, key)));

      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      expect(log.comments, isEmpty);
      expect(find.text('витрина треснула'), findsOneWidget,
          reason: 'ушёл без правки — на экране то, что пришло');
    });

    testWidgets('стёртое человеком примечание уезжает пустым',
        (tester) async {
      final log = _Log();
      await tester.pumpWidget(
          _host(_tile(_text(comment: 'витрина треснула'), log, GlobalKey())));
      await tester.enterText(find.byType(TextField).last, '');
      await tester.pump();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      expect(log.comments, ['']);
    });

    testWidgets('набранное примечание при выходе по-прежнему уезжает',
        (tester) async {
      final log = _Log();
      await tester.pumpWidget(_host(_tile(_text(), log, GlobalKey())));
      await tester.tap(find.text('Примечание'));
      await tester.pump();
      await tester.enterText(find.byType(TextField).last, 'сколот угол');
      await tester.pump();
      await tester.pumpWidget(const SizedBox()); // выход, фокус не отдан
      expect(log.comments, ['сколот угол']);
    });

    testWidgets('просмотр: примечание сменилось под плиткой — выход без записи',
        (tester) async {
      final key = GlobalKey();
      FillFieldTile view(String comment) => FillFieldTile(
          key: key,
          field: _text(text: 'чисто', comment: comment),
          readOnly: true);
      await tester.pumpWidget(_host(view('старое')));
      await tester.pumpWidget(_host(view('новое')));
      expect(find.text('новое'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    });

    testWidgets('фокус и уход без правки ничего не пишут', (tester) async {
      final log = _Log();
      await tester.pumpWidget(_host(_tile(
          _text(text: 'чисто', comment: 'проверено'), log, GlobalKey())));
      for (final input in [
        find.byType(TextField).first,
        find.byType(TextField).last
      ]) {
        await tester.tap(input);
        await tester.pump();
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump();
      }
      expect(log.texts, isEmpty);
      expect(log.comments, isEmpty);
    });

    testWidgets('«Готово» на клавиатуре пишет один раз', (tester) async {
      final log = _Log();
      await tester.pumpWidget(_host(
          _tile(_text(comment: 'проверено'), log, GlobalKey())));
      await tester.enterText(find.byType(TextField).first, 'чисто');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.enterText(find.byType(TextField).last, 'сколот угол');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(log.texts, ['чисто']);
      expect(log.comments, ['сколот угол']);
    });
  });

  group('таблица', () {
    testWidgets('ячейка показывает число из ответа', (tester) async {
      final log = _Log();
      final key = GlobalKey();
      await tester.pumpWidget(_host(_tile(_table(_row(5)), log, key)));
      expect(find.text('5'), findsOneWidget);
      // ответ сервера: те же строки новыми объектами, факт уже 7
      await tester.pumpWidget(_host(_tile(_table(_row(7)), log, key)));
      expect(find.text('7'), findsOneWidget);
      expect(find.text('5'), findsNothing);
    });

    testWidgets('текст ячейки пишется в текущую строку', (tester) async {
      final log = _Log();
      final key = GlobalKey();
      final cached = _row(5);
      final fresh = _row(5);
      final table = _table(fresh);
      await tester.pumpWidget(_host(_tile(_table(cached), log, key)));
      await tester.pumpWidget(_host(_tile(table, log, key)));

      await tester.enterText(find.byType(TextField).last, 'А-17');
      await tester.pump();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      expect(fresh.texts['series'], 'А-17');
      expect(cached.texts['series'], isNull,
          reason: 'строка из кэша экрану уже не принадлежит');
      expect(table.tableAnswered, isTrue);
    });

    testWidgets('набранное, но ещё не отправленное число ответ не затирает',
        (tester) async {
      final log = _Log();
      final key = GlobalKey();
      final fresh = _row(7);
      await tester.pumpWidget(_host(_tile(_table(_row(5)), log, key)));
      await tester.enterText(find.byType(TextField).first, '9');
      await tester.pump();
      // ответ пришёл, пока человек набирает
      await tester.pumpWidget(_host(_tile(_table(fresh), log, key)));
      expect(find.text('9'), findsOneWidget);

      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      expect(fresh.numbers['fact'], 9);
    });
  });

  group('бланк целиком', () {
    late Settings settings;
    late _Server server;

    setUp(() {
      resetMockStores();
      settings = Settings(baseUrl: 'http://test.local:9080');
      server = _Server(settings);
    });

    /// Крутит кадры, пока не выполнится условие: настоящие sqlite и MockClient
    /// внутри runAsync живут своим временем, pumpAndSettle его не даёт.
    Future<void> until(bool Function() done, WidgetTester tester) async {
      for (var i = 0; i < 100 && !done(); i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    testWidgets('второй заход: примечание с сервера видно и выход его не стирает',
        (tester) async {
      Map<String, Object?> field({String? comment}) => {
            'sectionIndex': 1,
            'section': 'Зал',
            'fieldIndex': 1,
            'code': 'f1',
            'name': 'Витрина',
            'type': 'text',
            if (comment != null) 'comment': comment,
          };
      await tester.runAsync(() async {
        final app = AppControllers(
            api: server.api, settings: settings, session: server.session);
        await app.account.updateSettings(settings);
        await app.repo.refresh();

        // первый заход оставил кэш бланка, примечания в нём нет
        server.fields = [field()];
        final first = FillController(
            db: app.repo.db, api: app.repo.api, taskId: 'ST1');
        await first.load();
        first.dispose();

        // на сервере примечание уже есть: записано после того, как кэш снят
        server.fields = [field(comment: 'витрина треснула')];
        server.holdBundle = Completer<void>();
        await tester.pumpWidget(MultiProvider(
          providers: app.providers,
          child: const MaterialApp(home: FillScreen(taskId: 'ST1')),
        ));
        await until(
            () => find.textContaining('Витрина').evaluate().isNotEmpty, tester);
        expect(find.text('витрина треснула'), findsNothing,
            reason: 'плитка собрана из кэша, ответ ещё в пути');

        server.holdBundle!.complete();
        await until(
            () => find.text('витрина треснула').evaluate().isNotEmpty, tester);
        expect(find.text('витрина треснула'), findsOneWidget);

        // выход без единого нажатия; запросу, если бы он был, даём уйти
        await tester.pumpWidget(const SizedBox());
        await until(() => server.written.isNotEmpty, tester);
        expect(server.written, isEmpty,
            reason: 'запись без примечания сервер читает как его очистку');
      });
    });
  });
}
