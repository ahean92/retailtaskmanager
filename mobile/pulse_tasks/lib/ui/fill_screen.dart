import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../data/fill_controller.dart';
import '../data/task_repository.dart';
import '../models/fill.dart';
import 'past_check_screen.dart';
import 'scan_screen.dart';
import 'theme.dart';
import 'widgets/fill_field_tile.dart';
import 'widgets/warn_bar.dart';

/// Generic schema-driven fill screen for form (procedure) tasks — one renderer for
/// every template. Sections are paged; the last page carries the resolution + finish.
class FillScreen extends StatefulWidget {
  final String taskId;
  const FillScreen({super.key, required this.taskId});

  @override
  State<FillScreen> createState() => _FillScreenState();
}

class _FillScreenState extends State<FillScreen> {
  late final FillController _c;
  final _pager = PageController();
  int _page = 0;

  /// load() уже запускался. Отдельно от контроллера: вне объекта задачи load()
  /// откладывается — он не только читает бланк, но и НАЧИНАЕТ выполнение на сервере
  /// (startExecution), а «открыл экран» не должно превращаться в «начал работу»
  /// не на месте (#36837). Запустится из build, когда человек снова окажется там.
  bool _loaded = false;

  /// Задача этого бланка — не того объекта, где человек стоит (#36837). Смотрит в
  /// репозиторий на каждый rebuild: полоса «вы не на этом объекте» обязана и
  /// появиться, и исчезнуть в тот же кадр, что и смена объекта в шапке списка.
  /// Задача, пропавшая из списка (закрыта, подтверждена сервером), не считается
  /// чужой — этим экраном по-прежнему занимается его собственная логика завершения.
  bool _away(TaskRepository repo) =>
      repo.viewOf(widget.taskId)?.elsewhere ?? false;

