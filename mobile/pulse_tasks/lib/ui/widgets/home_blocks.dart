import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';

import '../../models/home.dart';
import '../brand.dart';
import '../theme.dart';

/// Renderers for the blocks of the parameterized home screen.
///
/// One widget per *view*, not per customer: what a store manager and an inspector see
/// differs in the data the server sends, not in the code that draws it. Which view a
/// block uses is configuration too — the same «продажи по часам» read better as columns
/// during the day and as a line over a month.

/// Section caption shared by every block — the emoji from the config, the title, and an
/// optional second line.
class HomeSectionHeader extends StatelessWidget {
  final HomeBlock block;
  final Widget? trailing;
  const HomeSectionHeader({super.key, required this.block, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (block.icon != null) ...[
            Text(block.icon!, style: const TextStyle(fontSize: 17)),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  block.title,
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: Wms.text),
                ),
                if (block.subtitle != null)
                  Text(
                    block.subtitle!,
                    style: TextStyle(fontSize: 12, color: Wms.muted),
                  ),
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// Dispatches a `metrics` block to the view its configuration asks for. An unknown view
/// falls back to tiles rather than to nothing: a newer server may name a view this build
/// cannot draw, and the numbers themselves are still worth showing.
class HomeMetricsBlock extends StatelessWidget {
  final HomeBlock block;
  final String? objectId;
  final void Function(HomeMetric metric)? onTapMetric;

  const HomeMetricsBlock({
    super.key,
    required this.block,
    this.objectId,
    this.onTapMetric,
  });

  @override
  Widget build(BuildContext context) {
    if (block.metrics.isEmpty) return const SizedBox.shrink();
    switch (block.view) {
      case 'bars':
        return _Chart(block: block, objectId: objectId, line: false);
      case 'line':
        return _Chart(block: block, objectId: objectId, line: true);
      case 'donut':
        return _Donut(block: block, objectId: objectId);
      case 'progress':
        return _Progress(block: block, objectId: objectId);
      default:
        return _Tiles(
            block: block, objectId: objectId, onTapMetric: onTapMetric);
    }
  }
}

/// A card with the standard chrome every metric view sits in.
class _Panel extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  const _Panel({required this.child, this.padding = const EdgeInsets.all(14)});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      padding: padding,
      decoration: BoxDecoration(
        color: Wms.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Wms.line),
        boxShadow: Wms.cardShadow,
      ),
      child: child,
    );
  }
}

// ---------- tiles ----------

/// Two per row, big number first. The number is what the manager came for; the caption
/// only tells them which number it is. A tile with a filter behind it is tappable and
/// says so with a chevron — a figure you cannot open is a dead end.
class _Tiles extends StatelessWidget {
  final HomeBlock block;
  final String? objectId;
  final void Function(HomeMetric metric)? onTapMetric;
  const _Tiles({required this.block, this.objectId, this.onTapMetric});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: LayoutBuilder(
        builder: (context, c) {
          final tile = (c.maxWidth - 10) / 2;
          return Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final m in block.metrics)
                SizedBox(
                  width: tile,
                  child: _KpiTile(
                    metric: m,
                    objectId: objectId,
                    onTap: (m.filter != null && onTapMetric != null)
                        ? () => onTapMetric!(m)
                        : null,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _KpiTile extends StatelessWidget {
  final HomeMetric metric;
  final String? objectId;
  final VoidCallback? onTap;
  const _KpiTile({required this.metric, this.objectId, this.onTap});

  @override
  Widget build(BuildContext context) {
    final accent = Brand.parseColor(metric.color) ?? Wms.primary;
    final delta = metric.deltaFor(objectId);
    final was = metric.previousFor(objectId);
    final body = Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(
                child: Text(
                  metric.display(objectId),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w700,
                      color: accent,
                      height: 1.1),
                ),
              ),
              // With a change chip on the line there is no room for the unit as well, so
              // it joins the caption instead: «Чеков, шт».
              if (metric.unit != null && delta == null) ...[
                const SizedBox(width: 4),
                Text(metric.unit!,
                    style: TextStyle(fontSize: 12, color: Wms.muted)),
              ],
              if (delta != null) ...[
                const SizedBox(width: 6),
                _DeltaChip(delta: delta),
              ],
            ],
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Expanded(
                child: Text(
                  (metric.unit != null && delta != null)
                      ? '${metric.name}, ${metric.unit}'
                      : metric.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: Wms.muted),
                ),
              ),
              if (onTap != null)
                Icon(Icons.chevron_right, size: 18, color: Wms.muted),
            ],
          ),
          // The previous value spelled out under the change: «+12%» says how much it
          // moved, «было 1 104» says from where — the second question always follows.
          if (delta != null && was != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                'было ${HomeMetric.compact(was)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: Wms.muted),
              ),
            ),
        ],
      ),
    );

    return Container(
      decoration: BoxDecoration(
        color: Wms.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Wms.line),
        boxShadow: Wms.cardShadow,
      ),
      child: onTap == null
          ? body
          : Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(12),
                child: body,
              ),
            ),
    );
  }
}

