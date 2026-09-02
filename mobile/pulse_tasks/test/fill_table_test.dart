import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/fill_controller.dart';
import 'package:pulse_tasks/data/local_db.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/data/unsent.dart';
import 'package:pulse_tasks/models/fill.dart';
import 'package:pulse_tasks/ui/widgets/fill_field_tile.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/test_env.dart';
import 'support/fake_server.dart';

/// Заполнение таблиц в приложении (#36943).
///
/// Здесь проверяется то, чего в клиенте не было: адресация строки КЛЮЧОМ вместо
/// индекса, состав строк (добавить/убрать) своей очередью и расчёт колонок на самом
/// телефоне. Сервер-заглушка ведёт строки ровно как lsFusion — по `rowKey`, с
/// идемпотентным `apiAddRow` и upsert'ом в `apiSetCell`: на моке «одна строка = один
/// вызов» ни дубль после ретрая, ни правка мимо строки видны бы не были.

/// Сервер-заглушка: строки заполнения по ключу, как `row = GROUP AGGR ... BY rowKey`.
class _Server {
  /// rowKey → {subjectId, subject, cells}
  final Map<String, Map<String, dynamic>> rows = {};
  final calls = <String>[];
  bool offline = false;

  /// Порядок ручек — им проверяется, что строка создаётся раньше правки её ячеек.
  List<String> get order => calls;

  int countOf(String action) => calls.where((c) => c == action).length;

  /// Справочник канала: доступные на объекте и один товар за его пределами.
  final catalog = const [
    {'subjectId': 'ITM-1', 'name': 'Молоко 3,2 %', 'available': true},
    {'subjectId': 'ITM-2', 'name': 'Хлеб «Нарочанский»', 'available': true},
    {'subjectId': 'ITM-9', 'name': 'Кефир 1 %', 'available': false},
  ];

  void seedRow(String key, String subjectId, String subject,
      {Map<String, double>? cells, bool offSystem = false}) {
    rows[key] = {
      'subjectId': subjectId,
      'subject': subject,
      'offSystem': offSystem,
      'cells': <String, double>{...?cells},
    };
  }

  http.Client get client => MockClient((request) async {
        final action = actionOf(request);
        if (offline) throw const SocketException('нет связи');
        calls.add(action);
        switch (action) {
          case 'apiAddRow':
            final b = jsonDecode(request.body) as Map<String, dynamic>;
            final key = b['rowKey'] as String;
            // идемпотентность сервера: тот же ключ — та же строка, а не вторая
            if (!rows.containsKey(key)) {
              seedRow(key, (b['subjectId'] ?? '') as String,
                  (b['subjectName'] ?? '') as String,
                  offSystem: b['subjectId'] == 'ITM-9');
            }
            return okJson('[]');
          case 'apiDeleteRow':
            // повтор по уже удалённой — no-op, как на сервере
            rows.remove((jsonDecode(request.body) as Map)['rowKey']);
            return okJson('[]');
          case 'apiSetCell':
            final b = jsonDecode(request.body) as Map<String, dynamic>;
            final key = b['rowKey'] as String;
            final row = rows.putIfAbsent(
                key,
                () => {
                      'subjectId': '',
                      'subject': '',
                      'offSystem': false,
                      'cells': <String, double>{}
                    });
            (row['cells'] as Map<String, double>)[b['col'] as String] =
                (b['number'] as num).toDouble();
            return okJson('[]');
          case 'apiRowSubjects':
            final all = request.url.queryParameters['allItems'] != null;
            final q =
                (request.url.queryParameters['query'] ?? '').toLowerCase();
            return okJson(jsonEncode([
              for (final c in catalog)
                if ((all || c['available'] == true) &&
                    (q.isEmpty ||
                        (c['name'] as String).toLowerCase().contains(q)))
                  c
            ]));
          case 'apiExecutionInfo':
            return okJson(jsonEncode([
              {
                'object': 'Магазин №1',
                'template': 'Пересчёт',
                'answered': 0,
                'total': 1,
                'finished': false,
              }
            ]));
          case 'apiExecutionFields':
            return okJson(jsonEncode([
              {
                'sectionIndex': 1,
                'section': 'Позиции',
                'fieldIndex': 1,
                'code': 'positions',
                'name': 'Позиции',
                'type': 'table',
                'refKind': 'item',
                'rowSource': 'host',
                'allowManual': true,
              }
            ]));
          case 'apiExecutionColumns':
            return okJson(jsonEncode(_columns));
          case 'apiExecutionRows':
            final out = <Map<String, dynamic>>[];
            var i = 0;
            for (final e in rows.entries) {
              i++;
              final cells = e.value['cells'] as Map<String, double>;
              for (final col in _columns) {
                out.add({
                  'fieldCode': 'positions',
                  'rowIndex': i,
                  'rowKey': e.key,
                  'subjectId': e.value['subjectId'],
                  'subject': e.value['subject'],
                  'offSystem': e.value['offSystem'],
                  'colCode': col['colCode'],
                  if (cells[col['colCode']] != null)
                    'number': cells[col['colCode']],
                });
              }
            }
            return okJson(jsonEncode(out));
          default:
            return okJson('[]');
        }
      });

