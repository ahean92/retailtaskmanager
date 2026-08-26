import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/comment.dart';
import '../models/task.dart';
import '../models/task_status.dart';
import 'client_id.dart' as ids;

/// One queued, not-yet-synced status change.
class OutboxEntry {
  final String taskId;
  final String statusId;
  final String? statusName;
  const OutboxEntry(this.taskId, this.statusId, this.statusName);
}

/// Сводка кэша ленты одной задачи (#36844): сколько сообщений в кэше и сколько чужих
/// новее местной отметки «прочитано до». Из неё список собирает бейдж, не дёргая
/// сервер и не читая саму ленту.
class CommentStats {
  final int total;
  final int unread;
  const CommentStats(this.total, this.unread);
}

/// Local offline store: cached tasks + status dictionary + an outbox of pending
/// status changes. The outbox is the source of truth for a task's *effective*
/// status until the change is confirmed by the server.
///
/// One file per user rather than one file per device with a `userKey` column in every
/// table: nine tables and every query in them would have to remember the filter, and a
/// single forgotten `WHERE` gives the next person on the phone somebody else's tasks.
/// A file the other user's queries cannot even name isolates by construction, and the
/// schema stays exactly as it was — the version and [_onUpgrade] are shared by all files.
class LocalDb {
  final Database _db;

  /// Whose base this is — see [keyFor]. Evidence photos are filed under the same key, so
  /// `FillController` takes it from here instead of deriving the identity a second time.
  final String userKey;

  LocalDb(this._db, this.userKey);

  static Future<LocalDb> open(String userKey) async {
    final dir = await getDatabasesPath();
    final path = _pathFor(dir, userKey);
    await _adoptLegacyDatabase(dir, path);
    final db = await openDatabase(path,
        version: 20, onCreate: _onCreate, onUpgrade: _onUpgrade);
    return LocalDb(db, userKey);
  }

  static String _pathFor(String dir, String userKey) =>
      p.join(dir, 'pulse_tasks_$userKey.db');

  /// Closed when the person signs out — the base carries their name, and it must not stay
  /// open across a change of user.
  Future<void> close() => _db.close();

  /// Erase one person's base — «выйти и удалить данные», the half of it that lives in
  /// sqlite. Only the file named after that one identity is removed, so a phone shared by
  /// a shift keeps everybody else's tasks, queues and photos exactly where they were.
  ///
  /// The base has to be closed first: an open handle would be deleted out from under
  /// whatever still holds it. [deleteDatabase] takes the journal/WAL siblings with it.
  static Future<void> deleteFor(String userKey) async {
    await deleteDatabase(_pathFor(await getDatabasesPath(), userKey));
  }

  /// Everything this person has changed that the server has not confirmed yet: statuses,
  /// field values, table cells, the pending outcome and photos still waiting to go up.
  ///
  /// Counted across every queue rather than the status one alone, because this is the
  /// number the sign-out asks about — «сколько изменений останутся неотправленными» is a
  /// promise that has to hold for the photo taken in the aisle, not just for the tick in
  /// the list. The legacy `checklist_*` queues are left out: nothing in the app drains
  /// them any more, so counting them would show a number that can never fall.
  Future<int> pendingChanges() async {
    final r = await _db.rawQuery('''
      SELECT (SELECT COUNT(*) FROM outbox)
           + (SELECT COUNT(*) FROM fill_outbox)
           + (SELECT COUNT(*) FROM fill_cell_outbox)
           + (SELECT COUNT(*) FROM fill_resolution)
           + (SELECT COUNT(*) FROM fill_photos WHERE uploaded = 0)
           + (SELECT COUNT(*) FROM task_outbox)
           + (SELECT COUNT(*) FROM start_outbox)
           + (SELECT COUNT(*) FROM finish_outbox)
           + (SELECT COUNT(*) FROM take_outbox)
           + (SELECT COUNT(*) FROM comment_outbox)
           + (SELECT COUNT(*) FROM task_file_outbox)
           + (SELECT COUNT(*) FROM simple_photos WHERE uploaded = 0)
           + (SELECT COUNT(*) FROM simple_comment_outbox)
           + (SELECT COUNT(*) FROM simple_start_outbox)
           + (SELECT COUNT(*) FROM simple_finish_outbox) AS pending''');
    return (r.first['pending'] as int?) ?? 0;
  }

  /// Which file a person gets: the server address and the login together. The address is
  /// half of it on purpose — one and the same person on the test server and on the live one
  /// is looking at two different sets of tasks, and a single cache holding both would be
  /// wrong in whichever of them it was opened.
  ///
  /// The login is folded to lower case exactly as the platform treats it (see
  /// `Session.matches`), and the address loses its trailing slashes the same way
  /// `ApiClient` does, so `http://srv:9080/` and `http://srv:9080` are one installation
  /// rather than two bases.
  static String keyFor(String baseUrl, String login) {
    final server = baseUrl.trim().toLowerCase().replaceAll(RegExp(r'/+$'), '');
    final user = login.trim().toLowerCase();
    // The length of the address goes into the digest ahead of the two halves, so that no
    // pair can be re-cut into another one: without it an address and a login could be
    // glued into the same string as a shorter address and a longer login, and two people
    // would share a file. Half a sha256 is plenty for a file name, and it gives away
    // neither the address nor the login to whoever reads the directory listing.
    return sha256
        .convert(utf8.encode('${server.length}:$server$user'))
        .toString()
        .substring(0, 16);
  }

  /// The one base older builds kept for the whole device. It cannot simply be dropped: it
  /// may hold changes that never reached the server, and for a photo taken offline it is
  /// the only copy there is. Everything in it was made by the single person this device
  /// had, so the first sign-in after the update takes it over — the file is renamed into
  /// that person's name, once, and no legacy file is left for anybody else to adopt.
  static Future<void> _adoptLegacyDatabase(String dir, String path) async {
    final legacy = p.join(dir, 'pulse_tasks.db');
    if (!await databaseExists(legacy) || await databaseExists(path)) return;
    // the journal/WAL siblings travel with it — the last committed transaction may still
    // be sitting in them rather than in the .db file
    for (final suffix in const ['', '-journal', '-wal', '-shm']) {
      final f = File('$legacy$suffix');
      if (await f.exists()) await f.rename('$path$suffix');
    }
  }

  static Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE tasks (
        id TEXT PRIMARY KEY,
        clientId TEXT,
        name TEXT, description TEXT, object TEXT, objectId TEXT, address TEXT,
        type TEXT, typeId TEXT,
        status TEXT, statusId TEXT,
        executionKind TEXT, requirePhoto INTEGER,
        priority TEXT, assignedTo TEXT, assigneeId TEXT,
        author TEXT, authorId TEXT, postedAt TEXT,
        deadline TEXT, progress INTEGER, subtitle TEXT,
        takenById TEXT, takenBy TEXT, takenAt TEXT,
        canTake INTEGER, mine INTEGER,
        distance REAL,
        assigned INTEGER, authored INTEGER,
        commentCount INTEGER, unreadComments INTEGER,
        filesJson TEXT, executionsJson TEXT
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
    await _createChecklistTables(db);
    await _createPhotoTable(db);
    await _createFillTables(db);
    await _createHomeTable(db);
    await _createPlaceTable(db);
    await _createQuickTable(db);
    await _createCreationQueues(db);
    await _createPastFillTable(db);
    await _createTakeOutbox(db);
    await _createCommentTables(db);
    await _createSimpleTables(db);
    await _createTaskFileOutbox(db);
    await _createAppsTable(db);
  }