/// The change since last time. Colour follows the metric's own direction, not the sign:
/// for «просрочено» a rise is bad news and painting it green would mislead.
class _DeltaChip extends StatelessWidget {
  final MetricDelta delta;
  const _DeltaChip({required this.delta});

  @override
  Widget build(BuildContext context) {
    final color = delta.flat ? Wms.muted : (delta.good ? Wms.ok : Wms.warn);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!delta.flat)
            Icon(
              delta.up ? Icons.arrow_upward : Icons.arrow_downward,
              size: 11,
              color: color,
            ),
          Text(
            delta.label,
            style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.w700, color: color),
          ),
        ],
      ),
    );
  }
}

// ---------- bars / line ----------

/// Columns or a line over the same points — for series where the shape matters more than
/// any single number.
class _Chart extends StatelessWidget {
  final HomeBlock block;
  final String? objectId;
  final bool line;
  const _Chart({required this.block, this.objectId, required this.line});

  @override
  Widget build(BuildContext context) {
    final points = <_Point>[
      for (final m in block.metrics)
        if (m.valueFor(objectId) != null)
          _Point(m.name, m.valueFor(objectId)!,
              Brand.parseColor(m.color) ?? Wms.accent),
    ];
    if (points.isEmpty) return const SizedBox.shrink();

    var max = 0.0;
    for (final p in points) {
      max = math.max(max, p.value);
    }
    if (max <= 0) max = 1;

    return _Panel(
      padding: const EdgeInsets.fromLTRB(10, 14, 10, 8),
      child: SizedBox(
        height: 140,
        child: line
            ? _LinePlot(points: points, max: max, color: Wms.primary)
            : Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (final p in points)
                    Expanded(
                      child: _Bar(
                        point: p,
                        fraction: p.value / max,
                        // the tallest column takes the brand colour so the peak hour is
                        // findable at a glance
                        color: p.value == max ? Wms.primary : p.color,
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}

class _Point {
  final String label;
  final double value;
  final Color color;
  const _Point(this.label, this.value, this.color);
}

class _Bar extends StatelessWidget {
  final _Point point;
  final double fraction;
  final Color color;
  const _Bar({required this.point, required this.fraction, required this.color});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1.5),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              HomeMetric.compact(point.value),
              style: TextStyle(
                  fontSize: 9, color: Wms.muted, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(height: 3),
          Container(
            height: (92 * fraction).clamp(3, 92),
            decoration: BoxDecoration(
              color: color,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
            ),
          ),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(point.label,
                style: TextStyle(fontSize: 10, color: Wms.muted)),
          ),
        ],
      ),
    );
  }
}

