import 'package:flutter/material.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../models/format.dart';
import '../../../models/home.dart';
import '../../theme.dart';
import '../ds.dart';

/// Server-authored HTML. Rendered with plain widgets (no webview): the text comes from
/// the customer's own администратор through a WYSIWYG field, and what it needs is
/// headings, lists and emphasis — not a browser. Ссылки открываются во внешнем
/// браузере и только http/https: текст пишет администратор, и `file:` или `intent:`
/// открывали бы с телефона то, чего он не задумывал.
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
      onTapUrl: _open,
    );
  }

  /// true — ссылка обработана: и открытая, и отвергнутая (иначе пакет попробовал бы
  /// открыть её сам).
  static Future<bool> _open(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return true;
    }
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // браузера нет — ссылке просто некуда открыться
    }
    return true;
  }
}

/// Верх содержимого высотой [height]: свёрнутый текст обрезается без жалоб на
/// переполнение (Column под ConstrainedBox их сыпал), а [onLong] узнаёт, длиннее ли
/// текст свёрнутого вида — короткому «Читать полностью» не нужно.
class _Folded extends StatefulWidget {
  final double height;
  final Widget child;
  final ValueChanged<bool> onLong;
  const _Folded(
      {required this.height, required this.child, required this.onLong});

  @override
  State<_Folded> createState() => _FoldedState();
}

class _FoldedState extends State<_Folded> {
  final ScrollController _clip = ScrollController();

  @override
  void dispose() {
    _clip.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _clip.hasClients) {
        widget.onLong(_clip.position.maxScrollExtent > 0);
      }
    });
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: widget.height),
      child: SingleChildScrollView(
        controller: _clip,
        physics: const NeverScrollableScrollPhysics(),
        child: widget.child,
      ),
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

  /// Текст длиннее свёрнутого вида — только тогда есть что разворачивать.
  bool _long = false;

  @override
  Widget build(BuildContext context) {
    final body = widget.block.body;
    if (body == null) return const SizedBox.shrink();
    final html = HomeHtml(html: body, color: Wms.text);
    final foldable = _open || _long;

    return DsCardBox(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      ink: true,
      onTap: foldable ? () => setState(() => _open = !_open) : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Collapsed height rather than maxLines: the body is HTML, so it is a
            // column of widgets, and there is no single line count to cut at.
            if (_open)
              html
            else
              _Folded(
                height: 96,
                onLong: (long) {
                  if (long != _long) setState(() => _long = long);
                },
                child: html,
              ),
            if (foldable) ...[
              const SizedBox(height: 6),
              Text(
                _open ? 'Свернуть' : 'Читать полностью',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Wms.primary),
              ),
            ],
          ],
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
    // раскрытие — за своей новостью, а не за позицией в ленте: пришедшая сверху
    // свежая не должна раскрыться вместо прочитанной
    return Column(
      children: [
        for (final n in items)
          _NewsCard(key: ValueKey('${n.date}|${n.title}'), item: n),
      ],
    );
  }
}

class _NewsCard extends StatefulWidget {
  final HomeNewsItem item;
  const _NewsCard({super.key, required this.item});

  @override
  State<_NewsCard> createState() => _NewsCardState();
}

class _NewsCardState extends State<_NewsCard> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final n = widget.item;
    return DsCardBox(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      ink: true,
      onTap: n.body == null ? null : () => setState(() => _open = !_open),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (n.date != null)
              Text(
                formatDate(n.date) ?? n.date!,
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
                child: _open
                    ? HomeHtml(
                        html: n.body!, color: Wms.muted, fontSize: 13)
                    : _Folded(
                        height: 44,
                        onLong: (_) {},
                        child: HomeHtml(
                            html: n.body!, color: Wms.muted, fontSize: 13),
                      ),
              ),
          ],
        ),
      ),
    );
  }
}
