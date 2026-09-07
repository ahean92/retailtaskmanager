import 'package:flutter/material.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';

import '../../../models/home.dart';
import '../../theme.dart';

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
