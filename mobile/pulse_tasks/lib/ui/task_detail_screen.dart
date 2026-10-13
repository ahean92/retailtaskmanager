import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/api_client.dart';
import '../data/task_file_cache.dart';
import '../data/task_file_controller.dart';
import '../data/task_repository.dart';
import '../models/fill.dart';
import '../models/task.dart';
import '../models/task_file.dart';
import '../models/task_status.dart';
import '../models/task_view.dart';
import 'fill_screen.dart';
import 'past_check_screen.dart';
import 'simple_execution_screen.dart';
import 'task_result_screen.dart';
import 'theme.dart';
import 'widgets/acceptance.dart';
import 'widgets/ds.dart';
import 'widgets/photo_picker.dart';
import 'widgets/task_comments.dart';
import 'widgets/task_photo.dart';
import 'widgets/warn_bar.dart';

class TaskDetailScreen extends StatefulWidget {
  final String taskId;

  /// Открыть карточку сразу на переписке (#37125): уведомление о комментарии зовёт
  /// человека именно туда, а лента живёт в подвале экрана.
  final bool showComments;

  const TaskDetailScreen(
      {super.key, required this.taskId, this.showComments = false});

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

  /// Снимки этой задачи, ещё не уехавшие (#36914): показываются рядом с приехавшими,
  /// с пометкой «ожидает отправки». Держатся в состоянии экрана, а не перечитываются
  /// на каждый кадр отрисовки: очередь меняется жестами человека, и перечитать её
  /// после жеста дешевле, чем спрашивать базу при каждом ребилде.
  List<({String clientId, String path})> _pending = const [];

  /// Якорь секции переписки — по нему карточка подкручивается к ленте, когда её
  /// открыли из уведомления о комментарии (#37125).
  final GlobalKey _commentsKey = GlobalKey();

  /// Бланк из кэша на телефоне (#37411, п. 5): «Заполнение N из M» и разделы с
  /// готовностью рисуются без открытия экрана заполнения. Читается из fill_cache
  /// при входе и по возвращении из бланка; пустой список — бланка в кэше ещё нет.
  List<FillField> _formFields = const [];

  @override
  void initState() {
    super.initState();
    final repo = context.read<TaskRepository>();
    final db = repo.localDb;
    if (db != null) {
      _photos = TaskFileCache(userKey: db.userKey, api: repo.api);
    }
    unawaited(_loadPending(repo));
    unawaited(_loadForm(repo));
    _revealComments();
  }

  /// Бланк задачи из локального кэша: только чтение, без обращения к серверу и
  /// без заведения выполнения (в отличие от FillController.load). Карточке нужен
  /// состав разделов и их готовность, а не рабочая копия бланка.
  ///
  /// Бланка в кэше ещё нет — карточка стягивает его сама (при связи, теми же
  /// чтениями, что и «Прошлая проверка»): без этого блок «Заполнение N из M»
  /// (мокет стр. 2) не виден до первого захода в бланк. Заведение выполнения
  /// здесь по-прежнему нет — его делает экран заполнения.
  Future<void> _loadForm(TaskRepository repo) async {
    final view = repo.viewOf(widget.taskId);
    if (view == null || !view.task.opensFill) return;
    final db = repo.localDb;
    if (db == null) return;
    final id = view.task.clientId ?? widget.taskId;
    var c = await db.fill.getFillCache(id);
    if (c == null && repo.online) {
      try {
        final fieldsRaw = await repo.api.fetchExecutionFields(id);
        final optionsRaw = await repo.api.fetchExecutionOptions(id);
        final columnsRaw = await repo.api.fetchExecutionColumns(id);
        final rowsRaw = await repo.api.fetchExecutionRows(id);
        final info = await repo.api.fetchExecutionInfo(id);
        await db.fill.saveFillCache(
          id,
          jsonEncode(fieldsRaw),
          jsonEncode(optionsRaw),
          jsonEncode(info ?? const {}),
          DateTime.now().toIso8601String(),
          columnsJson: jsonEncode(columnsRaw),
          rowsJson: jsonEncode(rowsRaw),
        );
        c = await db.fill.getFillCache(id);
      } catch (_) {
        // не стянулся — блок прогресса не рисуется, карточка живёт и без него
        return;
      }
    }
    if (c == null || !mounted) return;
    final fieldsRaw =
        (jsonDecode(c['fieldsJson'] as String) as List).cast<dynamic>();
    final optionsRaw =
        (jsonDecode(c['optionsJson'] as String) as List).cast<dynamic>();
    final columnsRaw = jsonDecode((c['columnsJson'] as String?) ?? '[]') as List;
    final rowsRaw = jsonDecode((c['rowsJson'] as String?) ?? '[]') as List;
    setState(() => _formFields =
        assembleFillFields(fieldsRaw, optionsRaw, columnsRaw, rowsRaw));
  }

