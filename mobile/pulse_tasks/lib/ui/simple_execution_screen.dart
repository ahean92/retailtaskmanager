import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../data/simple_controller.dart';
import '../data/sync_coordinator.dart';
import '../data/task_repository.dart';
import '../models/task_view.dart';
import 'theme.dart';
import 'widgets/acceptance.dart';
import 'widgets/ds.dart';

/// Выполнение поручения и корректирующего действия (#36872): снимки, комментарий,
/// «Выполнено». Не бланк: полей здесь нет и быть не может — задача такого вида
/// закрывается тем, что человек показывает результат, а не отвечает на вопросы.
///
/// Экран один на оба типа задач: и «Поручение», и «Корректирующее действие» стоят на
/// одном и том же выполнении с фотоотчётом, и разводить их по двум экранам значило бы
/// поддерживать две копии одного и того же. Какой задаче он положен, решает сервер
/// (`executionKind`), а не список типов внутри приложения.
///
/// Редизайн #37411 (п. 7): заголовок и срок с остатком, карточки «Фото выполнения»
/// и «Комментарий», одна кнопка внизу. Логика контроллера не менялась.
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

  /// Для dispose: context.read там уже нельзя, а бейдж «не отправлено» на главной
  /// обязан узнать про очереди, оставшиеся от этого экрана (#36916).
  late final TaskRepository _repo;

  @override
  void initState() {
    super.initState();
    final repo = _repo = context.read<TaskRepository>();
    // geo — чтобы старт и завершение унесли точку момента действия (#36838);
    // requirePhoto из списка — чтобы «Выполнено» гасло до снимка и там, где ответа
    // сервера ещё не было (задача, рождённая офлайн); возврат на доработку — чтобы по
    // сданному отчёту завелось новое выполнение (#37158)
    final view = repo.viewOf(widget.taskId);
    _c = SimpleExecutionController(
        db: repo.db,
        api: repo.api,
        taskId: widget.taskId,
        geo: repo.geo,
        requirePhotoHint: view?.task.requirePhoto == true,
        restartHint: view?.restartsExecution == true);
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
    // экраном: он ложится в очередь ровно так же, как если бы поле потеряло фокус.
    // Следом — пересчёт «не отправлено» (#36916): строго после enqueue, иначе бейдж
    // главной пересчитается по ещё пустой очереди. Молча: база могла закрыться
    // прямо под экраном (выход из аккаунта), счётчик ей уже не нужен
    unawaited(_c
        .setComment(_comment.text)
        .catchError((_) {})
        .then((_) => _repo.reloadLocal())
        .catchError((_) {}));
    _commentFocus.dispose();
    _comment.dispose();
    _c.dispose();
    super.dispose();
  }

  /// Кадр из названного источника: кнопки «Камера» и «Галерея» (#37411, п. 7)
  /// идут прямо в пикер, без листа-выбора между ними.
  Future<void> _pickPhoto(ImageSource source) async {
    final messenger = ScaffoldMessenger.of(context);
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

  /// Задача с приёмкой (#37158): «Выполнено» здесь — сдача, а не конец, и кнопка с
  /// сообщением говорят это прямо.
  bool get _submits =>
      _repo.viewOf(widget.taskId)?.task.needsAcceptance == true;

  Future<void> _finish() async {
    final sync = context.read<SyncCoordinator>();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final submits = _submits;
    // набранный текст уходит вместе с отчётом, а не после него: комментарий —
    // часть того, что человек показывает, и «Выполнено» не должно его обгонять
    await _c.setComment(_comment.text);
    final ok = await _c.finish();
    if (!mounted) return;
    if (ok) {
      messenger.showSnackBar(SnackBar(
          content: Text(_c.online
              ? (submits ? 'Сдано на приёмку' : 'Задача выполнена')
              : (submits
                  ? 'Сдано — уедет на сервер при связи'
                  : 'Выполнено — уедет на сервер при связи'))));
      unawaited(sync.syncAndRefresh());
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
                Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: Center(
                    child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Wms.text2)),
                  ),
                )
              else if (_c.pendingCount > 0)
                Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: Center(
                    child: DsChip(
                      '${_c.pendingCount}',
                      icon: Icons.sync_problem,
                      tone: DsTone.caution,
                    ),
                  ),
                ),
            ],
          ),
          body: _c.loading
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.only(top: 4),
                  children: [
                    _header(context, repo),
                    // почему задача снова здесь (#37158) — словами принимающего
                    if (repo.viewOf(widget.taskId)?.returned == true)
                      DsBanner(Icons.undo,
                          returnedLine(repo.viewOf(widget.taskId)!)),
                    // почему кнопка погашена — словами и заранее: отказ сервера
                    // постфактум человек читал бы, уже уйдя с точки (#36872)
                    if (!_c.finished && _c.requirePhoto && !_c.hasPhoto)
                      const DsBanner(
                          Icons.photo_camera_outlined,
                          'По этой задаче нужно фото — снимите результат работы',
                          tone: DsTone.brandSoft),
                    if (!_c.online)
                      const DsBanner(Icons.cloud_off,
                          'Офлайн — снимок и комментарий сохранены и уедут при связи'),
                    if (_c.online && _c.lastSyncError != null)
                      DsBanner(Icons.sync_problem,
                          'Не принято: ${_c.lastSyncError}',
                          tone: DsTone.danger),
                    _photoCard(),
                    _commentCard(),
                    _geoLine(),
                    const SizedBox(height: 24),
                  ],
                ),
          bottomNavigationBar: _bottomBar(context),
        );
      },
    );
  }

  /// Шапка (п. 7): заголовок задачи и срок с остатком времени. Объект и название
  /// берутся из кэша задачи, когда состояние с сервера ещё не читалось: задача,
  /// рождённая в подвале, к серверу не ходила ни разу, а знать, что именно
  /// выполняешь, надо и там.
  Widget _header(BuildContext context, TaskRepository repo) {
    final view = repo.viewOf(widget.taskId);
    final task = view?.task;
    final object = _c.object ?? task?.object ?? '';
    final name = _c.name ?? task?.name ?? '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (object.isNotEmpty)
            Text(object, style: TextStyle(fontSize: 12, color: Wms.text2)),
          if (name.isNotEmpty) ...[
            if (object.isNotEmpty) const SizedBox(height: 2),
            Text(name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                    color: Wms.text)),
          ],
          if (view != null && _dueLine(view) != null) ...[
            const SizedBox(height: 8),
            DsDeadlineChip(_dueLine(view)!,
                overdue: view.overdue, soon: view.dueToday),
          ],
        ],
      ),
    );
  }

  /// «Срок: 30.08 · осталось 2 дня» — дата срока у задачи дневная, поэтому остаток
  /// честно дневной, без выдуманных часов. Просроченной открытой задаче — «на сколько».
  static String? _dueLine(TaskView view) {
    final label = view.task.deadlineText;
    if (label == null) return null;
    final d = view.task.deadlineDate;
    if (view.overdue && d != null) {
      final days = DateTime.now().difference(d).inDays + 1;
      return 'Срок: $label · просрочено на ${_days(days)}';
    }
    if (d != null) {
      final today = DateTime.now();
      final days = d.difference(DateTime(today.year, today.month, today.day)).inDays;
      if (days > 0) return 'Срок: $label · осталось ${_days(days)}';
      if (days == 0 && !view.overdue) return 'Срок: $label · сегодня';
    }
    return 'Срок: $label';
  }

  /// «1 день», «2 дня», «5 дней» — со склонением, а не «N дн.».
  static String _days(int n) {
    final mod10 = n % 10, mod100 = n % 100;
    final word = (mod10 == 1 && mod100 != 11)
        ? 'день'
        : (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14))
            ? 'дня'
            : 'дней';
    return '$n $word';
  }

  /// Карточка «Фото выполнения» (п. 7): счётчик, сетка миниатюр по три в ряд,
  /// «Убрать все» и кнопки «Камера»/«Галерея» под сеткой.
  Widget _photoCard() {
    final local = _c.photoPaths;
    final remote = local.isEmpty ? _c.serverPhotoIndexes : const <int>[];
    final count = local.isNotEmpty ? local.length : _c.serverPhotoCount;
    return DsCard(children: [
      Row(
        children: [
          Text('Фото выполнения',
              style: TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w700, color: Wms.text)),
          const Spacer(),
          if (count > 0)
            Text('$count',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Wms.text2)),
        ],
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final path in local)
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.file(File(path),
                  width: 96,
                  height: 96,
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
                  borderRadius: BorderRadius.circular(12),
                  child: Image.memory(bytes,
                      width: 96, height: 96, fit: BoxFit.cover),
                );
              },
            ),
          if (count == 0)
            Text('Снимите результат работы — фото попадёт в файлы задачи',
                style: TextStyle(fontSize: 13, color: Wms.muted)),
        ],
      ),
      if (_c.hasPhoto && !_c.finished) ...[
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: _c.clearPhotos,
            icon: Icon(Icons.delete_outline, size: 18, color: Wms.danger),
            label: Text('Убрать все', style: TextStyle(color: Wms.danger)),
          ),
        ),
      ],
      if (!_c.finished) ...[
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 48,
                child: FilledButton.icon(
                  onPressed: () => _pickPhoto(ImageSource.camera),
                  style: FilledButton.styleFrom(
                    backgroundColor: Wms.brandTint,
                    foregroundColor: Wms.primary,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                  icon: const Icon(Icons.photo_camera_outlined, size: 20),
                  label: const Text('Камера'),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: SizedBox(
                height: 48,
                child: OutlinedButton.icon(
                  onPressed: () => _pickPhoto(ImageSource.gallery),
                  icon: const Icon(Icons.photo_library_outlined, size: 20),
                  label: const Text('Галерея'),
                ),
              ),
            ),
          ],
        ),
      ],
    ]);
  }

  /// Карточка «Комментарий» (п. 7): подсказка «Комментарий попадёт в ленту
  /// задачи, фото — в её файлы» живёт в карточке, под полем.
  Widget _commentCard() {
    return DsCard(children: [
      Text('Комментарий',
          style: TextStyle(
              fontSize: 15, fontWeight: FontWeight.w700, color: Wms.text)),
      const SizedBox(height: 12),
      TextField(
        controller: _comment,
        focusNode: _commentFocus,
        enabled: !_c.finished,
        maxLines: 4,
        maxLength: 500,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(
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
      const SizedBox(height: 4),
      Text(
        'Комментарий попадёт в ленту задачи, фото — в её файлы.',
        style: TextStyle(fontSize: 12, color: Wms.muted),
      ),
    ]);
  }

  /// Строка про геометку (#36838), тем же текстом, что и в бланке: в задачу
  /// пишутся две точки — где работа начата и где завершена.
  Widget _geoLine() {
    if (_c.finished) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
      child: Row(
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
    );
  }

  Widget _placeholder({Widget? child}) => Container(
        width: 96,
        height: 96,
        decoration: BoxDecoration(
          color: Wms.bg,
          border: Border.all(color: Wms.line),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Center(
            child: child ??
                Icon(Icons.broken_image_outlined, size: 20, color: Wms.muted)),
      );

  Widget _bottomBar(BuildContext context) {
    if (MediaQuery.of(context).viewInsets.bottom > 0) {
      return const SizedBox.shrink();
    }
    return DsBottomActionBar(
      // выполненная (в том числе офлайн, с завершением в очереди) задача
      // не выполняется второй раз — иначе экран противоречил бы списку
      onPrimary: _c.canFinish ? _finish : null,
      primaryLabel: _submits
          ? (_c.finished ? 'Сдано на приёмку' : 'Сдать на приёмку')
          : (_c.finished ? 'Задача выполнена' : 'Выполнено'),
      primaryBackground: Wms.ok,
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
              Container(
                width: 72,
                height: 72,
                alignment: Alignment.center,
                decoration:
                    BoxDecoration(color: Wms.chipBg, shape: BoxShape.circle),
                child: Icon(Icons.near_me_disabled_outlined,
                    size: 32, color: Wms.text2),
              ),
              const SizedBox(height: 16),
              Text(
                'Вы не на этом объекте',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                    color: Wms.text),
              ),
              const SizedBox(height: 10),
              Text(
                'Выполнять можно только на объекте задачи'
                '${d == null ? '' : ' — до него $d'}. '
                'Всё снятое на месте сохранено и синхронизируется как обычно.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, height: 1.4, color: Wms.text2),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.arrow_back, size: 18),
                  label: const Text('К задаче'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
