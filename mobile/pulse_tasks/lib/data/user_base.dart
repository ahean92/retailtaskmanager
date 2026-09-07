import 'local_db.dart';
import 'session.dart';
import 'settings.dart';

/// Кто живёт в базе вошедшего: при каждой её смене получает новую открытую базу — или
/// null, когда никто не вошёл, — и обязан сначала забыть ушедшего, потом прочитать
/// своё из новой.
typedef BaseHook = Future<void> Function(LocalDb? db);

/// The local base of whoever is signed in, and nothing at all while nobody is: the file
/// is named after the identity (see [LocalDb.keyFor]), so without one there is nothing
/// to open — and, just as much to the point, nothing of the previous person's left open.
///
/// Всё, что приложение знает офлайн, висит на этом одном файле: задачи, место, главная,
/// пресеты, очереди. Каждый, кто держит своё в нём, регистрируется через [onChange] и
/// при смене базы (вход, выход, другой сервер) получает её первым делом — в порядке
/// регистрации, потому что одни читают то, что прочитали другие: строка «прошлая
/// проверка» ищет объект по месту, а место читает LocationController.
class UserBase {
  final Settings settings;
  final Session session;

  UserBase({required this.settings, required this.session});

  LocalDb? _db;
  final List<BaseHook> _hooks = [];

  /// Открытая база; null — никто не вошёл.
  LocalDb? get db => _db;

  /// Имя открытой базы ([LocalDb.keyFor]); null — базы нет.
  String? get userKey => _db?.userKey;

  void onChange(BaseHook hook) => _hooks.add(hook);

  /// Point the base at whoever is signed in: open it on the way in, swap it when the
  /// identity changes (another person, or the same one against another server), close it
  /// on the way out. Everything the app knows offline hangs off this single file, so the
  /// swap *is* the isolation — no query can reach the other user's rows, because they are
  /// in a file this one does not have open.
  Future<void> rebind() async {
    final key = session.isActive
        ? LocalDb.keyFor(settings.baseUrl, session.login)
        : null;
    if (key == _db?.userKey) return;
    final previous = _db;
    _db = null; // nothing may reach the old base once it is on its way out
    await previous?.close();
    if (key != null) _db = await LocalDb.open(key);
    // whoever is at the app now is somebody else than a moment ago (or nobody): every
    // keeper forgets the one who left and reads the newcomer's own, in this order
    for (final hook in _hooks) {
      await hook(_db);
    }
  }

  Future<void> close() async {
    final db = _db;
    _db = null;
    await db?.close();
  }
}
