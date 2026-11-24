import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_tasks/data/local_db.dart';
import 'package:pulse_tasks/models/task.dart';
import 'package:pulse_tasks/models/task_status.dart';
import 'support/test_env.dart';

/// Задача со всеми ключами apiTasks, каждый со значением: флаги — и true, и false, чтобы
/// дорогу прошли оба. Новое поле задачи без строки здесь роняет тест ниже — так он и
/// задуман.
Map<String, dynamic> _everyKey() => {
      'id': 'ST00000042',
      'clientId': '7f1c2a9e-0d4b-4c51-9a3e-2b6f8c1d0e55',
      'name': 'Проверить выкладку',
      'description': 'Полка у кассы',
      'object': 'Магазин №1',
      'objectId': 'SOS-101',
      'placeId': 'SOS-101-P1',
      'distance': 120.5,
      'address': 'ул. Притыцкого, 1',
      'type': 'Поручение',
      'typeId': 'issue',
      'status': 'В работе',
      'statusId': 'in progress',
      'closedAt': '2026-11-18T10:42:00',
      'nextStatuses': [
        {'id': 'done'},
        {'id': 'canceled'}
      ],
      'executionKind': 'simple',
      'requirePhoto': true,
      'priority': 'Высокий',
      'priorityId': 'high',
      'assignedTo': 'Петров П.П.',
      'assigneeId': 'p2',
      'author': 'Иванов И.И.',
      'authorId': 'p1',
      'postedAt': '2026-11-17T09:00:00',
      'deadline': '2026-11-20',
      'dueToday': false,
      'overdue': true,
      'progress': 40,
      'subtitle': 'Открытие магазина',
      'lastCommentText': 'Готово',
      'lastCommentAuthor': 'Петров П.П.',
      'lastCommentAt': '2026-11-18T10:40:00',
      'lastCommentFiles': 2,
      'takenById': 'p3',
      'takenBy': 'Сидоров С.С.',
      'takenAt': '2026-11-18T08:00:00',
      'canTake': false,
      'mine': true,
      'assigned': true,
      'authored': false,
      'watched': true,
      'following': false,
      'needsAcceptance': true,
      'acceptor': 'Кузнецов К.К.',
      'acceptorId': 'p4',
      'submittedAt': '2026-11-18T10:41:00',
      'awaitingDecision': false,
      'reviewing': true,
      'returned': false,
      'returnReason': 'Нет фото',
      'commentCount': 3,
      'unreadComments': 1,
      'files': [
        {
          'id': '7',
          'name': 'фото.jpg',
          'image': true,
          'dateTime': '2026-11-18T10:00:00',
          'author': 'Петров П.П.'
        }
      ],
      'executions': [
        {
          'id': '9',
          'dateTime': '2026-11-18T09:30:00',
          'executor': 'Петров П.П.',
          'finished': true,
          'result': 'Пройдена',
          'photoId': '11'
        }
      ],
    };

void main() {
  initTestEnv();

  test('задача доходит от apiTasks до кэша и обратно без потерь', () async {
    resetMockStores();
    final t = Task.fromJson(_everyKey());
    final map = t.toMap();
    expect([for (final e in map.entries) if (e.value == null) e.key], isEmpty,
        reason: 'поле осталось пустым: fromJson его не читает или toMap не пишет');

    // настоящая таблица tasks: схема, toMap и fromMap обязаны сходиться
    final db = await LocalDb.open('ttask_roundtrip');
    try {
      await db.tasks.insertLocalTask(t);
      final back = (await db.tasks.getTasks()).single;
      expect(back.toMap(), map);
    } finally {
      await db.close();
    }
  });

  test('Task.fromJson parses the apiTasks shape (null fields omitted)', () {
    final t = Task.fromJson({
      'id': 'ST000001',
      'object': 'Магазин №1 (Тверская)',
      'type': 'Проверка по чек-листу',
      'typeId': 'checklist',
      'status': 'В процессе',
      'statusId': 'in progress',
      'deadline': '2026-07-25',
      'subtitle': 'Открытие магазина',
    });
    expect(t.id, 'ST000001');
    expect(t.object, 'Магазин №1 (Тверская)');
    expect(t.statusId, 'in progress');
    expect(t.address, isNull); // omitted in JSON -> null
    expect(t.progress, isNull);
  });

  test('Task round-trips through the sqflite map', () {
    const t = Task(
        id: 'ST000009', object: 'X', statusId: 'new', progress: 50);
    final back = Task.fromMap(t.toMap());
    expect(back.id, 'ST000009');
    expect(back.object, 'X');
    expect(back.statusId, 'new');
    expect(back.progress, 50);
  });

  test('поля взятия (#36836): парсинг и трёхзначность флагов', () {
    final t = Task.fromJson({
      'id': 'ST000010',
      'takenById': 'p2',
      'takenBy': 'Петров П.П.',
      'takenAt': '2026-08-20T10:42:00',
      'mine': true,
    });
    expect(t.takenById, 'p2');
    expect(t.takenBy, 'Петров П.П.');
    expect(t.mine, isTrue);
    // ключа не было — это ответ «сервер не говорил», а не false
    expect(t.canTake, isNull);

    // тройственность переживает дорогу через sqlite-карту
    final back = Task.fromMap(t.toMap());
    expect(back.mine, isTrue);
    expect(back.canTake, isNull);
    expect(back.takenAt, '2026-08-20T10:42:00');

    // строка без ключей взятия (рождена на телефоне)
    final legacy = Task.fromJson({'id': 'ST000011'});
    expect(legacy.mine, isNull);
    expect(legacy.takenById, isNull);
    expect(legacy.canTake, isNull);
  });

  test('участие и переписка (#36844): флаги, счётчики, авторская-и-только', () {
    final authored = Task.fromJson({
      'id': 'ST000020',
      'authored': true,
      'commentCount': 3,
      'unreadComments': 2,
    });
    expect(authored.authored, isTrue);
    expect(authored.assigned, isNull, reason: 'ключа не было — сервер не говорил');
    expect(authored.authoredOnly, isTrue);
    expect(authored.commentCount, 3);
    expect(authored.unreadComments, 2);

    final both = Task.fromJson(
        {'id': 'ST000021', 'authored': true, 'assigned': true});
    expect(both.authoredOnly, isFalse, reason: 'сам себе поставил — исполнитель');

    // строка без ключей участия (рождена на телефоне): назначенная
    final legacy = Task.fromJson({'id': 'ST000022'});
    expect(legacy.authoredOnly, isFalse);
    expect(legacy.commentCount, isNull);

    // дорога через sqlite-карту сохраняет и трёхзначность, и числа
    final back = Task.fromMap(authored.toMap());
    expect(back.authored, isTrue);
    expect(back.assigned, isNull);
    expect(back.commentCount, 3);
    expect(back.unreadComments, 2);
  });

  test('TaskStatus treats an omitted "closed" as open', () {
    final open = TaskStatus.fromJson(
        {'id': 'new', 'name': 'Новый', 'sortingOrder': 1});
    final closed = TaskStatus.fromJson(
        {'id': 'done', 'name': 'Выполнен', 'closed': true, 'sortingOrder': 3});
    expect(open.closed, isFalse);
    expect(closed.closed, isTrue);
  });
}
