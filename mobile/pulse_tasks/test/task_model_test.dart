import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_tasks/models/task.dart';
import 'package:pulse_tasks/models/task_status.dart';

void main() {
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

    // строка старого сервера — ни одного ключа взятия
    final legacy = Task.fromJson({'id': 'ST000011'});
    expect(legacy.mine, isNull);
    expect(legacy.takenById, isNull);
    expect(legacy.canTake, isNull);
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
