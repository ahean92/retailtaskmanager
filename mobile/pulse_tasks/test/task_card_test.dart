import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_tasks/models/task.dart';
import 'package:pulse_tasks/models/task_view.dart';
import 'package:pulse_tasks/ui/widgets/task_card.dart';

// Строка списка (#36915, возврат по приёмке): адрес объекта и срок человеческой датой.

Future<void> _pump(WidgetTester tester, Task task, {double width = 360}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: ListView(children: [
        TaskCard(view: TaskView(task, 'new', 'Новая', false), onTap: () {}),
      ]),
    ),
  ));
}

void main() {
  final year = DateTime.now().year;

  group('formatDate', () {
    test('полная дата — для карточки задачи', () {
      expect(formatDate('2026-08-30'), '30.08.2026');
      expect(formatDate('2025-01-05'), '05.01.2025');
    });

    test('короткая: без года в текущем году, с годом — в другом', () {
      expect(formatDate('$year-08-30', short: true), '30.08');
      expect(formatDate('${year - 1}-08-30', short: true), '30.08.${year - 1}');
      expect(formatDate('${year + 1}-01-02', short: true), '02.01.${year + 1}');
    });

    test('время отбрасывается — и через T, и через пробел', () {
      expect(formatDate('2026-07-12T14:00:00'), '12.07.2026');
      expect(formatDate('2026-07-12 14:00:00'), '12.07.2026');
    });

    test('пустое — null, не дата — как пришло', () {
      expect(formatDate(null), isNull);
      expect(formatDate(''), isNull);
      expect(formatDate('послезавтра'), 'послезавтра');
    });

    test('Task.deadlineText — короткий срок той же функцией', () {
      expect(Task(id: 'ST1', deadline: '$year-08-30').deadlineText, '30.08');
      expect(const Task(id: 'ST1').deadlineText, isNull);
    });
  });

  group('строка списка', () {
    testWidgets('адрес — отдельной строкой под объектом, срок — «30.08»',
        (tester) async {
      await _pump(
          tester,
          Task(
            id: 'ST1',
            object: 'Санта №23, Брест',
            address: 'г. Брест, бульвар Шевченко, 4',
            type: 'Проверка по чек-листу',
            subtitle: 'Открытие магазина',
            deadline: '$year-08-30',
          ));

      final address = find.text('г. Брест, бульвар Шевченко, 4');
      expect(address, findsOneWidget);
      expect(find.text('30.08'), findsOneWidget);
      expect(find.text('$year-08-30'), findsNothing);

      // под объектом и над мета-строкой, а не внутри неё
      final objectY = tester.getTopLeft(find.text('Санта №23, Брест')).dy;
      final metaY = tester
          .getTopLeft(find.text('Проверка по чек-листу · Открытие магазина'))
          .dy;
      final addressY = tester.getTopLeft(address).dy;
      expect(addressY, greaterThan(objectY));
      expect(addressY, lessThan(metaY));
    });

    testWidgets('длинный адрес — в одну линию с многоточием, без переполнения',
        (tester) async {
      await _pump(
          tester,
          const Task(
            id: 'ST1',
            object: 'Санта №24, Брест (ТЦ)',
            address: 'Брестская область, г. Брест, бульвар Шевченко, 4, '
                'торговый центр «Дидас Персия», второй этаж, павильон 17',
          ),
          width: 320);

      final text = tester.widget<Text>(find.textContaining('бульвар Шевченко'));
      expect(text.maxLines, 1);
      expect(text.overflow, TextOverflow.ellipsis);
      expect(tester.takeException(), isNull);
    });

    testWidgets('адреса нет или он пустой — строки нет', (tester) async {
      for (final address in [null, ' ']) {
        await _pump(
            tester,
            Task(
                id: 'ST1',
                object: 'Магазин №1',
                type: 'Поручение',
                address: address));
        expect(_cardTexts(tester), ['Магазин №1', 'Поручение', 'Новая']);
      }
    });
  });
}

List<String?> _cardTexts(WidgetTester tester) => tester
    .widgetList<Text>(
        find.descendant(of: find.byType(TaskCard), matching: find.byType(Text)))
    .map((t) => t.data)
    .toList();
