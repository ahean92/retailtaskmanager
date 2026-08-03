import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../data/fill_controller.dart';
import '../data/task_repository.dart';
import '../models/fill.dart';
import 'theme.dart';
import 'widgets/fill_field_tile.dart';

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

  @override
  void initState() {
    super.initState();
    final repo = context.read<TaskRepository>();
    _c = FillController(db: repo.db, api: repo.api, taskId: widget.taskId);
    _c.load();
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
      messenger
          .showSnackBar(const SnackBar(content: Text('Задача завершена')));
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
      await _c.setPhoto(f, file.path);
    } catch (e) {
      messenger
          .showSnackBar(SnackBar(content: Text('Не удалось получить фото: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
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
                        if (!_c.online) const _Bar(Icons.cloud_off,
                            'Офлайн — данные сохраняются и синхронизируются позже'),
                        if (_c.online && _c.lastSyncError != null)
                          _Bar(Icons.sync_problem,
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
      decoration: const BoxDecoration(
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
                style: const TextStyle(fontSize: 13, color: Wms.muted)),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(value: ratio, minHeight: 6),
            ),
            const SizedBox(height: 4),
            Text(
              'заполнено ${_c.answeredCount} из ${_c.totalCount}'
              '${_c.missingEvidence > 0 ? ' · нужно свидетельство: ${_c.missingEvidence}' : ''}',
              style: const TextStyle(fontSize: 12, color: Wms.muted),
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
                  style: const TextStyle(fontSize: 12, color: Wms.muted)),
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
                    onOption: (c) => _c.setOption(f, c),
                    onNumber: (v) => _c.setNumber(f, v),
                    onText: (t) => _c.setText(f, t),
                    onBool: (b) => _c.setBool(f, b),
                    onDatePick: () => _pickDate(f),
                    onComment: (t) => _c.setComment(f, t),
                    onPhoto: () => _pickPhoto(f),
                    onRemovePhoto: () => _c.removePhoto(f),
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
    final last = _page >= _c.sectionCount - 1;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (last && _c.resolutionRequired) _resolutionPicker(),
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
                    onPressed: _finish,
                    icon: const Icon(Icons.check),
                    label: const Text('Завершить'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _resolutionPicker() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          const Text('Исход:', style: TextStyle(fontSize: 13, color: Wms.muted)),
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

class _Bar extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Bar(this.icon, this.text);

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Wms.warn.withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          children: [
            Icon(icon, size: 16, color: Wms.warn),
            const SizedBox(width: 8),
            Expanded(
              child: Text(text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: Wms.warn)),
            ),
          ],
        ),
      ),
    );
  }
}
