import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_tasks/models/home.dart';
import 'package:pulse_tasks/ui/widgets/home/charts.dart';
import 'package:pulse_tasks/ui/widgets/home/tiles.dart';

import 'support/fake_pulse_server.dart';

/// Графики главной на блоке показателей, записанном с сервера (сводка «Мои задачи»
/// сида: открытых 16, остальное по нулям, разрез по объекту ZZZE2E). Вид рисования —
/// настройка блока на сервере (`view`), содержимое то же: столбики и график
/// подписывают каждый показатель объекта, кольцо делит целое без нулевых долей и
/// несёт «всего» в центре, шкала выполнения рисуется только при плане и честно
/// показывает перевыполнение.

const _object = 'ZZZE2E';

/// Блок сводки из записанной главной с видом [view].
Map<String, dynamic> _kpi(String view) {
  final block = (fixtureMap('apiHome')['blocks'] as List)
      .cast<Map>()
      .firstWhere((b) => b['code'] == 'myKpi')
      .cast<String, dynamic>();
  return block..['view'] = view;
}

Map<String, dynamic> _metric(Map<String, dynamic> block, String code) =>
    (block['metrics'] as List)
        .cast<Map>()
        .firstWhere((m) => m['code'] == code)
        .cast<String, dynamic>();

Future<void> _show(WidgetTester t, Map<String, dynamic> block) => t.pumpWidget(
    MaterialApp(
        home: Scaffold(
            body: HomeMetricsBlock(
                block: HomeBlock.fromJson(block), objectId: _object))));

void main() {
  testWidgets('столбики и график: подпись и число каждого показателя объекта',
      (t) async {
    final bars = _kpi('bars');
    // сеть и объект расходятся — на главной объекта числа объекта
    _metric(bars, 'myOpen')['value'] = 99;
    await _show(t, bars);
    expect(find.byType(HomeChart), findsOneWidget);
    for (final name in ['Открытых', 'На сегодня', 'Просрочено', 'Ждут приёмки']) {
      expect(find.text(name), findsOneWidget, reason: name);
    }
    expect(find.text('16'), findsOneWidget, reason: 'число объекта, а не сети');
    expect(find.text('99'), findsNothing);
    expect(find.text('0'), findsNWidgets(3));

    await _show(t, _kpi('line'));
    expect(find.byType(HomeChart), findsOneWidget);
    expect(find.text('Открытых'), findsOneWidget);
    expect(find.text('Ждут приёмки'), findsOneWidget);
  });

  testWidgets('кольцо: доли без нулевых, в центре — всего', (t) async {
    final donut = _kpi('donut');
    _metric(donut, 'myToday')['values'] = [
      {'object': _object, 'value': 4}
    ];
    await _show(t, donut);
    expect(find.byType(HomeDonut), findsOneWidget);
    expect(find.text('20'), findsOneWidget, reason: 'всего: 16 + 4');
    expect(find.text('всего'), findsOneWidget);
    expect(find.text('Открытых'), findsOneWidget);
    expect(find.text('80%'), findsOneWidget);
    expect(find.text('На сегодня'), findsOneWidget);
    expect(find.text('20%'), findsOneWidget);
    expect(find.text('Просрочено'), findsNothing,
        reason: 'нулевая доля в кольце не рисуется и в легенду не идёт');
  });

  testWidgets('шкала выполнения: без плана не рисуется, перевыполнение — полная '
      'полоса и настоящий процент', (t) async {
    // в сиде плана нет — ключа target сервер не выгружает
    await _show(t, _kpi('progress'));
    expect(find.byType(LinearProgressIndicator), findsNothing);

    final progress = _kpi('progress');
    // план объекту ставит интеграция (apiSetMetric) — на разрезе тот же ключ target
    (_metric(progress, 'myOpen')['values'] as List).cast<Map>().single['target'] =
        10;
    await _show(t, progress);
    expect(find.text('160%'), findsOneWidget, reason: 'настоящий процент');
    expect(find.text('16 из 10'), findsOneWidget);
    final bar =
        t.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator));
    expect(bar.value, 1.0, reason: 'полоса не вылезает за край');
  });
}
