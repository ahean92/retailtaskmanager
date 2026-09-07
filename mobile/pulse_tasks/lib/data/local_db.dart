import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'db/cache_dao.dart';
import 'db/comments_dao.dart';
import 'db/fill_dao.dart';
import 'db/local_db_schema.dart';
import 'db/queue_dao.dart';
import 'db/simple_dao.dart';
import 'db/tasks_dao.dart';

export 'db/cache_dao.dart';
export 'db/comments_dao.dart';
export 'db/fill_dao.dart';
export 'db/queue_dao.dart';
export 'db/simple_dao.dart';
export 'db/tasks_dao.dart';

/// Local offline store: cached tasks + status dictionary + an outbox of pending
/// status changes. The outbox is the source of truth for a task's *effective*
/// status until the change is confirmed by the server.
///
/// One file per user rather than one file per device with a `userKey` column in every
/// table: nine tables and every query in them would have to remember the filter, and a
/// single forgotten `WHERE` gives the next person on the phone somebody else's tasks.
/// A file the other user's queries cannot even name isolates by construction, and the
/// schema stays exactly as it was — the version and [LocalDbSchema.onUpgrade] are shared by all files.
class LocalDb {
  final Database _db;

  /// Whose base this is — see [keyFor]. Evidence photos are filed under the same key, so
  /// `FillController` takes it from here instead of deriving the identity a second time.
  final String userKey;

  LocalDb(this._db, this.userKey);

  /// Таблицы по областям — у каждого DAO своя. Фасад держит только жизнь файла:
  /// открыть, закрыть, удалить, назвать.
  late final tasks = TasksDao(_db);
  late final cache = CacheDao(_db);
  late final fill = FillDao(_db);
  late final simple = SimpleDao(_db);
  late final comments = CommentsDao(_db);
  late final queues = QueueDao(_db, simple: simple);

  static Future<LocalDb> open(String userKey) async {
    final dir = await getDatabasesPath();
    final path = _pathFor(dir, userKey);
    await _adoptLegacyDatabase(dir, path);
    final db = await openDatabase(path,
        version: LocalDbSchema.version,
        onCreate: LocalDbSchema.onCreate,
        onUpgrade: LocalDbSchema.onUpgrade);
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
}
