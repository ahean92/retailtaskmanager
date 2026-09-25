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
import 'widgets/task_photo.dart';
import 'widgets/warn_bar.dart';

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
/// (#36842), «стало» — все снимки сданного отчёта и комментарий, а не один первый кадр,
/// как в выдаче задач. Прежние раунды — ниже: повторная сдача прежний результат не
/// стирает, и сравнить «что вернул — что переделали» можно здесь же.
///
/// Внизу — «Принять» и «Вернуть», пока задача ждёт моего решения. Исполнитель видит
/// тот же экран без них: что он сдал.
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
      body: Column(
        children: [
          if (view.returned) WarnBar(Icons.undo, returnedLine(view)),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(t.object ?? t.name ?? t.id,
                    style: Theme.of(context).textTheme.titleLarge),
                if (t.object != null && t.name != null)
                  Text(t.name!,
                      style: TextStyle(fontSize: 14, color: Wms.muted)),
                if (view.onAcceptance) ...[
                  const SizedBox(height: 6),
                  Text(submittedLine(view),
                      style: TextStyle(fontSize: 13, color: Wms.muted)),
                ],
                _before(t),
                _after(t),
                _earlier(t),
              ],
            ),
          ),
          if (view.awaitingDecision)
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                child: DecisionBar(view: view, popAfter: true),
              ),
            ),
        ],
      ),
    );
  }

  /// «Было» — снимки задачи: проблемный участок от автора и досланное к задаче.
  Widget _before(Task t) {
    final images = [for (final f in t.files) if (f.image) f];
    if (images.isEmpty || _files == null) return const SizedBox.shrink();
    return _Section(
      title: 'Было',
      child: Wrap(spacing: 8, runSpacing: 8, children: [
        for (final f in images)
          TaskPhotoThumb(
            loader: _files!.loaderFor(f.id),
            caption: _fileCaption(f),
          ),
      ]),
    );
  }

  /// «Стало» — сданный отчёт: все снимки и комментарий исполнителя. У задачи без
  /// фотоотчёта — последнее выполнение из выдачи.
  Widget _after(Task t) {
    final report = _report;
    if (report == null) {
      if (t.executions.isEmpty) return const SizedBox.shrink();
      return _Section(title: 'Стало', child: _execution(t.executions.last));
    }
    return ListenableBuilder(
      listenable: report,
      builder: (context, _) {
        if (report.loading && report.date == null) {
          return const Padding(
            padding: EdgeInsets.only(top: 24),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final error = report.error;
        if (error != null && report.date == null) {
          return _Section(
            title: 'Стало',
            child: Text(error, style: TextStyle(color: Wms.muted)),
          );
        }
        final comment = report.comment?.trim();
        final by = [
          report.executor,
          formatDateTime(report.date),
        ].whereType<String>().join(' · ');
        return _Section(
          title: 'Стало',
          badge: report.photoIndexes.isEmpty
              ? null
              : '${report.photoIndexes.length}',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!report.online)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                      'Офлайн — показан сохранённый отчёт, '
                      'нескачанные фото недоступны',
                      style: TextStyle(fontSize: 12, color: Wms.warn)),
                ),
              if (report.photoIndexes.isEmpty)
                Text('Без фото', style: TextStyle(color: Wms.muted))
              else
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final i in report.photoIndexes)
                    TaskPhotoThumb(
                      loader: ({required thumb}) =>
                          report.photo(i, thumb: thumb),
                      caption: ['Стало', if (by.isNotEmpty) by].join(' · '),
                    ),
                ]),
              const SizedBox(height: 12),
              Text('Комментарий исполнителя',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Wms.text)),
              const SizedBox(height: 4),
              Text(
                comment == null || comment.isEmpty ? 'Без комментария' : comment,
                style: TextStyle(
                    fontSize: 15,
                    height: 1.35,
                    color: comment == null || comment.isEmpty
                        ? Wms.muted
                        : Wms.text),
              ),
              if (by.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(by, style: TextStyle(fontSize: 12, color: Wms.muted)),
              ],
            ],
          ),
        );
      },
    );
  }

  /// Прежние раунды — всё, кроме последнего выполнения: после возврата видно, что
  /// сдавали в прошлый раз.
  Widget _earlier(Task t) {
    if (t.executions.length < 2) return const SizedBox.shrink();
    final earlier = t.executions.sublist(0, t.executions.length - 1);
    return _Section(
      title: 'Прежние выполнения',
      badge: '${earlier.length}',
      child: Column(
        children: [
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

  static String _fileCaption(TaskFileRef f) => [
        'Было',
        if (f.author != null) f.author!,
        if (formatDateTime(f.dateTime) != null) formatDateTime(f.dateTime)!,
      ].join(' · ');
}

/// Блок экрана с заголовком и числом — «Стало 3».
class _Section extends StatelessWidget {
  final String title;
  final String? badge;
  final Widget child;
  const _Section({required this.title, this.badge, required this.child});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            if (badge != null) ...[
              const SizedBox(width: 8),
              Text(badge!,
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: Wms.primary)),
            ],
          ]),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}
