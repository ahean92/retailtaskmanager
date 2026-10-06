import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/task_file_cache.dart';
import '../data/task_repository.dart';
import '../data/task_result_controller.dart';
import '../models/task.dart';
import '../models/task_file.dart';
import '../models/task_view.dart';
import 'past_check_screen.dart';
import 'theme.dart';
import 'widgets/acceptance.dart';
import 'widgets/ds.dart';
import 'widgets/task_photo.dart';

/// Результат задачи (#37158): проверку — её сданным бланком на чтение (тем же
/// просмотром, что прошлая проверка), остальное — экраном «было / стало».
Route<void> taskResultRoute(TaskView view) {
  // рождённая на телефоне задача всю жизнь адресуется своим UUID — как её бланк
  final id = view.task.clientId ?? view.id;
  return MaterialPageRoute(
    builder: (_) => view.task.opensFill
        ? PastCheckScreen.forResult(id)
        : TaskResultScreen(taskId: id),
  );
}

void openTaskResult(BuildContext context, TaskView view) =>
    Navigator.of(context).push(taskResultRoute(view));

/// Результат поручения или корректирующего действия (#37158): что было, что стало и
/// что сказал исполнитель — то, по чему принимающий решает. «Было» — снимки задачи
/// (#36842), «Стало» — все снимки сданного отчёта и комментарий, а не один первый кадр,
/// как в выдаче задач. Прежние раунды — ниже: повторная сдача прежний результат не
/// стирает, и сравнить «что вернул — что переделали» можно здесь же.
///
/// Редизайн #37411 (п. 8): чипы «тип · статус», исполнитель и время сдачи с пометкой
/// «в срок» / «с опозданием», «Было» и «Стало» рядом — каждая листается по фото и
/// несёт точки-индикатор, «Прежние выполнения» свёрнуты строкой с последней причиной
/// возврата, решение принимающего — нижней панелью.
class TaskResultScreen extends StatefulWidget {
  final String taskId;
  const TaskResultScreen({super.key, required this.taskId});

  @override
  State<TaskResultScreen> createState() => _TaskResultScreenState();
}

class _TaskResultScreenState extends State<TaskResultScreen> {
  /// Отчёт простого выполнения — только у задач, которые им выполняются; у прочих
  /// «стало» — выполнения из выдачи задач.
  TaskResultController? _report;

  /// Снимки задачи и выполнений — тем же кэшем, что на карточке.
  TaskFileCache? _files;

  bool _leaving = false;

  /// «Прежние выполнения» раскрыты (#37411, п. 8): строкой по умолчанию, списком —
  /// по тапу; сворачивается обратно.
  bool _earlierOpen = false;

  @override
  void initState() {
    super.initState();
    final repo = context.read<TaskRepository>();
    final db = repo.localDb;
    if (db == null) return;
    _files = TaskFileCache(userKey: db.userKey, api: repo.api);
    if (repo.viewOf(widget.taskId)?.task.opensSimple == true) {
      _report = TaskResultController(db: db, api: repo.api, taskId: widget.taskId)
        ..load();
    }
  }

  @override
  void dispose() {
    _report?.dispose();
    super.dispose();
  }

