import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../data/simple_controller.dart';
import '../data/task_repository.dart';
import 'theme.dart';
import 'widgets/warn_bar.dart';

/// Выполнение поручения и корректирующего действия (#36872): снимки, комментарий,
/// «Выполнено». Не бланк: полей здесь нет и быть не может — задача такого вида
/// закрывается тем, что человек показывает результат, а не отвечает на вопросы.
///
/// Экран один на оба типа задач: и «Поручение», и «Корректирующее действие» стоят на
/// одном и том же выполнении с фотоотчётом, и разводить их по двум экранам значило бы
/// поддерживать две копии одного и того же. Какой задаче он положен, решает сервер
/// (`executionKind`), а не список типов внутри приложения.
class SimpleExecutionScreen extends StatefulWidget {
  final String taskId;
  const SimpleExecutionScreen({super.key, required this.taskId});

  @override
  State<SimpleExecutionScreen> createState() => _SimpleExecutionScreenState();
}

class _SimpleExecutionScreenState extends State<SimpleExecutionScreen> {
  late final SimpleExecutionController _c;
  late final TextEditingController _comment;

  /// load() уже запускался. Отдельно от контроллера: вне объекта задачи он
  /// откладывается — load() не только читает состояние, но и НАЧИНАЕТ работу на
  /// сервере, а «открыл экран» не должно превращаться в «начал работу» не на месте
  /// (#36837). Запустится из build, когда человек снова окажется там.
  bool _loaded = false;

  /// Задача не того объекта, где человек стоит (#36837): смотрим репозиторий на
  /// каждый rebuild, чтобы полоса появлялась и исчезала в тот же кадр, что и смена
  /// объекта в шапке списка.
  bool _away(TaskRepository repo) =>
      repo.viewOf(widget.taskId)?.elsewhere ?? false;

  @override
  void initState() {
    super.initState();
    final repo = context.read<TaskRepository>();
    // geo — чтобы старт и завершение унесли точку момента действия (#36838);
    // requirePhoto из списка — чтобы «Выполнено» гасло до снимка и там, где ответа
    // сервера ещё не было (задача, рождённая офлайн)
    _c = SimpleExecutionController(
        db: repo.db,
        api: repo.api,
        taskId: widget.taskId,
        geo: repo.geo,
        requirePhotoHint: repo.viewOf(widget.taskId)?.task.requirePhoto == true);
    _comment = TextEditingController();
    _c.addListener(_syncCommentField);
    if (!_away(repo)) {
      _loaded = true;
      _c.load();
    }
  }

  /// Текст из контроллера — в поле, но только когда человек его не правит: иначе
  /// ответ сервера, пришедший в середине фразы, увёл бы курсор в начало.
  void _syncCommentField() {
    final incoming = _c.comment ?? '';
    if (_commentFocus.hasFocus || _comment.text == incoming) return;
    _comment.text = incoming;
  }

  final _commentFocus = FocusNode();

