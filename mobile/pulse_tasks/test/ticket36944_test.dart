import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pulse_tasks/data/local_db.dart';
import 'package:pulse_tasks/data/task_repository.dart';
import 'package:pulse_tasks/models/task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// dueToday и overdue считает сервер, клиент фильтрует по признакам (#36944).
///
/// Проверяется то, ради чего всё затевалось: «сегодня» у списка — серверное, а не то,
/// что показывают часы телефона. Дата устройства в этих тестах намеренно расходится со
/// «серверной»: срок ставится завтрашним, а признак приходит «просрочена», — и список
/// обязан верить признаку. Плюс совместимость (старый сервер признаков не шлёт),
/// переживание кэша (самолётный режим) и миграция базы.
///
/// Настоящий sqlite (ffi) там, где речь про кэш и обновление: признак живёт в строке
/// задачи, и мок не проверил бы ни хранение, ни ALTER TABLE.

String _iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

final _today = DateTime.now();
final _yesterday = _today.subtract(const Duration(days: 1));
final _tomorrow = _today.add(const Duration(days: 1));

TaskView _view(Task t,
        {bool closed = false, TaskGroup group = TaskGroup.mine}) =>
    TaskView(t, closed ? 'done' : 'new', closed ? 'Выполнено' : 'Новый', false,
        closed: closed, group: group);

int _seq = 0;