  /// Задачи в списке больше нет (принята здесь же или закрыта): экран о ней — тупик.
  void _leave() {
    if (_leaving) return;
    _leaving = true;
    final navigator = Navigator.of(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (navigator.mounted && navigator.canPop()) navigator.pop();
    });
  }

  /// Кто и когда сдал: у простого выполнения — отчёт, у прочих — последнее
  /// выполнение из выдачи. null — «не знаем» (сдача ещё в очереди).
  (String?, String?) get _submittedBy {
    final report = _report;
    if (report != null) {
      return (report.executor, report.date);
    }
    final view = context.read<TaskRepository>().viewOf(widget.taskId);
    final execs = view?.task.executions ?? const <TaskExecution>[];
    if (execs.isEmpty) return (null, null);
    return (execs.last.executor, execs.last.dateTime);
  }

  /// Сдано ли с опозданием: сравниваем момент сдачи с концом дня срока. Срок у
  /// задачи дневной (сервер так его экспортирует), поэтому честнее «до конца дня
  /// срока», а не его полуночи.
  bool _late(String? submittedAtRaw) {
    if (submittedAtRaw == null) return false;
    final view = context.read<TaskRepository>().viewOf(widget.taskId);
    final deadline = view?.task.deadlineDate;
    if (deadline == null) return false;
    final submitted = DateTime.tryParse(submittedAtRaw.replaceFirst(' ', 'T'));
    if (submitted == null) return false;
    return submitted.isAfter(
        DateTime(deadline.year, deadline.month, deadline.day, 23, 59, 59));
  }

  @override
  Widget build(BuildContext context) {
    final view = context.watch<TaskRepository>().viewOf(widget.taskId);
    if (view == null) {
      _leave();
      return const Scaffold(body: SizedBox.shrink());
    }
    final t = view.task;
    return Scaffold(
      appBar: AppBar(title: const Text('Результат')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          if (view.returned) DsBanner(Icons.undo, returnedLine(view)),
          _header(view, t),
          const SizedBox(height: 12),
          _compareRow(t),
          const SizedBox(height: 12),
          _commentCard(t),
          _earlier(view, t),
        ],
      ),
      bottomNavigationBar: view.awaitingDecision
          ? Container(
              decoration: BoxDecoration(
                color: Wms.card,
                border: Border(top: BorderSide(color: Wms.line)),
              ),
              child: SafeArea(
                minimum: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: DecisionBar(view: view, popAfter: true),
              ),
            )
          : null,
    );
  }

  /// Чипы «тип · статус», заголовок и строка сдачи с пометкой «в срок» /
  /// «с опозданием» (п. 8). До ответа сервера о сдаче — честное «ждёт отправки»
  /// (submittedLine), пометки при этом нет: опоздание ещё не определено.
  Widget _header(TaskView view, Task t) {
    final (who, at) = _submittedBy;
    final hasSubmission = who != null || at != null;
    final onTime = hasSubmission && !_late(at);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                [t.type, t.subtitle].whereType<String>().join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: Wms.text2),
              ),
            ),
            DsChip(
              view.statusName ?? view.statusId ?? '—',
              tone: dsToneOf(view.statusId),
              compact: true,
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          t.name ?? t.object ?? t.id,
          style: TextStyle(
              fontSize: 24, fontWeight: FontWeight.w700, height: 1.2, color: Wms.text),
        ),
        const SizedBox(height: 10),
        if (hasSubmission)
          Row(
            children: [
              if (who != null) ...[
                DsAvatar(who, size: 32),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (who != null)
                      Text(who,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: Wms.text)),
                    Text(
                      'сдал${formatDateTime(at) == null ? '' : ' ${formatDateTime(at)}'}',
                      style: TextStyle(fontSize: 12, color: Wms.text2),
                    ),
                  ],
                ),
              ),
              DsChip(
                onTime ? 'в срок' : 'с опозданием',
                tone: onTime ? DsTone.done : DsTone.danger,
                compact: true,
              ),
            ],
          )
        else if (view.onAcceptance)
          Text(submittedLine(view),
              style: TextStyle(fontSize: 13, color: Wms.text2)),
      ],
    );
  }

  /// «Было» и «Стало» — рядом (п. 8): две карточки в ряд, каждая листается по фото
  /// с точками-индикатором. «Было» — снимки задачи, «Стало» — сданный отчёт, а у
  /// задачи без фотоотчёта — последнее выполнение из выдачи.
  Widget _compareRow(Task t) {
    final before = [for (final f in t.files) if (f.image) f];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _PhotoPane(
            label: 'Было',
            photos: [
              if (_files != null)
                for (final f in before) _files!.loaderFor(f.id),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Expanded(child: _afterPane(t)),
      ],
    );
  }

  /// «Стало»: отчёт простого выполнения (снимки + комментарий ниже) либо
  /// последнее выполнение из выдачи. Пока отчёт едет — место занято спиннером,
  /// а не «Без фото», чтобы карточка не мигала пустотой.
  Widget _afterPane(Task t) {
    final report = _report;
    if (report == null) {
      final last = t.executions.isEmpty ? null : t.executions.last;
      return _PhotoPane(
        label: 'Стало',
        photos: [
          if (last?.photoId != null && _files != null)
            _files!.loaderFor(last!.photoId!),
        ],
      );
    }
    return ListenableBuilder(
      listenable: report,
      builder: (context, _) {
        final error = report.error;
        if (report.loading && report.date == null) {
          return const _PhotoPane(label: 'Стало', loading: true);
        }
        if (error != null && report.date == null) {
          return _PhotoPane(label: 'Стало', error: error);
        }
        return _PhotoPane(
          label: 'Стало',
          photos: [
            for (final i in report.photoIndexes)
              ({required bool thumb}) => report.photo(i, thumb: thumb),
          ],
        );
      },
    );
  }

  /// Карточка «Комментарий исполнителя» (п. 8): у простого выполнения — текст
  /// отчёта, у прочих — результат последнего выполнения. Пустой комментарий
  /// честно называется пустым, а не прячется.
  Widget _commentCard(Task t) {
    final report = _report;
    final String? raw;
    final String by;
    if (report != null) {
      raw = report.comment?.trim();
      by = [report.executor, formatDateTime(report.date)]
          .whereType<String>()
          .join(' · ');
    } else if (t.executions.isNotEmpty) {
      raw = t.executions.last.result?.trim();
      by = [
        t.executions.last.executor,
        formatDateTime(t.executions.last.dateTime),
      ].whereType<String>().join(' · ');
    } else {
      raw = null;
      by = '';
    }
    final hasComment = raw != null && raw.isNotEmpty;
    return DsCard(children: [
      Text('Комментарий исполнителя',
          style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Wms.text2)),
      const SizedBox(height: 6),
      Text(
        hasComment ? raw : 'Без комментария',
        style: TextStyle(
            fontSize: 15,
            height: 1.35,
            color: hasComment ? Wms.text : Wms.muted),
      ),
      if (by.isNotEmpty) ...[
        const SizedBox(height: 8),
        Text(by, style: TextStyle(fontSize: 12, color: Wms.muted)),
      ],
    ]);
  }

  /// Прежние раунды — всё, кроме последнего выполнения: после возврата видно, что
  /// сдавали в прошлый раз. Свёрнуты строкой с последней причиной возврата (п. 8),
  /// по тапу раскрываются списком. Причина возврата у выполнения не хранится —
  /// она одна у задачи (последний возврат), её и показываем.
  Widget _earlier(TaskView view, Task t) {
    if (t.executions.length < 2) return const SizedBox.shrink();
    final earlier = t.executions.sublist(0, t.executions.length - 1);
    final lastReturn = view.returnReason?.trim();
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => setState(() => _earlierOpen = !_earlierOpen),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
              child: Row(
                children: [
                  Icon(
                    _earlierOpen
                        ? Icons.keyboard_arrow_down
                        : Icons.keyboard_arrow_right,
                    size: 20,
                    color: Wms.text2,
                  ),
                  const SizedBox(width: 4),
                  Text('Прежние выполнения',
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Wms.text)),
                  const SizedBox(width: 6),
                  Text('${earlier.length}',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Wms.primary)),
                  if (!_earlierOpen &&
                      lastReturn != null &&
                      lastReturn.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'последний возврат: $lastReturn',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: Wms.text2),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (_earlierOpen)
            for (final e in earlier.reversed)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _execution(e),
              ),
        ],
      ),
    );
  }

  Widget _execution(TaskExecution e) {
    final line = [
      e.executor,
      formatDateTime(e.dateTime),
      if ((e.result ?? '').isNotEmpty) e.result,
    ].whereType<String>().join(' · ');
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (e.photoId != null && _files != null) ...[
          TaskPhotoThumb(
            loader: _files!.loaderFor(e.photoId!),
            size: 84,
            caption: ['Стало', if (line.isNotEmpty) line].join(' · '),
          ),
          const SizedBox(width: 10),
        ],
        Expanded(
          child: Text(line.isEmpty ? 'Выполнение' : line,
              style: const TextStyle(fontSize: 13)),
        ),
      ],
    );
  }
}

