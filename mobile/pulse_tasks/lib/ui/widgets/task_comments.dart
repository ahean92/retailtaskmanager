import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../data/comment_controller.dart';
import '../../data/task_repository.dart';
import '../../models/comment.dart';
import '../theme.dart';
import 'task_photo.dart';

/// Лента комментариев задачи и поле ввода (#36844) — секция карточки задачи.
///
/// Лента по задаче, а не мессенджер: без редактирования, без удаления чужого, без
/// реакций. Сообщение пишут там же, где заполняют бланк, — часто без связи: оно встаёт
/// в ленту сразу с пометкой «не отправлено» и уезжает при связи (TaskCommentsController).
/// Показанное — прочитано: отметка ставится на последнее серверное сообщение, и бейджи
/// на карточках гаснут в том же кадре (TaskRepository.reloadLocal).
class TaskCommentsSection extends StatefulWidget {
  final String taskId;
  const TaskCommentsSection({super.key, required this.taskId});

  @override
  State<TaskCommentsSection> createState() => _TaskCommentsSectionState();
}

class _TaskCommentsSectionState extends State<TaskCommentsSection> {
  /// null — базы нет (сессия умерла под открытой карточкой): секция рисует пустое
  /// место, а не роняет экран, которому и так осталось жить один кадр.
  TaskCommentsController? _controller;
  TaskCommentsController get _c => _controller!;
  final TextEditingController _text = TextEditingController();

  /// Снимок, выбранный к следующему сообщению, — показан над полем ввода, пока не
  /// отправлен или не убран.
  String? _photo;
  bool _sending = false;

  /// Сколько серверных сообщений было на экране при последней отметке прочтения —
  /// отметка ставится, только когда их стало больше, а не на каждую перерисовку.
  int _markedCount = -1;

  @override
  void initState() {
    super.initState();
    final repo = context.read<TaskRepository>();
    final db = repo.localDb;
    if (db == null) return;
    final c = TaskCommentsController(
        db: db, api: repo.api, taskId: widget.taskId);
    _controller = c;
    c.addListener(_onChanged);
    c.load();
  }

  @override
  void dispose() {
    _controller?.removeListener(_onChanged);
    _controller?.dispose();
    _text.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    setState(() {});
    final shown = _c.items.where((c) => !c.pending).length;
    if (_c.loading || shown == _markedCount) return;
    _markedCount = shown;
    final repo = context.read<TaskRepository>();
    _c.markRead().then((_) => repo.reloadLocal());
  }