class _LinePlot extends StatelessWidget {
  final List<_Point> points;
  final double max;
  final Color color;
  const _LinePlot(
      {required this.points, required this.max, required this.color});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: CustomPaint(
            size: Size.infinite,
            painter: _LinePainter(
              points: points,
              max: max,
              color: color,
              grid: Wms.line,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            for (final p in points)
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(p.label,
                      style: TextStyle(fontSize: 10, color: Wms.muted)),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _LinePainter extends CustomPainter {
  final List<_Point> points;
  final double max;
  final Color color;
  final Color grid;

  _LinePainter(
      {required this.points,
      required this.max,
      required this.color,
      required this.grid});

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;

    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (var i = 0; i <= 2; i++) {
      final y = size.height * i / 2;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    final step = points.length == 1 ? 0.0 : size.width / (points.length - 1);
    Offset at(int i) => Offset(
          points.length == 1 ? size.width / 2 : step * i,
          size.height - (points[i].value / max) * size.height,
        );

    final path = Path()..moveTo(at(0).dx, at(0).dy);
    for (var i = 1; i < points.length; i++) {
      path.lineTo(at(i).dx, at(i).dy);
    }

    // The tinted area under the line does the same job as the grid: it gives the eye a
    // baseline, so a shallow curve still reads as "low" rather than as "flat".
    final area = Path.from(path)
      ..lineTo(at(points.length - 1).dx, size.height)
      ..lineTo(at(0).dx, size.height)
      ..close();
    canvas.drawPath(area, Paint()..color = color.withValues(alpha: 0.10));

    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    final dot = Paint()..color = color;
    for (var i = 0; i < points.length; i++) {
      canvas.drawCircle(at(i), 2.5, dot);
    }
  }

  @override
  bool shouldRepaint(_LinePainter old) =>
      old.points != points || old.max != max || old.color != color;
}

// ---------- donut ----------

/// Shares of a whole — structure of findings, split of sales by category. The centre
/// carries the total, because the first question about a share is «из скольких».
class _Donut extends StatelessWidget {
  final HomeBlock block;
  final String? objectId;
  const _Donut({required this.block, this.objectId});

  static const _palette = [
    Color(0xFF2069B4),
    Color(0xFF2E9E4F),
    Color(0xFFE8A33D),
    Color(0xFFD9342B),
    Color(0xFF7B5EA7),
    Color(0xFF00ABE3),
  ];

  @override
  Widget build(BuildContext context) {
    final slices = <_Point>[];
    var total = 0.0;
    for (var i = 0; i < block.metrics.length; i++) {
      final m = block.metrics[i];
      final v = m.valueFor(objectId);
      if (v == null || v <= 0) continue;
      total += v;
      slices.add(_Point(m.name, v,
          Brand.parseColor(m.color) ?? _palette[i % _palette.length]));
    }
    if (slices.isEmpty) return const SizedBox.shrink();

    return _Panel(
      child: Row(
        children: [
          SizedBox(
            width: 108,
            height: 108,
            child: CustomPaint(
              painter: _DonutPainter(slices: slices, total: total),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      HomeMetric.compact(total),
                      style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: Wms.text),
                    ),
                    Text('всего',
                        style: TextStyle(fontSize: 11, color: Wms.muted)),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final s in slices)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                              color: s.color, shape: BoxShape.circle),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            s.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 13, color: Wms.text),
                          ),
                        ),
                        Text(
                          '${(s.value / total * 100).round()}%',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Wms.muted),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DonutPainter extends CustomPainter {
  final List<_Point> slices;
  final double total;
  _DonutPainter({required this.slices, required this.total});

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.20;
    final rect = Rect.fromCircle(
      center: Offset(size.width / 2, size.height / 2),
      radius: (size.width - stroke) / 2,
    );
    var start = -math.pi / 2;
    for (final s in slices) {
      final sweep = (s.value / total) * 2 * math.pi;
      canvas.drawArc(
        rect,
        start,
        // a hair of a gap between sectors so touching colours stay distinguishable
        math.max(sweep - 0.02, 0.01),
        false,
        Paint()
          ..color = s.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.butt,
      );
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(_DonutPainter old) =>
      old.slices != slices || old.total != total;
}

// ---------- progress ----------

/// Fact against plan. Over-fulfilment is shown as a full bar with the real percentage
/// beside it — clamping the number too would hide the good news.
class _Progress extends StatelessWidget {
  final HomeBlock block;
  final String? objectId;
  const _Progress({required this.block, this.objectId});

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (final m in block.metrics) {
      final value = m.valueFor(objectId);
      final target = m.targetFor(objectId);
      if (value == null || target == null || target <= 0) continue;
      final ratio = value / target;
      final color = Brand.parseColor(m.color) ??
          (ratio >= 1 ? Wms.ok : (ratio < 0.6 ? Wms.warn : Wms.primary));
      rows.add(Padding(
        padding: EdgeInsets.only(top: rows.isEmpty ? 0 : 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    m.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: Wms.text),
                  ),
                ),
                Text(
                  '${(ratio * 100).round()}%',
                  style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w700, color: color),
                ),
              ],
            ),
            const SizedBox(height: 5),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: ratio.clamp(0.0, 1.0),
                minHeight: 8,
                backgroundColor: Wms.bg,
                valueColor: AlwaysStoppedAnimation<Color>(color),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${HomeMetric.compact(value)} из ${HomeMetric.compact(target)}'
              '${m.unit == null ? '' : ' ${m.unit}'}',
              style: TextStyle(fontSize: 12, color: Wms.muted),
            ),
          ],
        ),
      ));
    }
    if (rows.isEmpty) return const SizedBox.shrink();
    return _Panel(child: Column(children: rows));
  }
}