/// Половина пары «Было / Стало»: подпись со счётчиком, листающийся по фото блок
/// с точками-индикатором. Пустая — плейсхолдер «Без фото»: половинка пары не
/// исчезает, иначе сравнивать не с чем.
class _PhotoPane extends StatefulWidget {
  final String label;
  final List<PhotoLoader> photos;

  /// Отчёт ещё едет / не прочитался: место занято, а не «Без фото».
  final bool loading;
  final String? error;

  const _PhotoPane({
    required this.label,
    this.photos = const [],
    this.loading = false,
    this.error,
  });

  @override
  State<_PhotoPane> createState() => _PhotoPaneState();
}

class _PhotoPaneState extends State<_PhotoPane> {
  final _pager = PageController();
  int _index = 0;

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DsCard(
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.all(12),
      children: [
        Row(
          children: [
            Text(widget.label,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Wms.text2)),
            const Spacer(),
            if (widget.photos.isNotEmpty)
              Text('${widget.photos.length}',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Wms.text2)),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 150,
          child: widget.loading
              ? const Center(
                  child: SizedBox(
                      width: 20,
                      height: 20,
                      child:
                          CircularProgressIndicator(strokeWidth: 2)),
                )
              : widget.error != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Text(widget.error!,
                            textAlign: TextAlign.center,
                            style:
                                TextStyle(fontSize: 12, color: Wms.muted)),
                      ),
                    )
                  : widget.photos.isEmpty
                      ? _empty()
                      : PageView.builder(
                          controller: _pager,
                          itemCount: widget.photos.length,
                          onPageChanged: (i) =>
                              setState(() => _index = i),
                          itemBuilder: (context, i) => _PanePhoto(
                              // ключ вида «panePhoto:Стало:0» — сквозные прогоны
                              // (#37158) ждут по нему снимок «стало»
                              key: ValueKey(
                                  'panePhoto:${widget.label}:$i'),
                              loader: widget.photos[i],
                              caption: widget.label),
                        ),
        ),
        if (widget.photos.length > 1)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < widget.photos.length; i++)
                  Container(
                    width: 6,
                    height: 6,
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    decoration: BoxDecoration(
                      color: i == _index ? Wms.primary : Wms.chipBg,
                      shape: BoxShape.circle,
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _empty() => Container(
        decoration: BoxDecoration(
          color: Wms.bg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Wms.line),
        ),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.image_not_supported_outlined,
                size: 22, color: Wms.muted),
            const SizedBox(height: 4),
            Text('Без фото', style: TextStyle(fontSize: 12, color: Wms.muted)),
          ],
        ),
      );
}

/// Один кадр пары «Было / Стало»: миниатюра качается лениво, тап открывает полный
/// размер тем же просмотрщиком, что и остальные снимки задачи.
class _PanePhoto extends StatelessWidget {
  final PhotoLoader loader;
  final String caption;
  const _PanePhoto({super.key, required this.loader, required this.caption});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: loader(thumb: true),
      builder: (context, snap) {
        Widget body;
        if (snap.connectionState != ConnectionState.done) {
          body = const Center(
            child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2)),
          );
        } else if (snap.data == null) {
          body = Center(
            child: Icon(Icons.cloud_off, size: 22, color: Wms.muted),
          );
        } else {
          body = ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.file(snap.data!,
                fit: BoxFit.cover,
                width: double.infinity,
                height: double.infinity,
                errorBuilder: (_, __, ___) => Icon(
                      Icons.broken_image_outlined,
                      size: 22,
                      color: Wms.muted,
                    )),
          );
        }
        return InkWell(
          onTap: snap.data == null
              ? null
              : () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) =>
                      TaskPhotoViewer(loader: loader, caption: caption))),
          child: SizedBox.expand(child: body),
        );
      },
    );
  }
}