  @override
  void initState() {
    super.initState();
    final repo = context.read<TaskRepository>();
    _c = FillController(db: repo.db, api: repo.api, taskId: widget.taskId);
    if (!_away(repo)) {
      _loaded = true;
      _c.load();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    _pager.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    final repo = context.read<TaskRepository>();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final ok = await _c.finish();
    if (ok) {
      messenger.showSnackBar(SnackBar(
          content: Text(_c.online
              ? 'Задача завершена'
              : 'Завершено — уедет на сервер при связи')));
      unawaited(repo.syncAndRefresh());
      navigator.pop();
    } else {
      messenger.showSnackBar(
          SnackBar(content: Text(_c.error ?? 'Не удалось завершить')));
    }
  }

  Future<void> _pickDate(FillField f) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(now.year - 2),
      lastDate: DateTime(now.year + 2),
    );
    if (picked == null) return;
    final iso =
        '${picked.year.toString().padLeft(4, '0')}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
    await _c.setDate(f, iso);
  }

  Future<void> _scanCode(FillField f) async {
    final code = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const ScanScreen()),
    );
    if (code == null || !mounted) return;
    await _c.setText(f, code);
  }

  Future<void> _pickPhoto(FillField f) async {
    final messenger = ScaffoldMessenger.of(context);
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(children: [
          ListTile(
            leading: const Icon(Icons.photo_camera),
            title: const Text('Камера'),
            onTap: () => Navigator.pop(ctx, ImageSource.camera),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library),
            title: const Text('Галерея'),
            onTap: () => Navigator.pop(ctx, ImageSource.gallery),
          ),
        ]),
      ),
    );
    if (source == null) return;
    try {
      final file = await ImagePicker().pickImage(
          source: source, maxWidth: 1280, maxHeight: 1280, imageQuality: 70);
      if (file == null) return;
      await _c.addPhoto(f, file.path);
    } catch (e) {
      messenger
          .showSnackBar(SnackBar(content: Text('Не удалось получить фото: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    // watch, а не read: отъезд и возвращение перекрашивают открытый бланк сами —
    // гвард только на входе оставлял бы лазейку «открыл на месте, дозаполнил из дома»
    final repo = context.watch<TaskRepository>();
    if (_away(repo)) return _awayScreen(context);
    if (!_loaded) {
      // человек вернулся на объект, не закрывая бланка, — загрузка, отложенная в
      // initState, стартует теперь (из post-frame: build не место для side effects)
      _loaded = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _c.load();
      });
    }
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('Заполнение'),
            actions: [
              if (_c.syncing)
                const Padding(
                  padding: EdgeInsets.only(right: 16),
                  child: Center(
                    child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white)),
                  ),
                )
              else if (_c.pendingCount > 0)
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Center(
                    child: Chip(
                      visualDensity: VisualDensity.compact,
                      label: Text('${_c.pendingCount}'),
                      avatar: const Icon(Icons.sync_problem, size: 16),
                    ),
                  ),
                ),
            ],
          ),
          body: _c.loading && _c.fields.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : _c.fields.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(_c.error ?? 'Полей нет',
                            textAlign: TextAlign.center),
                      ),
                    )
                  : Column(
                      children: [
                        _header(context),
                        if (!_c.online) const WarnBar(Icons.cloud_off,
                            'Офлайн — данные сохраняются и синхронизируются позже'),
                        if (_c.online && _c.lastSyncError != null)
                          WarnBar(Icons.sync_problem,
                              'Не принято: ${_c.lastSyncError}'),
                        Expanded(child: _pages(context)),
                        _bottomBar(context),
                      ],
                    ),
        );
      },
    );
  }

  Widget _header(BuildContext context) {
    final ratio = _c.totalCount == 0 ? 0.0 : _c.answeredCount / _c.totalCount;
    return Container(
      decoration: BoxDecoration(
        color: Wms.card,
        border: Border(bottom: BorderSide(color: Wms.line)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_c.object ?? '',
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            Text(_c.template ?? '',
                style: TextStyle(fontSize: 13, color: Wms.muted)),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(value: ratio, minHeight: 6),
            ),
            const SizedBox(height: 4),
            Text(
              'заполнено ${_c.answeredCount} из ${_c.totalCount}'
              '${_c.missingEvidence > 0 ? ' · нужно свидетельство: ${_c.missingEvidence}' : ''}',
              style: TextStyle(fontSize: 12, color: Wms.muted),
            ),
            if (_c.summary.hasScored && _c.summary.percent != null) ...[
              const SizedBox(height: 8),
              _score(context),
            ],
            if (_c.summary.prevDate != null) ...[
              const SizedBox(height: 8),
              _prevCheckLine(context),
            ],
          ],
        ),
      ),
    );
  }

  /// Итог прошлой проверки на входе в бланк (#36778): «чего здесь ждать» до того,
  /// как человек начал листать пункты. Тап открывает просмотр целиком. Отсутствие
  /// prevDate — объект по этому шаблону проверяется впервые, строки нет вовсе.
  Widget _prevCheckLine(BuildContext context) {
    final s = _c.summary;
    return InkWell(
      onTap: _openPast,
      borderRadius: BorderRadius.circular(6),
      child: Row(
        children: [
          Icon(Icons.history, size: 16, color: Wms.muted),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Прошлая проверка: '
              '${FillSummary.pastLine(s.prevDate!, s.prevPercent, s.prevRemarks)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: Wms.muted),
            ),
          ),
          Icon(Icons.chevron_right, size: 16, color: Wms.muted),
        ],
      ),
    );
  }

  void _openPast({String? fieldCode}) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PastCheckScreen.forTask(widget.taskId,
          initialFieldCode: fieldCode),
    ));
  }

  /// Current score and grade. Both come from the server: the scoring rules and the
  /// grade boundaries live there, and duplicating them here would be a second source
  /// of truth that drifts. So while there are unsynced answers the figure is openly
  /// labelled as stale rather than quietly recomputed.
  Widget _score(BuildContext context) {
    final s = _c.summary;
    final pct = s.percent!;
    final stale = _c.pendingCount > 0;
    final color = stale ? Wms.muted : (s.passed ? Wms.ok : Wms.warn);

    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            '${FillSummary.formatPercent(pct)}'
            '${s.verdict != null ? ' · ${s.verdict}' : ''}',
            style: TextStyle(
                fontSize: 13, fontWeight: FontWeight.w700, color: color),
          ),
        ),
        if (stale)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text('обновится после синхронизации',
                  style: TextStyle(fontSize: 11, color: Wms.muted)),
            ),
          ),
      ],
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
            itemBuilder: (context, page) {
              final items = _c.fieldsOfSection(page);
              return ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemCount: items.length,
                itemBuilder: (context, i) {
                  final f = items[i];
                  return FillFieldTile(
                    key: ValueKey(f.code),
                    field: f,
                    // завершённая проверка — просмотр, а не редактор (#36778).
                    // По ПОДТВЕРЖДЁННОМУ завершению: закрытую офлайн держим
                    // редактируемой, пока цепочка не дожалась, — отвергнутый
                    // сервером ответ иначе было бы нечем исправить
                    readOnly: _c.confirmedFinished,
                    onOpenPast: f.prevNonconformity
                        ? () => _openPast(fieldCode: f.code)
                        : null,
                    onOption: (c) => _c.setOption(f, c),
                    onNumber: (v) => _c.setNumber(f, v),
                    onText: (t) => _c.setText(f, t),
                    onBool: (b) => _c.setBool(f, b),
                    onDatePick: () => _pickDate(f),
                    onScan: () => _scanCode(f),
                    onComment: (t) => _c.setComment(f, t),
                    onPhoto: () => _pickPhoto(f),
                    onRemovePhoto: () => _c.clearPhotos(f),
                    onCell: (row, col, v) => _c.setCellNumber(f, row, col, v),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _bottomBar(BuildContext context) {
    // While the keyboard is up the section navigation sits right on top of it, competing
    // with the field's own «Готово» and inviting a mistap that jumps to another section
    // mid-sentence. Typing and paging are different modes; show only the one in use.
    if (MediaQuery.of(context).viewInsets.bottom > 0) {
      return const SizedBox.shrink();
    }

    final last = _page >= _c.sectionCount - 1;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // завершённой проверке исход не выбирают — он показан текстом
            if (last && _c.resolutionRequired && !_c.confirmedFinished)
              _resolutionPicker(),
            if (last && _c.confirmedFinished && _c.resolution != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Text('Исход: ',
                        style: TextStyle(fontSize: 13, color: Wms.muted)),
                    Text(
                      ResolutionOption.labelOf(_c.resolution) ?? '',
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            Row(
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
                  )
                else
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: Wms.ok,
                      foregroundColor: Colors.white,
                      minimumSize: const Size(0, 46),
                      textStyle: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w700),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                    // завершённая (в том числе офлайн, с finish в очереди) проверка
                    // не завершается второй раз — иначе экран противоречил бы списку
                    onPressed: _c.finished ? null : _finish,
                    icon: const Icon(Icons.check),
                    label: Text(_c.finished ? 'Завершено' : 'Завершить'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// «Вы не на этом объекте» — вместо бланка, а не поверх него (#36837). Полей не
  /// видно намеренно: read-only-бланк с живыми на вид контролами звал бы заполнять
  /// дальше. Введённое на месте цело и синхронизируется как обычно — экран это
  /// говорит прямо, потому что «нельзя продолжать» без этого читается как «пропало».
  Widget _awayScreen(BuildContext context) {
    final view = context.read<TaskRepository>().viewOf(widget.taskId);
    final d = view?.task.distanceText;
    return Scaffold(
      appBar: AppBar(title: const Text('Заполнение')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.near_me_disabled_outlined, size: 48, color: Wms.muted),
              const SizedBox(height: 16),
              Text(
                'Вы не на этом объекте',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 17, fontWeight: FontWeight.w700, color: Wms.text),
              ),
              const SizedBox(height: 10),
              Text(
                'Заполнять можно только на объекте задачи'
                '${d == null ? '' : ' — до него $d'}. '
                'Всё введённое на месте сохранено и синхронизируется как обычно.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, height: 1.4, color: Wms.muted),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.arrow_back, size: 18),
                label: const Text('К задаче'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _resolutionPicker() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Text('Исход:', style: TextStyle(fontSize: 13, color: Wms.muted)),
          const SizedBox(width: 10),
          Expanded(
            child: DropdownButtonFormField<String>(
              initialValue: _c.resolution,
              isExpanded: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                isDense: true,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              ),
              hint: const Text('выберите'),
              items: [
                for (final r in ResolutionOption.all)
                  DropdownMenuItem(value: r.code, child: Text(r.label)),
              ],
              onChanged: (v) {
                if (v != null) _c.setResolution(v);
              },
            ),
          ),
        ],
      ),
    );
  }
}
