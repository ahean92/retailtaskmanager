import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/task_file_cache.dart';
import '../data/task_repository.dart';
import '../models/task.dart';
import '../models/task_file.dart';
import '../models/task_status.dart';
import 'fill_screen.dart';
import 'past_check_screen.dart';
import 'simple_execution_screen.dart';
import 'theme.dart';
import 'widgets/task_comments.dart';
import 'widgets/task_photo.dart';
import 'widgets/warn_bar.dart';

class TaskDetailScreen extends StatefulWidget {
  final String taskId;
  const TaskDetailScreen({super.key, required this.taskId});

  @override
  State<TaskDetailScreen> createState() => _TaskDetailScreenState();
}

class _TaskDetailScreenState extends State<TaskDetailScreen> {
  /// Set once the screen is on its way out, so a rebuild while the pop is pending cannot
  /// schedule a second one and take the task list down with it.
  bool _leaving = false;

  /// Кэш снимков задачи (#36842) — один на экран, а не на плитку: миниатюра качается
  /// однажды и остаётся на диске, поэтому вернувшийся в карточку человек и человек без
  /// сети видят одно и то же. null — базы нет (сессия умерла под открытой карточкой):
  /// тогда галерея просто не рисуется, как и лента переписки.
  TaskFileCache? _photos;

  @override
  void initState() {
    super.initState();
    final repo = context.read<TaskRepository>();
    final db = repo.localDb;
    if (db != null) {
      _photos = TaskFileCache(userKey: db.userKey, api: repo.api);
    }
  }

