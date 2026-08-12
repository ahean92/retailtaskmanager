import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_tasks/models/home.dart';
import 'package:pulse_tasks/ui/widgets/home_blocks.dart';

/// Плитка сводки: «сколько здесь» и «сколько всего», когда числа расходятся.
///
/// Демо-набор тикета: шесть открытых задач, по одной на шести объектах. Плитка считается
/// по магазину, в котором человек стоит, сетевая цифра добирается второй строкой — и
/// только при расхождении, иначе исполнитель с одним магазином читал бы каждую плитку
/// дважды.

HomeBlock _kpi(HomeMetric metric) => HomeBlock(
      code: 'myKpi',
      type: 'metrics',
      view: 'tiles',
      byObject: true,
      title: 'Сводка',
      metrics: [metric],
    );

Future<void> _pump(
    WidgetTester tester, HomeMetric metric, String objectId) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: HomeMetricsBlock(
        block: _kpi(metric),
        objectId: objectId,
        onTapMetric: (_) {},
      ),
    ),
  ));
}

void main() {
  const open = HomeMetric(
    code: 'myOpen',
    name: 'Открытых',
    value: 6,
    filter: 'open',
    values: {
      'p18': HomeMetricValue(value: 1),
      'b23': HomeMetricValue(value: 0),
      'k31': HomeMetricValue(value: 6),
    },
  );

  testWidgets('числа расходятся — «1 здесь / всего 6»', (tester) async {
    await _pump(tester, open, 'p18');

    expect(find.text('1'), findsOneWidget);
    expect(find.text('здесь'), findsOneWidget);
    expect(find.text('всего 6'), findsOneWidget);
  });

  testWidgets('магазин без задач — «0 здесь / всего 6», а не сетевые шесть',
      (tester) async {
    await _pump(tester, open, 'b23');

    expect(find.text('0'), findsOneWidget);
    expect(find.text('здесь'), findsOneWidget);
    expect(find.text('всего 6'), findsOneWidget);
  });

  // Слова «здесь» и «всего» появляются строго парой: одинокая подпись при совпавших
  // числах ничего бы не объясняла, а только шумела.
  testWidgets('числа совпали — одно число, без подписей', (tester) async {
    await _pump(tester, open, 'k31');

    expect(find.text('6'), findsOneWidget);
    expect(find.textContaining('всего'), findsNothing);
    expect(find.text('здесь'), findsNothing);
  });

  // Объект, о котором сервер ничего не прислал, показывает сетевую цифру — и хвост
  // «всего» рядом с ней дублировал бы её же.
  testWidgets('без своих данных — сетевая цифра и тоже без подписей',
      (tester) async {
    await _pump(tester, open, 'x99');

    expect(find.text('6'), findsOneWidget);
    expect(find.textContaining('всего'), findsNothing);
    expect(find.text('здесь'), findsNothing);
  });

  // На строке с цифрой помещается один сосед: «здесь» выталкивает единицу измерения
  // в подпись — тем же правилом, что и чип динамики.
  testWidgets('с подписью «здесь» единица переезжает в подпись плитки',
      (tester) async {
    const checks = HomeMetric(
      code: 'checks',
      name: 'Чеков',
      unit: 'шт',
      value: 200,
      values: {'p18': HomeMetricValue(value: 120)},
    );
    await _pump(tester, checks, 'p18');

    expect(find.text('Чеков, шт'), findsOneWidget);
    expect(find.text('шт'), findsNothing);

    // а без второй цифры единица остаётся у числа, как раньше
    await _pump(tester, checks, 'x99');
    expect(find.text('шт'), findsOneWidget);
    expect(find.text('Чеков'), findsOneWidget);
  });
}