  /// Подкрутить карточку к переписке, когда её открыли из уведомления о комментарии.
  ///
  /// Зовётся дважды — после первого кадра и когда лента догрузилась (onLoaded): на
  /// первом кадре под секцией ещё пусто, крутить некуда, и один только первый вызов
  /// оставлял экран на шапке (проверено на стенде: список прокрутился на 7 точек из
  /// 663). Следующий кадр после загрузки — и переписка сверху.
  void _revealComments() {
    if (!widget.showComments) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = _commentsKey.currentContext;
      if (ctx == null) return;
      unawaited(Scrollable.ensureVisible(ctx,
          duration: const Duration(milliseconds: 250), alignment: 0.05));
    });
  }

  Future<void> _loadPending(TaskRepository repo) async {
    final queued = await repo.pendingTaskPhotos(widget.taskId);
    if (!mounted) return;
    setState(() => _pending = queued);
  }

  /// Снять или выбрать кадры и приложить их к задаче — очередью, как всё остальное на
  /// этом экране: в подвале без связи снимок ложится в очередь и уезжает при сети.
  Future<void> _attachPhotos(TaskRepository repo, int left) async {
    final picked = await pickTaskPhotos(context, limit: left);
    if (picked.isEmpty) return;
    for (final path in picked) {
      await repo.attachTaskPhoto(widget.taskId, path);
    }
    await _loadPending(repo);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(repo.online
          ? 'Фото приложено к задаче'
          : 'Фото приложено — уедет на сервер при связи'),
      duration: const Duration(seconds: 2),
    ));
  }

  /// «Приложить фото» (#36914) живёт одной кнопкой — в нижней панели рядом с
  /// главным действием (стр. 2 макета): дублирующая кнопка в теле карточки
  /// убрана. Предел «десять на задачу» объявляется строкой у снимков, когда он
  /// исчерпан, — вместо погашенной кнопки.
  Widget _limitNote(Task t) {
    final images = [for (final f in t.files) if (f.image) f];
    final left =
        TaskFilesController.maxPerTask - images.length - _pending.length;
    if (left > 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(TaskFilesController.limitMessage(0),
          style: TextStyle(fontSize: 12, color: Wms.muted)),
    );
  }

  /// Плитка снимка, который ещё в очереди: тот же виджет, что и у приехавших, только
  /// файл берётся с диска. Крестик убирает кадр совсем — и из очереди, и с диска.
  Widget _pendingPhoto(
      TaskRepository repo, ({String clientId, String path}) q) {
    return Stack(
      children: [
        Opacity(
          opacity: 0.75,
          child: TaskPhotoThumb(
            loader: localPhoto(File(q.path)),
            caption: 'Ожидает отправки',
          ),
        ),
        Positioned(
          left: 4,
          bottom: 4,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: Wms.scrim,
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Icon(Icons.sync_problem, size: 12, color: Colors.white),
          ),
        ),
        Positioned(
          right: 0,
          top: 0,
          child: InkWell(
            onTap: () async {
              await repo.discardTaskPhoto(q.clientId);
              await _loadPending(repo);
            },
            child: Container(
              decoration: const BoxDecoration(
                color: Wms.scrim,
                shape: BoxShape.circle,
              ),
              padding: const EdgeInsets.all(2),
              child: const Icon(Icons.close, size: 14, color: Colors.white),
            ),
          ),
        ),
      ],
    );
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
        // статус и взятие у исполнителя, сервер такие вызовы и так отвергает.
        // Наблюдаемая-и-только (#37135) — ровно то же самое, отличается лишь объяснение
        // в баннере, поэтому гасит работу общий readOnly, а не каждый признак по себе.
        final authoredOnly = view.authoredOnly;
        final readOnly = view.readOnly;
        // кто я этой задаче, если не исполнитель (#36844, #37135, #37158): баннер
        // роли. Сданная исполнителем — тоже только чтение, но объясняет это плашка
        // приёмки ниже, а не «работа у исполнителя»
        final roleBanner =
            view.authoredOnly || view.watchedOnly || view.reviewingOnly;
        final choices = view.statusChoices(repo.statuses);
        // главное действие нижней панели (#37411, п. 5) — одно, по контексту
        final primary = _primaryAction(view, t, readOnly, repo);
        final photo = _photoButton(repo, t, away, readOnly);
        final secondary = _secondaryActions(view, t, away, readOnly);
        return Scaffold(
          // шапка без заголовка (стр. 2 макета): слева назад, справа «Прошлая
          // проверка» и меню второстепенных действий
          appBar: AppBar(
            title: const SizedBox.shrink(),
            actions: [
              if (t.opensFill)
                IconButton(
                  tooltip: 'Прошлая проверка',
                  icon: const Icon(Icons.remove_red_eye_outlined),
                  onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) =>
                              PastCheckScreen.forTask(t.clientId ?? t.id))),
                ),
              if (secondary.isNotEmpty)
                PopupMenuButton<VoidCallback>(
                  tooltip: 'Ещё действия',
                  icon: const Icon(Icons.more_vert),
                  itemBuilder: (_) => [
                    for (final a in secondary)
                      PopupMenuItem(
                        value: a.onTap,
                        child: Row(children: [
                          Icon(a.icon, size: 18, color: Wms.text2),
                          const SizedBox(width: 10),
                          Text(a.label),
                        ]),
                      ),
                  ],
                  onSelected: (onTap) => onTap(),
                ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              // ярус чипов (стр. 2 макета): тип и статус-пилюля одной строкой
              // слева, над заголовком. Подзаголовок типа не дублируем — название
              // задачи стоит прямо под этим ярусом. Оба — Flexible: длинный статус
              // ужимается многоточием, а не уплывает за край экрана
              Row(children: [
                if (t.type != null) ...[
                  Flexible(
                    child: Text(t.type!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: Wms.text2)),
                  ),
                  const SizedBox(width: 8),
                ],
                Flexible(
                  child: DsChip(
                    view.statusName ?? view.statusId ?? '—',
                    tone: dsToneOf(view.statusId),
                    compact: true,
                  ),
                ),
              ]),
              const SizedBox(height: 6),
              Text(
                t.name ?? t.object ?? t.id,
                style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    color: Wms.text,
                    height: 1.2),
              ),
              if (view.pending) ...[
                const SizedBox(height: 6),
                Text('ожидает синхронизации',
                    style:
                        TextStyle(fontSize: 12, color: Wms.caution)),
              ],
              // объект задачи (стр. 2 макета): пин и «имя, адрес» — где задача
              // выполняется. «Только просмотр» у чужого объекта остаётся здесь же
              if ([
                t.object,
                t.address,
                if (away) 'только просмотр',
              ].whereType<String>().any((s) => s.isNotEmpty)) ...[
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.location_on_outlined,
                        size: 16, color: Wms.muted),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        [
                          if (t.object != null && t.object!.isNotEmpty)
                            t.object!,
                          if (t.address != null && t.address!.isNotEmpty)
                            t.address!,
                          if (away)
                            'только просмотр'
                                '${t.distanceText == null ? '' : ' · ${t.distanceText}'}',
                        ].join(', '),
                        style: TextStyle(fontSize: 13, color: Wms.muted),
                      ),
                    ),
                  ],
                ),
              ],
              if (t.deadlineText != null) ...[
                const SizedBox(height: 10),
                _DeadlinePlate(
                    label: t.deadlineText!, overdue: view.overdue),
              ],
              // приёмка (#37158): ждёт моего решения — с кнопками; сдана — когда и
              // кому; возвращена — почему. Сверху, раньше всего: это и есть ответ на
              // «что с задачей сейчас»
              if (view.awaitingDecision)
                _DecisionPanel(view: view)
              else if (view.onAcceptance)
                _AcceptanceNote(view: view)
              else if (view.returned)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: _ReturnedNote(view: view),
                ),
              if (roleBanner)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Material(
                    color: Wms.brandTint,
                    borderRadius: BorderRadius.circular(12),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      child: Row(
                        children: [
                          Icon(
                              authoredOnly
                                  ? Icons.edit_note
                                  : view.reviewingOnly
                                      ? Icons.fact_check_outlined
                                      : Icons.visibility_outlined,
                              size: 18,
                              color: Wms.primary),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '${_readOnlyRole(view)}'
                              '${t.assignedTo == null ? '' : ' — исполнитель: ${t.assignedTo}'}. '
                              'Здесь можно смотреть и переписываться; работа по '
                              'задаче — у исполнителя.',
                              style:
                                  TextStyle(fontSize: 12, color: Wms.text),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              if (away && !readOnly)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: WarnBar(
                    Icons.near_me_outlined,
                    'Вы не на этом объекте'
                    '${t.distanceText == null ? '' : ' — до него ${t.distanceText}'}. '
                    'Задача только для просмотра: заполнять и менять статус можно '
                    'на месте.',
                  ),
                ),
              // что именно не так (#36842): описание — первое, ради чего карточку
              // открывают, поэтому сразу под заголовком, а не в ряду полей внизу.
              // С сервера оно приходит уже без разметки
              if ((t.description ?? '').trim().isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(t.description!.trim(),
                    style: const TextStyle(fontSize: 15, height: 1.35)),
              ],
              // «было» — снимок проблемного участка (#36842). Тоже до кнопок: сначала
              // человек видит, что не так, и только потом решает, что с этим делать.
              // Здесь же кадры досылаются к задаче (#36914) — без комментария, прямо
              // в этот блок, а не в ленту переписки
              _problemPhotos(repo, t),
              // «Заполнение N из M» и разделы с готовностью — из бланка, который
              // уже лежит на телефоне (#37411, п. 5)
              if (t.opensFill && _formFields.isNotEmpty) ...[
                const SizedBox(height: 12),
                _FillProgressCard(fields: _formFields),
              ],
              const SizedBox(height: 12),
              _keyValueCard(view, t),
              // «стало» — кто работал по задаче и с каким результатом (#36842)
              _executions(t),
              const Divider(height: 32),
              Row(
                children: [
                  Text('Статус', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(width: 10),
                  if (view.pending)
                    DsChip('не синхронизировано',
                        icon: Icons.sync_problem, compact: true),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                view.statusName ?? view.statusId ?? '—',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 16),
              // куда перевести, говорит сервер (nextStatuses): правила переходов по
              // ролям, статусы типа, «Новый» при выполнении. Автору — то, что правила
              // ему разрешают, наблюдателю — ничего (TaskView.statusChoices)
              if (repo.statuses.isEmpty && !readOnly)
                Text('Справочник статусов не загружен',
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.outline))
              else if (!choices.any((s) => s.id != view.statusId))
                readOnly
                    ? const SizedBox.shrink()
                    : Text(
                        'Перевести задачу в другой статус вам нельзя: '
                        'переходы задаёт администратор',
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.outline))
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: choices.map((s) {
                    final selected = s.id == view.statusId;
                    // «Новый» у задачи, по которой уже есть выполнение, сервер
                    // отклоняет: статус говорил бы «не начиналась», а бланк остался
                    // бы «в работе». Возврат в пул делается на карточке в бэк-офисе
                    // («Вернуть в новые»), и он же стирает пустой бланк. Гасим здесь,
                    // чтобы отказ не оседал строкой в офлайн-очереди.
                    final backToNew = s.id == 'new' && t.executions.isNotEmpty;
                    // у завершённой на телефоне задачи статусы не переключаются:
                    // смена ушла бы на сервер раньше застрявшего finish, и его
                    // 'done' молча перезаписал бы её — хронология наоборот.
                    // Вне объекта — тоже (#36837): смена статуса — работа. Автора
                    // это не касается: его статус — решение по задаче, а не работа
                    // на месте, и баннер «вы не на объекте» ему не показывается
                    return DsOutlineChip(
                      _statusLabel(view, s),
                      selected: selected,
                      onTap: selected ||
                              view.locallyFinished ||
                              (away && !readOnly) ||
                              backToNew
                          ? null
                          : () => _change(context, repo, t.id, s),
                    );
                  }).toList(),
                ),
              const Divider(height: 32),
              // переписка по задаче (#36844): лента и поле ввода — здесь, в карточке;
              // задача, рождённая на телефоне, адресуется своим UUID, как и бланк
              TaskCommentsSection(
                  key: _commentsKey,
                  taskId: t.clientId ?? t.id,
                  onLoaded: _revealComments),
            ],
          ),
          // одно главное действие по контексту + кнопка фото (#37411, п. 5):
          // фото — контурный квадрат слева, действие — справа (стр. 2 макета).
          // Главного действия может не быть (работа сдана, задача чужая на
          // просмотр) — панель с одной фото-кнопкой всё равно остаётся:
          // свидетельство к задаче прикладывается независимо от статуса
          bottomNavigationBar: primary == null && photo == null
              ? null
              : DsBottomActionBar(
                  primaryLabel: primary?.label,
                  onPrimary: primary?.onTap,
                  leading: photo,
                ),
        );
      },
    );
  }

  /// Главное действие панели. Порядок — по «что сейчас делает человек с этой
  /// задачей»: продолжение работы, затем — её начало (взятие). Задаче, ждущей
  /// решения, панель не нужна: наверху у неё своя, с «Принять»/«Вернуть».
  /// Второстепенное уехало в текстовые кнопки над блоком «ключ — значение»;
  /// вне объекта кнопка погашена — работа делается на месте (#36837).
  ({String label, VoidCallback? onTap})? _primaryAction(
      TaskView view, Task t, bool readOnly, TaskRepository repo) {
    final away = view.elsewhere;
    if (view.awaitingDecision) return null;
    if (!readOnly && t.opensFill) {
      final section = _nextSection();
      return (
        label: section == null ? _fillLabel(t.typeId) : 'Продолжить: $section',
        onTap: away
            ? null
            : () async {
                await Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) =>
                        FillScreen(taskId: t.clientId ?? t.id)));
                // бланк вернулся изменённым — прогресс в карточке тоже должен
                await _loadForm(repo);
              },
      );
    }
    if (!readOnly && t.opensSimple) {
      return (
        label: t.requirePhoto == true ? 'Выполнить с фото' : 'Выполнить',
        onTap: away
            ? null
            : () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) =>
                    SimpleExecutionScreen(taskId: t.clientId ?? t.id))),
      );
    }
    if (view.canTake) {
      return (
        label: 'Взять',
        onTap: () => _take(context, repo, view.id),
      );
    }
    return null;
  }

  /// Раздел бланка, куда продолжать: первый с незаполненными полями. null —
  /// всё заполнено (бланк дожимает свои «Завершить» на своём экране).
  String? _nextSection() {
    for (final s in _formSections()) {
      if (!s.complete) return s.name;
    }
    return null;
  }

  /// Разделы кэша бланка: имя, заполнено/всего. Порядок — бланковый.
  List<({String name, int answered, int total, bool complete})>
      _formSections() {
    final byIndex = <int, List<FillField>>{};
    for (final f in _formFields) {
      byIndex.putIfAbsent(f.sectionIndex, () => []).add(f);
    }
    final indexes = byIndex.keys.toList()..sort();
    return [
      for (final i in indexes)
        () {
          final fields = byIndex[i]!;
          final answered = fields.where((f) => f.answered).length;
          return (
            name: fields
                    .firstWhere((f) => (f.section ?? '').isNotEmpty,
                        orElse: () => fields.first)
                    .section ??
                'Раздел ${i + 1}',
            answered: answered,
            total: fields.length,
            complete: answered >= fields.length,
          );
        }(),
    ];
  }

  /// Второстепенные действия: снятие с себя, подписка, просмотр результата у
  /// сданной. Живут в меню «⋮» шапки (стр. 2 макета): одно главное действие —
  /// в нижней панели, «Прошлая проверка» — глазом там же в шапке. Терять их
  /// нельзя.
  List<({IconData icon, String label, VoidCallback? onTap})>
      _secondaryActions(
          TaskView view, Task t, bool away, bool readOnly) {
    final actions = <({IconData icon, String label, VoidCallback? onTap})>[];
    void add(IconData icon, String label, VoidCallback? onTap) =>
        actions.add((icon: icon, label: label, onTap: onTap));

    // сданная работа (#37158) — посмотреть, что сдано. Читать результат
    // сервер пускает исполнителя и принимающего; автору и наблюдателю его
    // «стало» — блок выполнений ниже. Ждущему решения вход — в плашке сверху
    if (view.onAcceptance &&
        t.onAcceptance &&
        !view.awaitingDecision &&
        !view.authoredOnly &&
        !view.watchedOnly) {
      add(Icons.fact_check_outlined, 'Результат',
          () => openTaskResult(context, view));
    }
    if (view.releasable) {
      add(Icons.undo, 'Снять с себя', () => _release(context, context.read<TaskRepository>(), view.id));
    }
    // подписка (#37136): «Следить» — там, где она что-то даёт (см.
    // TaskView.canFollow), «Не следить» — где подписка личная: подписку
    // подразделения с телефона не снять
    if (view.following || view.canFollow) {
      add(
          view.following
              ? Icons.visibility_off_outlined
              : Icons.visibility_outlined,
          view.following ? 'Не следить' : 'Следить',
          () => view.following
              ? _unfollow(context, context.read<TaskRepository>(), view)
              : _follow(context, context.read<TaskRepository>(), view.id));
    }
    return actions;
  }

  /// Кнопка фото рядом с главным действием: приложить снимок к задаче (#36914),
  /// не заходя в блок «было». Тональная, 52×52. Доступна и автору, и наблюдателю —
  /// как раньше кнопкой в теле карточки: решение о праве остаётся за сервером.
  /// Вне объекта гаснет (#36837) — свидетельства прикладываются на месте.
  Widget? _photoButton(
      TaskRepository repo, Task t, bool away, bool readOnly) {
    if (away) return null;
    final images = [for (final f in t.files) if (f.image) f];
    final left =
        TaskFilesController.maxPerTask - images.length - _pending.length;
    if (left <= 0) return null;
    return SizedBox(
      key: const ValueKey('taskAttachPhoto'),
      width: 52,
      height: 52,
      child: OutlinedButton(
        onPressed: () => _attachPhotos(repo, left),
        style: OutlinedButton.styleFrom(
          padding: EdgeInsets.zero,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        child: const Icon(Icons.add_a_photo_outlined, size: 22),
      ),
    );
  }

  /// Блок «ключ — значение» (стр. 2 макета): строки «метка слева — значение
  /// справа», между строками тонкий разделитель. Пустые строки не рисуются —
  /// разделителей вслед за ними тоже нет.
  Widget _keyValueCard(TaskView view, Task t) {
    Widget? kv(String label, String? value) {
      if (value == null || value.isEmpty) return null;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(label,
                  style: TextStyle(fontSize: 13, color: Wms.muted)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(value,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Wms.text)),
            ),
          ],
        ),
      );
    }

    final rows = [
      kv('Поставил', t.author),
      kv('Поставлена', formatDate(t.postedAt)),
      kv('Исполнитель', t.assignedTo),
      kv('Принимает', t.acceptor),
      kv('Взял на себя', _takenLine(view)),
      kv('Сдана', formatDateTime(t.submittedAt)),
      kv('Крайний срок', formatDate(t.deadline)),
      kv('Приоритет', t.priority),
      kv('Прогресс', t.progress == null ? null : '${t.progress}%'),
    ].whereType<Widget>().toList();
    // без горизонтального отступа: экран уже выравнивает содержимое на 16,
    // собственная маржа карточки ужимала бы её против плашек и снимков
    return DsCard(
      margin: const EdgeInsets.only(bottom: 12),
      children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0)
            Divider(height: 1, thickness: 1, color: Wms.line),
          rows[i],
        ],
      ],
    );
  }

  /// «Было»: снимок проблемного участка и прочие файлы задачи (#36842), плюс
  /// дозагрузка кадров к самой задаче (#36914).
  ///
  /// Отдельный блок с подписью, а не общая лента снимков: «зафиксировал изменение в
  /// положительную сторону» читается только тогда, когда «было» и «стало» видно
  /// порознь. Вложения переписки сюда не попадают — их место в ленте, и сервер их
  /// в этом списке не присылает.
  ///
  /// Досланный кадр цепляется к задаче, а не к сообщению: он виден здесь же и в АРМ
  /// гридом файлов — там, где его ищут, а не в ленте, куда никто не заглядывает.
  /// Пока снимок не уехал, он показан тут же с пометкой «ожидает отправки» — тем же
  /// виджетом, что и приехавшие с сервера, только из локального файла.
  Widget _problemPhotos(TaskRepository repo, Task t) {
    final files = t.files;
    final images = [for (final f in files) if (f.image) f];
    final others = [for (final f in files) if (!f.image) f];
    if (_photos == null) return const SizedBox.shrink();
    // пустой блок с заголовком — шум (#36842): пока фотографий нет ни на сервере, ни
    // в очереди, приложить их предлагает кнопка среди действий, а не заголовок ни
    // над чем
    if (files.isEmpty && _pending.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionTitle('Было — фото проблемы',
              badge: '${files.length + _pending.length}'),
          const SizedBox(height: 8),
          if (images.isNotEmpty || _pending.isNotEmpty) ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final f in images)
                  TaskPhotoThumb(
                    loader: _photos!.loaderFor(f.id),
                    caption: _fileCaption(f),
                  ),
                for (final q in _pending) _pendingPhoto(repo, q),
              ],
            ),
            _limitNote(t),
          ],
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

  /// `2026-07-20 10:42` -> `20.07.2026 10:42`; время у lsFusion приходит через
  /// пробел, у ISO — через `T`, поэтому разбор терпит оба.
  static String? _dateTimeText(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final parsed = DateTime.tryParse(raw.replaceFirst(' ', 'T'));
    if (parsed == null) return formatDate(raw);
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

  /// Подпись статуса в переключателе. У задачи с приёмкой (#37158) закрытие — не
  /// конец, а сдача: сервер переведёт её «На приёмке», и чип говорит это заранее.
  /// Отмена — закрытие, но не сдача.
  static String _statusLabel(TaskView view, TaskStatus s) {
    final submits = view.task.needsAcceptance == true &&
        !view.onAcceptance &&
        !view.awaitingDecision &&
        s.closed &&
        s.id != TaskView.canceledStatusId &&
        s.id != view.statusId;
    return submits ? 'Сдать на приёмку' : (s.name ?? s.id);
  }

  /// Почему задача только для чтения — первой строкой баннера. Наблюдающий в составе
  /// подразделения (#37136) узнаёт об этом здесь же: «Не следить» у него нет, и без
  /// объяснения это читалось бы как пропавшая кнопка.
  static String _readOnlyRole(TaskView view) {
    if (view.authoredOnly) return 'Вы автор этой задачи';
    if (view.reviewingOnly) return 'Вы принимаете эту задачу';
    return view.following
        ? 'Вы наблюдаете за этой задачей'
        : 'Вы наблюдаете за этой задачей в составе подразделения';
  }

  Future<void> _follow(
      BuildContext context, TaskRepository repo, String id) async {
    final messenger = ScaffoldMessenger.of(context);
    await repo.followTask(id);
    messenger.showSnackBar(SnackBar(
      content: Text(repo.online
          ? 'Вы следите за задачей — уведомления по ней придут в ленту'
          : 'Подписка сохранена офлайн — уйдёт на сервер при связи'),
      duration: const Duration(seconds: 2),
    ));
  }

  /// Отписка от задачи, которая была здесь только ради наблюдения, убирает её из списка
  /// сразу — и этот экран закрывается сам (задачи больше нет). Сообщение уходит в
  /// корневой ScaffoldMessenger и переживает закрытие: человек видит, что произошло.
  Future<void> _unfollow(
      BuildContext context, TaskRepository repo, TaskView view) async {
    final messenger = ScaffoldMessenger.of(context);
    await repo.unfollowTask(view.id);
    final gone = view.watchedOnly ? ' — задача убрана из «Наблюдаю»' : '';
    messenger.showSnackBar(SnackBar(
      content: Text(repo.online
          ? 'Вы больше не следите за задачей$gone'
          : 'Отписка сохранена офлайн$gone, на сервер уйдёт при связи'),
      duration: const Duration(seconds: 3),
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

/// Плашка срока в карточке (#37411, п. 5): вся ширина, иконка и дата. Просрочка —
/// пара «опасно», и это единственное её обозначение на экране. «На сколько
/// просрочено» считается здесь же: список говорит «срок», карточка — «насколько
/// всё плохо», и это разные ответы.
class _DeadlinePlate extends StatelessWidget {
  final String label;
  final bool overdue;
  const _DeadlinePlate({required this.label, required this.overdue});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: overdue ? Wms.dangerTint : Wms.chipBg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(overdue ? Icons.event_busy : Icons.event,
              size: 18, color: overdue ? Wms.danger : Wms.text2),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              overdue ? 'Просрочено — $label' : 'Срок: $label',
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: overdue ? Wms.danger : Wms.text2),
            ),
          ),
        ],
      ),
    );
  }
}

