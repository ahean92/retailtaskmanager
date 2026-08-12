/// The home screen as the server describes it.
///
/// The screen is not a fixed layout with a fixed set of cards: a store manager opens the
/// app to see the shop's numbers, an inspector to see the regulation and what changed.
/// Which blocks exist, in what order, who sees them and how the numbers are drawn is
/// server-side configuration (`HomeScreen.lsf`); the client only knows how to draw each
/// *type* of block in each *view*.
///
/// So an unknown `type` or `view` is not an error here — it is a newer server talking to
/// an older app, and the right answer is to skip or fall back, not to fail the screen.
class HomeLayout {
  final List<HomeBlock> blocks;

  /// Objects the metrics can be broken down by. Sent with every layout so switching the
  /// shop on the phone is instant and works offline — the values for all of them are
  /// already here.
  final List<HomeObject> objects;

  const HomeLayout({this.blocks = const [], this.objects = const []});

  bool get isEmpty => blocks.isEmpty;

  /// True when at least one visible block is broken down by object — that is what makes
  /// the store selector worth showing.
  bool get hasObjectBlocks => blocks.any((b) => b.byObject);

  factory HomeLayout.fromJson(Map<String, dynamic> j) => HomeLayout(
        blocks: _list(j['blocks'], HomeBlock.fromJson),
        objects: _list(j['objects'], HomeObject.fromJson),
      );

  Map<String, dynamic> toJson() => {
        'blocks': blocks.map((b) => b.toJson()).toList(),
        if (objects.isNotEmpty)
          'objects': objects.map((o) => o.toJson()).toList(),
      };
}

class HomeObject {
  final String id;
  final String name;
  final String? address;

  const HomeObject({required this.id, required this.name, this.address});

  factory HomeObject.fromJson(Map<String, dynamic> j) => HomeObject(
        id: _str(j['id']) ?? '',
        name: _str(j['name']) ?? '',
        address: _str(j['address']),
      );

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, if (address != null) 'address': address};
}

class HomeBlock {
  final String code;

  /// `tasks` | `metrics` | `text` | `news` — see HomeBlockType on the server.
  final String type;

  /// How a `metrics` block is drawn: `tiles` | `bars` | `line` | `donut` | `progress`.
  final String? view;

  /// The numbers of this block are per object, and [HomeMetric.values] carries them.
  final bool byObject;

  final String title;
  final String? subtitle;

  /// An emoji from the block's настройка. Emoji rather than an icon name so a new block
  /// gets its picture from the config form, without a client release.
  final String? icon;

  /// Body of a `text` block — регламент, памятка. HTML: it is edited on the server in a
  /// WYSIWYG field, so lists and emphasis survive the trip.
  final String? body;

  final List<HomeMetric> metrics;
  final List<HomeNewsItem> news;

  const HomeBlock({
    required this.code,
    required this.type,
    this.view,
    this.byObject = false,
    required this.title,
    this.subtitle,
    this.icon,
    this.body,
    this.metrics = const [],
    this.news = const [],
  });

  /// Legacy layouts (cached by an older build, or an older server) used one block type
  /// per drawing style. Map them onto the view so a stale cache still renders.
  static String _type(Object? raw) {
    final t = _str(raw) ?? '';
    return (t == 'kpi' || t == 'chart') ? 'metrics' : t;
  }

  static String? _view(Map<String, dynamic> j) {
    final v = _str(j['view']);
    if (v != null) return v;
    return switch (_str(j['type'])) {
      'kpi' => 'tiles',
      'chart' => 'bars',
      _ => null,
    };
  }

  factory HomeBlock.fromJson(Map<String, dynamic> j) => HomeBlock(
        code: _str(j['code']) ?? '',
        type: _type(j['type']),
        view: _view(j),
        byObject: j['byObject'] == true,
        title: _str(j['title']) ?? '',
        subtitle: _str(j['subtitle']),
        icon: _str(j['icon']),
        body: _str(j['body']),
        metrics: _list(j['metrics'], HomeMetric.fromJson),
        news: _list(j['news'], HomeNewsItem.fromJson),
      );

  Map<String, dynamic> toJson() => {
        'code': code,
        'type': type,
        if (view != null) 'view': view,
        if (byObject) 'byObject': true,
        'title': title,
        if (subtitle != null) 'subtitle': subtitle,
        if (icon != null) 'icon': icon,
        if (body != null) 'body': body,
        if (metrics.isNotEmpty)
          'metrics': metrics.map((m) => m.toJson()).toList(),
        if (news.isNotEmpty) 'news': news.map((n) => n.toJson()).toList(),
      };
}