  static Future<void> _onUpgrade(Database db, int oldV, int newV) async {
    if (oldV < 2) await _createChecklistTables(db);
    if (oldV < 3) await _createPhotoTable(db);
    if (oldV < 4) {
      await _createFillTables(db); // current schema (incl. v5 table-cell bits)
    } else if (oldV < 5) {
      await db.execute('ALTER TABLE fill_cache ADD COLUMN columnsJson TEXT');
      await db.execute('ALTER TABLE fill_cache ADD COLUMN rowsJson TEXT');
      await _createCellOutbox(db);
    }
    if (oldV < 6) await _migratePhotosToMulti(db);
    if (oldV < 7) await _createHomeTable(db);
    if (oldV < 8) {
      // the cached tasks stay: their objectId arrives with the next refresh, and until
      // then they belong to nobody's object — which is exactly what a NULL column says
      await db.execute('ALTER TABLE tasks ADD COLUMN objectId TEXT');
      await _createPlaceTable(db);
    }
    if (oldV < 9) await _createQuickTable(db);
    if (oldV < 10) {
      // cached server tasks get their clientId with the next refresh; a NULL until then
      // just means «not an offline-born task», which is true for every row that exists
      await db.execute('ALTER TABLE tasks ADD COLUMN clientId TEXT');
      await _createCreationQueues(db);
    }
    if (oldV < 11) await _createPastFillTable(db);
    if (oldV < 12) {
      // кэшированные строки получат поля взятия следующим refresh; NULL до тех пор —
      // честный ответ «сервер про взятие этой строки ещё не говорил»
      for (final col in const [
        'takenById TEXT',
        'takenBy TEXT',
        'takenAt TEXT',
        'canTake INTEGER',
        'mine INTEGER',
      ]) {
        await db.execute('ALTER TABLE tasks ADD COLUMN $col');
      }
      await _createTakeOutbox(db);
    }
    if (oldV < 13) {
      // расстояние до объекта задачи (#36837) — приедет следующим refresh; NULL до
      // тех пор честен: старая строка о расстоянии ничего не знала
      await db.execute('ALTER TABLE tasks ADD COLUMN distance REAL');
    }
    if (oldV < 14) {
      // координаты момента действия (#36838) едут в очереди вместе со стартом и
      // завершением. NULL у строк, застрявших с прошлой версии, честен: в их момент
      // никто не мерил. Время отдельной колонки не получает: createdAt очереди — и
      // есть момент действия (старт кладётся при создании задачи, finish — при тапе).
      for (final table in const ['start_outbox', 'finish_outbox']) {
        await db.execute('ALTER TABLE $table ADD COLUMN lat REAL');
        await db.execute('ALTER TABLE $table ADD COLUMN lon REAL');
      }
    }
    if (oldV < 15) {
      // участие и переписка (#36844) приедут следующим refresh; NULL до тех пор честен:
      // строка старой схемы — назначенная без известной переписки, как и было
      for (final col in const [
        'assigned INTEGER',
        'authored INTEGER',
        'commentCount INTEGER',
        'unreadComments INTEGER',
      ]) {
        await db.execute('ALTER TABLE tasks ADD COLUMN $col');
      }
      await _createCommentTables(db);
    }
    if (oldV < 16) {
      // карточка задачи (#36842): описание, кто поставил и когда, файлы задачи и
      // выполнения. Всё приедет следующим refresh; NULL до тех пор честен — строка
      // старой схемы ничего этого не знала, и карточка покажет её как раньше
      for (final col in const [
        'description TEXT',
        'author TEXT',
        'authorId TEXT',
        'postedAt TEXT',
        'filesJson TEXT',
        'executionsJson TEXT',
      ]) {
        await db.execute('ALTER TABLE tasks ADD COLUMN $col');
      }
    }
    if (oldV < 17) {
      // выполнение поручения фотоотчётом (#36872). executionKind приедет следующим
      // refresh; NULL до тех пор честен и безопасен — задача без него открывается по
      // прежнему списку типов (Task.opensFill), ровно как до обновления
      for (final col in const ['executionKind TEXT', 'requirePhoto INTEGER']) {
        await db.execute('ALTER TABLE tasks ADD COLUMN $col');
      }
      await _createSimpleTables(db);
    }
    if (oldV < 18) await _migrateTaskPhotosToQueue(db);
    if (oldV < 19) await _createAppsTable(db);
    if (oldV < 20) {
      // поле-ссылка (#36841): значение в очереди — id предмета и текст-снимок;
      // кандидаты канала кэшируются вместе с бланком, офлайн-выбор без них не собрать.
      // NULL у старых строк честен: до этой версии полей-ссылок телефон не заполнял.
      // Гварды — по прецеденту v18: ветка oldV<4 уже создала таблицы в НОВОЙ схеме
      // (двойное ALTER упало бы), а минимальная база без fill-таблиц вовсе (тестовые
      // сценарии обновления) просто получает их целиком.
      if (!await _hasTable(db, 'fill_outbox')) {
        await _createFillTables(db);
      } else {
        if (!await _hasColumn(db, 'fill_outbox', 'refId')) {
          await db.execute('ALTER TABLE fill_outbox ADD COLUMN refId TEXT');
          await db.execute('ALTER TABLE fill_outbox ADD COLUMN refName TEXT');
        }
        if (!await _hasColumn(db, 'fill_cache', 'subjectsJson')) {
          await db.execute('ALTER TABLE fill_cache ADD COLUMN subjectsJson TEXT');
        }
      }
    }
  }

  /// v18: фото задачи — очередью и во множественном числе (#36914).
  ///
  /// Кадр, снятый при создании, и кадр, досланный к готовой задаче, — одно и то же
  /// событие «к задаче добавился файл», поэтому очередь одна и ручка одна
  /// (apiAddTaskFile). Ключ строки — clientId файла: сервер узнаёт по нему повтор,
  /// так что ретрай не оставляет на задаче второй такой же снимок.
  ///
  /// Единственный кадр, лежавший в task_outbox.photoPath, переезжает сюда: он может
  /// быть единственной копией снимка (исходник из камеры человек давно стёр), и
  /// потерять его при обновлении приложения нельзя. Колонка после переноса уходит —
  /// sqlite не умеет DROP COLUMN в старых версиях, поэтому таблица пересобирается.
  static Future<void> _migrateTaskPhotosToQueue(Database db) async {
    await _createTaskFileOutbox(db);
    // база, доросшая до v10+ уже после этой правки, создала task_outbox без колонки —
    // переносить нечего, но пересборка ниже всё равно безвредна
    if (await _hasColumn(db, 'task_outbox', 'photoPath')) {
      final rows = await db.query('task_outbox',
          columns: ['clientId', 'photoPath', 'createdAt']);
      for (final r in rows) {
        final path = r['photoPath'] as String?;
        if (path == null) continue;
        await db.insert('task_file_outbox', {
          'clientId': ids.newClientId(),
          'taskId': r['clientId'],
          'path': path,
          'createdAt': r['createdAt'],
        });
      }
    }
    await db.execute('''
      CREATE TABLE task_outbox_new (
        clientId TEXT PRIMARY KEY,
        payload TEXT NOT NULL,
        createdAt TEXT NOT NULL
      )''');
    await db.execute('INSERT INTO task_outbox_new (clientId, payload, createdAt) '
        'SELECT clientId, payload, createdAt FROM task_outbox');
    await db.execute('DROP TABLE task_outbox');
    await db.execute('ALTER TABLE task_outbox_new RENAME TO task_outbox');
  }

  static Future<bool> _hasColumn(
      Database db, String table, String column) async {
    final info = await db.rawQuery('PRAGMA table_info($table)');
    return info.any((r) => r['name'] == column);
  }

