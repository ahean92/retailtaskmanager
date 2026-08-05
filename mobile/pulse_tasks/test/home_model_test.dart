import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_tasks/models/home.dart';

void main() {
  test('fromJson reads blocks with their metrics, news and objects', () {
    final layout = HomeLayout.fromJson({
      'objects': [
        {'id': 'p18', 'name': 'Санта №18, Пинск', 'address': 'ул. Первомайская, 158'},
        {'id': 'b23', 'name': 'Санта №23, Брест'},
      ],
      'blocks': [
        {
          'code': 'storeKpi',
          'type': 'metrics',
          'view': 'tiles',
          'byObject': true,
          'title': 'Магазин сегодня',
          'subtitle': 'Данные кассового узла',
          'icon': '🏬',
          'metrics': [
            {
              'code': 'checksToday',
              'name': 'Чеков',
              'value': 1284,
              'unit': 'шт',
              'values': [
                {'object': 'p18', 'value': 1104},
                {'object': 'b23', 'value': 998},
              ],
            },
          ],
        },
        {
          'code': 'news',
          'type': 'news',
          'title': 'Новости',
          'news': [
            {'date': '2026-07-20', 'title': 'Итоги июля', 'body': '<p>84%</p>'},
          ],
        },
      ],
    });

    expect(layout.blocks.length, 2);
    expect(layout.objects.map((o) => o.id), ['p18', 'b23']);
    expect(layout.objects.first.address, 'ул. Первомайская, 158');
    expect(layout.hasObjectBlocks, isTrue);

    final kpi = layout.blocks.first;
    expect(kpi.type, 'metrics');
    expect(kpi.view, 'tiles');
    expect(kpi.byObject, isTrue);
    expect(kpi.metrics.single.values.length, 2);
    expect(layout.blocks[1].news.single.title, 'Итоги июля');
  });

  test('a per-object metric answers for the selected object, else network-wide', () {
    const m = HomeMetric(
      code: 'revenue',
      name: 'Выручка',
      value: 31.6,
      values: {'p18': HomeMetricValue(value: 27.2, target: 40)},
    );
    expect(m.valueFor('p18'), 27.2);
    expect(m.valueFor('k31'), 31.6); // no data of its own — the company figure stands
    expect(m.valueFor(null), 31.6);
    expect(m.targetFor('p18'), 40);
    expect(m.targetFor('k31'), isNull);
  });

  group('динамика показателя', () {
    const grew = HomeMetric(
        code: 'checks', name: 'Чеков', value: 1284, previous: 1147);

    test('в процентах и в количестве — по настройке показателя', () {
      final pct = HomeMetric.fromJson({
        ...grew.toJson(),
        'trend': 'percent',
      }).deltaFor(null)!;
      expect(pct.up, isTrue);
      expect(pct.good, isTrue);
      expect(pct.label, '+12%'); // от 10% дробная часть уже только шумит

      final abs = HomeMetric.fromJson({
        ...grew.toJson(),
        'trend': 'absolute',
      }).deltaFor(null)!;
      expect(abs.label, '+137');
    });

    // «Просрочено» выросло — это плохая новость, и красить её зелёным было бы ложью.
    test('для перевёрнутого показателя рост — плохо', () {
      final normal = HomeMetric.fromJson(
          {...grew.toJson(), 'trend': 'percent'}).deltaFor(null)!;
      final inverted = HomeMetric.fromJson(
              {...grew.toJson(), 'trend': 'percent', 'inverse': true})
          .deltaFor(null)!;
      expect(normal.good, isTrue);
      expect(inverted.good, isFalse);
      expect(inverted.up, isTrue);
    });

    test('падение подписывается минусом', () {
      final fell = HomeMetric.fromJson({
        'code': 'avg',
        'name': 'Средний чек',
        'value': 24.6,
        'previous': 25.9,
        'trend': 'percent',
      }).deltaFor(null)!;
      expect(fell.up, isFalse);
      expect(fell.good, isFalse);
      expect(fell.label, '−5.0%');
    });

    test('без настройки, без истории и от нуля в процентах — не показывается', () {
      expect(grew.deltaFor(null), isNull); // trend не задан
      expect(
          HomeMetric.fromJson({...grew.toJson(), 'trend': 'none'})
              .deltaFor(null),
          isNull);
      expect(
          const HomeMetric(code: 'a', name: 'a', value: 5, trend: 'percent')
              .deltaFor(null),
          isNull); // нет предыдущего
      expect(
          const HomeMetric(
                  code: 'a', name: 'a', value: 5, previous: 0, trend: 'percent')
              .deltaFor(null),
          isNull); // от нуля процент не считается
      // ...а в количестве от нуля — вполне
      expect(
          const HomeMetric(
                  code: 'a', name: 'a', value: 5, previous: 0, trend: 'absolute')
              .deltaFor(null)!
              .label,
          '+5');
    });

    test('в разрезе объекта сравнивается с предыдущим того же объекта', () {
      const m = HomeMetric(
        code: 'revenue',
        name: 'Выручка',
        value: 31.6,
        previous: 29.7,
        trend: 'absolute',
        values: {'p18': HomeMetricValue(value: 20, previous: 25)},
      );
      expect(m.deltaFor('p18')!.up, isFalse);
      expect(m.deltaFor('p18')!.label, '−5');
      expect(m.deltaFor('k31')!.up, isTrue); // своих данных нет — сетевые
    });
  });

  // A layout cached by an earlier build used one block type per drawing style.
  test('legacy kpi/chart types map onto the metrics type and a view', () {
    final legacy = HomeLayout.fromJson({
      'blocks': [
        {'code': 'a', 'type': 'kpi', 'title': 'Сводка'},
        {'code': 'b', 'type': 'chart', 'title': 'По часам'},
      ],
    });
    expect(legacy.blocks[0].type, 'metrics');
    expect(legacy.blocks[0].view, 'tiles');
    expect(legacy.blocks[1].type, 'metrics');
    expect(legacy.blocks[1].view, 'bars');
  });

  // The server omits nested arrays that would be empty, and answers {} when nothing is
  // configured at all — neither may crash the start page.
  test('missing blocks/metrics/news degrade to empty, not to an error', () {
    expect(HomeLayout.fromJson(const {}).isEmpty, isTrue);
    expect(HomeLayout.fromJson(const {}).hasObjectBlocks, isFalse);
    final b = HomeBlock.fromJson(const {'code': 'x', 'type': 'tasks'});
    expect(b.metrics, isEmpty);
    expect(b.news, isEmpty);
    expect(b.byObject, isFalse);
    expect(b.view, isNull);
    expect(b.title, '');
  });

  test('a value that never arrived shows as a dash, not as zero', () {
    const m = HomeMetric(code: 'myToday', name: 'На сегодня');
    expect(m.display(), '—');
    expect(HomeMetric.compact(null), '—');
    expect(const HomeMetric(code: 'z', name: 'z', value: 0).display(), '0');
  });

  test('format drops a trailing .0 and groups thousands', () {
    const sp = HomeMetric.groupSeparator;
    expect(HomeMetric.format(4.0), '4');
    expect(HomeMetric.format(24.6), '24.6');
    expect(HomeMetric.format(1284), '1${sp}284');
    expect(HomeMetric.format(1234567), '1${sp}234${sp}567');
    expect(HomeMetric.format(-1284), '-1${sp}284');
    expect(HomeMetric.format(1284.5), '1${sp}284.5');
  });

  group('компактная запись на плитке', () {
    test('от тысячи — K, от миллиона — M', () {
      expect(HomeMetric.compact(2300), '2.3K');
      expect(HomeMetric.compact(2300000), '2.3M');
      expect(HomeMetric.compact(2300000000), '2.3B');
    });

    test('до тысячи число остаётся точным', () {
      expect(HomeMetric.compact(0), '0');
      expect(HomeMetric.compact(4), '4');
      expect(HomeMetric.compact(24.6), '24.6');
      expect(HomeMetric.compact(999), '999');
    });

    // Дробная часть нужна, пока что-то значит: 128.4K на плитке — это шум.
    test('от сотни единиц масштаба дробная часть отбрасывается', () {
      expect(HomeMetric.compact(12800), '12.8K');
      expect(HomeMetric.compact(128400), '128K');
      expect(HomeMetric.compact(1284), '1.3K');
    });

    test('ровное значение не тащит .0 за собой', () {
      expect(HomeMetric.compact(2000), '2K');
      expect(HomeMetric.compact(5000000), '5M');
    });

    // Граница округления: 999 500 должно стать «1M», а не «1000K».
    test('на границе масштаб повышается, а не растёт число', () {
      expect(HomeMetric.compact(999499), '999K');
      expect(HomeMetric.compact(999500), '1M');
      expect(HomeMetric.compact(999499000), '999M');
      expect(HomeMetric.compact(999500000), '1B');
      expect(HomeMetric.compact(999), '999');
      expect(HomeMetric.compact(1000), '1K');
    });

    test('знак сохраняется', () {
      expect(HomeMetric.compact(-2300), '-2.3K');
      expect(HomeMetric.compact(-128400), '-128K');
    });

    test('плитка показывает компактно, а «было» — тоже', () {
      const m = HomeMetric(code: 'checks', name: 'Чеков', value: 23400);
      expect(m.display(), '23.4K');
    });
  });

  test('toJson round-trips a layout so it can be cached for offline', () {
    final src = HomeLayout.fromJson({
      'objects': [
        {'id': 'p18', 'name': 'Пинск'}
      ],
      'blocks': [
        {
          'code': 'plan',
          'type': 'metrics',
          'view': 'progress',
          'byObject': true,
          'title': 'План',
          'metrics': [
            {
              'code': 'rev',
              'name': 'Выручка',
              'value': 612,
              'target': 900,
              'filter': 'overdue',
              'values': [
                {'object': 'p18', 'value': 526, 'target': 900}
              ],
            },
          ],
        },
      ],
    });
    final back = HomeLayout.fromJson(src.toJson());
    final block = back.blocks.single;
    expect(block.view, 'progress');
    expect(block.byObject, isTrue);
    expect(back.objects.single.id, 'p18');
    expect(block.metrics.single.filter, 'overdue');
    expect(block.metrics.single.valueFor('p18'), 526);
    expect(block.metrics.single.targetFor('p18'), 900);
  });
}