/// «Заполнение N из M» и разделы с готовностью — из бланка, который уже лежит на
/// телефоне. Готовый раздел — галочка «готово», текущий — фирменным числом.
class _FillProgressCard extends StatelessWidget {
  final List<FillField> fields;
  const _FillProgressCard({required this.fields});

  @override
  Widget build(BuildContext context) {
    // пересчёт здесь же, а не передачей из состояния: карточке нужен только
    // готовый список разделов, и его сборка дешёвая
    final byIndex = <int, List<FillField>>{};
    for (final f in fields) {
      byIndex.putIfAbsent(f.sectionIndex, () => []).add(f);
    }
    final indexes = byIndex.keys.toList()..sort();
    final sections = [
      for (final i in indexes)
        (
          name: byIndex[i]!
                  .firstWhere((f) => (f.section ?? '').isNotEmpty,
                      orElse: () => byIndex[i]!.first)
                  .section ??
              'Раздел ${i + 1}',
          answered: byIndex[i]!.where((f) => f.answered).length,
          total: byIndex[i]!.length,
        ),
    ];
    final answered = fields.where((f) => f.answered).length;

    // без горизонтального отступа: экран уже выравнивает содержимое на 16,
    // собственная маржа карточки ужимала бы её против плашек и снимков
    return DsCard(
      margin: const EdgeInsets.only(bottom: 12),
      children: [
      Text('Заполнение $answered из ${fields.length}',
          style: TextStyle(
              fontSize: 15, fontWeight: FontWeight.w700, color: Wms.text)),
      const SizedBox(height: 10),
      // полоса под счётчиком (стр. 2 макета): тонкая, скруглённая, фирменным
      ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: LinearProgressIndicator(
          value: fields.isEmpty ? 0 : answered / fields.length,
          minHeight: 6,
          backgroundColor: Wms.chipBg,
          valueColor: AlwaysStoppedAnimation<Color>(Wms.primary),
        ),
      ),
      const SizedBox(height: 12),
      for (final s in sections)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Icon(
                s.answered >= s.total
                    ? Icons.check_circle
                    : Icons.radio_button_unchecked,
                size: 18,
                color: s.answered >= s.total ? Wms.done : Wms.muted,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(s.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: Wms.text)),
              ),
              Text('${s.answered} / ${s.total}',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: s.answered >= s.total ? Wms.done : Wms.muted)),
            ],
          ),
        ),
      ],
    );
  }
}

