import 'package:flutter/material.dart';

import '../../../models/home.dart';
import '../../brand.dart';
import '../../theme.dart';
import 'charts.dart';

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
        return HomeChart(block: block, objectId: objectId, line: false);
      case 'line':
        return HomeChart(block: block, objectId: objectId, line: true);
      case 'donut':
        return HomeDonut(block: block, objectId: objectId);
      case 'progress':
        return HomeProgress(block: block, objectId: objectId);
      default:
        return _Tiles(
            block: block, objectId: objectId, onTapMetric: onTapMetric);
    }
  }
}

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
    // Цвет метрики приходит с сервера и подобран под белую карточку — им написана
    // сама цифра, поэтому в тёмной теме он поднимается до читаемого (#36917).
    final accent = Wms.readable(Brand.parseColor(metric.color) ?? Wms.primary);
    final delta = metric.deltaFor(objectId);
    final was = metric.previousFor(objectId);
    final total = metric.totalFor(objectId);
    // The number line fits one companion besides the figure: a change chip or the
    // «здесь» label push the unit down into the caption — «Чеков, шт».
    final unitInCaption = metric.unit != null && (delta != null || total != null);
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
              Expanded(
                child: Row(
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
                    // «2 здесь … всего 3»: both figures carry a label, and the words
                    // appear strictly as a pair — a lone «всего» under an unlabelled
                    // number left the reader guessing what it was the total of.
                    if (total != null) ...[
                      const SizedBox(width: 4),
                      Text('здесь',
                          style: TextStyle(fontSize: 12, color: Wms.muted)),
                    ],
                    if (metric.unit != null && !unitInCaption) ...[
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
              ),
              // The network-wide half sits at the tile's right edge, on the number's
              // baseline — the top-right corner was empty anyway, and the pair reads
              // in one line. Shown only when it disagrees with the big figure:
              // matching numbers would just repeat each other on every tile of a
              // one-shop executor. The left group owns the flexible space, so a long
              // number compacts before the tail loses anything.
              if (total != null) ...[
                const SizedBox(width: 8),
                Text(
                  'всего ${HomeMetric.compact(total)}',
                  style: TextStyle(fontSize: 12, color: Wms.muted),
                ),
              ],
            ],
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Expanded(
                child: Text(
                  unitInCaption ? '${metric.name}, ${metric.unit}' : metric.name,
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
