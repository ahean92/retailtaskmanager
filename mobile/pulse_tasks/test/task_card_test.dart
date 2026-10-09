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
    // Редизайн #37411, п. 4: заголовок строки — название задачи, а не объект;
    // адрес в списке не показывается вовсе — его место в карточке задачи.

    testWidgets('адрес не показывается, просроченный срок — «на сколько»',
        (tester) async {
      await _pump(
          tester,
          Task(
            id: 'ST1',
            name: 'Проверка кассовой зоны',
            object: 'Санта №23, Брест',
            address: 'г. Брест, бульвар Шевченко, 4',
            type: 'Проверка по чек-листу',
            subtitle: 'Открытие магазина',
            deadline: '${year - 1}-08-30',
          ));

      expect(find.text('г. Брест, бульвар Шевченко, 4'), findsNothing,
          reason: 'адрес — в карточке задачи, не в строке списка');
      // срок прошлый — чип говорит «на сколько» просрочен, а не голую дату
      // (стр. 2 макета; время сервер не присылает, глубина — днями)
      final now = DateTime.now();
      final days = DateTime(now.year, now.month, now.day)
          .difference(DateTime(year - 1, 8, 30))
          .inDays;
      expect(find.text('Просрочено на $days дн.'), findsOneWidget);
      expect(find.text('${year - 1}-08-30'), findsNothing);

      // тип — ярусом над заголовком, статус — чипом справа
      final typeY = tester
          .getTopLeft(find.text('Проверка по чек-листу · Открытие магазина'))
          .dy;
      final titleY = tester.getTopLeft(find.text('Проверка кассовой зоны')).dy;
      expect(titleY, greaterThan(typeY));
    });

    testWidgets('названия нет — заголовком становится объект', (tester) async {
      await _pump(
          tester,
          const Task(
              id: 'ST1', object: 'Магазин №1', type: 'Поручение'));
      // порядок ярусов: тип и статус, затем заголовок
      expect(_cardTexts(tester), ['Поручение', 'Новая', 'Магазин №1']);
    });

    testWidgets('длинное название — две строки с многоточием, без переполнения',
        (tester) async {
      await _pump(
          tester,
          const Task(
            id: 'ST1',
            object: 'Санта №24',
            name: 'Переоценка акционных товаров большой группы позиций '
                'в торговом зале и складских помещениях с пересчётом остатков',
          ),
          width: 320);

      final text =
          tester.widget<Text>(find.textContaining('Переоценка акционных'));
      expect(text.maxLines, 2);
      expect(text.overflow, TextOverflow.ellipsis);
      expect(tester.takeException(), isNull);
    });

    testWidgets('пустой адрес не оставляет следов', (tester) async {
      for (final address in [null, ' ']) {
        await _pump(
            tester,
            Task(
                id: 'ST1',
                name: 'Проверка зала',
                object: 'Магазин №1',
                type: 'Поручение',
                address: address));
        expect(_cardTexts(tester), ['Поручение', 'Новая', 'Проверка зала']);
      }
    });

    // последнее сообщение ленты — цитатой под заголовком (#37411, стр. 2):
    // «о чём сейчас разговор» видно из списка, без открытия задачи
    testWidgets('последний комментарий — цитатой с автором', (tester) async {
      await _pump(
          tester,
          const Task(
              id: 'ST1',
              name: 'Проверка зала',
              type: 'Поручение',
              lastCommentText: 'Не забудьте пересчитать молоко',
              lastCommentAuthor: 'Петров И.'));
      expect(find.text('«Не забудьте пересчитать молоко» — Петров И.'),
          findsOneWidget);
    });

    testWidgets(
        'фото-вложение — тоже последнее: строкой «Фотография», а не текстом постарше',
        (tester) async {
      // последнее сообщение — фото без текста: сервер в этом случае text НЕ
      // присылает вовсе, только автора/время/вложения. Подменять фото старым
      // текстом значило бы соврать о том, что сейчас в ленте
      await _pump(
          tester,
          const Task(
              id: 'ST1',
              name: 'Проверка зала',
              type: 'Поручение',
              lastCommentAuthor: 'Петров И.',
              lastCommentAt: '2026-10-09T12:00:00',
              lastCommentFiles: 1));
      expect(find.text('Фотография — Петров И.'), findsOneWidget);
      expect(find.textContaining('Фотография'), findsOneWidget);

      // без автора — просто «Фотография»
      await _pump(
          tester,
          const Task(
              id: 'ST1',
              name: 'Проверка зала',
              type: 'Поручение',
              lastCommentAt: '2026-10-09T12:00:00',
              lastCommentFiles: 2));
      expect(find.text('Фотография'), findsOneWidget);
    });

    testWidgets('сообщений нет — строки нет; текст без автора — без тире',
        (tester) async {
      await _pump(
          tester,
          const Task(
              id: 'ST1',
              name: 'Проверка зала',
              type: 'Поручение',
              lastCommentText: 'Пересчитайте к вечеру'));
      expect(find.text('«Пересчитайте к вечеру»'), findsOneWidget);

      await _pump(
          tester,
          const Task(
              id: 'ST1',
              name: 'Проверка зала',
              type: 'Поручение',
              lastCommentText: ' ',
              lastCommentAuthor: 'Система'));
      expect(find.textContaining('Система'), findsNothing,
          reason: 'ни текста, ни вложений — сообщения нет');
    });
  });
}

List<String?> _cardTexts(WidgetTester tester) => tester
    .widgetList<Text>(
        find.descendant(of: find.byType(TaskCard), matching: find.byType(Text)))
    .map((t) => t.data)
    .toList();
