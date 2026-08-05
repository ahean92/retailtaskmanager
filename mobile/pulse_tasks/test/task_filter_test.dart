import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_tasks/data/task_repository.dart';
import 'package:pulse_tasks/models/task.dart';

String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

TaskView _view({String? deadline, bool closed = false}) => TaskView(
      Task(id: 'ST1', deadline: deadline),
      closed ? 'done' : 'new',
      closed ? 'Выполнено' : 'Новый',
      false,
      closed: closed,
    );

void main() {
  final today = DateTime.now();
  final yesterday = today.subtract(const Duration(days: 1));
  final tomorrow = today.add(const Duration(days: 1));

  test('overdue is yesterday and open; today and tomorrow are not', () {
    expect(_view(deadline: _iso(yesterday)).overdue, isTrue);
    expect(_view(deadline: _iso(today)).overdue, isFalse);
    expect(_view(deadline: _iso(tomorrow)).overdue, isFalse);
  });

  // The deadline stopped mattering the moment the work was done — a closed task must not
  // keep shouting from the list in red.
  test('a closed task is never overdue or due today', () {
    expect(_view(deadline: _iso(yesterday), closed: true).overdue, isFalse);
    expect(_view(deadline: _iso(today), closed: true).dueToday, isFalse);
  });

  test('no deadline means neither overdue nor due today', () {
    expect(_view().overdue, isFalse);
    expect(_view().dueToday, isFalse);
    expect(_view(deadline: 'не дата').overdue, isFalse);
  });

  test('dueToday is exactly today', () {
    expect(_view(deadline: _iso(today)).dueToday, isTrue);
    expect(_view(deadline: _iso(yesterday)).dueToday, isFalse);
  });

  test('filters select what their titles promise', () {
    final overdue = _view(deadline: _iso(yesterday));
    final todayTask = _view(deadline: _iso(today));
    final later = _view(deadline: _iso(tomorrow));
    final closed = _view(deadline: _iso(yesterday), closed: true);

    expect(TaskFilter.all.matches(closed), isTrue);
    expect(TaskFilter.open.matches(closed), isFalse);
    expect(TaskFilter.open.matches(later), isTrue);
    expect(TaskFilter.today.matches(todayTask), isTrue);
    expect(TaskFilter.today.matches(later), isFalse);
    expect(TaskFilter.overdue.matches(overdue), isTrue);
    expect(TaskFilter.overdue.matches(todayTask), isFalse);
  });

  // An unknown code is a newer server offering a filter this build does not know; showing
  // everything beats showing nothing.
  test('an unknown filter code falls back to all', () {
    expect(TaskFilter.parse('overdue'), TaskFilter.overdue);
    expect(TaskFilter.parse('somethingNew'), TaskFilter.all);
    expect(TaskFilter.parse(null), TaskFilter.all);
  });
}
