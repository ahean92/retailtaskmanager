import 'package:sqflite/sqflite.dart';

/// Кэши «одна строка на человека»: главная, каталог объектов (#37047), пресеты
/// создания, внешние приложения, разбор списка, место, где человек стоит, — и
/// кэш просмотра прошлых проверок (#36778). Всё это сырые ответы сервера как есть.
class CacheDao {
  CacheDao(this._db);

  final Database _db;

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

  Future<void> saveCatalog(
      String json, String? version, String fetchedAtIso) async {
    await _db.insert(
      'catalog_cache',
      {'id': 1, 'json': json, 'version': version, 'fetchedAt': fetchedAtIso},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Сырое тело каталога и версия, под которой он скачан; null — кэша ещё нет.
  Future<(String, String?)?> getCatalog() async {
    final rows = await _db.query('catalog_cache', where: 'id = 1');
    if (rows.isEmpty) return null;
    final r = rows.first;
    return (r['json'] as String? ?? '', r['version'] as String?);
  }

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

  Future<void> saveListPrefs(String json) async {
    await _db.insert(
      'list_prefs',
      {'id': 1, 'json': json},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<String?> getListPrefs() async {
    final rows = await _db.query('list_prefs', where: 'id = 1');
    return rows.isEmpty ? null : rows.first['json'] as String?;
  }

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
}