  static const _columns = [
    {
      'fieldCode': 'positions',
      'colCode': 'plan',
      'name': 'Учёт',
      'type': 'number',
      'readonly': true,
      'colIndex': 1,
    },
    {
      'fieldCode': 'positions',
      'colCode': 'fact',
      'name': 'Факт',
      'type': 'number',
      'compareTo': 'plan',
      'colIndex': 2,
    },
    {
      'fieldCode': 'positions',
      'colCode': 'diff',
      'name': 'Расхожд.',
      'type': 'number',
      'readonly': true,
      'calcKind': 'diff',
      'operandA': 'fact',
      'operandB': 'plan',
      'totalMode': 'sum',
      'colIndex': 3,
    },
    {
      'fieldCode': 'positions',
      'colCode': 'cost',
      'name': 'Стоимость',
      'type': 'number',
      'readonly': true,
      'calcKind': 'product',
      'operandA': 'fact',
      'constB': 2.5,
      'totalMode': 'sum',
      'colIndex': 4,
    },
  ];

}

/// Строка со всеми колонками — заготовка для проверок расчёта без сервера.
FillRowData _row(Map<String, double?> numbers, {Map<String, double?>? prev}) {
  final r = FillRowData(1, rowKey: 'k1');
  r.numbers.addAll(numbers);
  if (prev != null) r.prevNumbers.addAll(prev);
  return r;
}

FillField _tableField(List<FillColumn> columns, List<FillRowData> rows,
        {bool allowManual = false}) =>
    FillField(
      sectionIndex: 1,
      fieldIndex: 1,
      code: 'positions',
      name: 'Позиции',
      type: 'table',
      allowManual: allowManual,
      columns: columns,
      rows: rows,
    );

int _seq = 0;

