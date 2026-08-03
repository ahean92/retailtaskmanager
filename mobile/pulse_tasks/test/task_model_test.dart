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

  test('TaskStatus treats an omitted "closed" as open', () {
    final open = TaskStatus.fromJson(
        {'id': 'new', 'name': 'Новый', 'sortingOrder': 1});
    final closed = TaskStatus.fromJson(
        {'id': 'done', 'name': 'Выполнен', 'closed': true, 'sortingOrder': 3});
    expect(open.closed, isFalse);
    expect(closed.closed, isTrue);
  });
}