  /// The task is gone from the list — completed on this very screen, or closed and
  /// confirmed by the server (`apiTasks` only ever sends open tasks). Details of a task
  /// that no longer exists are a dead end, so the screen steps back to the list rather
  /// than staying to announce its own emptiness.
  void _leave() {
    if (_leaving) return;
    _leaving = true;
    final navigator = Navigator.of(context);
    // during a build there is no popping — the frame this decision is made in has to be
    // finished first
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (navigator.mounted && navigator.canPop()) navigator.pop();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<TaskRepository>(
      builder: (context, repo, _) {
        // Поиск и по clientId тоже (см. viewOf): экран, открытый на задаче, рождённой
        // на телефоне, держит её UUID — а после синхронизации строка в кэше несёт
        // ST-номер в id и тот же UUID в clientId. Без второго сравнения этот экран
        // решил бы, что задача исчезла, и закрылся бы у человека под рукой.
        final found = repo.viewOf(widget.taskId);

        if (found == null) {
          _leave();
          // one frame with nothing on it, and it is the frame that is being replaced
          return const Scaffold(body: SizedBox.shrink());
        }

        final TaskView view = found;
        final t = view.task;
        // задача другого объекта (#36837): смотреть можно всё, работать — ничего.
        // Решение локальное и мгновенное (см. TaskView.elsewhere) — вернувшись на
        // объект и обновив местоположение, человек застаёт этот же экран рабочим.
        final away = view.elsewhere;
        // авторская-и-только задача (#36844): в приложении ради переписки — бланк,
        // статус и взятие у исполнителя, сервер такие вызовы и так отвергает
        final authoredOnly = view.authoredOnly;
        return Scaffold(
          appBar: AppBar(title: Text('Задача ${t.id}')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (authoredOnly)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Material(
                    color: Wms.active,
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      child: Row(
                        children: [
                          Icon(Icons.edit_note, size: 18, color: Wms.primary),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Вы автор этой задачи'
                              '${t.assignedTo == null ? '' : ' — исполнитель: ${t.assignedTo}'}. '
                              'Здесь можно смотреть и переписываться; работа по '
                              'задаче — у исполнителя.',
                              style: TextStyle(fontSize: 12, color: Wms.text),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              if (away && !authoredOnly)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: WarnBar(
                    Icons.near_me_outlined,
                    'Вы не на этом объекте'
                    '${t.distanceText == null ? '' : ' — до него ${t.distanceText}'}. '
                    'Задача только для просмотра: заполнять и менять статус можно '
                    'на месте.',
                  ),
                ),
              Text(
                t.object ?? t.name ?? t.id,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              // что именно не так (#36842): описание — первое, ради чего карточку
              // открывают, поэтому сразу под заголовком, а не в ряду полей внизу.
              // С сервера оно приходит уже без разметки
              if ((t.description ?? '').trim().isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(t.description!.trim(),
                    style: const TextStyle(fontSize: 15, height: 1.35)),
              ],
              // «было» — снимок проблемного участка (#36842). Тоже до кнопок: сначала
              // человек видит, что не так, и только потом решает, что с этим делать
              _problemPhotos(t),
              // Чем открывать задачу, говорит сервер (#36872): бланк — задачам с
              // шаблоном, простой отчёт — поручению и корректирующему действию.
              // Список типов внутри приложения остался только запасным путём для
              // старого сервера (Task.opensFill).
              if (t.opensFill && !authoredOnly) ...[
                const SizedBox(height: 12),
                FilledButton.icon(
                  // задача, рождённая на телефоне, всю жизнь адресуется своим UUID:
                  // на нём её локальный кэш бланка и очереди, и сервер понимает оба
                  // адреса — поэтому clientId, а не ST-номер, когда он есть.
                  // Вне объекта кнопка погашена: заполнение — работа, а работа
                  // делается на месте (#36837); баннер выше объясняет, почему
                  onPressed: away
                      ? null
                      : () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) =>
                                  FillScreen(taskId: t.clientId ?? t.id),
                            ),
                          ),
                  icon: Icon(_fillIcon(t.typeId)),
                  label: Text(_fillLabel(t.typeId)),
                ),
                // история — не работа (#36837): вне объекта просмотр прошлой
                // проверки остаётся доступным. На месте вход в неё живёт в шапке
                // бланка, как и раньше, — здесь он появляется только взамен
                // погашенного заполнения
                if (away) ...[
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) =>
                            PastCheckScreen.forTask(t.clientId ?? t.id),
                      ),
                    ),
                    icon: const Icon(Icons.history),
                    label: const Text('Прошлая проверка'),
                  ),
                ],
              ],
              // простое выполнение — фотоотчёт с комментарием (#36872). Адрес тот же,
              // что у бланка: задача, рождённая на телефоне, всю жизнь адресуется
              // своим UUID. Вне объекта кнопка погашена — работа делается на месте
              if (t.opensSimple && !authoredOnly) ...[
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: away
                      ? null
                      : () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => SimpleExecutionScreen(
                                  taskId: t.clientId ?? t.id),
                            ),
                          ),
                  icon: const Icon(Icons.photo_camera_outlined),
                  label: Text(t.requirePhoto == true
                      ? 'Выполнить с фото'
                      : 'Выполнить'),
                ),
              ],
              // взятие из пула (#36836): право рисует серверный canTake, снятие —
              // взятость мной; оба уходят той же офлайн-очередью, что и в списке
              if (view.canTake) ...[
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: () => _take(context, repo, view.id),
                  icon: const Icon(Icons.back_hand_outlined),
                  label: const Text('Взять на себя'),
                ),
              ],
              if (view.releasable) ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () => _release(context, repo, view.id),
                  icon: const Icon(Icons.undo),
                  label: const Text('Снять с себя'),
                ),
              ],
              const SizedBox(height: 16),
              _Field(label: 'Тип', value: t.type),
              _Field(label: 'Детали', value: t.subtitle),
              _Field(label: 'Название', value: t.name),
              _Field(label: 'Адрес', value: t.address),
              _Field(label: 'Расстояние', value: t.distanceText),
              // кто поставил и когда (#36842): поручение от директора и поручение от
              // коллеги читаются по-разному, и без автора карточка на это не отвечает
              _Field(label: 'Поставил', value: t.author),
              _Field(label: 'Поставлена', value: _dateText(t.postedAt)),
              _Field(label: 'Исполнитель', value: t.assignedTo),
              _Field(label: 'Взял на себя', value: _takenLine(view)),
              _Field(label: 'Приоритет', value: t.priority),
              // тем же форматом, что и «Поставлена»: срок в карточке читают глазами,
              // и `2026-08-25` рядом с `24.08.2026` смотрелось бы как чужая строка
              _Field(label: 'Срок', value: _dateText(t.deadline)),
              _Field(
                  label: 'Прогресс',
                  value: t.progress == null ? null : '${t.progress}%'),
              // «стало» — кто работал по задаче и с каким результатом (#36842)
              _executions(t),
              const Divider(height: 32),
              Row(
                children: [
                  Text('Статус', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(width: 10),
                  if (view.pending)
                    const Chip(
                      visualDensity: VisualDensity.compact,
                      avatar: Icon(Icons.sync_problem, size: 16),
                      label: Text('не синхронизировано'),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                view.statusName ?? view.statusId ?? '—',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 16),
              // автору статус показывается, но не переключается (#36844): смена
              // статуса — работа исполнителя
              if (authoredOnly)
                const SizedBox.shrink()
              else if (repo.statuses.isEmpty)
                Text('Справочник статусов не загружен',
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.outline))
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: repo.statuses.map((s) {
                    final selected = s.id == view.statusId;
                    // у завершённой на телефоне задачи статусы не переключаются:
                    // смена ушла бы на сервер раньше застрявшего finish, и его
                    // 'done' молча перезаписал бы её — хронология наоборот.
                    // Вне объекта — тоже (#36837): смена статуса — работа
                    return ChoiceChip(
                      label: Text(s.name ?? s.id),
                      selected: selected,
                      onSelected: selected || view.locallyFinished || away
                          ? null
                          : (_) => _change(context, repo, t.id, s),
                    );
                  }).toList(),
                ),
              const Divider(height: 32),
              // переписка по задаче (#36844): лента и поле ввода — здесь, в карточке;
              // задача, рождённая на телефоне, адресуется своим UUID, как и бланк
              TaskCommentsSection(taskId: t.clientId ?? t.id),
            ],
          ),
        );
      },
    );
  }

  /// «Было»: снимок проблемного участка и прочие файлы задачи (#36842).
  ///
  /// Отдельный блок с подписью, а не общая лента снимков: «зафиксировал изменение в
  /// положительную сторону» читается только тогда, когда «было» и «стало» видно
  /// порознь. Вложения переписки сюда не попадают — их место в ленте, и сервер их
  /// в этом списке не присылает.
  Widget _problemPhotos(Task t) {
    final files = t.files;
    if (files.isEmpty || _photos == null) return const SizedBox.shrink();
    final images = [for (final f in files) if (f.image) f];
    final others = [for (final f in files) if (!f.image) f];
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionTitle('Было — фото проблемы', badge: '${files.length}'),
          const SizedBox(height: 8),
          if (images.isNotEmpty)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final f in images)
                  TaskPhotoThumb(
                    loader: _photos!.loaderFor(f.id),
                    caption: _fileCaption(f),
                  ),
              ],
            ),
          for (final f in others)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  Icon(Icons.attach_file, size: 16, color: Wms.muted),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(f.name ?? 'файл',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, color: Wms.muted)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// «Стало»: выполнения задачи — кто работал, когда, с каким результатом и со
  /// снимком результата (#36842). До этой задачи их в приложении не было видно вовсе,
  /// хотя модель допускает несколько выполнений на задачу с самого начала.
  Widget _executions(Task t) {
    final items = t.executions;
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionTitle('Стало — выполнения', badge: '${items.length}'),
          const SizedBox(height: 8),
          for (final e in items)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Wms.card,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Wms.line),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (e.photoId != null && _photos != null) ...[
                    TaskPhotoThumb(
                      loader: _photos!.loaderFor(e.photoId!),
                      size: 84,
                      caption: _executionCaption(e),
                    ),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                                e.finished
                                    ? Icons.check_circle
                                    : Icons.timelapse,
                                size: 16,
                                color: e.finished ? Wms.primary : Wms.muted),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(e.executor ?? 'Без исполнителя',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          [
                            _dateTimeText(e.dateTime),
                            e.finished ? 'завершено' : 'в работе',
                          ].whereType<String>().join(' · '),
                          style: TextStyle(fontSize: 12, color: Wms.muted),
                        ),
                        if ((e.result ?? '').isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(e.result!,
                              style: const TextStyle(fontSize: 13)),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// Подпись снимка в полный экран: без неё «было» и «стало» на чёрном фоне
  /// неразличимы — а именно их и сравнивают.
  String _fileCaption(TaskFileRef f) => [
        'Было',
        if (f.author != null) f.author!,
        if (_dateTimeText(f.dateTime) != null) _dateTimeText(f.dateTime)!,
      ].join(' · ');

  String _executionCaption(TaskExecution e) => [
        'Стало',
        if (e.executor != null) e.executor!,
        if (_dateTimeText(e.dateTime) != null) _dateTimeText(e.dateTime)!,
      ].join(' · ');

  /// `2026-07-20` -> `20.07.2026`; что угодно другое показывается как пришло.
  static String? _dateText(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final parts = raw.split('T').first.split('-');
    return parts.length == 3 ? '${parts[2]}.${parts[1]}.${parts[0]}' : raw;
  }

  /// `2026-07-20 10:42` -> `20.07.2026 10:42`; время у lsFusion приходит через
  /// пробел, у ISO — через `T`, поэтому разбор терпит оба.
  static String? _dateTimeText(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final parsed = DateTime.tryParse(raw.replaceFirst(' ', 'T'));
    if (parsed == null) return _dateText(raw);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(parsed.day)}.${two(parsed.month)}.${parsed.year} '
        '${two(parsed.hour)}:${two(parsed.minute)}';
  }

  Future<void> _change(BuildContext context, TaskRepository repo, String id,
      TaskStatus status) async {
    final messenger = ScaffoldMessenger.of(context);
    await repo.setStatus(id, status);
    messenger.showSnackBar(
      SnackBar(
        content: Text(repo.online
            ? 'Статус изменён: ${status.name ?? status.id}'
            : 'Сохранено офлайн — синхронизируется при связи'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  /// Кто держит задачу, для карточки: имя, время — и честная пометка, пока взятие
  /// не подтверждено сервером.
  String? _takenLine(TaskView view) {
    final who = view.takenBy;
    if (who == null) return null;
    if (view.takePending) return '$who — ожидает подтверждения';
    final at = DateTime.tryParse(view.takenAt ?? '');
    if (at == null) return who;
    final hhmm = '${at.hour.toString().padLeft(2, '0')}:'
        '${at.minute.toString().padLeft(2, '0')}';
    final now = DateTime.now();
    final sameDay =
        at.year == now.year && at.month == now.month && at.day == now.day;
    return sameDay
        ? '$who, в $hhmm'
        : '$who, ${at.day.toString().padLeft(2, '0')}.'
            '${at.month.toString().padLeft(2, '0')} $hhmm';
  }

  Future<void> _take(
      BuildContext context, TaskRepository repo, String id) async {
    final messenger = ScaffoldMessenger.of(context);
    await repo.takeTask(id);
    messenger.showSnackBar(SnackBar(
      content: Text(repo.online
          ? 'Задача перенесена в «Мои»'
          : 'Взятие сохранено офлайн — ожидает подтверждения'),
      duration: const Duration(seconds: 2),
    ));
  }

  Future<void> _release(
      BuildContext context, TaskRepository repo, String id) async {
    final messenger = ScaffoldMessenger.of(context);
    await repo.releaseTask(id);
    messenger.showSnackBar(SnackBar(
      content: Text(repo.online
          ? 'Задача возвращена в «Свободные»'
          : 'Снятие сохранено офлайн — синхронизируется при связи'),
      duration: const Duration(seconds: 2),
    ));
  }
}

IconData _fillIcon(String? typeId) {
  switch (typeId) {
    case 'checklist':
      return Icons.checklist;
    case 'recount':
      return Icons.inventory_2_outlined;
    case 'pricing':
      return Icons.sell_outlined;
    default:
      return Icons.assignment_turned_in;
  }
}

String _fillLabel(String? typeId) {
  switch (typeId) {
    case 'checklist':
      return 'Заполнить чек-лист';
    case 'recount':
      return 'Пересчитать';
    case 'pricing':
      return 'Проверить ценники';
    default:
      return 'Заполнить';
  }
}

/// Заголовок блока карточки с числом элементов — «Было — фото проблемы 2».
class _SectionTitle extends StatelessWidget {
  final String text;
  final String? badge;
  const _SectionTitle(this.text, {this.badge});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(text, style: Theme.of(context).textTheme.titleMedium),
        if (badge != null) ...[
          const SizedBox(width: 8),
          Text(badge!,
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: Wms.primary)),
        ],
      ],
    );
  }
}

class _Field extends StatelessWidget {
  final String label;
  final String? value;
  const _Field({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    if (value == null || value!.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(label,
                style: TextStyle(color: Theme.of(context).colorScheme.outline)),
          ),
          Expanded(child: Text(value!)),
        ],
      ),
    );
  }
}