void main() {
  initTestEnv();

  late Settings settings;
  late Session session;
  late _Server server;

  setUp(() {
    resetMockStores();
    settings = Settings(baseUrl: 'http://test.local:9080');
    session = Session(
        login: 'ivanov', name: 'Иванов И.И.', token: 'token', signedIn: true);
    server = _Server();
  });

  Future<LocalDb> openDb() async {
    final db = await LocalDb.open(
        't36943_${DateTime.now().microsecondsSinceEpoch}_${_seq++}');
    addTearDown(() async => db.close());
    return db;
  }

  FillController controller(LocalDb db) {
    final c = FillController(
      db: db,
      api: ApiClient(settings, session, client: server.client),
      taskId: 'ST1',
    );
    addTearDown(c.dispose);
    return c;
  }

  // ===== расчёт: та же арифметика, что в ColumnCalc.lsf =====

  group('расчёт', () {
    test('произведение колонки на константу — цена одна на всю таблицу', () {
      const cost = FillColumn(
          fieldCode: 'f',
          code: 'cost',
          type: 'number',
          calcKind: 'product',
          operandA: 'fact',
          constB: 2.5);
      final r = _row({'fact': 4});
      expect(r.cellValue(cost), 10);
    });

    test('расхождение — разность двух колонок', () {
      const diff = FillColumn(
          fieldCode: 'f',
          code: 'diff',
          type: 'number',
          calcKind: 'diff',
          operandA: 'fact',
          operandB: 'plan');
      expect(_row({'fact': 7, 'plan': 10}).cellValue(diff), -3);
    });

    test('незаполненный операнд оставляет ячейку пустой, а не нулём', () {
      const diff = FillColumn(
          fieldCode: 'f',
          code: 'diff',
          type: 'number',
          calcKind: 'diff',
          operandA: 'fact',
          operandB: 'plan');
      expect(_row({'plan': 10}).cellValue(diff), isNull);
    });

    test('расход прибора — разность с прошлой проверкой', () {
      const used = FillColumn(
          fieldCode: 'f',
          code: 'used',
          type: 'number',
          calcKind: 'reading',
          operandA: 'reading');
      final r = _row({'reading': 1250}, prev: {'reading': 1200});
      expect(r.cellValue(used), 50);
    });

    test('на первой проверке расхода нет — прошлого показания не существует', () {
      const used = FillColumn(
          fieldCode: 'f',
          code: 'used',
          type: 'number',
          calcKind: 'reading',
          operandA: 'reading');
      expect(_row({'reading': 1250}).cellValue(used), isNull);
    });

    test('стоимость расхода — расход на тариф колонки', () {
      const cost = FillColumn(
          fieldCode: 'f',
          code: 'cost',
          type: 'number',
          calcKind: 'readingCost',
          operandA: 'reading',
          constB: 0.2);
      final r = _row({'reading': 1250}, prev: {'reading': 1200});
      expect(r.cellValue(cost), closeTo(10, 0.0001));
    });

    test('неизвестный вид расчёта не выдумывает число', () {
      const weird = FillColumn(
          fieldCode: 'f',
          code: 'x',
          type: 'number',
          calcKind: 'quantumFlux',
          operandA: 'fact');
      expect(_row({'fact': 4}).cellValue(weird), isNull);
    });
  });

  group('итоги', () {
    const fact = FillColumn(
        fieldCode: 'f', code: 'fact', type: 'number', totalMode: 'sum');
    const avg = FillColumn(
        fieldCode: 'f', code: 'fact', type: 'number', totalMode: 'avg');
    const cnt = FillColumn(
        fieldCode: 'f', code: 'fact', type: 'number', totalMode: 'count');
    const plain = FillColumn(fieldCode: 'f', code: 'fact', type: 'number');

    List<FillRowData> rows() =>
        [_row({'fact': 2}), _row({'fact': 5}), _row({})];

    test('сумма считается по заполненным строкам', () {
      expect(_tableField([fact], rows()).columnTotal(fact), 7);
    });

    test('среднее делит на заполненные, а не на все строки', () {
      expect(_tableField([avg], rows()).columnTotal(avg), 3.5);
    });

    test('количество считает заполненные ячейки', () {
      expect(_tableField([cnt], rows()).columnTotal(cnt), 2);
    });

    test('у колонки без режима итога итога нет', () {
      expect(_tableField([plain], rows()).columnTotal(plain), isNull);
    });

    test('итог вычисляемой колонки суммирует посчитанное на телефоне', () {
      const cost = FillColumn(
          fieldCode: 'f',
          code: 'cost',
          type: 'number',
          calcKind: 'product',
          operandA: 'fact',
          constB: 2,
          totalMode: 'sum');
      // ни одной ячейки cost в данных нет — сумма берётся из расчёта
      expect(_tableField([cost], rows()).columnTotal(cost), 14);
    });
  });

  // ===== сборка строк: ключ, а не индекс =====

  test('строки разбираются по ключу: одинаковый индекс не склеивает их', () {
    final fields = assembleFillFields(
      [
        {
          'sectionIndex': 1,
          'fieldIndex': 1,
          'code': 'positions',
          'type': 'table'
        }
      ],
      const [],
      _Server._columns,
      [
        // две строки, созданные офлайн на разных устройствах: индекс у обеих 1
        {
          'fieldCode': 'positions',
          'rowIndex': 1,
          'rowKey': 'aaa',
          'subject': 'Молоко',
          'colCode': 'fact',
          'number': 3
        },
        {
          'fieldCode': 'positions',
          'rowIndex': 1,
          'rowKey': 'bbb',
          'subject': 'Хлеб',
          'offSystem': true,
          'colCode': 'fact',
          'number': 8
        },
      ],
    );
    final rows = fields.single.rows;
    expect(rows.length, 2);
    expect(rows.map((r) => r.subject), containsAll(['Молоко', 'Хлеб']));
    expect(rows.firstWhere((r) => r.rowKey == 'bbb').offSystem, isTrue);
  });

  test('прошлое показание приезжает в строку и участвует в расчёте', () {
    final fields = assembleFillFields(
      [
        {
          'sectionIndex': 1,
          'fieldIndex': 1,
          'code': 'positions',
          'type': 'table'
        }
      ],
      const [],
      const [
        {
          'fieldCode': 'positions',
          'colCode': 'reading',
          'type': 'number',
          'colIndex': 1
        },
        {
          'fieldCode': 'positions',
          'colCode': 'used',
          'type': 'number',
          'calcKind': 'reading',
          'operandA': 'reading',
          'colIndex': 2
        },
      ],
      const [
        {
          'fieldCode': 'positions',
          'rowIndex': 1,
          'rowKey': 'k',
          'colCode': 'reading',
          'number': 1250,
          'prevNumber': 1200
        },
      ],
    );
    final f = fields.single;
    expect(f.cellValue(f.rows.single, f.columns.last), 50);
  });

  // ===== очередь строк =====

  test('добавленная позиция уезжает целиком: строка, потом её ячейка', () async {
    final db = await openDb();
    server.seedRow('host-1', 'ITM-1', 'Молоко 3,2 %', cells: {'plan': 10});
    final c = controller(db);
    await c.load();
    final f = c.fields.single;

    final row = await c.addRow(f, subjectId: 'ITM-2', subjectName: 'Хлеб');
    await c.setCellNumber(f, row, f.columns[1], 4);
    await c.syncAll();

    expect(server.rows.length, 2);
    final added = server.rows[row.rowKey]!;
    expect(added['subject'], 'Хлеб');
    expect((added['cells'] as Map)['fact'], 4);
    // строка создаётся раньше, чем правятся её ячейки: имя товара живёт в apiAddRow
    expect(server.order.indexOf('apiAddRow'),
        lessThan(server.order.lastIndexOf('apiSetCell')));
    expect(await c.db.getRowOutbox('ST1'), isEmpty);
  });

  test('повторная отправка той же строки не создаёт вторую', () async {
    final db = await openDb();
    final c = controller(db);
    await c.load();
    final f = c.fields.single;

    final row = await c.addRow(f, subjectId: 'ITM-1', subjectName: 'Молоко');
    await c.syncAll();
    // ретрай очереди: тот же ключ уходит второй раз
    await db.enqueueAddRow('ST1', f.code, row.rowKey,
        subjectId: 'ITM-1',
        subjectName: 'Молоко',
        createdAtIso: DateTime.now().toIso8601String());
    await c.syncAll();

    expect(server.countOf('apiAddRow'), 2);
    expect(server.rows.length, 1);
  });

  test('позиция, добавленная офлайн, переживает перезапуск и доезжает',
      () async {
    final db = await openDb();
    final c = controller(db);
    await c.load();
    server.offline = true;
    final row = await c.addRow(f0(c), subjectId: 'ITM-1', subjectName: 'Молоко');
    await c.setCellNumber(f0(c), row, f0(c).columns[1], 6);

    // «перезапуск приложения»: новый контроллер на той же базе
    final c2 = controller(db);
    await c2.load();
    final restored = f0(c2).rows.singleWhere((r) => r.rowKey == row.rowKey);
    expect(restored.subject, 'Молоко');
    expect(restored.numbers['fact'], 6);
    expect(c2.pendingCount, greaterThan(0));

    server.offline = false;
    await c2.syncAll();
    expect(server.rows[row.rowKey]!['subject'], 'Молоко');
    expect((server.rows[row.rowKey]!['cells'] as Map)['fact'], 6);
    expect(c2.pendingCount, 0);
  });

  test('строка, созданная и убранная офлайн, на сервере не появляется вовсе',
      () async {
    final db = await openDb();
    final c = controller(db);
    await c.load();
    server.offline = true;
    final row = await c.addRow(f0(c), subjectId: 'ITM-1', subjectName: 'Молоко');
    await c.setCellNumber(f0(c), row, f0(c).columns[1], 6);
    await c.deleteRow(f0(c), row);

    expect(await db.getRowOutbox('ST1'), isEmpty);
    expect(await db.getCellOutbox('ST1'), isEmpty);

    server.offline = false;
    await c.syncAll();
    expect(server.rows, isEmpty);
    expect(server.countOf('apiAddRow'), 0);
    expect(server.countOf('apiDeleteRow'), 0);
  });

  test('серверная строка, удалённая офлайн, после синхронизации не воскресает',
      () async {
    final db = await openDb();
    server.seedRow('host-1', 'ITM-1', 'Молоко 3,2 %', cells: {'plan': 10});
    server.seedRow('host-2', 'ITM-2', 'Хлеб', cells: {'plan': 4});
    final c = controller(db);
    await c.load();
    server.offline = true;
    await c.deleteRow(f0(c), f0(c).rows.firstWhere((r) => r.rowKey == 'host-1'));

    // до связи строка уже ушла с экрана — и не возвращается при перезагрузке кэша
    final c2 = controller(db);
    await c2.load();
    expect(f0(c2).rows.map((r) => r.rowKey), ['host-2']);

    server.offline = false;
    await c2.syncAll();
    expect(server.rows.keys, ['host-2']);
    await c2.load();
    expect(f0(c2).rows.map((r) => r.rowKey), ['host-2']);
  });

  test('повтор удаления уже удалённой строки очередь не роняет', () async {
    final db = await openDb();
    server.seedRow('host-1', 'ITM-1', 'Молоко', cells: {'plan': 10});
    final c = controller(db);
    await c.load();
    await c.deleteRow(f0(c), f0(c).rows.single);
    await c.syncAll();
    await db.enqueueDeleteRow('ST1', 'positions', 'host-1',
        createdAtIso: DateTime.now().toIso8601String());
    await c.syncAll();

    expect(server.countOf('apiDeleteRow'), 2);
    expect(await db.getRowOutbox('ST1'), isEmpty);
    expect(c.lastSyncError, isNull);
  });

  test('состав строк виден на экране «Не отправлено»', () async {
    final db = await openDb();
    final c = controller(db);
    await c.load();
    server.offline = true;
    await c.addRow(f0(c), subjectId: 'ITM-1', subjectName: 'Молоко');

    final ops = await loadUnsentOps(db);
    expect(ops.single.detail, contains('строка'));
  });

  // ===== поиск предмета =====

  test('кандидаты табличного поля кэшируются вместе с бланком — офлайн-выбор', () async {
    final db = await openDb();
    final c = controller(db);
    await c.load();
    // связь пропала после загрузки: пикер обязан остаться рабочим, иначе позицию в
    // пересчёт офлайн не добавить вовсе — а это ровно тот случай, ради которого
    // очередь и заведена
    server.offline = true;
    c.online = false;
    final found = await c.searchRowSubjects(f0(c), 'молоко');
    expect(found.single.id, 'ITM-1');
  });

  test('«показать все» открывает то, чего в остатках объекта нет', () async {
    final db = await openDb();
    final c = controller(db);
    await c.load();
    final f = f0(c);

    final near = await c.searchRowSubjects(f, 'кефир');
    expect(near, isEmpty);
    final all = await c.searchRowSubjects(f, 'кефир', allItems: true);
    expect(all.single.id, 'ITM-9');
    expect(all.single.available, isFalse);
  });

  // ===== экран =====

  testWidgets('«+ позиция» показана только полю с ручным добавлением',
      (tester) async {
    const cols = [
      FillColumn(fieldCode: 'positions', code: 'fact', type: 'number'),
    ];
    Future<void> pump(bool allowManual) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: FillFieldTile(
            field: _tableField(cols, [
              _row({'fact': 1})
            ], allowManual: allowManual),
            onOption: (_) {},
            onNumber: (_) {},
            onText: (_) {},
            onBool: (_) {},
            onDatePick: () {},
            onScan: () {},
            onComment: (_) {},
            onPhoto: () {},
            onRemovePhoto: () {},
            onDeleteShot: (_) {},
            onCell: (_, __, ___) {},
            onAddRow: (_, __) async {},
            onDeleteRow: (_) {},
            onRowSubjectSearch: (_, {allItems = false}) async => const [],
            onRef: (_, __) {},
            onRefSearch: (_) async => const [],
          ),
        ),
      ));
      await tester.pump();
    }

    await pump(true);
    expect(find.text('позиция'), findsOneWidget);

    await pump(false);
    expect(find.text('позиция'), findsNothing);
  });

  testWidgets('расчёт и итог обновляются на вводе, не дожидаясь отправки',
      (tester) async {
    const cols = [
      FillColumn(fieldCode: 'positions', code: 'fact', type: 'number'),
      FillColumn(
          fieldCode: 'positions',
          code: 'cost',
          type: 'number',
          readonly: true,
          calcKind: 'product',
          operandA: 'fact',
          constB: 2,
          totalMode: 'sum'),
    ];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FillFieldTile(
          field: _tableField(cols, [_row({})], allowManual: true),
          onOption: (_) {},
          onNumber: (_) {},
          onText: (_) {},
          onBool: (_) {},
          onDatePick: () {},
          onScan: () {},
          onComment: (_) {},
          onPhoto: () {},
          onRemovePhoto: () {},
          onDeleteShot: (_) {},
          onCell: (_, __, ___) {},
          onAddRow: (_, __) async {},
          onDeleteRow: (_) {},
          onRowSubjectSearch: (_, {allItems = false}) async => const [],
          onRef: (_, __) {},
          onRefSearch: (_) async => const [],
        ),
      ),
    ));
    await tester.pump();

    await tester.enterText(find.byType(TextField).first, '3');
    await tester.pump();
    // 3 × 2 = 6 — и в ячейке стоимости, и в итоге под таблицей, до всякой отправки
    expect(find.text('6'), findsNWidgets(2));
  });

  // ===== миграция =====

  test('база версии 24: очередь ячеек переезжает на ключ, строки появляются',
      () async {
    final key = 'mig36943_${DateTime.now().microsecondsSinceEpoch}';
    final path = p.join(await getDatabasesPath(), 'pulse_tasks_$key.db');
    // база, какой её оставила версия 24: ячейки адресуются индексом строки,
    // очереди состава строк нет вовсе
    final old = await databaseFactory.openDatabase(path,
        options: OpenDatabaseOptions(
          version: 24,
          onCreate: (db, _) async {
            await db.execute('''
              CREATE TABLE fill_cell_outbox (
                taskId TEXT NOT NULL, fieldCode TEXT NOT NULL,
                rowIndex INTEGER NOT NULL, colCode TEXT NOT NULL,
                number REAL, text TEXT, createdAt TEXT NOT NULL,
                PRIMARY KEY (taskId, fieldCode, rowIndex, colCode)
              )''');
          },
        ));
    await old.insert('fill_cell_outbox', {
      'taskId': 'ST1',
      'fieldCode': 'positions',
      'rowIndex': 1,
      'colCode': 'fact',
      'number': 5,
      'createdAt': DateTime.now().toIso8601String(),
    });
    await old.close();

    final db = await LocalDb.open(key);
    // правка, адресованная индексом, теряется намеренно: индекс в ключ не
    // превращается, а угадывать, какой строке она принадлежала, значит записать её
    // в чужую — сервер с #36779 индексов не знает вовсе
    expect(await db.getCellOutbox('ST1'), isEmpty);

    // а обе очереди работают в новой адресации
    await db.enqueueCell('ST1', 'positions', 'k1', 'fact',
        number: 5, createdAtIso: DateTime.now().toIso8601String());
    expect((await db.getCellOutbox('ST1')).single['rowKey'], 'k1');
    await db.enqueueAddRow('ST1', 'positions', 'k1',
        subjectName: 'Молоко', createdAtIso: DateTime.now().toIso8601String());
    expect((await db.getRowOutbox('ST1')).single['subjectName'], 'Молоко');
    await db.close();
    await databaseFactory.deleteDatabase(path);
  });
}

/// Единственное табличное поле бланка — читается после каждой перезагрузки заново:
/// `load()` собирает поля с нуля, и ссылка, взятая до неё, указывает на прошлый разбор.
FillField f0(FillController c) => c.fields.single;
