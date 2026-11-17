import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_tasks/models/home.dart';
import 'package:pulse_tasks/ui/widgets/home/tiles.dart';

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
    WidgetTester tester, HomeMetric metric, String? objectId) async {
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

  // Объект, о котором сервер ничего не прислал: прочерк, а не сетевая цифра — та читалась
  // как цифра магазина. Сетевая остаётся рядом, подписанная «всего».
  testWidgets('без своих данных — прочерк здесь, сетевая цифра — «всего»',
      (tester) async {
    await _pump(tester, open, 'x99');

    expect(find.text('—'), findsOneWidget);
    expect(find.text('здесь'), findsOneWidget);
    expect(find.text('всего 6'), findsOneWidget);
    expect(find.text('6'), findsNothing);
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
    await _pump(tester, checks, null);
    expect(find.text('шт'), findsOneWidget);
    expect(find.text('Чеков'), findsOneWidget);
  });

  // Изменение и «всего» рядом с «здесь» сжимали саму цифру до нуля: плитка в пол-экрана
  // на 320 dp — около 110 px внутри. С «всего» изменение и сетевая цифра уходят ниже
  // цифры, а не помещаются рядом — «всего» встаёт своей строкой, не теряя цифр. Тестовый
  // шрифт шире настоящего (глиф — квадрат во весь кегль): четырёхзначное «1.3K» в нём
  // ещё обрезается, в Roboto устройства — нет (54,9 px из ~90 на 320 dp); здесь —
  // ширина больше нуля, «всего» целиком и без переполнения.
  group('плитка с изменением и «всего» на узком экране', () {
    const small = HomeMetric(
      code: 'myOpen',
      name: 'Открытых',
      value: 6,
      trend: 'percent',
      values: {'p18': HomeMetricValue(value: 5, previous: 3)},
    );
    const big = HomeMetric(
      code: 'checks',
      name: 'Чеков',
      unit: 'шт',
      value: 2300,
      trend: 'percent',
      values: {'p18': HomeMetricValue(value: 1284, previous: 1147)},
    );

    for (final width in [320.0, 360.0]) {
      testWidgets('ширина $width: цифра видна, изменение и «всего» — второй строкой',
          (tester) async {
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        await _pump(tester, small, 'p18');
        expect(tester.takeException(), isNull);
        final five = tester.renderObject<RenderParagraph>(find.text('5'));
        expect(five.size.width, greaterThan(0));
        expect(five.didExceedMaxLines, isFalse);
        expect(find.text('здесь'), findsOneWidget);
        expect(find.text('+67%'), findsOneWidget);
        expect(find.text('всего 6'), findsOneWidget);
        // изменение и «всего» — ниже цифры, «всего» — целиком
        final below = tester.getBottomLeft(find.text('5')).dy - 1;
        expect(tester.getTopLeft(find.text('+67%')).dy, greaterThan(below));
        expect(tester.getTopLeft(find.text('всего 6')).dy, greaterThan(below));
        expect(
            tester
                .renderObject<RenderParagraph>(find.text('всего 6'))
                .didExceedMaxLines,
            isFalse);

        await _pump(tester, big, 'p18');
        expect(tester.takeException(), isNull);
        expect(tester.getSize(find.text('1.3K')).width, greaterThan(0));
        expect(find.text('всего 2.3K'), findsOneWidget);
        expect(find.text('+12%'), findsOneWidget);
      });
    }
  });
}