/// One number on the home screen. The same entity backs a KPI tile, a column, a point of
/// the line, a sector of the donut and a progress bar — everywhere it is a label and a
/// value; only the block's view decides how it is drawn.
class HomeMetric {
  final String code;
  final String name;

  /// Network-wide value; for a per-object block it is the fallback when the selected
  /// object has none of its own.
  final double? value;

  /// What the value was before the last update. 1284 чека is neither much nor little on
  /// its own — the answer comes from comparing it with last time.
  final double? previous;

  /// Plan the value is measured against — what the `progress` view fills up to.
  final double? target;

  /// How the change is shown: `percent` | `absolute`; `none` or null hides it. For
  /// «касс открыто» the dynamics say nothing and the tile is quieter without them.
  final String? trend;

  /// Growth is a worsening — «просрочено», «замечаний». Painting that green would be a
  /// plain lie, and the direction is a property of the metric, not a guess from its name.
  final bool inverse;

  final String? unit;

  /// `#RRGGBB` from the config, when this particular number should stand out.
  final String? color;

  /// Which task list a tap opens: `open` | `today` | `overdue` | `done`. Null means the
  /// number leads nowhere — a dashboard figure with no list behind it.
  final String? filter;

  /// Per-object values, keyed by object id.
  final Map<String, HomeMetricValue> values;

  const HomeMetric({
    required this.code,
    required this.name,
    this.value,
    this.previous,
    this.target,
    this.trend,
    this.inverse = false,
    this.unit,
    this.color,
    this.filter,
    this.values = const {},
  });

  factory HomeMetric.fromJson(Map<String, dynamic> j) {
    final byObject = <String, HomeMetricValue>{};
    final raw = j['values'];
    if (raw is List) {
      for (final e in raw.whereType<Map>()) {
        final m = e.cast<String, dynamic>();
        final id = _str(m['object']);
        if (id != null) {
          byObject[id] = HomeMetricValue(
            value: _num(m['value']),
            previous: _num(m['previous']),
            target: _num(m['target']),
          );
        }
      }
    }
    return HomeMetric(
      code: _str(j['code']) ?? '',
      name: _str(j['name']) ?? '',
      value: _num(j['value']),
      previous: _num(j['previous']),
      target: _num(j['target']),
      trend: _str(j['trend']),
      inverse: j['inverse'] == true,
      unit: _str(j['unit']),
      color: _str(j['color']),
      filter: _str(j['filter']),
      values: byObject,
    );
  }

  Map<String, dynamic> toJson() => {
        'code': code,
        'name': name,
        if (value != null) 'value': value,
        if (previous != null) 'previous': previous,
        if (target != null) 'target': target,
        if (trend != null) 'trend': trend,
        if (inverse) 'inverse': true,
        if (unit != null) 'unit': unit,
        if (color != null) 'color': color,
        if (filter != null) 'filter': filter,
        if (values.isNotEmpty)
          'values': [
            for (final e in values.entries)
              {
                'object': e.key,
                if (e.value.value != null) 'value': e.value.value,
                if (e.value.previous != null) 'previous': e.value.previous,
                if (e.value.target != null) 'target': e.value.target,
              }
          ],
      };

  /// The value to show for [objectId]. Falls back to the network figure so a shop with no
  /// data of its own shows the company number rather than a blank tile.
  double? valueFor(String? objectId) =>
      (objectId == null ? null : values[objectId]?.value) ?? value;

  /// The network-wide figure when it disagrees with the local one — the second half of
  /// «1 здесь · 6 всего». Null when there is nothing to add: no object selected, no
  /// network figure, or the two numbers coincide — an executor whose every task is in
  /// this one shop would otherwise read the same number twice on every tile.
  double? totalFor(String? objectId) {
    if (objectId == null) return null;
    final here = valueFor(objectId);
    if (here == null || value == null || here == value) return null;
    return value;
  }

  double? previousFor(String? objectId) =>
      (objectId == null ? null : values[objectId]?.previous) ?? previous;

  double? targetFor(String? objectId) =>
      (objectId == null ? null : values[objectId]?.target) ?? target;

  /// The change since the previous value, ready to draw, or null when there is nothing
  /// to say: no setting, no history, or a previous zero that no percentage can describe.
  MetricDelta? deltaFor(String? objectId) {
    final mode = trend;
    if (mode == null || mode == 'none') return null;
    final now = valueFor(objectId);
    final was = previousFor(objectId);
    if (now == null || was == null) return null;
    final diff = now - was;
    if (mode == 'percent') {
      if (was == 0) return null;
      return MetricDelta(diff, (diff / was.abs()) * 100, true, inverse);
    }
    return MetricDelta(diff, null, false, inverse);
  }

