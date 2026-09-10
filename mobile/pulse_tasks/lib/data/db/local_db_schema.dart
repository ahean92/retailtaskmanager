import 'package:sqflite/sqflite.dart';

import '../client_id.dart' as ids;

/// Схема локальной базы: что создаётся у новой базы ([onCreate]) и как база
/// прошлой версии доводится до текущей ([onUpgrade], список [_migrations]).
/// Только DDL и переносы данных между формами таблиц; чтение и запись строк —
/// в DAO рядом (tasks_dao.dart, fill_dao.dart, …). Версия и миграции общие для
/// всех файлов баз — по файлу на человека, см. LocalDb.
class LocalDbSchema {
  static Future<void> onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE tasks (
        id TEXT PRIMARY KEY,
        clientId TEXT,
        name TEXT, description TEXT, object TEXT, objectId TEXT, address TEXT,
        type TEXT, typeId TEXT,
        status TEXT, statusId TEXT,
        executionKind TEXT, requirePhoto INTEGER,
        priority TEXT, priorityId TEXT, assignedTo TEXT, assigneeId TEXT,
        author TEXT, authorId TEXT, postedAt TEXT,
        deadline TEXT, dueToday INTEGER, overdue INTEGER,
        progress INTEGER, subtitle TEXT,
        takenById TEXT, takenBy TEXT, takenAt TEXT,
        canTake INTEGER, mine INTEGER,
        distance REAL,
        assigned INTEGER, authored INTEGER, watched INTEGER, following INTEGER,
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
    await _createWatchOutbox(db);
    await _createCommentTables(db);
    await _createSimpleTables(db);
    await _createTaskFileOutbox(db);
    await _createAppsTable(db);
    await _createListPrefsTable(db);
    await _createSyncErrorsTable(db);
    await _createCatalogTable(db);
  }

  /// Текущая версия схемы — версия последней миграции: одно место с номером, и
  /// добавить миграцию, забыв поднять версию, невозможно.
  static int get version => _migrations.last.version;

  /// Миграции по порядку: каждая доводит базу до своей версии и применяется, если
  /// база старше. Часть их идемпотентна нарочно: более ранняя миграция того же
  /// обновления могла создать таблицу уже в новой форме (v4 создаёт fill-таблицы
  /// целиком, v10 — очереди жизненного цикла сразу с координатами), и повторный
  /// ALTER упал бы на «duplicate column» — поэтому гварды _hasTable/_hasColumn, а не
  /// вера в то, каким путём шла эта конкретная база. Что цепочка с v1 приходит к
  /// той же схеме, что onCreate, проверяет test/local_db_migration_test.dart.
  static const List<_Migration> _migrations = [
    _Migration(2, _createChecklistTables),
    _Migration(3, _createPhotoTable),
    _Migration(4, _createFillTables), // current schema (incl. v5 table-cell bits)
    _Migration(5, _v5),
    _Migration(6, _migratePhotosToMulti),
    _Migration(7, _createHomeTable),
    _Migration(8, _v8),
    _Migration(9, _createQuickTable),
    _Migration(10, _v10),
    _Migration(11, _createPastFillTable),
    _Migration(12, _v12),
    _Migration(13, _v13),
    _Migration(14, _v14),
    _Migration(15, _v15),
    _Migration(16, _v16),
    _Migration(17, _v17),
    _Migration(18, _migrateTaskPhotosToQueue),
    _Migration(19, _createAppsTable),
    _Migration(20, _v20),
    _Migration(21, _v21),
    _Migration(22, _createSyncErrorsTable),
    _Migration(23, _v23),
    _Migration(24, _v24),
    _Migration(25, _v25),
    _Migration(26, _createCatalogTable),
    _Migration(27, _v27),
    _Migration(28, _v28),
  ];

  static Future<void> onUpgrade(Database db, int oldV, int newV) async {
    for (final m in _migrations) {
      if (oldV < m.version) await m.apply(db);
    }
  }

  /// v5: колонки таблиц в кэше бланка и очередь ячеек. База, получившая fill-таблицы
  /// в v4 этим же обновлением, уже несёт их — тогда добавлять нечего.
  static Future<void> _v5(Database db) async {
    if (await _hasColumn(db, 'fill_cache', 'columnsJson')) return;
    await db.execute('ALTER TABLE fill_cache ADD COLUMN columnsJson TEXT');
    await db.execute('ALTER TABLE fill_cache ADD COLUMN rowsJson TEXT');
    await _createCellOutbox(db);
  }