  @override
  void dispose() {
    _c.removeListener(_syncCommentField);
    // комментарий, набранный и не «сохранённый» явно, не должен пропасть вместе с
    // экраном: он ложится в очередь ровно так же, как если бы поле потеряло фокус
    unawaited(_c.setComment(_comment.text));
    _commentFocus.dispose();
    _comment.dispose();
    _c.dispose();
    super.dispose();
  }

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
      if (file == null) return;
      await _c.addPhoto(file.path);
    } catch (e) {
      messenger
          .showSnackBar(SnackBar(content: Text('Не удалось получить фото: $e')));
    }
  }

  Future<void> _finish() async {
    final repo = context.read<TaskRepository>();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    // набранный текст уходит вместе с отчётом, а не после него: комментарий —
    // часть того, что человек показывает, и «Выполнено» не должно его обгонять
    await _c.setComment(_comment.text);
    final ok = await _c.finish();
    if (!mounted) return;
    if (ok) {
      messenger.showSnackBar(SnackBar(
          content: Text(_c.online
              ? 'Задача выполнена'
              : 'Выполнено — уедет на сервер при связи')));
      unawaited(repo.syncAndRefresh());
      navigator.pop();
    } else {
      // сервер отказал — показываем ЕГО причину, а не «успех»: это и есть тот
      // случай, ради которого завершение проверяет применение (#36872)
      messenger.showSnackBar(
          SnackBar(content: Text(_c.error ?? 'Не удалось завершить')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<TaskRepository>();
    if (_away(repo)) return _awayScreen(context);
    if (!_loaded) {
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
            title: const Text('Выполнение'),
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
          body: _c.loading
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    _header(context, repo),
                    if (!_c.online)
                      const WarnBar(Icons.cloud_off,
                          'Офлайн — снимок и комментарий сохранены и уедут при связи'),
                    if (_c.online && _c.lastSyncError != null)
                      WarnBar(Icons.sync_problem,
                          'Не принято: ${_c.lastSyncError}'),
                    Expanded(child: _body(context)),
                    _bottomBar(context),
                  ],
                ),
        );
      },
    );
  }

  /// Шапка. Объект и название берутся из кэша задачи, когда состояние с сервера ещё
  /// не читалось: задача, рождённая в подвале, к серверу не ходила ни разу, а знать,
  /// что именно выполняешь, надо и там.
  Widget _header(BuildContext context, TaskRepository repo) {
    final task = repo.viewOf(widget.taskId)?.task;
    final object = _c.object ?? task?.object ?? '';
    final name = _c.name ?? task?.name ?? '';
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
            Text(object,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            if (name.isNotEmpty)
              Text(name, style: TextStyle(fontSize: 13, color: Wms.muted)),
            if (_c.requirePhoto && !_c.finished) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(Icons.photo_camera_outlined,
                      size: 14, color: _c.hasPhoto ? Wms.ok : Wms.warn),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      _c.hasPhoto
                          ? 'Фото приложено'
                          : 'Нужно фото выполненной работы',
                      style: TextStyle(
                          fontSize: 12,
                          color: _c.hasPhoto ? Wms.muted : Wms.warn),
                    ),
                  ),
                ],
              ),
            ],
            // Сказать вслух, а не умолчать (#36838), тем же текстом, что и бланк:
            // в задачу пишутся две точки — где работа начата и где завершена.
            if (!_c.finished) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(Icons.place_outlined, size: 14, color: Wms.muted),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      'В задачу записываются место и время начала и завершения',
                      style: TextStyle(fontSize: 11, color: Wms.muted),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      children: [
        Text('Фото выполнения',
            style: TextStyle(
                fontSize: 13, fontWeight: FontWeight.w600, color: Wms.text)),
        const SizedBox(height: 8),
        _photos(context),
        const SizedBox(height: 20),
        Text('Комментарий',
            style: TextStyle(
                fontSize: 13, fontWeight: FontWeight.w600, color: Wms.text)),
        const SizedBox(height: 8),
        TextField(
          controller: _comment,
          focusNode: _commentFocus,
          enabled: !_c.finished,
          maxLines: 4,
          maxLength: 500,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: 'Что сделано (необязательно)',
          ),
          // фокус ушёл — текст в очередь: набранное не должно зависеть от того,
          // вспомнил ли человек нажать «Выполнено» (и от того, что связи нет)
          onTapOutside: (_) {
            _commentFocus.unfocus();
            unawaited(_c.setComment(_comment.text));
          },
          onEditingComplete: () {
            _commentFocus.unfocus();
            unawaited(_c.setComment(_comment.text));
          },
        ),
        const SizedBox(height: 6),
        Text(
          'Комментарий попадёт в ленту задачи, фото — в её файлы.',
          style: TextStyle(fontSize: 11, color: Wms.muted),
        ),
      ],
    );
  }

  /// Галерея: снимки этого устройства, снимки, о которых знает только сервер (сделаны
  /// на другом устройстве), плитка «добавить» и «убрать все».
  Widget _photos(BuildContext context) {
    final local = _c.photoPaths;
    final remote = local.isEmpty ? _c.serverPhotoIndexes : const <int>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final path in local)
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.file(File(path),
                    width: 84,
                    height: 84,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => _placeholder()),
              ),
            // снимки с сервера показываются, только когда своих нет: иначе один и тот
            // же кадр (свой, уже уехавший) висел бы на экране дважды
            for (final index in remote)
              FutureBuilder(
                future: _c.serverPhoto(index),
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return _placeholder(child: const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2)));
                  }
                  final bytes = snap.data;
                  if (bytes == null) {
                    return _placeholder(
                        child: Icon(Icons.cloud_off, size: 20, color: Wms.muted));
                  }
                  return ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.memory(bytes,
                        width: 84, height: 84, fit: BoxFit.cover),
                  );
                },
              ),
            if (!_c.finished)
              InkWell(
                onTap: _pickPhoto,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  width: 84,
                  height: 84,
                  decoration: BoxDecoration(
                    border: Border.all(color: Wms.line),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(Icons.add_a_photo, size: 24, color: Wms.muted),
                ),
              ),
          ],
        ),
        if (_c.hasPhoto && !_c.finished) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              Text(
                'фото: ${local.isNotEmpty ? local.length : _c.serverPhotoCount}',
                style: TextStyle(fontSize: 12, color: Wms.muted),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: _c.clearPhotos,
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('Убрать все'),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _placeholder({Widget? child}) => Container(
        width: 84,
        height: 84,
        decoration: BoxDecoration(
          color: Wms.bg,
          border: Border.all(color: Wms.line),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Center(
            child: child ??
                Icon(Icons.broken_image_outlined, size: 20, color: Wms.muted)),
      );

  Widget _bottomBar(BuildContext context) {
    if (MediaQuery.of(context).viewInsets.bottom > 0) {
      return const SizedBox.shrink();
    }
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // почему кнопка погашена — словами и заранее: отказ сервера постфактум
            // человек читал бы, уже уйдя с точки (#36872)
            if (!_c.finished && _c.requirePhoto && !_c.hasPhoto)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, size: 14, color: Wms.warn),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'По этой задаче нужно фото — снимите результат работы',
                        style: TextStyle(fontSize: 12, color: Wms.warn),
                      ),
                    ),
                  ],
                ),
              ),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: Wms.ok,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(0, 46),
                  textStyle:
                      const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
                // выполненная (в том числе офлайн, с завершением в очереди) задача
                // не выполняется второй раз — иначе экран противоречил бы списку
                onPressed: _c.canFinish ? _finish : null,
                icon: const Icon(Icons.check),
                label: Text(_c.finished ? 'Задача выполнена' : 'Выполнено'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// «Вы не на этом объекте» — вместо экрана, а не поверх него (#36837): работа
  /// делается на месте, и живая на вид кнопка «Выполнено» звала бы закрыть задачу из
  /// дома. Снятое на месте цело и уедет как обычно — экран говорит это прямо.
  Widget _awayScreen(BuildContext context) {
    final view = context.read<TaskRepository>().viewOf(widget.taskId);
    final d = view?.task.distanceText;
    return Scaffold(
      appBar: AppBar(title: const Text('Выполнение')),
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
                'Выполнять можно только на объекте задачи'
                '${d == null ? '' : ' — до него $d'}. '
                'Всё снятое на месте сохранено и синхронизируется как обычно.',
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
}
