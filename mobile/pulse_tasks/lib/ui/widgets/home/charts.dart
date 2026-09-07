import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../models/home.dart';
import '../../brand.dart';
import '../../theme.dart';
import 'panel.dart';

/// Columns or a line over the same points — for series where the shape matters more than
/// any single number.
class HomeChart extends StatelessWidget {
  final HomeBlock block;
  final String? objectId;
  final bool line;
  const HomeChart({super.key, required this.block, this.objectId, required this.line});

  @override
  Widget build(BuildContext context) {
    final points = <_Point>[
      for (final m in block.metrics)
        if (m.valueFor(objectId) != null)
          _Point(m.name, m.valueFor(objectId)!,
              Wms.readable(Brand.parseColor(m.color) ?? Wms.accent)),
    ];
    if (points.isEmpty) return const SizedBox.shrink();

    var max = 0.0;
    for (final p in points) {
      max = math.max(max, p.value);
    }
    if (max <= 0) max = 1;

    return HomePanel(
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
class HomeDonut extends StatelessWidget {
  final HomeBlock block;
  final String? objectId;
  const HomeDonut({super.key, required this.block, this.objectId});

  // Цвета долей — фиксированные и различимые между собой; читаемость на тёмной
  // карточке добавляет Wms.readable там, где они попадают в кадр (#36917).
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
          Wms.readable(
              Brand.parseColor(m.color) ?? _palette[i % _palette.length])));
    }
    if (slices.isEmpty) return const SizedBox.shrink();

    return HomePanel(
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
class HomeProgress extends StatelessWidget {
  final HomeBlock block;
  final String? objectId;
  const HomeProgress({super.key, required this.block, this.objectId});

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (final m in block.metrics) {
      final value = m.valueFor(objectId);
      final target = m.targetFor(objectId);
      if (value == null || target == null || target <= 0) continue;
      final ratio = value / target;
      final color = Wms.readable(Brand.parseColor(m.color) ??
          (ratio >= 1 ? Wms.ok : (ratio < 0.6 ? Wms.warn : Wms.primary)));
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
    return HomePanel(child: Column(children: rows));
  }
}

// ---------- text / news ----------