Future<LocalDb> _openDb() async =>
    LocalDb.open('t36944_${DateTime.now().microsecondsSinceEpoch}_${_seq++}');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  group('серверная дата сильнее даты телефона', () {
    // Телефон в другом часовом поясе или с руками сдвинутой датой — ровно тот случай,
    // из-за которого плитка «Просроченные: 3» открывала список из двух строк.
    test('признак перевешивает срок, посчитанный от часов устройства', () {
      final overdue = _view(Task(
          id: 'ST1',
          deadline: _iso(_tomorrow),
          overdue: true,
          dueToday: false));
      expect(overdue.overdue, isTrue,
          reason: 'по часам телефона срок ещё завтра, по серверу — вчера');
      expect(overdue.dueToday, isFalse);

      final today = _view(Task(
          id: 'ST2',
          deadline: _iso(_yesterday),
          dueToday: true,
          overdue: false));
      expect(today.dueToday, isTrue);
      expect(today.overdue, isFalse,
          reason: 'по часам телефона срок вчерашний, по серверу — сегодняшний');
    });

    // Главное, ради чего признак 0/1, а не «есть или нет»: пришедший ноль — это ответ
    // сервера «нет», и он обязан отличаться от молчания старого сервера.
    test('ноль — это ответ «нет», а не отсутствие ответа', () {
      final said = _view(Task(
          id: 'ST1',
          deadline: _iso(_today),
          dueToday: false,
          overdue: false));
      expect(said.dueToday, isFalse,
          reason: 'сервер сказал «нет» — местная дата тут больше не спрашивается');
      expect(said.overdue, isFalse);

      final silent = _view(Task(id: 'ST2', deadline: _iso(_today)));
      expect(silent.dueToday, isTrue,
          reason: 'ключей нет вовсе — старый сервер, работает прежний расчёт');
    });

    test('без признаков всё считается как раньше', () {
      expect(_view(Task(id: 'A', deadline: _iso(_yesterday))).overdue, isTrue);
      expect(_view(Task(id: 'B', deadline: _iso(_today))).dueToday, isTrue);
      expect(_view(Task(id: 'C', deadline: _iso(_tomorrow))).overdue, isFalse);
      expect(_view(const Task(id: 'D')).overdue, isFalse);
      expect(_view(const Task(id: 'E', deadline: 'не дата')).overdue, isFalse);
    });

    // Про завершение, которое ещё лежит в очереди, сервер не знает — и строка
    // «Завершена — не отправлена» не должна продолжать краснеть.
    test('локально завершённая не просрочена, что бы ни сказал сервер', () {
      final v = _view(Task(id: 'ST1', deadline: _iso(_yesterday), overdue: true),
          closed: true);
      expect(v.overdue, isFalse);
      expect(
          _view(Task(id: 'ST2', deadline: _iso(_today), dueToday: true),
                  closed: true)
              .dueToday,
          isFalse);
    });
  });

  group('разбор ответа сервера', () {
    test('0 и 1 читаются как флаги, отсутствие ключа — как null', () {
      final t = Task.fromJson(const {
        'id': 'ST1',
        'deadline': '2026-08-27',
        'dueToday': 1,
        'overdue': 0,
      });
      expect(t.dueToday, isTrue);
      expect(t.overdue, isFalse);

      final old = Task.fromJson(const {'id': 'ST2', 'deadline': '2026-08-27'});
      expect(old.dueToday, isNull);
      expect(old.overdue, isNull);
    });
  });

  group('кэш', () {
    // Самолётный режим: фильтр работает по последнему известному ответу, а не гаснет.
    test('признак переживает кэш, включая «сервер сказал нет»', () async {
      final db = await _openDb();
      await db.replaceTasks([
        const Task(id: 'ST1', deadline: '2026-08-27', overdue: true),
        const Task(id: 'ST2', deadline: '2026-08-27', overdue: false),
        const Task(id: 'ST3', deadline: '2026-08-27'),
      ]);

      final byId = {for (final t in await db.getTasks()) t.id: t};
      expect(byId['ST1']!.overdue, isTrue);
      expect(byId['ST2']!.overdue, isFalse,
          reason: 'ноль обязан пережить sqlite: иначе офлайн он станет молчанием');
      expect(byId['ST3']!.overdue, isNull);
      await db.close();
    });
  });

  group('обновление приложения', () {
    test('база версии 22 получает колонки, старые строки — null', () async {
      final key = 'mig36944_${DateTime.now().microsecondsSinceEpoch}';
      final path = p.join((await getDatabasesPath()), 'pulse_tasks_$key.db');
      // база, какой её оставила версия 22: у задач ещё нет признаков срока
      final old = await databaseFactory.openDatabase(path,
          options: OpenDatabaseOptions(
            version: 22,
            onCreate: (db, _) async {
              // схема tasks ровно та, что оставила v22, — до колонок признаков:
              // ALTER TABLE должен лечь на настоящую таблицу, а не на огрызок
              await db.execute('''
                CREATE TABLE tasks (
                  id TEXT PRIMARY KEY,
                  clientId TEXT,
                  name TEXT, description TEXT, object TEXT, objectId TEXT,
                  address TEXT,
                  type TEXT, typeId TEXT,
                  status TEXT, statusId TEXT,
                  executionKind TEXT, requirePhoto INTEGER,
                  priority TEXT, priorityId TEXT, assignedTo TEXT,
                  assigneeId TEXT,
                  author TEXT, authorId TEXT, postedAt TEXT,
                  deadline TEXT, progress INTEGER, subtitle TEXT,
                  takenById TEXT, takenBy TEXT, takenAt TEXT,
                  canTake INTEGER, mine INTEGER,
                  distance REAL,
                  assigned INTEGER, authored INTEGER,
                  commentCount INTEGER, unreadComments INTEGER,
                  filesJson TEXT, executionsJson TEXT
                )''');
            },
          ));
      await old.insert('tasks',
          {'id': 'ST1', 'name': 'Проверить ценники', 'deadline': '2026-08-27'});
      await old.close();

      final db = await LocalDb.open(key);
      final kept = (await db.getTasks()).single;
      expect(kept.id, 'ST1', reason: 'переезд не теряет кэш задач');
      expect(kept.overdue, isNull,
          reason: 'признака у старой строки не было — и врать про него нечем');
      expect(kept.dueToday, isNull);

      // а новая выдача уже пишется в те же колонки
      await db.insertLocalTask(
          const Task(id: 'ST1', deadline: '2026-08-27', overdue: true));
      expect((await db.getTasks()).single.overdue, isTrue);
      await db.close();
      await databaseFactory.deleteDatabase(path);
    });
  });

  group('фильтры считают то же, что плитки главной', () {
    // Плитка считает mine(Task, User); тап по ней открывает этот фильтр. Просроченная
    // задача свободного пула в него попадать не должна — иначе цифра и список снова
    // расходятся, только уже не из-за дат (#36751).
    test('«просроченные» — только мои, чужая просрочка не в счёт', () {
      final mine = _view(Task(id: 'A', deadline: _iso(_yesterday)));
      final free = _view(Task(id: 'B', deadline: _iso(_yesterday)),
          group: TaskGroup.free);
      final taken = _view(Task(id: 'C', deadline: _iso(_yesterday)),
          group: TaskGroup.taken);
      final authored = _view(Task(id: 'D', deadline: _iso(_yesterday)),
          group: TaskGroup.authored);

      expect(TaskFilter.overdue.matches(mine), isTrue);
      expect(TaskFilter.overdue.matches(free), isFalse);
      expect(TaskFilter.overdue.matches(taken), isFalse);
      expect(TaskFilter.overdue.matches(authored), isFalse);

      // и та же мера у «на сегодня» и «открытых» — у них тоже есть плитка-двойник
      final freeToday =
          _view(Task(id: 'E', deadline: _iso(_today)), group: TaskGroup.free);
      expect(TaskFilter.today.matches(freeToday), isFalse);
      expect(TaskFilter.open.matches(freeToday), isFalse);
    });

    // «Все задачи» — единственный чип без плитки: через него видно то, что три
    // остальных прячут, иначе свободный пул стал бы недостижим с этого экрана.
    test('«все задачи» показывают список целиком', () {
      final free = _view(Task(id: 'B', deadline: _iso(_yesterday)),
          group: TaskGroup.free);
      expect(TaskFilter.all.matches(free), isTrue);
    });

    // Приёмка в миниатюре: цифра плитки и длина списка — одно число, и остаются одним,
    // когда часы телефона врут на сутки.
    test('длина списка равна цифре плитки при сдвинутой дате телефона', () {
      // сервер: две мои просрочены, одна моя на сегодня, одна чужая просрочена
      final views = [
        _view(Task(
            id: 'A',
            deadline: _iso(_tomorrow),
            overdue: true,
            dueToday: false)),
        _view(Task(
            id: 'B',
            deadline: _iso(_tomorrow),
            overdue: true,
            dueToday: false)),
        _view(Task(
            id: 'C',
            deadline: _iso(_tomorrow),
            overdue: false,
            dueToday: true)),
        _view(
            Task(
                id: 'D',
                deadline: _iso(_tomorrow),
                overdue: true,
                dueToday: false),
            group: TaskGroup.free),
      ];
      const tileOverdue = 2; // myOverdue: mine + deadline < currentDate()
      const tileToday = 1;

      expect(views.where(TaskFilter.overdue.matches).length, tileOverdue);
      expect(views.where(TaskFilter.today.matches).length, tileToday);
    });
  });
}
