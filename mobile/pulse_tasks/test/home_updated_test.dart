import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_tasks/models/home.dart';
import 'package:pulse_tasks/ui/widgets/home/tiles.dart';

/// «Обновлено …» в шапке блока главной: когда внешняя система в последний раз прислала
/// числа. Без этого зависшая интеграция неотличима от свежей цифры — вчерашняя выручка
/// стоит на плитке так же уверенно, как сегодняшняя.

HomeBlock _block(List<Map<String, dynamic>> metrics) => HomeBlock.fromJson({
      'code': 'sales',
      'type': 'metrics',
      'view': 'bars',
      'byObject': true,
      'title': 'Продажи',
      'metrics': metrics,
    });

void main() {
  test('время — своего уровня: сетевое у сети, по объекту у объекта', () {
    final b = _block([
      {
        'code': 'rev',
        'name': 'Выручка',
        'value': 612,
        'time': '2026-11-18T09:00:00',
        'values': [
          {'object': 'p18', 'value': 526, 'time': '2026-11-17T21:30:00'},
          {'object': 'b23', 'value': 498},
        ],
      },
    ]);
    final m = b.metrics.single;
    expect(m.timeFor(null), DateTime(2026, 11, 18, 9));
    expect(m.timeFor('p18'), DateTime(2026, 11, 17, 21, 30));
    // у объекта своего времени нет — сетевое ему не подставляется
    expect(m.timeFor('b23'), isNull);
  });

  test('блок отвечает самым старым временем, расчётные показатели не в счёт', () {
    final b = _block([
      {'code': 'rev', 'name': 'Выручка', 'value': 1, 'time': '2026-11-18T09:00:00'},
      {'code': 'checks', 'name': 'Чеки', 'value': 2, 'time': '2026-11-16T23:00:00'},
      // считает сама система — времени нет, и «обновлено» оно не старит
      {'code': 'myOpen', 'name': 'Открытых', 'value': 3},
    ]);
    expect(b.updatedFor(null), DateTime(2026, 11, 16, 23));
    final computed = _block([
      {'code': 'myOpen', 'name': 'Открытых', 'value': 3},
    ]);
    expect(computed.updatedFor(null), isNull);
  });

  test('время переживает кэш главной', () {
    final src = HomeLayout.fromJson({
      'blocks': [
        {
          'code': 'sales',
          'type': 'metrics',
          'byObject': true,
          'title': 'Продажи',
          'metrics': [
            {
              'code': 'rev',
              'name': 'Выручка',
              'value': 612,
              'time': '2026-11-18T09:00:00',
              'values': [
                {'object': 'p18', 'value': 526, 'time': '2026-11-17T21:30:00'},
              ],
            },
          ],
        },
      ],
    });
    final m = HomeLayout.fromJson(src.toJson()).blocks.single.metrics.single;
    expect(m.timeFor(null), DateTime(2026, 11, 18, 9));
    expect(m.timeFor('p18'), DateTime(2026, 11, 17, 21, 30));
  });

  test('подпись: сегодня — время, раньше — дата, другой год — с годом', () {
    final now = DateTime(2026, 11, 18, 15, 0);
    expect(HomeSectionHeader.updatedText(DateTime(2026, 11, 18, 9, 5), now),
        'обновлено 09:05');
    expect(HomeSectionHeader.updatedText(DateTime(2026, 11, 17, 23, 59), now),
        'обновлено 17.11');
    expect(HomeSectionHeader.updatedText(DateTime(2025, 3, 4, 8, 0), now),
        'обновлено 04.03.2025');
  });

  testWidgets('шапка блока показывает время выбранного объекта', (tester) async {
    final b = _block([
      {
        'code': 'rev',
        'name': 'Выручка',
        'value': 612,
        'time': '2024-02-01T09:00:00',
        'values': [
          {'object': 'p18', 'value': 526, 'time': '2024-01-31T21:30:00'},
        ],
      },
    ]);
    Future<void> pump(String? objectId) => tester.pumpWidget(MaterialApp(
          home: Scaffold(body: HomeSectionHeader(block: b, objectId: objectId)),
        ));

    await pump(null);
    expect(find.text('обновлено 01.02.2024'), findsOneWidget);
    await pump('p18');
    expect(find.text('обновлено 31.01.2024'), findsOneWidget);
    // у блока без внешних чисел строки нет вовсе
    final computed = _block([
      {'code': 'myOpen', 'name': 'Открытых', 'value': 3},
    ]);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: HomeSectionHeader(block: computed)),
    ));
    expect(find.textContaining('обновлено'), findsNothing);
  });
}