  @override
  Widget build(BuildContext context) {
    if (_controller == null) return const SizedBox.shrink();
    final items = _c.items;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Комментарии',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(width: 8),
            if (items.isNotEmpty)
              Text('${items.length}',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: Wms.primary)),
            const Spacer(),
            if (_c.syncing)
              const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2)),
          ],
        ),
        const SizedBox(height: 8),
        if (_c.loading && items.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (items.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(_c.error ?? 'Сообщений пока нет — напишите первым',
                style: TextStyle(fontSize: 13, color: Wms.muted)),
          )
        else
          for (final c in items)
            _Bubble(
              comment: c,
              controller: _c,
              onDiscard: c.pending && c.sendError != null && c.clientId != null
                  ? () => _discard(c.clientId!)
                  : null,
            ),
        if (!_c.online)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              children: [
                Icon(Icons.cloud_off, size: 14, color: Wms.muted),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Офлайн — показана сохранённая переписка; новое уйдёт при '
                    'связи',
                    style: TextStyle(fontSize: 12, color: Wms.muted),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 10),
        _composer(context),
      ],
    );
  }

  bool get _canSend =>
      !_sending && (_text.text.trim().isNotEmpty || _photo != null);

  Widget _composer(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_photo != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.file(File(_photo!),
                      width: 56,
                      height: 56,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => brokenPhoto(56)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Фото уйдёт вместе с сообщением',
                      style: TextStyle(fontSize: 12, color: Wms.muted)),
                ),
                IconButton(
                  tooltip: 'Убрать фото',
                  icon: const Icon(Icons.close),
                  onPressed:
                      _sending ? null : () => setState(() => _photo = null),
                ),
              ],
            ),
          ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            IconButton(
              tooltip: 'Фото',
              icon: Icon(Icons.add_a_photo_outlined, color: Wms.primary),
              onPressed: _sending ? null : _pickPhoto,
            ),
            Expanded(
              child: TextField(
                controller: _text,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  hintText: 'Написать…',
                  isDense: true,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20)),
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 10),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 4),
            IconButton.filled(
              tooltip: 'Отправить',
              icon: const Icon(Icons.send, size: 20),
              onPressed: _canSend ? _send : null,
            ),
          ],
        ),
      ],
    );
  }

  /// Камера или галерея — тот же выбор, что у фото к пункту бланка (FillScreen):
  /// снимок «с места» делают камерой, а «вот что было утром» берут из галереи.
  Future<void> _pickPhoto() async {
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
      if (file == null || !mounted) return;
      setState(() => _photo = file.path);
    } catch (e) {
      messenger
          .showSnackBar(SnackBar(content: Text('Не удалось получить фото: $e')));
    }
  }

  Future<void> _send() async {
    final repo = context.read<TaskRepository>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _sending = true);
    try {
      await _c.send(_text.text, photoPath: _photo);
      _text.clear();
      _photo = null;
      // счётчик на карточке — в том же кадре, что и пузырь в ленте
      await repo.reloadLocal();
      if (!repo.online) {
        messenger.showSnackBar(const SnackBar(
          content: Text('Сохранено офлайн — отправится при связи'),
          duration: Duration(seconds: 2),
        ));
      }
    } catch (e) {
      messenger.showSnackBar(
          SnackBar(content: Text('Не удалось сохранить сообщение: $e')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _discard(String clientId) async {
    final repo = context.read<TaskRepository>();
    await _c.discard(clientId);
    await repo.reloadLocal();
  }
}

/// Одно сообщение: свои справа на подложке выделения, чужие слева на карточке;
/// автор и время, текст, вложения, у неотправленного — пометка и причина.
class _Bubble extends StatelessWidget {
  final TaskComment comment;
  final TaskCommentsController controller;
  final VoidCallback? onDiscard;
  const _Bubble(
      {required this.comment, required this.controller, this.onDiscard});

  @override
  Widget build(BuildContext context) {
    final c = comment;
    final mine = c.mine;
    final failed = c.sendError != null;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.82),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: BoxDecoration(
          color: mine ? Wms.active : Wms.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: failed ? Wms.warn : Wms.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    mine ? 'Вы' : (c.author ?? 'Без имени'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: mine ? Wms.primaryDark : Wms.primary),
                  ),
                ),
                const SizedBox(width: 8),
                Text(_when(c.when),
                    style: TextStyle(fontSize: 11, color: Wms.muted)),
              ],
            ),
            if ((c.text ?? '').trim().isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(c.text!.trim(), style: const TextStyle(fontSize: 14)),
            ],
            if (c.photoPath != null) ...[
              const SizedBox(height: 6),
              TaskPhotoThumb(loader: localPhoto(File(c.photoPath!))),
            ],
            for (final f in c.files) ...[
              const SizedBox(height: 6),
              if (f.image)
                TaskPhotoThumb(
                    loader: ({required thumb}) =>
                        controller.photoFile(f.id, thumb: thumb))
              else
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.attach_file, size: 14, color: Wms.muted),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(f.name ?? 'файл',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: Wms.muted)),
                    ),
                  ],
                ),
            ],
            if (c.pending) ...[
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(failed ? Icons.error_outline : Icons.schedule,
                      size: 13, color: failed ? Wms.warn : Wms.muted),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      failed
                          ? 'не принято: ${c.sendError}'
                          : 'не отправлено — уйдёт при связи',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11, color: failed ? Wms.warn : Wms.muted),
                    ),
                  ),
                  if (onDiscard != null)
                    TextButton(
                      onPressed: onDiscard,
                      style: TextButton.styleFrom(
                          minimumSize: const Size(0, 28),
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          visualDensity: VisualDensity.compact),
                      child: const Text('Убрать'),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// «сегодня 10:42», «вчера 18:05», «12.07 09:30» — как в ленте уведомлений.
  static String _when(DateTime? t) {
    if (t == null) return '';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(t.year, t.month, t.day);
    String two(int v) => v.toString().padLeft(2, '0');
    final hm = '${two(t.hour)}:${two(t.minute)}';
    if (day == today) return 'сегодня $hm';
    if (day == today.subtract(const Duration(days: 1))) return 'вчера $hm';
    return '${two(t.day)}.${two(t.month)} $hm';
  }
}