  static Future<void> _v8(Database db) async {
    // the cached tasks stay: their objectId arrives with the next refresh, and until
    // then they belong to nobody's object — which is exactly what a NULL column says
    await db.execute('ALTER TABLE tasks ADD COLUMN objectId TEXT');
    await _createPlaceTable(db);
  }

  static Future<void> _v10(Database db) async {
    // cached server tasks get their clientId with the next refresh; a NULL until then
    // just means «not an offline-born task», which is true for every row that exists
    await db.execute('ALTER TABLE tasks ADD COLUMN clientId TEXT');
    await _createCreationQueues(db);
  }

  static Future<void> _v12(Database db) async {
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

  static Future<void> _v13(Database db) async {
    // расстояние до объекта задачи (#36837) — приедет следующим refresh; NULL до
    // тех пор честен: старая строка о расстоянии ничего не знала
    await db.execute('ALTER TABLE tasks ADD COLUMN distance REAL');
  }

  static Future<void> _v14(Database db) async {
    // координаты момента действия (#36838) едут в очереди вместе со стартом и
    // завершением. NULL у строк, застрявших с прошлой версии, честен: в их момент
    // никто не мерил. Время отдельной колонки не получает: createdAt очереди — и
    // есть момент действия (старт кладётся при создании задачи, finish — при тапе).
    // База, получившая эти очереди в v10 этим же обновлением, уже несёт координаты —
    // без гварда путь с v9 и старше падал на «duplicate column».
    for (final table in const ['start_outbox', 'finish_outbox']) {
      if (await _hasColumn(db, table, 'lat')) continue;
      await db.execute('ALTER TABLE $table ADD COLUMN lat REAL');
      await db.execute('ALTER TABLE $table ADD COLUMN lon REAL');
    }
  }

  static Future<void> _v15(Database db) async {
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

  static Future<void> _v16(Database db) async {
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

  static Future<void> _v17(Database db) async {
    // выполнение поручения фотоотчётом (#36872). executionKind приедет следующим
    // refresh; NULL до тех пор честен и безопасен — задача без него открывается по
    // прежнему списку типов (Task.opensFill), ровно как до обновления
    for (final col in const ['executionKind TEXT', 'requirePhoto INTEGER']) {
      await db.execute('ALTER TABLE tasks ADD COLUMN $col');
    }
    await _createSimpleTables(db);
  }

  static Future<void> _v20(Database db) async {
    // поле-ссылка (#36841): значение в очереди — id предмета и текст-снимок;
    // кандидаты канала кэшируются вместе с бланком, офлайн-выбор без них не собрать.
    // NULL у старых строк честен: до этой версии полей-ссылок телефон не заполнял.
    // Гварды — по прецеденту v18: ветка v4 уже создала таблицы в НОВОЙ схеме
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

  static Future<void> _v21(Database db) async {
    // разбор списка (#36915): ключ приоритета приедет следующим refresh, NULL до
    // тех пор честен — старая строка знала только название. Гварды — по прецеденту
    // v20: минимальная база тестовых сценариев обновления живёт без таблицы tasks
    if (await _hasTable(db, 'tasks') &&
        !await _hasColumn(db, 'tasks', 'priorityId')) {
      await db.execute('ALTER TABLE tasks ADD COLUMN priorityId TEXT');
    }
    await _createListPrefsTable(db);
  }

  static Future<void> _v23(Database db) async {
    // серверные «на сегодня» и «просрочено» (#36944). NULL у старых строк честен и
    // работает: до первой синхронизации на новом сервере признака нет, и фильтр
    // считает по-старому — от даты устройства. Гварды — по прецеденту v20/v21:
    // минимальная база тестовых сценариев обновления живёт без таблицы tasks
    if (await _hasTable(db, 'tasks') &&
        !await _hasColumn(db, 'tasks', 'overdue')) {
      await db.execute('ALTER TABLE tasks ADD COLUMN dueToday INTEGER');
      await db.execute('ALTER TABLE tasks ADD COLUMN overdue INTEGER');
    }
  }

  static Future<void> _v24(Database db) async {
    // удаление одного снимка пункта (#36946). NULL в serverIdx у снимков, уехавших
    // прошлой версией, честен: под каким индексом они легли, устройство не знало —
    // и сверка с photoIndexes при первой же загрузке бланка их опознает. Гварды —
    // по прецеденту v20/v21: минимальная база тестовых сценариев обновления живёт
    // без fill-таблиц вовсе.
    if (!await _hasTable(db, 'fill_photos')) {
      await _createFillTables(db);
    } else {
      if (!await _hasColumn(db, 'fill_photos', 'serverIdx')) {
        await db.execute('ALTER TABLE fill_photos ADD COLUMN serverIdx INTEGER');
      }
      if (!await _hasTable(db, 'fill_photo_deletes')) {
        await _createPhotoDeleteQueue(db);
      }
    }
  }

  static Future<void> _v25(Database db) async {
    // заполнение таблиц с телефона (#36943): очередь ячеек переезжает с rowIndex на
    // rowKey, рядом появляется очередь операций над строками.
    //
    // Застрявшие правки ячеек при этом ТЕРЯЮТСЯ, и это честнее переноса: индекс в
    // ключ не превращается — сервер с #36779 индексов не знает, а угадывать, какой
    // строке принадлежала правка, значит записать её в чужую. Пересоздание таблицы,
    // а не ALTER: SQLite не умеет переименовать колонку в составе первичного ключа.
    // Гварды — по прецеденту v20/v24: минимальная база тестовых сценариев
    // обновления живёт без fill-таблиц вовсе.
    if (!await _hasTable(db, 'fill_cell_outbox')) {
      await _createFillTables(db);
    } else {
      if (!await _hasColumn(db, 'fill_cell_outbox', 'rowKey')) {
        await db.execute('DROP TABLE fill_cell_outbox');
        await _createCellOutbox(db);
      }
      if (!await _hasTable(db, 'fill_row_outbox')) {
        await _createRowOutbox(db);
      }
    }
  }

  static Future<void> _v27(Database db) async {
    // наблюдение за задачей (#37135) приедет следующим refresh; NULL до тех пор честен:
    // строка старой схемы — не наблюдаемая, потому что наблюдателей сервер тогда не знал
    // и таких задач в выдаче не было вовсе. Гвард на таблицу — по прецеденту v20/v24/v25:
    // минимальная база тестовых сценариев обновления живёт без tasks вовсе.
    if (!await _hasTable(db, 'tasks')) return;
    await db.execute('ALTER TABLE tasks ADD COLUMN watched INTEGER');
  }

  static Future<void> _v28(Database db) async {
    // подписка с телефона (#37136): личная подписка приедет следующим refresh, NULL до
    // тех пор честен — «Не следить» просто не нарисуется до первой синхронизации. Гвард на
    // таблицу — по прецеденту v27: минимальная база тестовых сценариев живёт без tasks
    if (await _hasTable(db, 'tasks') &&
        !await _hasColumn(db, 'tasks', 'following')) {
      await db.execute('ALTER TABLE tasks ADD COLUMN following INTEGER');
    }
    await _createWatchOutbox(db);
  }

  /// v22: причина последней неудачи отправки (#36916) — одной таблицей на все
  /// очереди, а не колонкой в каждой из пятнадцати: причина принадлежит операции
  /// экрана «Не отправлено» (задача + вид действия), а не строке очереди — у бланка
  /// таких строк десятки, и все они падают одной причиной. Ключ — `вид:задача`,
  /// см. lib/data/unsent.dart, где перечислены виды и собираются сами операции.
  static Future<void> _createSyncErrorsTable(Database db) async {
    await db.execute('''
      CREATE TABLE sync_errors (
        opKey TEXT PRIMARY KEY,
        message TEXT NOT NULL,
        at TEXT NOT NULL
      )''');
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
    //
    // serverIdx (#36946) — под каким индексом снимок лежит на сервере: без него удалить
    // можно только весь набор. Заполняется при отправке и сверяется с photoIndexes при
    // каждой загрузке бланка; NULL — снимок ещё не уехал.
    await db.execute('''
      CREATE TABLE fill_photos (
        taskId TEXT NOT NULL, fieldCode TEXT NOT NULL, idx INTEGER NOT NULL DEFAULT 0,
        path TEXT, uploaded INTEGER NOT NULL DEFAULT 0, createdAt TEXT NOT NULL,
        serverIdx INTEGER,
        PRIMARY KEY (taskId, fieldCode, idx)
      )''');
    await _createPhotoDeleteQueue(db);
    await _createCellOutbox(db);
    await _createRowOutbox(db);
  }

  /// v24: удаление одного снимка пункта (#36946) — своя очередь, а не строка в
  /// `fill_photos`: та адресуется локальным idx, а удаление адресуется СЕРВЕРНЫМ
  /// индексом и переживает удаление самой строки со снимком. Ключ — тройка, так что
  /// повторный тап по тому же кадру не задваивает отправку.
  static Future<void> _createPhotoDeleteQueue(Database db) async {
    await db.execute('''
      CREATE TABLE fill_photo_deletes (
        taskId TEXT NOT NULL, fieldCode TEXT NOT NULL, serverIdx INTEGER NOT NULL,
        createdAt TEXT NOT NULL,
        PRIMARY KEY (taskId, fieldCode, serverIdx)
      )''');
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

  /// v21: как этот человек разобрал свой список — фильтры и сортировка (#36915).
  /// Это рабочая настройка, а не разовый ввод, поэтому она переживает перезапуск; в
  /// базе пользователя, а не в настройках устройства, — следующий на этом телефоне
  /// разбирает свой список сам. Одна строка: у списка одна раскладка.
  static Future<void> _createListPrefsTable(Database db) async {
    await db.execute('''
      CREATE TABLE list_prefs (
        id INTEGER PRIMARY KEY, json TEXT NOT NULL
      )''');
  }

  /// v26: каталог объектов проверки (#37047) — сырой ответ apiObjects как есть и
  /// версия, под которой он скачан: следующая синхронизация сверяет её с
  /// catalogVersion профиля и перекачивает только при расхождении. В базе
  /// пользователя, как главная: выбор объекта на главной обязан работать в подвале
  /// без сети. Одна строка: у пользователя один каталог.
  static Future<void> _createCatalogTable(Database db) async {
    await db.execute('''
      CREATE TABLE catalog_cache (
        id INTEGER PRIMARY KEY, json TEXT NOT NULL, version TEXT,
        fetchedAt TEXT NOT NULL
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

  /// v28: очередь подписок (#37136) — «Следить» и «Не следить», той же механикой, что
  /// взятия: одна строка на задачу (REPLACE), и «подписался, передумал, отписался»
  /// схлопывается в последнее намерение. Ключа идемпотентности сверх задачи нет и не
  /// нужно: подписка на сервере — признак на паре (задача, исполнитель), второй не бывает.
  static Future<void> _createWatchOutbox(Database db) async {
    await db.execute('''
      CREATE TABLE watch_outbox (
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
  //
  // v25 (#36943): строка адресуется rowKey — uuid, выданным телефоном при создании, —
  // а не порядковым индексом. Индекс двух строк, созданных офлайн на разных
  // устройствах, совпадает, и правка ушла бы в чужую строку; сервер с #36779 индекс
  // и не принимает.
  static Future<void> _createCellOutbox(Database db) async {
    await db.execute('''
      CREATE TABLE fill_cell_outbox (
        taskId TEXT NOT NULL, fieldCode TEXT NOT NULL,
        rowKey TEXT NOT NULL, colCode TEXT NOT NULL,
        number REAL, text TEXT, createdAt TEXT NOT NULL,
        PRIMARY KEY (taskId, fieldCode, rowKey, colCode)
      )''');
  }

  /// v25: добавление и удаление строк табличного поля (#36943) — своя очередь.
  ///
  /// Одна таблица на оба действия: они адресуются одним ключом, и порядок между ними
  /// важен ровно в одну сторону — строку сперва создают, потом правят её ячейки, а
  /// удаление идёт последним. Ключ строки в PRIMARY KEY даёт идемпотентность даром:
  /// повтор той же операции из очереди не создаёт вторую строку, как и на сервере.
  ///
  /// `op` — `add` или `delete`. Удаление строки, которая ещё не уехала, снимает и
  /// саму операцию добавления: на сервере такой строки не появится вовсе.
  static Future<void> _createRowOutbox(Database db) async {
    await db.execute('''
      CREATE TABLE fill_row_outbox (
        taskId TEXT NOT NULL, fieldCode TEXT NOT NULL, rowKey TEXT NOT NULL,
        op TEXT NOT NULL, subjectId TEXT, subjectName TEXT,
        createdAt TEXT NOT NULL,
        PRIMARY KEY (taskId, fieldCode, rowKey)
      )''');
  }
}

/// Одна миграция схемы: до какой версии доводит и что для этого делает.
class _Migration {
  final int version;
  final Future<void> Function(Database db) apply;
  const _Migration(this.version, this.apply);
}