  static Future<bool> _hasTable(Database db, String table) async {
    final rows = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
        [table]);
    return rows.isNotEmpty;
  }

  /// Очередь файлов задачи (#36914) — снимки, ещё не доехавшие до сервера. Строка
  /// живёт до подтверждённой отправки: пока она есть, кадр показывается на карточке
  /// как «ожидает отправки» и лежит на диске единственной копией.
  ///
  /// taskId — UUID задачи, рождённой на телефоне, или её серверный номер: ручка
  /// принимает оба (taskByAnyId), поэтому очередь не нужно переписывать в момент,
  /// когда сервер выдаёт задаче номер.
  static Future<void> _createTaskFileOutbox(Database db) async {
    await db.execute('''
      CREATE TABLE task_file_outbox (
        clientId TEXT PRIMARY KEY,
        taskId TEXT NOT NULL,
        path TEXT NOT NULL,
        createdAt TEXT NOT NULL
      )''');
  }

  /// v6: a field may hold several photos. sqlite cannot widen a primary key in place,
  /// so the table is rebuilt and existing rows are carried over as photo #0 — pending
  /// uploads survive the upgrade, which matters because they may be the only copy.
  static Future<void> _migratePhotosToMulti(Database db) async {
    await db.execute('''
      CREATE TABLE fill_photos_v6 (
        taskId TEXT NOT NULL, fieldCode TEXT NOT NULL, idx INTEGER NOT NULL DEFAULT 0,
        path TEXT, uploaded INTEGER NOT NULL DEFAULT 0, createdAt TEXT NOT NULL,
        PRIMARY KEY (taskId, fieldCode, idx)
      )''');
    await db.execute('''
      INSERT INTO fill_photos_v6 (taskId, fieldCode, idx, path, uploaded, createdAt)
      SELECT taskId, fieldCode, 0, path, uploaded, createdAt FROM fill_photos''');
    await db.execute('DROP TABLE fill_photos');
    await db.execute('ALTER TABLE fill_photos_v6 RENAME TO fill_photos');
  }

  static Future<void> _createChecklistTables(Database db) async {
    await db.execute('''
      CREATE TABLE checklist_cache (
        taskId TEXT PRIMARY KEY,
        itemsJson TEXT, optionsJson TEXT,
        object TEXT, checklist TEXT, threshold REAL,
        fetchedAt TEXT
      )''');
    await db.execute('''
      CREATE TABLE checklist_outbox (
        taskId TEXT NOT NULL, si INTEGER NOT NULL, ii INTEGER NOT NULL,
        numeric INTEGER, optionIndex INTEGER, value REAL, comment TEXT,
        createdAt TEXT NOT NULL,
        PRIMARY KEY (taskId, si, ii)
      )''');
  }

  static Future<void> _createPhotoTable(Database db) async {
    // path NULL = a pending "clear the photo on the server" intent.
    await db.execute('''
      CREATE TABLE checklist_photos (
        taskId TEXT NOT NULL, si INTEGER NOT NULL, ii INTEGER NOT NULL,
        path TEXT, uploaded INTEGER NOT NULL DEFAULT 0,
        createdAt TEXT NOT NULL,
        PRIMARY KEY (taskId, si, ii)
      )''');
  }

  // --- generic fillable engine (Filling) ---
  static Future<void> _createFillTables(Database db) async {
    await db.execute('''
      CREATE TABLE fill_cache (
        taskId TEXT PRIMARY KEY,
        fieldsJson TEXT, optionsJson TEXT, infoJson TEXT,
        columnsJson TEXT, rowsJson TEXT,
        subjectsJson TEXT,
        fetchedAt TEXT
      )''');
    await db.execute('''
      CREATE TABLE fill_outbox (
        taskId TEXT NOT NULL, fieldCode TEXT NOT NULL, type TEXT,
        optionCode TEXT, number REAL, text TEXT, boolVal INTEGER, dateVal TEXT, comment TEXT,
        refId TEXT, refName TEXT,
        createdAt TEXT NOT NULL,
        PRIMARY KEY (taskId, fieldCode)
      )''');
    await db.execute('''
      CREATE TABLE fill_resolution (
        taskId TEXT PRIMARY KEY, resolution TEXT NOT NULL, createdAt TEXT NOT NULL
      )''');
    // idx is part of the key: a field holds several shots, and one photo of a display
    // case is rarely enough to document what is wrong with it.
    await db.execute('''
      CREATE TABLE fill_photos (
        taskId TEXT NOT NULL, fieldCode TEXT NOT NULL, idx INTEGER NOT NULL DEFAULT 0,
        path TEXT, uploaded INTEGER NOT NULL DEFAULT 0, createdAt TEXT NOT NULL,
        PRIMARY KEY (taskId, fieldCode, idx)
      )''');
    await _createCellOutbox(db);
  }

  /// v7: the home screen the server drew for *this* person — their blocks, their numbers.
  /// It used to sit in shared_preferences, one per device, so the next person to sign in
  /// saw the previous one's dashboard until the server answered (and offline, for good).
  /// One row: a user has one home page.
  static Future<void> _createHomeTable(Database db) async {
    await db.execute('''
      CREATE TABLE home_cache (
        id INTEGER PRIMARY KEY, json TEXT NOT NULL, fetchedAt TEXT NOT NULL
      )''');
  }

  /// v8: where this person is standing — the object they picked, the neighbours with
  /// their distances, and when it was all measured. In the user's own base rather than in
  /// the device's settings: the object belongs to whoever is on shift, and the next person
  /// to sign in on this phone stands where they themselves stand. One row: a person is in
  /// one place.
  static Future<void> _createPlaceTable(Database db) async {
    await db.execute('''
      CREATE TABLE place_cache (
        id INTEGER PRIMARY KEY, json TEXT NOT NULL, locatedAt TEXT NOT NULL
      )''');
  }

  /// v9: пресеты создания задач и предзагруженные под них справочники (шаблоны,
  /// исполнители) — три сырых ответа сервера как есть. В базе пользователя, а не в
  /// настройках устройства: список «что мне разрешено создавать» отфильтрован сервером
  /// по ролям того, кто вошёл. Одна строка: у пользователя один набор пресетов.
  static Future<void> _createQuickTable(Database db) async {
    await db.execute('''
      CREATE TABLE quick_cache (
        id INTEGER PRIMARY KEY,
        actionsJson TEXT NOT NULL, templatesJson TEXT NOT NULL,
        performersJson TEXT NOT NULL, fetchedAt TEXT NOT NULL
      )''');
  }

  /// v19: внешние приложения, настроенные на сервере (#36840), — сырой ответ
  /// apiExternalApps как есть. В базе пользователя по той же причине, что пресеты:
  /// список отфильтрован сервером по ролям того, кто вошёл. Одна строка: у
  /// пользователя один набор приложений.
  static Future<void> _createAppsTable(Database db) async {
    await db.execute('''
      CREATE TABLE apps_cache (
        id INTEGER PRIMARY KEY, json TEXT NOT NULL, fetchedAt TEXT NOT NULL
      )''');
  }

  /// v10: задачи, рождённые на телефоне (#36716). Три очереди жизненного цикла:
  /// создание (тело apiCreateTask как есть), отложенный старт выполнения и отложенное
  /// завершение. Порядок между ними — забота синхронизатора: создание — барьер для
  /// всего остального по этой задаче, завершение идёт последним.
  ///
  /// Фото автора до v18 ехало колонкой photoPath внутри того же POST — ровно одно на
  /// задачу. С #36914 кадров может быть несколько, и все они уехали в task_file_outbox
  /// (см. [_createTaskFileOutbox]): одна очередь на «снято при создании» и «дослано к
  /// готовой задаче», одна ручка на сервере.
  static Future<void> _createCreationQueues(Database db) async {
    await db.execute('''
      CREATE TABLE task_outbox (
        clientId TEXT PRIMARY KEY,
        payload TEXT NOT NULL,
        createdAt TEXT NOT NULL
      )''');
    // lat/lon (#36838) — где устройство стояло в момент действия; createdAt — когда.
    // Снятые при постановке в очередь, они переживают офлайн и уезжают с самой
    // операцией — сервер так никогда не примет место появления сети за место работы.
    await db.execute('''
      CREATE TABLE start_outbox (
        taskId TEXT PRIMARY KEY, createdAt TEXT NOT NULL, lat REAL, lon REAL
      )''');
    await db.execute('''
      CREATE TABLE finish_outbox (
        taskId TEXT PRIMARY KEY, createdAt TEXT NOT NULL, lat REAL, lon REAL
      )''');
  }

  /// v11: прошлая проверка, закэшированная вместе с задачей (#36778) — история,
  /// доступная только онлайн, бесполезна именно там, где нужна: в поле без сети.
  /// Две адресации под одним ключом kind+key: 'task' + id задачи (прошлая проверка
  /// относительно её бланка) и 'object' + id объекта (последняя завершённая проверка
  /// объекта, вход с карточки объекта). Пять сырых ответов сервера как есть — тот же
  /// формат, что fill_cache, и та же сборка assembleFillFields поверх.
  static Future<void> _createPastFillTable(Database db) async {
    await db.execute('''
      CREATE TABLE past_fill_cache (
        kind TEXT NOT NULL, key TEXT NOT NULL,
        fieldsJson TEXT, optionsJson TEXT, infoJson TEXT,
        columnsJson TEXT, rowsJson TEXT,
        fetchedAt TEXT,
        PRIMARY KEY (kind, key)
      )''');
  }

  /// v12: очередь взятий/снятий (#36836) — та же офлайн-механика, что у правок
  /// бланка: намерение ложится строкой и уезжает, когда есть связь. Одна строка на
  /// задачу (REPLACE): «взял, передумал, снял» схлопывается в последнее намерение —
  /// это и есть «откат снимает пометку и ничего больше», отправлять оба нет смысла.
  static Future<void> _createTakeOutbox(Database db) async {
    await db.execute('''
      CREATE TABLE take_outbox (
        taskId TEXT PRIMARY KEY,
        action TEXT NOT NULL,
        createdAt TEXT NOT NULL
      )''');
  }

  /// v15: переписка по задаче (#36844) — кэш серверной ленты (переписку читают в
  /// подвале без сети), очередь неотправленных сообщений и «прочитано до» по задаче.
  /// Ключ очереди — clientId, UUID сообщения: по нему сервер узнаёт повтор (ретрай не
  /// задваивает), а кэш — своё же сообщение, приехавшее обратно в серверной выдаче.
  static Future<void> _createCommentTables(Database db) async {
    await db.execute('''
      CREATE TABLE comment_cache (
        taskId TEXT NOT NULL, id TEXT NOT NULL,
        clientId TEXT, author TEXT, mine INTEGER NOT NULL DEFAULT 0,
        dateTime TEXT, text TEXT, filesJson TEXT,
        PRIMARY KEY (taskId, id)
      )''');
    await db.execute('''
      CREATE TABLE comment_outbox (
        clientId TEXT PRIMARY KEY,
        taskId TEXT NOT NULL,
        text TEXT, photoPath TEXT,
        createdAt TEXT NOT NULL
      )''');
    // upTo — серверное время последнего показанного сообщения; pending — отметка ещё
    // не дошла до сервера (ленту читали офлайн)
    await db.execute('''
      CREATE TABLE comment_read (
        taskId TEXT PRIMARY KEY,
        upTo TEXT NOT NULL,
        pending INTEGER NOT NULL DEFAULT 1
      )''');
  }

  /// v17: простое выполнение — фотоотчёт с комментарием (#36872). Свои очереди, а не
  /// общие с бланком: start_outbox/finish_outbox дренит FillController, и старт
  /// поручения, попавший туда, ушёл бы в ручку бланка — та для задачи без шаблона
  /// заводила бы новое выполнение на каждый вызов. Кто дренит очередь, видно по её
  /// имени, а не по догадке о типе задачи (типов клиент как раз знать перестал).
  ///
  /// simple_photos повторяет fill_photos: idx в ключе, path = NULL — намерение
  /// «стереть все на сервере», uploaded — снимок уже там (файл остаётся на диске,
  /// это единственная копия до следующей синхронизации списка).
  static Future<void> _createSimpleTables(Database db) async {
    await db.execute('''
      CREATE TABLE simple_cache (
        taskId TEXT PRIMARY KEY, infoJson TEXT, fetchedAt TEXT
      )''');
    await db.execute('''
      CREATE TABLE simple_photos (
        taskId TEXT NOT NULL, idx INTEGER NOT NULL,
        path TEXT, uploaded INTEGER NOT NULL DEFAULT 0, createdAt TEXT NOT NULL,
        PRIMARY KEY (taskId, idx)
      )''');
    // комментарий на выполнении один — одна строка на задачу, последняя правка
    // затирает предыдущую (REPLACE): отправлять промежуточные редакции незачем
    await db.execute('''
      CREATE TABLE simple_comment_outbox (
        taskId TEXT PRIMARY KEY, text TEXT, createdAt TEXT NOT NULL
      )''');
    await db.execute('''
      CREATE TABLE simple_start_outbox (
        taskId TEXT PRIMARY KEY, createdAt TEXT NOT NULL, lat REAL, lon REAL
      )''');
    await db.execute('''
      CREATE TABLE simple_finish_outbox (
        taskId TEXT PRIMARY KEY, createdAt TEXT NOT NULL, lat REAL, lon REAL
      )''');
  }

  // pending, not-yet-synced table cell edits, keyed by (task, field, row, column)
  static Future<void> _createCellOutbox(Database db) async {
    await db.execute('''
      CREATE TABLE fill_cell_outbox (
        taskId TEXT NOT NULL, fieldCode TEXT NOT NULL,
        rowIndex INTEGER NOT NULL, colCode TEXT NOT NULL,
        number REAL, text TEXT, createdAt TEXT NOT NULL,
        PRIMARY KEY (taskId, fieldCode, rowIndex, colCode)
      )''');
  }

  // --- tasks ---

  /// Replace the cached list with the server's answer — except the tasks born on this
  /// phone whose creation has not reached the server yet: those are the only rows the
  /// server can neither confirm nor deny, so they survive every refresh (#36716).
  ///
  /// A fetched task carrying one of our queued UUIDs is the server saying «создание
  /// доехало» — even if the POST's own answer was lost on the way back. The creation
  /// queue entry closes on the spot and the local row yields to the server one, which
  /// is what keeps the task from showing up twice. Снимки автора (#36914) закрытие
  /// создания НЕ трогает: они едут своей очередью и после него — задача, вернувшаяся
  /// с сервера, ещё ждёт свои кадры.
  Future<void> replaceTasks(List<Task> tasks) async {
    await _db.transaction((txn) async {
      final rows = await txn.query('task_outbox');
      final pending = {for (final r in rows) r['clientId'] as String};
      // Переживают замену строки задач, у которых жив ЛЮБОЙ шаг жизненного цикла, а
      // не только создание: create мог уехать, а start/finish застрять — fetch, не
      // вернувший такую задачу (сервер успел её закрыть, или создание ещё едет),
      // иначе стёр бы карточку «Завершена — не отправлена» посреди дожима.
      final keep = {
        ...pending,
        for (final r in await txn.query('start_outbox', columns: ['taskId']))
          r['taskId'] as String,
        for (final r in await txn.query('finish_outbox', columns: ['taskId']))
          r['taskId'] as String,
        // снимки, ещё не уехавшие (#36914), — такой же живой шаг, как старт и
        // завершение: карточка, где они показаны «ожидает отправки», не должна
        // исчезнуть из-под человека, пока кадр лежит только у него в телефоне
        for (final r in await txn.query('task_file_outbox', columns: ['taskId']))
          r['taskId'] as String,
      };
      for (final t in tasks) {
        final cid = t.clientId;
        if (cid == null) continue;
        // сервер вернул задачу сам — его строка главнее местной, какой бы шаг ни был
        // в очереди (очереди адресуются UUID'ом и без строки)
        keep.remove(cid);
        if (pending.remove(cid)) {
          await txn
              .delete('task_outbox', where: 'clientId = ?', whereArgs: [cid]);
        }
      }
      if (keep.isEmpty) {
        await txn.delete('tasks');
      } else {
        final marks = List.filled(keep.length, '?').join(',');
        await txn.delete('tasks',
            where: 'id NOT IN ($marks)', whereArgs: [...keep]);
      }
      final batch = txn.batch();
      for (final t in tasks) {
        batch.insert('tasks', t.toMap(),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
  }

  /// One task the phone just gave birth to — straight into the cache, so the list shows
  /// it in the same frame. Survives refreshes via the task_outbox check above.
  Future<void> insertLocalTask(Task t) async {
    await _db.insert('tasks', t.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Task>> getTasks() async {
    final rows = await _db.query('tasks');
    return rows.map(Task.fromMap).toList();
  }

  /// Update just the cached status of one task (after a confirmed sync), so the
  /// list reflects server truth without waiting for a full refresh. Статус-очередь
  /// рождённой на телефоне задачи ключуется UUID'ом, а строка после первой
  /// синхронизации несёт ST-номер — обновление ищет по обоим адресам.
  Future<void> updateTaskStatus(
      String taskId, String statusId, String? statusName) async {
    await _db.update(
      'tasks',
      {'statusId': statusId, 'status': statusName},
      where: 'id = ? OR clientId = ?',
      whereArgs: [taskId, taskId],
    );
  }

  // --- statuses ---

  Future<void> replaceStatuses(List<TaskStatus> statuses) async {
    await _db.transaction((txn) async {
      await txn.delete('statuses');
      final batch = txn.batch();
      for (final s in statuses) {
        batch.insert('statuses', s.toMap(),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
  }

  Future<List<TaskStatus>> getStatuses() async {
    final rows = await _db.query('statuses', orderBy: 'sortingOrder ASC');
    return rows.map(TaskStatus.fromMap).toList();
  }

  // --- outbox ---

  Future<void> enqueue(String taskId, String statusId, String? statusName,
      String createdAtIso) async {
    await _db.insert(
      'outbox',
      {
        'taskId': taskId,
        'statusId': statusId,
        'statusName': statusName,
        'createdAt': createdAtIso,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> dequeue(String taskId) async {
    await _db.delete('outbox', where: 'taskId = ?', whereArgs: [taskId]);
  }

  /// Pending changes keyed by task id (one latest change per task).
  Future<Map<String, OutboxEntry>> getOutbox() async {
    final rows = await _db.query('outbox', orderBy: 'createdAt ASC');
    return {
      for (final r in rows)
        r['taskId'] as String: OutboxEntry(
          r['taskId'] as String,
          r['statusId'] as String,
          r['statusName'] as String?,
        )
    };
  }

  // --- очередь взятий/снятий (#36836) ---

  /// action — 'take' | 'release'. REPLACE поверх противоположного намерения по той же
  /// задаче — снятие ещё не ушедшего взятия не оставляет в очереди ничего лишнего.
  Future<void> enqueueTake(
      String taskId, String action, String createdAtIso) async {
    await _db.insert(
      'take_outbox',
      {'taskId': taskId, 'action': action, 'createdAt': createdAtIso},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Map<String, Object?>>> getTakeOutbox() async {
    return _db.query('take_outbox', orderBy: 'createdAt ASC');
  }

  /// Сверка по action несёт гонку в полёте: пока взятие ехало на сервер, человек мог
  /// передумать, и его строку в очереди REPLACE'ом сменило снятие — ответ взятия не
  /// должен снести намерение, записанное позже него.
  Future<void> dequeueTake(String taskId, String action) async {
    await _db.delete('take_outbox',
        where: 'taskId = ? AND action = ?', whereArgs: [taskId, action]);
  }

  /// Привести строку кэша к состоянию взятия, которое сервер только что подтвердил
  /// (ответом ручки или телом 409) — иначе до следующего refresh задача прыгала бы
  /// обратно в прежнюю группу. NULL здесь — значение, а не «не трогать»: снятие
  /// честно стирает имя и время.
  Future<void> updateTaskTake(String taskId,
      {String? takenById,
      String? takenBy,
      String? takenAt,
      required bool mine,
      required bool canTake}) async {
    await _db.update(
      'tasks',
      {
        'takenById': takenById,
        'takenBy': takenBy,
        'takenAt': takenAt,
        'mine': mine ? 1 : null,
        'canTake': canTake ? 1 : null,
      },
      where: 'id = ?',
      whereArgs: [taskId],
    );
  }

  // --- home screen ---

  Future<void> saveHome(String json, String fetchedAtIso) async {
    await _db.insert(
      'home_cache',
      {'id': 1, 'json': json, 'fetchedAt': fetchedAtIso},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<String?> getHome() async {
    final rows = await _db.query('home_cache', where: 'id = 1');
    return rows.isEmpty ? null : rows.first['json'] as String?;
  }

  // --- quick-create presets + preloaded catalogs ---

  Future<void> saveQuickCreate(String actionsJson, String templatesJson,
      String performersJson, String fetchedAtIso) async {
    await _db.insert(
      'quick_cache',
      {
        'id': 1,
        'actionsJson': actionsJson,
        'templatesJson': templatesJson,
        'performersJson': performersJson,
        'fetchedAt': fetchedAtIso,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Три сырых тела в том порядке, в котором их ждёт QuickCreateData.parse;
  /// null — кэша ещё нет.
  Future<(String, String, String)?> getQuickCreate() async {
    final rows = await _db.query('quick_cache', where: 'id = 1');
    if (rows.isEmpty) return null;
    final r = rows.first;
    return (
      r['actionsJson'] as String? ?? '',
      r['templatesJson'] as String? ?? '',
      r['performersJson'] as String? ?? '',
    );
  }

  // --- external applications (#36840) ---

  Future<void> saveApps(String json, String fetchedAtIso) async {
    await _db.insert(
      'apps_cache',
      {'id': 1, 'json': json, 'fetchedAt': fetchedAtIso},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<String?> getApps() async {
    final rows = await _db.query('apps_cache', where: 'id = 1');
    return rows.isEmpty ? null : rows.first['json'] as String?;
  }

  // --- tasks born on the phone: creation / start / finish queues (#36716) ---

  /// Everything a new offline task needs, in one transaction: the visible list row,
  /// the queued apiCreateTask body and — for a template preset — the queued start plus
  /// a fill cache seeded from the preloaded template, so the form opens with no server
  /// anywhere near. Half of this committed and half not would be a task that can be
  /// seen but not synced, or synced but not seen.
  /// [photos] — снятые при создании кадры (#36914), парами «clientId файла → путь».
  /// Ложатся в ту же транзакцию: задача, у которой в списке нарисованы три снимка, но
  /// в очереди их нет, — ровно та потеря, ради которой всё это одной транзакцией.
  Future<void> createLocalTask(
    Task task, {
    required String payloadJson,
    Map<String, String> photos = const {},
    required String createdAtIso,
    bool queueStart = false,
    double? startLat,
    double? startLon,
    String? seedFieldsJson,
    String? seedOptionsJson,
    String? seedColumnsJson,
    String? seedInfoJson,
  }) async {
    await _db.transaction((txn) async {
      await txn.insert('tasks', task.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.insert(
        'task_outbox',
        {
          'clientId': task.id,
          'payload': payloadJson,
          'createdAt': createdAtIso,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      for (final e in photos.entries) {
        await txn.insert(
          'task_file_outbox',
          {
            'clientId': e.key,
            'taskId': task.id,
            'path': e.value,
            'createdAt': createdAtIso,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      if (queueStart) {
        await txn.insert(
          'start_outbox',
          {
            'taskId': task.id,
            'createdAt': createdAtIso,
            'lat': startLat,
            'lon': startLon,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      if (seedFieldsJson != null) {
        await txn.insert(
          'fill_cache',
          {
            'taskId': task.id,
            'fieldsJson': seedFieldsJson,
            'optionsJson': seedOptionsJson ?? '[]',
            'infoJson': seedInfoJson ?? '{}',
            'columnsJson': seedColumnsJson ?? '[]',
            'rowsJson': '[]',
            'fetchedAt': createdAtIso,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  /// The queued apiCreateTask of one task, or null once it has gone up.
  Future<Map<String, Object?>?> getCreateEntry(String taskId) async {
    final rows = await _db
        .query('task_outbox', where: 'clientId = ?', whereArgs: [taskId]);
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> dequeueCreate(String taskId) async {
    await _db
        .delete('task_outbox', where: 'clientId = ?', whereArgs: [taskId]);
  }

  /// Tasks whose creation is still queued — the rows replaceTasks keeps and the statuses
  /// syncOutbox must hold back (a status change cannot overtake the task itself).
  Future<Set<String>> getCreateTaskIds() async {
    final rows = await _db.query('task_outbox', columns: ['clientId']);
    return {for (final r in rows) r['clientId'] as String};
  }

  Future<bool> hasStart(String taskId) async {
    final rows = await _db
        .query('start_outbox', where: 'taskId = ?', whereArgs: [taskId]);
    return rows.isNotEmpty;
  }

  // --- очередь снимков задачи (#36914) ---

  /// Кадр в очередь: снятый при создании — вместе с задачей (см. [createLocalTask]),
  /// досланный к готовой задаче — этим методом. [clientId] рождается вместе со
  /// снимком: по нему сервер узнаёт повтор, поэтому ретрай не двоит кадр на задаче.
  Future<void> enqueueTaskFile(String clientId, String taskId,
      {required String path, required String createdAtIso}) async {
    await _db.insert(
      'task_file_outbox',
      {
        'clientId': clientId,
        'taskId': taskId,
        'path': path,
        'createdAt': createdAtIso,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Неотправленные снимки одной задачи, старейший первым — карточка рисует их
  /// «ожидает отправки» тем же виджетом, что и приехавшие с сервера.
  Future<List<Map<String, Object?>>> getTaskFileOutbox(String taskId) {
    return _db.query('task_file_outbox',
        where: 'taskId = ?', whereArgs: [taskId], orderBy: 'createdAt ASC');
  }

  /// Вся очередь снимков — для дренажа при синхронизации.
  Future<List<Map<String, Object?>>> getAllTaskFileOutbox() {
    return _db.query('task_file_outbox', orderBy: 'createdAt ASC');
  }

  /// Сколько снимков задачи ещё ждут отправки — счётчик для предела «десять на
  /// задачу»: считать надо и то, что на сервере, и то, что только в телефоне.
  Future<Map<String, int>> taskFilePendingCounts() async {
    final rows = await _db.query('task_file_outbox', columns: ['taskId']);
    final counts = <String, int>{};
    for (final r in rows) {
      final id = r['taskId'] as String;
      counts[id] = (counts[id] ?? 0) + 1;
    }
    return counts;
  }

  Future<void> dequeueTaskFile(String clientId) async {
    await _db.delete('task_file_outbox',
        where: 'clientId = ?', whereArgs: [clientId]);
  }

  /// The queued start whole — the sync needs its lat/lon/createdAt, because they, not
  /// the send moment, are where and when the work actually began (#36838).
  Future<Map<String, Object?>?> getStartEntry(String taskId) async {
    final rows = await _db
        .query('start_outbox', where: 'taskId = ?', whereArgs: [taskId]);
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> dequeueStart(String taskId) async {
    await _db.delete('start_outbox', where: 'taskId = ?', whereArgs: [taskId]);
  }

  /// Tasks whose queued start is still owed — counted into the list's pending marks,
  /// so «create уехал, старт застрял» не выглядит синхронизированным. Оба вида
  /// выполнения разом (#36872): метка на карточке отвечает на вопрос «уехало ли»,
  /// а не «какой ручкой уедет», и очередь у поручения своя.
  Future<Set<String>> getStartTaskIds() async {
    final rows = await _db.query('start_outbox', columns: ['taskId']);
    final simple = await _db.query('simple_start_outbox', columns: ['taskId']);
    return {
      for (final r in [...rows, ...simple]) r['taskId'] as String,
    };
  }

  Future<void> enqueueFinish(String taskId, String createdAtIso,
      {double? lat, double? lon}) async {
    await _db.insert(
      'finish_outbox',
      {'taskId': taskId, 'createdAt': createdAtIso, 'lat': lat, 'lon': lon},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<bool> hasFinish(String taskId) async {
    final rows = await _db
        .query('finish_outbox', where: 'taskId = ?', whereArgs: [taskId]);
    return rows.isNotEmpty;
  }

  /// The queued finish whole — see [getStartEntry].
  Future<Map<String, Object?>?> getFinishEntry(String taskId) async {
    final rows = await _db
        .query('finish_outbox', where: 'taskId = ?', whereArgs: [taskId]);
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> dequeueFinish(String taskId) async {
    await _db.delete('finish_outbox', where: 'taskId = ?', whereArgs: [taskId]);
  }

  /// Tasks marked done on the phone with the server still unaware — the list shows them
  /// as «завершена, не отправлена» until the finish goes up and the next refresh drops
  /// the row. Оба вида выполнения — см. [getStartTaskIds]; на этом же множестве стоит
  /// барьер очереди статусов, и поручение обязано его получить наравне с бланком.
  Future<Set<String>> getFinishTaskIds() async {
    final rows = await _db.query('finish_outbox', columns: ['taskId']);
    final simple = await _db.query('simple_finish_outbox', columns: ['taskId']);
    return {
      for (final r in [...rows, ...simple]) r['taskId'] as String,
    };
  }

  /// The task's own creation or start is still queued. While this is true, nothing else
  /// about the task may be sent — and a finish can only be queued, not performed.
  Future<bool> lifecyclePending(String taskId) async {
    return await getCreateEntry(taskId) != null || await hasStart(taskId);
  }

  /// То же для простого выполнения (#36872): создание задачи — общий барьер обоих
  /// видов, старт — свой.
  Future<bool> simpleLifecyclePending(String taskId) async {
    return await getCreateEntry(taskId) != null || await hasSimpleStart(taskId);
  }

  /// Every task with any lifecycle step still queued — what the repository walks on
  /// reconnect, so an offline-born task drains to the server even if no screen of it
  /// is ever opened again.
  ///
  /// Ответы бланка — тоже (#36841): у СЕРВЕРНОЙ задачи, заполненной офлайн и
  /// закрытой без завершения, никакого шага жизненного цикла нет, и до этой правки
  /// её очередь полей уезжала только при следующем открытии бланка — «заполняется
  /// офлайн» держалось на том, что человек не выйдет с экрана до появления сети.
  Future<Set<String>> getLifecycleTaskIds() async {
    final create = await _db.query('task_outbox', columns: ['clientId']);
    final start = await _db.query('start_outbox', columns: ['taskId']);
    final finish = await _db.query('finish_outbox', columns: ['taskId']);
    final fields =
        await _db.query('fill_outbox', columns: ['taskId'], distinct: true);
    final cells = await _db.query('fill_cell_outbox',
        columns: ['taskId'], distinct: true);
    final resolution = await _db.query('fill_resolution', columns: ['taskId']);
    final photos = await _db.query('fill_photos',
        columns: ['taskId'], where: 'uploaded = 0', distinct: true);
    return {
      for (final r in create) r['clientId'] as String,
      for (final r in start) r['taskId'] as String,
      for (final r in finish) r['taskId'] as String,
      for (final r in fields) r['taskId'] as String,
      for (final r in cells) r['taskId'] as String,
      for (final r in resolution) r['taskId'] as String,
      for (final r in photos) r['taskId'] as String,
    };
  }

  // --- where this person is standing ---

  Future<void> savePlace(String json, String locatedAtIso) async {
    await _db.insert(
      'place_cache',
      {'id': 1, 'json': json, 'locatedAt': locatedAtIso},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<String?> getPlace() async {
    final rows = await _db.query('place_cache', where: 'id = 1');
    return rows.isEmpty ? null : rows.first['json'] as String?;
  }

  // --- checklist cache + answer outbox ---

  Future<void> saveChecklistCache(String taskId, String itemsJson,
      String optionsJson, String? object, String? checklist, double? threshold,
      String fetchedAtIso) async {
    await _db.insert(
      'checklist_cache',
      {
        'taskId': taskId,
        'itemsJson': itemsJson,
        'optionsJson': optionsJson,
        'object': object,
        'checklist': checklist,
        'threshold': threshold,
        'fetchedAt': fetchedAtIso,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Map<String, Object?>?> getChecklistCache(String taskId) async {
    final rows = await _db
        .query('checklist_cache', where: 'taskId = ?', whereArgs: [taskId]);
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> enqueueAnswer(String taskId, int si, int ii,
      {required bool numeric,
      int? optionIndex,
      double? value,
      String? comment,
      required String createdAtIso}) async {
    await _db.insert(
      'checklist_outbox',
      {
        'taskId': taskId,
        'si': si,
        'ii': ii,
        'numeric': numeric ? 1 : 0,
        'optionIndex': optionIndex,
        'value': value,
        'comment': comment,
        'createdAt': createdAtIso,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Map<String, Object?>>> getAnswerOutbox(String taskId) async {
    return _db.query('checklist_outbox',
        where: 'taskId = ?', whereArgs: [taskId], orderBy: 'createdAt ASC');
  }

  Future<void> dequeueAnswer(String taskId, int si, int ii) async {
    await _db.delete('checklist_outbox',
        where: 'taskId = ? AND si = ? AND ii = ?', whereArgs: [taskId, si, ii]);
  }

  // --- checklist evidence photos ---

  /// Record (or replace) a photo intent for one item. `path == null` means a
  /// pending clear (remove the photo from the server). Always resets `uploaded`.
  Future<void> savePhoto(String taskId, int si, int ii, String? path,
      String createdAtIso) async {
    await _db.insert(
      'checklist_photos',
      {
        'taskId': taskId,
        'si': si,
        'ii': ii,
        'path': path,
        'uploaded': 0,
        'createdAt': createdAtIso,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// All photo rows for a task (for overlaying local photos onto items).
  Future<List<Map<String, Object?>>> getPhotos(String taskId) async {
    return _db
        .query('checklist_photos', where: 'taskId = ?', whereArgs: [taskId]);
  }

  /// Photo rows not yet confirmed by the server (for syncing).
  Future<List<Map<String, Object?>>> getPendingPhotos(String taskId) async {
    return _db.query('checklist_photos',
        where: 'taskId = ? AND uploaded = 0',
        whereArgs: [taskId],
        orderBy: 'createdAt ASC');
  }

  Future<void> markPhotoUploaded(String taskId, int si, int ii) async {
    await _db.update('checklist_photos', {'uploaded': 1},
        where: 'taskId = ? AND si = ? AND ii = ?', whereArgs: [taskId, si, ii]);
  }

  Future<void> deletePhoto(String taskId, int si, int ii) async {
    await _db.delete('checklist_photos',
        where: 'taskId = ? AND si = ? AND ii = ?', whereArgs: [taskId, si, ii]);
  }

  // --- generic fillable engine: cache + field outbox + resolution + photos ---

  Future<void> saveFillCache(String taskId, String fieldsJson,
      String optionsJson, String infoJson, String fetchedAtIso,
      {String columnsJson = '[]',
      String rowsJson = '[]',
      String subjectsJson = '{}'}) async {
    await _db.insert(
      'fill_cache',
      {
        'taskId': taskId,
        'fieldsJson': fieldsJson,
        'optionsJson': optionsJson,
        'infoJson': infoJson,
        'columnsJson': columnsJson,
        'rowsJson': rowsJson,
        'subjectsJson': subjectsJson,
        'fetchedAt': fetchedAtIso,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Map<String, Object?>?> getFillCache(String taskId) async {
    final rows =
        await _db.query('fill_cache', where: 'taskId = ?', whereArgs: [taskId]);
    return rows.isEmpty ? null : rows.first;
  }

  /// Refresh only the cached `apiExecutionInfo` answer — the score moves after
  /// every synced edit, while fields and options change only on reload. A task
  /// with no cache row yet keeps none: half a cache is worse than no cache.
  Future<void> saveFillInfo(String taskId, String infoJson) async {
    await _db.update('fill_cache', {'infoJson': infoJson},
        where: 'taskId = ?', whereArgs: [taskId]);
  }

  // --- прошлая проверка: кэш просмотра (#36778) ---

  Future<void> savePastFillCache(String kind, String key, String fieldsJson,
      String optionsJson, String infoJson, String fetchedAtIso,
      {String columnsJson = '[]', String rowsJson = '[]'}) async {
    await _db.insert(
      'past_fill_cache',
      {
        'kind': kind,
        'key': key,
        'fieldsJson': fieldsJson,
        'optionsJson': optionsJson,
        'infoJson': infoJson,
        'columnsJson': columnsJson,
        'rowsJson': rowsJson,
        'fetchedAt': fetchedAtIso,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Map<String, Object?>?> getPastFillCache(String kind, String key) async {
    final rows = await _db.query('past_fill_cache',
        where: 'kind = ? AND key = ?', whereArgs: [kind, key]);
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> enqueueField(String taskId, String fieldCode,
      {required String type,
      String? optionCode,
      double? number,
      String? text,
      bool? boolVal,
      String? dateVal,
      String? comment,
      String? refId,
      String? refName,
      required String createdAtIso}) async {
    await _db.insert(
      'fill_outbox',
      {
        'taskId': taskId,
        'fieldCode': fieldCode,
        'type': type,
        'optionCode': optionCode,
        'number': number,
        'text': text,
        'boolVal': boolVal == null ? null : (boolVal ? 1 : 0),
        'dateVal': dateVal,
        'comment': comment,
        'refId': refId,
        'refName': refName,
        'createdAt': createdAtIso,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Map<String, Object?>>> getFieldOutbox(String taskId) async {
    return _db.query('fill_outbox',
        where: 'taskId = ?', whereArgs: [taskId], orderBy: 'createdAt ASC');
  }

  Future<void> dequeueField(String taskId, String fieldCode) async {
    await _db.delete('fill_outbox',
        where: 'taskId = ? AND fieldCode = ?', whereArgs: [taskId, fieldCode]);
  }

  Future<void> setResolutionOutbox(
      String taskId, String resolution, String createdAtIso) async {
    await _db.insert(
      'fill_resolution',
      {'taskId': taskId, 'resolution': resolution, 'createdAt': createdAtIso},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<String?> getResolutionOutbox(String taskId) async {
    final rows = await _db
        .query('fill_resolution', where: 'taskId = ?', whereArgs: [taskId]);
    return rows.isEmpty ? null : rows.first['resolution'] as String?;
  }

  Future<void> clearResolutionOutbox(String taskId) async {
    await _db
        .delete('fill_resolution', where: 'taskId = ?', whereArgs: [taskId]);
  }

  /// Next free local index for a field's photos — photos are appended, never replaced.
  Future<int> nextPhotoIndex(String taskId, String fieldCode) async {
    final r = await _db.rawQuery(
        'SELECT COALESCE(MAX(idx), -1) + 1 AS next FROM fill_photos '
        'WHERE taskId = ? AND fieldCode = ?',
        [taskId, fieldCode]);
    return (r.first['next'] as int?) ?? 0;
  }

  Future<void> saveFillPhoto(String taskId, String fieldCode, int idx,
      String? path, String createdAtIso) async {
    await _db.insert(
      'fill_photos',
      {
        'taskId': taskId,
        'fieldCode': fieldCode,
        'idx': idx,
        'path': path,
        'uploaded': 0,
        'createdAt': createdAtIso,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Map<String, Object?>>> getFillPhotos(String taskId) async {
    return _db.query('fill_photos',
        where: 'taskId = ?', whereArgs: [taskId], orderBy: 'fieldCode, idx');
  }

  Future<List<Map<String, Object?>>> getPendingFillPhotos(String taskId) async {
    return _db.query('fill_photos',
        where: 'taskId = ? AND uploaded = 0',
        whereArgs: [taskId],
        orderBy: 'createdAt ASC');
  }

  Future<void> markFillPhotoUploaded(
      String taskId, String fieldCode, int idx) async {
    await _db.update('fill_photos', {'uploaded': 1},
        where: 'taskId = ? AND fieldCode = ? AND idx = ?',
        whereArgs: [taskId, fieldCode, idx]);
  }

  Future<void> deleteFillPhoto(
      String taskId, String fieldCode, int idx) async {
    await _db.delete('fill_photos',
        where: 'taskId = ? AND fieldCode = ? AND idx = ?',
        whereArgs: [taskId, fieldCode, idx]);
  }

  // --- простое выполнение: кэш, снимки, комментарий, старт и завершение (#36872) ---

  /// Ответ apiSimpleInfo как есть — экран рисуется по нему и без сети.
  Future<void> saveSimpleInfo(String taskId, String infoJson) async {
    await _db.insert(
      'simple_cache',
      {
        'taskId': taskId,
        'infoJson': infoJson,
        'fetchedAt': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Map<String, Object?>?> getSimpleCache(String taskId) async {
    final rows = await _db
        .query('simple_cache', where: 'taskId = ?', whereArgs: [taskId]);
    return rows.isEmpty ? null : rows.first;
  }

  Future<int> nextSimplePhotoIndex(String taskId) async {
    final r = await _db.rawQuery(
        'SELECT COALESCE(MAX(idx), -1) + 1 AS next FROM simple_photos '
        'WHERE taskId = ?',
        [taskId]);
    return (r.first['next'] as int?) ?? 0;
  }

  Future<void> saveSimplePhoto(
      String taskId, int idx, String? path, String createdAtIso) async {
    await _db.insert(
      'simple_photos',
      {
        'taskId': taskId,
        'idx': idx,
        'path': path,
        'uploaded': 0,
        'createdAt': createdAtIso,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Map<String, Object?>>> getSimplePhotos(String taskId) async {
    return _db.query('simple_photos',
        where: 'taskId = ?', whereArgs: [taskId], orderBy: 'idx');
  }

  Future<List<Map<String, Object?>>> getPendingSimplePhotos(
      String taskId) async {
    return _db.query('simple_photos',
        where: 'taskId = ? AND uploaded = 0',
        whereArgs: [taskId],
        orderBy: 'createdAt ASC');
  }

  Future<void> markSimplePhotoUploaded(String taskId, int idx) async {
    await _db.update('simple_photos', {'uploaded': 1},
        where: 'taskId = ? AND idx = ?', whereArgs: [taskId, idx]);
  }

  Future<void> deleteSimplePhoto(String taskId, int idx) async {
    await _db.delete('simple_photos',
        where: 'taskId = ? AND idx = ?', whereArgs: [taskId, idx]);
  }

  /// Комментарий, ещё не ушедший на сервер. Одна строка на задачу: правка затирает
  /// предыдущую — отправлять черновики промежуточных редакций некому и незачем.
  Future<void> enqueueSimpleComment(
      String taskId, String? text, String createdAtIso) async {
    await _db.insert(
      'simple_comment_outbox',
      {'taskId': taskId, 'text': text, 'createdAt': createdAtIso},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Map<String, Object?>?> getSimpleComment(String taskId) async {
    final rows = await _db.query('simple_comment_outbox',
        where: 'taskId = ?', whereArgs: [taskId]);
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> dequeueSimpleComment(String taskId) async {
    await _db.delete('simple_comment_outbox',
        where: 'taskId = ?', whereArgs: [taskId]);
  }

  Future<void> enqueueSimpleStart(String taskId, String createdAtIso,
      {double? lat, double? lon}) async {
    await _db.insert(
      'simple_start_outbox',
      {'taskId': taskId, 'createdAt': createdAtIso, 'lat': lat, 'lon': lon},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<bool> hasSimpleStart(String taskId) async {
    final rows = await _db.query('simple_start_outbox',
        where: 'taskId = ?', whereArgs: [taskId]);
    return rows.isNotEmpty;
  }

  Future<Map<String, Object?>?> getSimpleStartEntry(String taskId) async {
    final rows = await _db.query('simple_start_outbox',
        where: 'taskId = ?', whereArgs: [taskId]);
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> dequeueSimpleStart(String taskId) async {
    await _db.delete('simple_start_outbox',
        where: 'taskId = ?', whereArgs: [taskId]);
  }

  Future<void> enqueueSimpleFinish(String taskId, String createdAtIso,
      {double? lat, double? lon}) async {
    await _db.insert(
      'simple_finish_outbox',
      {'taskId': taskId, 'createdAt': createdAtIso, 'lat': lat, 'lon': lon},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<bool> hasSimpleFinish(String taskId) async {
    final rows = await _db.query('simple_finish_outbox',
        where: 'taskId = ?', whereArgs: [taskId]);
    return rows.isNotEmpty;
  }

  Future<Map<String, Object?>?> getSimpleFinishEntry(String taskId) async {
    final rows = await _db.query('simple_finish_outbox',
        where: 'taskId = ?', whereArgs: [taskId]);
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> dequeueSimpleFinish(String taskId) async {
    await _db.delete('simple_finish_outbox',
        where: 'taskId = ?', whereArgs: [taskId]);
  }

  /// Задачи, по которым осталось что-то отправить простым выполнением — их обходит
  /// дренаж при возврате связи, чтобы отчёт уехал и без открытого экрана.
  Future<Set<String>> getSimpleQueueTaskIds() async {
    final ids = <String>{};
    for (final table in const [
      'simple_start_outbox',
      'simple_finish_outbox',
      'simple_comment_outbox',
    ]) {
      for (final r in await _db.query(table, columns: ['taskId'])) {
        ids.add(r['taskId'] as String);
      }
    }
    for (final r in await _db.query('simple_photos',
        columns: ['taskId'], where: 'uploaded = 0')) {
      ids.add(r['taskId'] as String);
    }
    return ids;
  }

  // --- table cells (one queued edit per cell) ---

  Future<void> enqueueCell(
      String taskId, String fieldCode, int rowIndex, String colCode,
      {double? number, String? text, required String createdAtIso}) async {
    await _db.insert(
      'fill_cell_outbox',
      {
        'taskId': taskId,
        'fieldCode': fieldCode,
        'rowIndex': rowIndex,
        'colCode': colCode,
        'number': number,
        'text': text,
        'createdAt': createdAtIso,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Map<String, Object?>>> getCellOutbox(String taskId) async {
    return _db.query('fill_cell_outbox',
        where: 'taskId = ?', whereArgs: [taskId], orderBy: 'createdAt ASC');
  }

  Future<void> dequeueCell(
      String taskId, String fieldCode, int rowIndex, String colCode) async {
    await _db.delete('fill_cell_outbox',
        where:
            'taskId = ? AND fieldCode = ? AND rowIndex = ? AND colCode = ?',
        whereArgs: [taskId, fieldCode, rowIndex, colCode]);
  }

  // --- переписка по задаче (#36844) ---

  /// Заменить кэш ленты задачи ответом сервера. Строки очереди, чей clientId сервер
  /// уже вернул, закрываются тут же: ответ на POST мог потеряться по дороге, а само
  /// сообщение — доехать; без этого оно висело бы «не отправленным» и уехало бы ещё
  /// раз (сервер ответил бы повтором, но пузырь в ленте раздвоился бы до refresh).
  /// Возвращает пути локальных фото закрытых строк — файлы удаляет вызывающий, вне
  /// транзакции.
  Future<List<String>> replaceComments(
      String taskId, List<TaskComment> comments) async {
    final orphanPhotos = <String>[];
    await _db.transaction((txn) async {
      await txn
          .delete('comment_cache', where: 'taskId = ?', whereArgs: [taskId]);
      final batch = txn.batch();
      for (final c in comments) {
        batch.insert('comment_cache', c.toMap(taskId),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
      final known = {
        for (final c in comments)
          if (c.clientId != null) c.clientId!
      };
      if (known.isEmpty) return;
      final rows = await txn
          .query('comment_outbox', where: 'taskId = ?', whereArgs: [taskId]);
      for (final r in rows) {
        final cid = r['clientId'] as String;
        if (!known.contains(cid)) continue;
        final photo = r['photoPath'] as String?;
        if (photo != null) orphanPhotos.add(photo);
        await txn
            .delete('comment_outbox', where: 'clientId = ?', whereArgs: [cid]);
      }
    });
    return orphanPhotos;
  }

  Future<List<TaskComment>> getComments(String taskId) async {
    final rows = await _db.query('comment_cache',
        where: 'taskId = ?',
        whereArgs: [taskId],
        orderBy: 'dateTime ASC, id ASC');
    return rows.map(TaskComment.fromMap).toList();
  }

  Future<void> enqueueComment(String clientId, String taskId,
      {String? text, String? photoPath, required String createdAtIso}) async {
    await _db.insert(
      'comment_outbox',
      {
        'clientId': clientId,
        'taskId': taskId,
        'text': text,
        'photoPath': photoPath,
        'createdAt': createdAtIso,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Map<String, Object?>>> getCommentOutbox(String taskId) {
    return _db.query('comment_outbox',
        where: 'taskId = ?', whereArgs: [taskId], orderBy: 'createdAt ASC');
  }

  /// Вся очередь сообщений — для дренажа при синхронизации и счётчиков.
  Future<List<Map<String, Object?>>> getAllCommentOutbox() {
    return _db.query('comment_outbox', orderBy: 'createdAt ASC');
  }

  Future<void> dequeueComment(String clientId) async {
    await _db
        .delete('comment_outbox', where: 'clientId = ?', whereArgs: [clientId]);
  }

  /// Прочитано до [upTo] (серверное время последнего показанного сообщения) —
  /// монотонно: отметка, приехавшая из прошлого (переоткрыли старый кэш), назад
  /// ничего не откатывает. Новая отметка всегда ждёт отправки.
  Future<void> markCommentsRead(String taskId, String upTo) async {
    final rows = await _db
        .query('comment_read', where: 'taskId = ?', whereArgs: [taskId]);
    if (rows.isNotEmpty &&
        (rows.first['upTo'] as String).compareTo(upTo) >= 0) {
      return;
    }
    await _db.insert(
      'comment_read',
      {'taskId': taskId, 'upTo': upTo, 'pending': 1},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Отметка ушла на сервер — но только эта: если за время полёта легла более
  /// свежая, ей ещё ехать.
  Future<void> markCommentReadSent(String taskId, String upTo) async {
    await _db.update('comment_read', {'pending': 0},
        where: 'taskId = ? AND upTo = ?', whereArgs: [taskId, upTo]);
  }

  Future<List<Map<String, Object?>>> getPendingCommentReads() {
    return _db.query('comment_read', where: 'pending = 1');
  }

  /// Сводка кэша по задачам — см. [CommentStats]. Сравнение времён — разбором, а не
  /// строкой: формат серверного DATETIME не обязан совпадать с местным ISO.
  Future<Map<String, CommentStats>> commentStats() async {
    final marks = {
      for (final r in await _db.query('comment_read'))
        r['taskId'] as String: DateTime.tryParse(r['upTo'] as String)
    };
    final rows = await _db.query('comment_cache',
        columns: ['taskId', 'mine', 'dateTime']);
    final total = <String, int>{};
    final unread = <String, int>{};
    for (final r in rows) {
      final id = r['taskId'] as String;
      total[id] = (total[id] ?? 0) + 1;
      if (r['mine'] == 1) continue;
      final at = DateTime.tryParse((r['dateTime'] as String?) ?? '');
      final mark = marks[id];
      if (mark != null && at != null && !at.isAfter(mark)) continue;
      unread[id] = (unread[id] ?? 0) + 1;
    }
    return {
      for (final e in total.entries)
        e.key: CommentStats(e.value, unread[e.key] ?? 0)
    };
  }
}
