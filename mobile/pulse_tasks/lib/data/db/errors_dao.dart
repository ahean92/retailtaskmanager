import 'package:sqflite/sqflite.dart';

/// Журнал ошибок приложения на устройстве (client_errors) — то, что ждёт отправки на
/// сервер (apiClientErrors). Одинаковые ошибки склеиваются по подписи [sig]: ошибка
/// отрисовки повторяется на каждом кадре, и сотня одинаковых строк не сказала бы больше
/// одной с числом. Журнал ограничен [cap] строками — старые уходят первыми: без связи
/// он копится, а место на телефоне не резиновое.
class ErrorsDao {
  ErrorsDao(this._db);

  final Database _db;

  static const cap = 200;

  Future<void> add({
    required String id,
    required String sig,
    required String atIso,
    required String kind,
    String? where,
    required String message,
    String? stack,
  }) async {
    await _db.transaction((txn) async {
      final same = await txn.query('client_errors',
          columns: ['id'], where: 'sig = ?', whereArgs: [sig], limit: 1);
      if (same.isNotEmpty) {
        await txn.rawUpdate(
            'UPDATE client_errors SET count = count + 1, at = ? WHERE id = ?',
            [atIso, same.first['id']]);
        return;
      }
      await txn.insert('client_errors', {
        'id': id,
        'sig': sig,
        'at': atIso,
        'kind': kind,
        'place': where,
        'message': message,
        'stack': stack,
        'count': 1,
      });
      await txn.rawDelete(
          'DELETE FROM client_errors WHERE id NOT IN '
          '(SELECT id FROM client_errors ORDER BY at DESC LIMIT ?)',
          [cap]);
    });
  }

  /// Самые старые [limit] записей — пачка на отправку.
  Future<List<Map<String, Object?>>> oldest(int limit) =>
      _db.query('client_errors', orderBy: 'at, id', limit: limit);

  Future<void> remove(Iterable<String> ids) async {
    final list = ids.toList();
    if (list.isEmpty) return;
    await _db.delete('client_errors',
        where: 'id IN (${List.filled(list.length, '?').join(',')})',
        whereArgs: list);
  }

  Future<int> count() async =>
      Sqflite.firstIntValue(
          await _db.rawQuery('SELECT COUNT(*) FROM client_errors')) ??
      0;
}