/// Задача ждёт моего решения (#37158): когда и кем сдана, вход в результат и сами
/// «Принять» / «Вернуть». Рамкой, а не строкой: это единственное, что принимающему
/// здесь нужно сделать.
class _DecisionPanel extends StatelessWidget {
  final TaskView view;
  const _DecisionPanel({required this.view});

  @override
  Widget build(BuildContext context) {
    final by = view.task.executions.isEmpty
        ? null
        : view.task.executions.last.executor;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Wms.active,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Wms.primary.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.fact_check_outlined, size: 18, color: Wms.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text('Ждёт вашего решения',
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: Wms.text)),
            ),
          ]),
          const SizedBox(height: 4),
          Text(
            [
              if (by != null) 'Сдал: $by',
              if (formatDateTime(view.task.submittedAt) != null)
                formatDateTime(view.task.submittedAt)!,
            ].join(' · '),
            style: TextStyle(fontSize: 13, color: Wms.muted),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () => openTaskResult(context, view),
            icon: const Icon(Icons.photo_library_outlined),
            label: const Text('Посмотреть результат'),
          ),
          const SizedBox(height: 8),
          DecisionBar(view: view),
        ],
      ),
    );
  }
}

/// Задача на приёмке, решать не мне (#37158): исполнителю — «сдана, ждёт решения», и
/// работать по ней до решения нечего; автору и наблюдателю — где она сейчас.
class _AcceptanceNote extends StatelessWidget {
  final TaskView view;
  const _AcceptanceNote({required this.view});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: Wms.active,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.hourglass_top, size: 18, color: Wms.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${submittedLine(view)}. Работа сдана — дальше решает '
                  'принимающий: примет или вернёт с причиной.',
                  style: TextStyle(fontSize: 12, color: Wms.text),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Задача возвращена на доработку (#37158) — причина целиком, а не обрезанной строкой:
/// ради неё исполнитель и открыл карточку.
class _ReturnedNote extends StatelessWidget {
  final TaskView view;
  const _ReturnedNote({required this.view});

  @override
  Widget build(BuildContext context) {
    final reason = view.returnReason?.trim();
    final who = view.task.acceptor;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Wms.warnTint,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.undo, size: 18, color: Wms.warn),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  view.decisionPending
                      ? 'Возвращено на доработку — ждёт отправки'
                      : 'Возвращено на доработку',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Wms.warn),
                ),
                if (reason != null && reason.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(reason,
                      key: const ValueKey('returnReasonText'),
                      style: TextStyle(
                          fontSize: 15, height: 1.35, color: Wms.text)),
                ],
                if (who != null) ...[
                  const SizedBox(height: 4),
                  Text('Принимает: $who',
                      style: TextStyle(fontSize: 12, color: Wms.muted)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
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