// ---------- text / news ----------

/// Server-authored HTML. Rendered with plain widgets (no webview): the text comes from
/// the customer's own администратор through a WYSIWYG field, and what it needs is
/// headings, lists and emphasis — not a browser.
class HomeHtml extends StatelessWidget {
  final String html;
  final Color color;
  final double fontSize;
  const HomeHtml(
      {super.key,
      required this.html,
      required this.color,
      this.fontSize = 14});

  @override
  Widget build(BuildContext context) {
    return HtmlWidget(
      html,
      textStyle: TextStyle(fontSize: fontSize, height: 1.45, color: color),
      renderMode: RenderMode.column,
    );
  }
}

/// A long text — регламент, памятка на смену. Collapsed by default: it is reference
/// material, and unfolded it would push everything else off the first screen.
class HomeTextBlock extends StatefulWidget {
  final HomeBlock block;
  const HomeTextBlock({super.key, required this.block});

  @override
  State<HomeTextBlock> createState() => _HomeTextBlockState();
}

class _HomeTextBlockState extends State<HomeTextBlock> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final body = widget.block.body;
    if (body == null) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Wms.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Wms.line),
        boxShadow: Wms.cardShadow,
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Collapsed height rather than maxLines: the body is HTML, so it is a
                // column of widgets, and there is no single line count to cut at.
                ConstrainedBox(
                  constraints: BoxConstraints(
                      maxHeight: _open ? double.infinity : 96),
                  child: ClipRect(
                    child: HomeHtml(html: body, color: Wms.text),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _open ? 'Свернуть' : 'Читать полностью',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Wms.primary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The news feed. Newest first — the server orders by date ascending, so the list is
/// turned around here.
class HomeNewsBlock extends StatelessWidget {
  final HomeBlock block;
  const HomeNewsBlock({super.key, required this.block});

  @override
  Widget build(BuildContext context) {
    final items = [...block.news]
      ..sort((a, b) => (b.date ?? '').compareTo(a.date ?? ''));
    return Column(
      children: [for (final n in items) _NewsCard(item: n)],
    );
  }
}

class _NewsCard extends StatefulWidget {
  final HomeNewsItem item;
  const _NewsCard({required this.item});

  @override
  State<_NewsCard> createState() => _NewsCardState();
}

class _NewsCardState extends State<_NewsCard> {
  bool _open = false;

  /// `2026-07-20` -> `20.07.2026`; anything else is shown as it came.
  String _date(String raw) {
    final p = raw.split('-');
    return p.length == 3 ? '${p[2]}.${p[1]}.${p[0]}' : raw;
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.item;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      decoration: BoxDecoration(
        color: Wms.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Wms.line),
        boxShadow: Wms.cardShadow,
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: n.body == null ? null : () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (n.date != null)
                  Text(
                    _date(n.date!),
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Wms.muted),
                  ),
                Text(
                  n.title,
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Wms.text),
                ),
                if (n.body != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                          maxHeight: _open ? double.infinity : 44),
                      child: ClipRect(
                        child: HomeHtml(
                            html: n.body!, color: Wms.muted, fontSize: 13),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
