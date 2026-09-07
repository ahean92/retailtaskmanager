import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pulse_tasks/data/local_db.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/test_env.dart';

/// Миграции локальной базы: телефон, обновившийся с самой первой сборки, обязан
/// прийти к той же схеме, что и телефон, поставивший приложение сегодня. Проверяется
/// не «миграция N-я отработала», а итог: таблицы и колонки базы, прошедшей всю
/// цепочку с v1, совпадают с тем, что создаёт _onCreate. Расхождение здесь — это
/// «работает на новых устройствах, падает на старых», которого в поле не видно.

/// Схема базы по sqlite_master и PRAGMA table_info: таблица → описания колонок.
/// Порядок колонок не сравнивается: ALTER TABLE дописывает в конец, а _onCreate
/// пишет по смыслу — это одна и та же схема.
Future<Map<String, Set<String>>> _schemaOf(String path) async {
  final db = await databaseFactory.openDatabase(path,
      options: OpenDatabaseOptions(readOnly: true));
  try {
    final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' "
        "AND name NOT LIKE 'sqlite_%' AND name <> 'android_metadata'");
    final result = <String, Set<String>>{};
    for (final t in tables) {
      final name = t['name'] as String;
      final cols = await db.rawQuery('PRAGMA table_info($name)');
      result[name] = {
        for (final c in cols)
          '${c['name']} ${c['type']} notnull=${c['notnull']} '
              'default=${c['dflt_value']} pk=${c['pk']}',
      };
    }
    return result;
  } finally {
    await db.close();
  }
}

Future<int> _userVersion(String path) async {
  final db = await databaseFactory.openDatabase(path,
      options: OpenDatabaseOptions(readOnly: true));
  try {
    return (await db.getVersion());
  } finally {
    await db.close();
  }
}

void main() {
  initTestEnv();

  test('база v1 после всех миграций совпадает со схемой _onCreate', () async {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final dir = await getDatabasesPath();

    // база, какой её оставила самая первая сборка: три таблицы, задачи — без
    // всего, что дописали позже (объект, взятие, переписка, признаки срока…)
    final oldKey = 'migv1_$stamp';
    final oldPath = p.join(dir, 'pulse_tasks_$oldKey.db');
    final v1 = await databaseFactory.openDatabase(oldPath,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, _) async {
            await db.execute('''
              CREATE TABLE tasks (
                id TEXT PRIMARY KEY,
                name TEXT, object TEXT, address TEXT,
                type TEXT, typeId TEXT,
                status TEXT, statusId TEXT,
                priority TEXT, assignedTo TEXT, assigneeId TEXT,
                deadline TEXT, progress INTEGER, subtitle TEXT
              )''');
            await db.execute('''
              CREATE TABLE statuses (
                id TEXT PRIMARY KEY, name TEXT, closed INTEGER, sortingOrder INTEGER
              )''');
            await db.execute('''
              CREATE TABLE outbox (
                taskId TEXT PRIMARY KEY,
                statusId TEXT NOT NULL,
                statusName TEXT,
                createdAt TEXT NOT NULL
              )''');
          },
        ));
    await v1.insert('tasks', {'id': 'ST1', 'name': 'Старая задача'});
    await v1.insert('outbox', {
      'taskId': 'ST1',
      'statusId': 's2',
      'statusName': 'В работе',
      'createdAt': '2026-01-01T10:00:00',
    });
    await v1.close();

    // прогнать цепочку миграций целиком
    final upgraded = await LocalDb.open(oldKey);
    expect((await upgraded.getTasks()).map((t) => t.id), ['ST1'],
        reason: 'данные первой сборки переживают все миграции');
    expect((await upgraded.getOutbox()).keys, ['ST1']);
    await upgraded.close();

    // и то же — с чистого листа
    final freshKey = 'migfresh_$stamp';
    final freshPath = p.join(dir, 'pulse_tasks_$freshKey.db');
    await (await LocalDb.open(freshKey)).close();

    final migrated = await _schemaOf(oldPath);
    final created = await _schemaOf(freshPath);
    expect(migrated.keys.toSet(), created.keys.toSet(),
        reason: 'набор таблиц после миграций и после _onCreate');
    for (final table in created.keys) {
      expect(migrated[table], created[table],
          reason: 'колонки таблицы $table после миграций и после _onCreate');
    }
    expect(await _userVersion(oldPath), await _userVersion(freshPath));

    await databaseFactory.deleteDatabase(oldPath);
    await databaseFactory.deleteDatabase(freshPath);
  });
}