  /// A missing value is shown as a dash, not as 0: «нет данных» and «ноль чеков» are
  /// different facts, and a dashboard that confuses them is worse than none.
  ///
  /// Compact by default — a KPI tile is half a phone wide and shares its top line with
  /// the unit and the change, so a full «2 300 000» simply does not fit.
  String display([String? objectId]) => compact(valueFor(objectId));

  /// `2300` -> `2.3K`, `2300000` -> `2.3M`. Below a thousand the exact number both fits
  /// and matters, so it is left alone.
  static String compact(double? v) {
    if (v == null) return '—';
    final abs = v.abs();
    // the bounds are the rounding edges, not the round numbers: 999 500 rounds to 1000
    // at K scale and has to step up to «1M» rather than print as «1000K»
    if (abs < 999.95) return format(v);
    if (abs < 999500) return _scaled(v / 1e3, 'K');
    if (abs < 999500000) return _scaled(v / 1e6, 'M');
    return _scaled(v / 1e9, 'B');
  }

  /// One decimal while it still carries information; from a hundred it is noise.
  static String _scaled(double v, String suffix) {
    final text = v.abs() >= 100
        ? v.round().toString()
        : _dropTrailingZero(v.toStringAsFixed(1));
    return '$text$suffix';
  }

  static String _dropTrailingZero(String s) =>
      s.endsWith('.0') ? s.substring(0, s.length - 2) : s;

  /// The number in full, thousands grouped. For places with room for it — the previous
  /// value, «X из Y» on a progress bar, anything the user is meant to read exactly.
  static String format(double? v) {
    if (v == null) return '—';
    final rounded = v.roundToDouble();
    final text = (v == rounded && v.abs() < 1e12)
        ? rounded.toInt().toString()
        : v.toStringAsFixed(1);
    return _grouped(text);
  }

  /// Non-breaking space between thousands — 1284 reads as «1 284», and the number never
  /// wraps in the middle inside a narrow KPI tile.
  static const groupSeparator = '\u00A0';

  static String _grouped(String s) {
    final dot = s.indexOf('.');
    var head = dot < 0 ? s : s.substring(0, dot);
    final tail = dot < 0 ? '' : s.substring(dot);
    final neg = head.startsWith('-');
    if (neg) head = head.substring(1);
    final buf = StringBuffer();
    for (var i = 0; i < head.length; i++) {
      if (i > 0 && (head.length - i) % 3 == 0) buf.write(groupSeparator);
      buf.write(head[i]);
    }
    return '${neg ? '-' : ''}$buf$tail';
  }
}

class HomeMetricValue {
  final double? value;
  final double? previous;
  final double? target;
  const HomeMetricValue({this.value, this.previous, this.target});
}

/// The change of a metric since its previous value, in the form the tile should show it.
class MetricDelta {
  /// Signed difference in the metric's own units.
  final double diff;

  /// Signed change in percent — null when the setting asks for absolute numbers.
  final double? percent;

  final bool asPercent;

  /// Growth is a worsening for this metric.
  final bool inverse;

  const MetricDelta(this.diff, this.percent, this.asPercent, this.inverse);

  bool get up => diff > 0;
  bool get flat => diff == 0;

  /// Whether this change is good news. Zero counts as neither — [flat] is checked first
  /// by the caller, which paints it grey.
  bool get good => inverse ? diff < 0 : diff > 0;

  /// `+12%` / `−148` — always signed, because an unsigned change is not a change.
  String get label {
    if (flat) return '0';
    final sign = up ? '+' : '−';
    if (asPercent) {
      final p = percent!.abs();
      final text = p >= 10 ? p.round().toString() : p.toStringAsFixed(1);
      return '$sign$text%';
    }
    return '$sign${HomeMetric.compact(diff.abs())}';
  }
}

class HomeNewsItem {
  final String? date;
  final String title;

  /// HTML, same as a text block's body.
  final String? body;

  const HomeNewsItem({this.date, required this.title, this.body});

  factory HomeNewsItem.fromJson(Map<String, dynamic> j) => HomeNewsItem(
        date: _str(j['date']),
        title: _str(j['title']) ?? '',
        body: _str(j['body']),
      );

  Map<String, dynamic> toJson() => {
        if (date != null) 'date': date,
        'title': title,
        if (body != null) 'body': body,
      };
}

String? _str(Object? v) {
  final s = v?.toString().trim();
  return (s == null || s.isEmpty) ? null : s;
}

double? _num(Object? v) {
  if (v is num) return v.toDouble();
  return double.tryParse(v?.toString().replaceAll(',', '.') ?? '');
}

List<T> _list<T>(Object? raw, T Function(Map<String, dynamic>) parse) {
  if (raw is! List) return const [];
  return raw
      .whereType<Map>()
      .map((e) => parse(e.cast<String, dynamic>()))
      .toList();
}
