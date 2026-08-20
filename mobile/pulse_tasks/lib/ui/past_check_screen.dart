import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/past_fill_controller.dart';
import '../data/task_repository.dart';
import '../models/fill.dart';
import 'theme.dart';
import 'widgets/fill_field_tile.dart';
import 'widgets/warn_bar.dart';

/// Просмотр прошлой проверки — только чтение (#36778): все пункты с ответами,
/// комментариями и фото, ничего не редактируется. Открывается из бланка (по задаче:
/// прошлая проверка того же объекта и шаблона, при необходимости прокрученная к
/// пункту) и с карточки объекта на главном (последняя завершённая, шаблон любой).
///
/// Рендерер тот же, что у бланка, — FillFieldTile в режиме readOnly; свой здесь
/// только тонкий каркас: шапка с итогом, пейджер секций и прокрутка к пункту.
class PastCheckScreen extends StatefulWidget {
  final String? taskId;
  final String? objectId;
  final String? initialFieldCode;

  const PastCheckScreen.forTask(this.taskId, {super.key, this.initialFieldCode})
      : objectId = null;

  const PastCheckScreen.forObject(this.objectId, {super.key})
      : taskId = null,
        initialFieldCode = null;

  @override
  State<PastCheckScreen> createState() => _PastCheckScreenState();
}

class _PastCheckScreenState extends State<PastCheckScreen> {
  late final PastFillController _c;
  late final PageController _pager;
  int _page = 0;
  final Map<String, GlobalKey> _tileKeys = {};
  bool _jumped = false;

  @override
  void initState() {
    super.initState();
    final repo = context.read<TaskRepository>();
    _c = widget.taskId != null
        ? PastFillController.forTask(repo.db, repo.api, widget.taskId!)
        : PastFillController.forObject(repo.db, repo.api, widget.objectId!);
    _pager = PageController();
    _c.load().then((_) => _jumpToInitial());
  }

  /// «Тап открывает просмотр, прокрученный к этому пункту»: страница секции —
  /// прыжком, сам пункт — ensureVisible по ключу плитки после того, как страница
  /// построилась (список секции строится целиком, см. _sectionList).
  void _jumpToInitial() {
    final code = widget.initialFieldCode;
    if (code == null || _jumped || !mounted || _c.fields.isEmpty) return;
    _jumped = true;
    final page = _c.pageOfField(code);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_pager.hasClients && page != _page) _pager.jumpToPage(page);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _tileKeys[code]?.currentContext;
        if (ctx != null) {
          Scrollable.ensureVisible(ctx,
              duration: const Duration(milliseconds: 300),
              alignment: 0.1);
        }
      });
    });
  }

  @override
  void dispose() {
    _c.dispose();
    _pager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(title: const Text('Прошлая проверка')),
          body: _c.loading && _c.fields.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : _c.empty
                  ? _empty(context)
                  : _c.fields.isEmpty
                      ? _empty(context, offline: true)
                      : Column(
                          children: [
                            _header(context),
                            if (!_c.online)
                              const WarnBar(Icons.cloud_off,
                                  'Офлайн — показана сохранённая проверка, '
                                  'нескачанные фото недоступны'),
                            Expanded(child: _pages(context)),
                            _bottomBar(context),
                          ],
                        ),
        );
      },
    );
  }

  Widget _empty(BuildContext context, {bool offline = false}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(offline ? Icons.cloud_off : Icons.history,
                size: 40, color: Wms.muted),
            const SizedBox(height: 12),
            Text(
              offline
                  ? (_c.error ?? 'Нет данных офлайн')
                  : 'Прошлых проверок здесь ещё не было',
              textAlign: TextAlign.center,
              style: TextStyle(color: Wms.muted),
            ),
          ],
        ),
      ),
    );
  }

  /// Итог прошлой проверки: дата обязательна («в прошлый раз» без даты бесполезно),
  /// дальше — кто проверял, оценка с вердиктом и число замечаний.
  Widget _header(BuildContext context) {
    final s = _c.summary;
    final date = FillSummary.shortDate(s.date);
    final pct = s.percent;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Wms.card,
        border: Border(bottom: BorderSide(color: Wms.line)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(s.object ?? '',
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            Text(s.template ?? '',
                style: TextStyle(fontSize: 13, color: Wms.muted)),
            const SizedBox(height: 6),
            Text(
              [
                if (date != null) 'Проверено $date',
                if ((s.executor ?? '').isNotEmpty) s.executor!,
              ].join(' · '),
              style: TextStyle(fontSize: 13, color: Wms.muted),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                if (pct != null)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: (s.passed ? Wms.ok : Wms.warn)
                          .withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '${FillSummary.formatPercent(pct)}'
                      '${s.verdict != null ? ' · ${s.verdict}' : ''}',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: s.passed ? Wms.ok : Wms.warn),
                    ),
                  ),
                if (pct != null) const SizedBox(width: 10),
                Text(
                  s.remarks > 0 ? 'замечаний: ${s.remarks}' : 'без замечаний',
                  style: TextStyle(
                      fontSize: 13,
                      color: s.remarks > 0 ? Wms.warn : Wms.muted),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _pages(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
          child: Row(
            children: [
              Text(_c.sectionTitle(_page),
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600)),
              const Spacer(),
              Text('Раздел ${_page + 1} из ${_c.sectionCount}',
                  style: TextStyle(fontSize: 12, color: Wms.muted)),
            ],
          ),
        ),
        Expanded(
          child: PageView.builder(
            controller: _pager,
            itemCount: _c.sectionCount,
            onPageChanged: (p) => setState(() => _page = p),
            itemBuilder: (context, page) => _sectionList(page),
          ),
        ),
      ],
    );
  }

  /// Список секции строится целиком (не builder'ом): просмотр не набирает высоту
  /// клавиатурами и контролами, а построенные плитки — то, к чему ensureVisible
  /// может прокрутить.
  Widget _sectionList(int page) {
    final items = _c.fieldsOfSection(page);
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: [
        for (final f in items)
          FillFieldTile(
            key: _tileKeys.putIfAbsent(f.code, GlobalKey.new),
            field: f,
            readOnly: true,
            photoLoader: (i, {required thumb}) =>
                _c.photoFile(f, i, thumb: thumb),
          ),
      ],
    );
  }

  Widget _bottomBar(BuildContext context) {
    final last = _page >= _c.sectionCount - 1;
    if (_c.sectionCount <= 1) return const SizedBox.shrink();
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
        child: Row(
          children: [
            if (_page > 0)
              OutlinedButton.icon(
                onPressed: () => _pager.previousPage(
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOut),
                icon: const Icon(Icons.chevron_left),
                label: const Text('Назад'),
              ),
            const Spacer(),
            if (!last)
              FilledButton.icon(
                onPressed: () => _pager.nextPage(
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOut),
                icon: const Icon(Icons.chevron_right),
                label: const Text('Далее'),
              ),
          ],
        ),
      ),
    );
  }
}
