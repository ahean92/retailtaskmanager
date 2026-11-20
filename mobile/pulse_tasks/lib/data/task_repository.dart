import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../models/quick_create.dart';
import '../models/task.dart';
import '../models/task_status.dart';
import '../models/task_view.dart';
import 'api_client.dart';
import 'cache_sweep.dart';
import 'client_id.dart' as ids;
import 'fill_cache_store.dart';
import 'geo.dart';
import 'local_db.dart';
import 'location_controller.dart';
import 'quiet_after_dispose.dart';
import 'session.dart';
import 'settings.dart';
import 'sync/decision_sync.dart';
import 'sync/outbox_drain.dart';
import 'sync/status_sync.dart';
import 'sync/take_sync.dart';
import 'sync/task_queue_sync.dart';
import 'sync/watch_sync.dart';
import 'task_file_controller.dart';
import 'unsent.dart';
import 'user_base.dart';

/// Сколько кэш бланка считается свежим и не перечитывается с сервера. Меньше —
/// открытие карточки сразу за выходом из бланка плодит круги; больше — цифра
/// «Заполнение N из M» заметно отстаёт от выполнения. 30 секунд закрывают и
/// «зашёл-вышел подряд», и не заставляют ждать честного счётчика.
const Duration fillCacheFreshness = Duration(seconds: 30);

/// Протух ли кэш бланка для карточки: старше [fillCacheFreshness] или даты в
/// нём нет вовсе. Отдельная функция ради теста — решение о лишнем сетевом круге
/// стоит проверить, а поднимать ради него экран целиком дороже.
@visibleForTesting
bool fillCacheStale(String? fetchedAtIso, DateTime now) {
  final at = fetchedAtIso == null ? null : DateTime.tryParse(fetchedAtIso);
  return at == null || now.difference(at) > fillCacheFreshness;
}

/// Offline-first repository. Reads always come from the local DB, so the app is
/// fully usable without connectivity. Writes (status changes) are recorded in an
/// outbox and pushed to the server opportunistically (immediately if online,
/// otherwise on the next reconnect / manual sync).
///
/// Здесь — список задач и то, что ложится на него из очередей: статусы, взятия,
/// подписки, решения, снимки, рождённые на телефоне задачи. Отправка каждой очереди —
/// свой синхронизатор в data/sync (StatusSync, TakeSync, WatchSync, DecisionSync,
/// TaskCreateSync); здесь — постановка в очередь, наложение на список и фасад для
/// экранов. Остальное живёт рядом и читает список отсюда: вход и выход —
/// AccountController, место — [LocationController], главная и пресеты —
/// HomeController, лента — NotificationsController, дренаж чужих очередей и расписание
/// синхронизации — SyncCoordinator. Собирает их вместе AppControllers.
typedef _Overlay = ({
  Map<String, OutboxEntry> outbox,
  Set<String> creating,
  Set<String> starting,
  Set<String> finishing,
  Map<String, String> takes,
  Map<String, String> watches,
  Map<String, ({String action, String? reason})> decisions,
  Map<String, CommentStats> commentStats,
  Map<String, int> commentQueue,
});

class TaskRepository extends ChangeNotifier with QuietAfterDispose {
  final ApiClient api;
  final Session session;
  final Settings settings;
  final Geo geo;

  /// База вошедшего — одна на всех, кто в ней живёт: список читает из неё задачи и
  /// свои очереди, остальные — своё, по [UserBase.onChange].
  final UserBase base;

  /// Где человек стоит: задачи делятся на «здесь» и «не здесь» ([TaskView.elsewhere]),
  /// и у сервера список спрашивается под этот объект.
  final LocationController location;

  /// Отправка очередей статусов и взятий и вердикт о сети — общая политика, см.
  /// [OutboxDrain]; экземпляр общий с [LocationController]: «сервер не ответил, кто
  /// рядом» и «сервер не принял статус» зажигают один и тот же баннер.
  final OutboxDrain drain;

  /// Кого позвать, когда в очереди жизненного цикла легло новое — созданная задача,
  /// снимок к существующей: эти очереди дренит SyncCoordinator, здесь только просьба
  /// «толкни, если сеть есть».
  Future<void> Function()? pushLocalTasks;

  TaskRepository(
      {required this.api,
      required this.settings,
      required this.session,
      required this.base,
      required this.location,
      required this.drain,
      required this.geo}) {
    base.onChange(_onBase);
  }

  /// For the screens, which only exist under a signed-in user. Reading it with nobody
  /// signed in is a bug in the caller, not a state to handle.
  LocalDb get db =>
      base.db ?? (throw StateError('no local database: nobody is signed in'));

  /// То же, но без исключения — для виджетов, которые могут оказаться построенными,
  /// когда базы нет (сессия умерла под открытой карточкой): им честнее нарисовать
  /// пустое место, чем уронить экран.
  LocalDb? get localDb => base.db;

  /// Всё, что назначено этому человеку, — включая задачи других объектов (#36837).
  /// Задачи объекта, на котором он стоит, идут первыми, остальные — ниже по
  /// расстоянию и помечены [TaskView.elsewhere]: видеть можно всё, работать — на месте.
  List<TaskView> tasks = const [];

  /// «Выполненные» (15.10): закрытые с сервера — выполненные и отменённые за 30
  /// дней, где человек участник. Отдельный список, а не часть [tasks]: это история,
  /// и рабочего списка она не перестраивает — счётчики групп, главная и «Не
  /// отправлено» про неё не знают. Свежие сверху (closedAt); offline читается из
  /// кэша, как и всё остальное.
  List<TaskView> closedTasks = const [];

  int syncGen = 0;

  _Overlay _overlay = (
    outbox: const {},
    creating: const {},
    starting: const {},
    finishing: const {},
    takes: const {},
    watches: const {},
    decisions: const {},
    commentStats: const {},
    commentQueue: const {},
  );

  List<TaskStatus> statuses = const [];

  /// Очередь отправки как список операций (#36916) — то, что рисует экран
  /// «Не отправлено», с человеческими названиями и причинами последних неудач.
  /// Пересобирается каждым [_reload], так что бейдж и экран всегда согласны.
  List<UnsentOp> unsentOps = const [];

  /// Число операций в очереди — оно же на бейдже шапки. Ровно [unsentOps.length]:
  /// человек, открывший экран по бейджу «3», должен увидеть три строки.
  int pendingCount = 0;

  bool loading = false;

  bool get online => drain.online;

  /// Вердикт о сети меняется и без похода в очередь — слушателем сети; экраны с
  /// баннером «офлайн» узнают об этом отсюда.
  set online(bool v) {
    drain.online = v;
    notifyListeners();
  }

  String? error; // last network error (for the offline banner / snackbar)

  /// База сменилась (вход, выход, другой сервер): сообщение о проигранной гонке —
  /// про задачу ушедшего, следующему его не показывают. Сам список перечитывает не
  /// хук, а тот, кто базу сменил, — [reloadLocal] после того, как все прочитали своё.
  Future<void> _onBase(LocalDb? db) async {
    _setTakeNotice(null);
  }

  TaskStatus? statusById(String? id) {
    if (id == null) return null;
    for (final s in statuses) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// Задача по любому из её адресов: ST-номер или UUID, которым рождённая на
  /// телефоне задача зовётся всю жизнь (бланк и очереди ключуются им и после того,
  /// как сервер выдал ей номер). Null — задачи в списке больше нет. Ищет и в архиве
  /// «Выполненных» (15.10): закрытая задача остаётся открываемой — карточкой по
  /// чипу и переходом из уведомления.
  TaskView? viewOf(String taskId) {
    for (final v in tasks) {
      if (v.id == taskId || v.task.clientId == taskId) return v;
    }
    for (final v in closedTasks) {
      if (v.id == taskId || v.task.clientId == taskId) return v;
    }
    return null;
  }

  Future<List<Task>?> fetchObjectTasks(String objectId) async {
    if (!settings.isConfigured || !session.isActive || base.db == null) {
      return null;
    }
    List<Task>? rows;
    final failure = await drain.attempt(() async {
      rows = await api.fetchObjectTasks(objectId,
          lat: location.place.latitude, lon: location.place.longitude);
    });
    return failure == null ? rows : null;
  }

  List<TaskView> objectViews(String objectId, List<Task>? rows,
      {required bool fresh}) {
    if (rows == null) {
      return tasks.where((v) => v.task.inPlace(objectId)).toList();
    }
    final cached = {for (final v in tasks) v.id: v};
    final seen = <String>{};
    final out = <TaskView>[];
    for (final t in rows) {
      final v = cached[t.id] ?? (fresh ? _view(t) : null);
      if (v != null && seen.add(v.id)) out.add(v);
    }
    for (final v in tasks) {
      if (v.task.inPlace(objectId) && seen.add(v.id)) out.add(v);
    }
    _sortOpen(out);
    return out;
  }

  /// Задача не того объекта, где человек стоит, — для аккаунта с обязательной
  /// геолокацией она видна, но только для чтения (#36837). Считается локально и
  /// мгновенно: смена объекта в шапке и отъезд перекрашивают список в том же кадре,
  /// без сервера — положение телефона меняется между синхронизациями, и серверному
  /// флагу здесь верить нельзя.
  ///
  /// A role excused from geolocation works from anywhere, and there is no object for
  /// them to be standing at — nothing is elsewhere for them.
  ///
  /// Наблюдаемая-и-только задача (#37136) не «не здесь» никогда: правило «не свой объект
  /// — не трогать» защищает работу, а работы по ней и так нет. Наблюдают почти всегда за
  /// чужим объектом, и гейт на такой задаче делал бы подписку бесполезной ровно там, где
  /// она нужна: пометка «вы не на объекте» и спрятанное «Приложить фото» при том, что
  /// переписка открыта отовсюду. Авторская задача (#36844) под гейтом остаётся, как была.
  /// Принимающий (#37158) — тоже вне гейта: решение по сданной работе — не работа на
  /// месте, и поручение, сданное в 11:00, не должно ждать, пока заведующий дойдёт до
  /// нужного магазина.
  bool _elsewhere(Task t, {required bool exempt}) =>
      session.geoRequired && !exempt && !location.place.holds(t);

  /// Rebuild the in-memory view from the local DB (tasks + statuses + outbox),
  /// applying the outbox status overlay. Nothing is filtered by assignee here: `apiTasks`
  /// only ever sends the signed-in user's tasks, so what is cached is already theirs.
  /// И по месту не фильтруется тоже (#36837): задачи чужих объектов остаются в списке
  /// с пометкой «только для чтения» — сортировка ниже ставит их после задач «здесь».
  ///
  /// Задачи, рождённые на телефоне, несут свои метки поверх той же строки кэша: пока
  /// создание в очереди — «не синхронизировано», пока в очереди финиш — «завершена, не
  /// отправлена» и closed, чтобы завершённая в подвале проверка не считалась просроченной.
  Future<void> _reload() async {
    final db = base.db;
    if (db == null) {
      // signed out: what is on the screen belongs to the person who has just left, and the
      // next one must not find it waiting for them
      tasks = const [];
      closedTasks = const [];
      statuses = const [];
      unsentOps = const [];
      pendingCount = 0;
      notifyListeners();
      return;
    }
    try {
      await _readFrom(db);
    } catch (_) {
      // Базу закрыли посреди чтения: выход из учётной записи, смена сервера, конец
      // работы приложения — а синхронизация, позвавшая сюда, шла без ожидания.
      // Список ушедшего читать дальше незачем: его перечитает тот, кто сменил базу.
      // Ошибка в базе, которая по-прежнему открыта, — настоящая и уходит дальше.
      if (identical(base.db, db)) rethrow;
    }
  }

  Future<void> _readFrom(LocalDb db) async {
    final all = await db.tasks.getTasks();
    final outbox = await db.tasks.getOutbox();
    final creating = await db.queues.getCreateTaskIds();
    final starting = await db.queues.getStartTaskIds();
    final finishing = await db.queues.getFinishTaskIds();
    final takes = {
      for (final r in await db.tasks.getTakeOutbox())
        r['taskId'] as String: r['action'] as String
    };
    // подписки (#37136) — своя очередь поверх серверных признаков, как у взятий
    final watches = {
      for (final r in await db.tasks.getWatchOutbox())
        r['taskId'] as String: r['action'] as String
    };
    // решения по сданным задачам (#37158) — тоже поверх серверных признаков
    final decisions = {
      for (final r in await db.tasks.getDecisionOutbox())
        r['taskId'] as String: (
          action: r['action'] as String,
          reason: r['reason'] as String?,
        )
    };
    // переписка (#36844): сводка кэша лент и своя очередь — поверх серверных чисел
    final commentStats = await db.comments.commentStats();
    final commentQueue = <String, int>{};
    for (final r in await db.comments.getAllCommentOutbox()) {
      final id = r['taskId'] as String;
      commentQueue[id] = (commentQueue[id] ?? 0) + 1;
    }
    statuses = await db.tasks.getStatuses();

    _overlay = (
      outbox: outbox,
      creating: creating,
      starting: starting,
      finishing: finishing,
      takes: takes,
      watches: watches,
      decisions: decisions,
      commentStats: commentStats,
      commentQueue: commentQueue,
    );
    tasks = all.map(_view).whereType<TaskView>().toList();
    _sortOpen(tasks);
    // «Выполненные» (15.10): закрытые с сервера, без наложения очередей — у истории
    // очередей не бывает (завершённая здесь, но не отправленная живёт в рабочей
    // половине с пометкой «не отправлена», а не здесь). Свежие закрытия сверху;
    // строка без closedAt (не сказало или не разобралось) — вниз: сортировать её
    // нечем. Равные остаются как пришли — компаратор добит исходным индексом, как
    // у рабочего списка.
    final shut = await db.tasks.getClosedTasks();
    closedTasks = [
      for (final t in shut)
        TaskView(
          t,
          t.statusId,
          t.status,
          false,
          closed: true,
          archived: true,
          // участие — как у рабочего списка: архивная карточка тоже решает по
          // флагам, кому что показывать (кнопка «Результат» автору и наблюдателю
          // не положена — сервер им сданное не отдаёт)
          authoredOnly: t.authoredOnly,
          watchedOnly: t.watchedOnly,
          reviewingOnly: t.reviewingOnly,
          commentCount: t.commentCount ?? 0,
          unreadComments: t.unreadComments ?? 0,
          group: TaskGroup.done,
        ),
    ];
    final shutOrder = {
      for (var i = 0; i < closedTasks.length; i++) closedTasks[i]: i
    };
    closedTasks.sort((a, b) {
      final da = a.task.closedAtDate, dd = b.task.closedAtDate;
      if (da == null && dd == null) return shutOrder[a]!.compareTo(shutOrder[b]!);
      if (da == null) return 1;
      if (dd == null) return -1;
      final byDate = dd.compareTo(da);
      return byDate != 0 ? byDate : shutOrder[a]!.compareTo(shutOrder[b]!);
    });

    // Все очереди, а не только видимые списку (#36916): ответ бланка и снимок,
    // ждущие в подвале, — такие же «не отправлено», как смена статуса. Считаются
    // операциями, а не строками таблиц: бейдж «3» обещает три строки на экране.
    unsentOps = await loadUnsentOps(db);
    pendingCount = unsentOps.length;
    notifyListeners();
  }

  TaskView? _view(Task t) {
    final o = _overlay;
    final outbox = o.outbox;
    final creating = o.creating;
    final starting = o.starting;
    final finishing = o.finishing;
    final takes = o.takes;
    final watches = o.watches;
    final decisions = o.decisions;
    final commentStats = o.commentStats;
    final commentQueue = o.commentQueue;
    // очереди рождённой на телефоне задачи всю жизнь ключуются её UUID, а строка
    // кэша после первой синхронизации несёт уже ST-номер — метки ищутся по обоим,
    // иначе завершённая офлайн проверка «открывалась» бы обратно после refresh
    final cid = t.clientId;
    bool inQ(Set<String> q) =>
        q.contains(t.id) || (cid != null && q.contains(cid));

    // Решение из очереди (#37158). Принятая здесь задача уходит из списка сразу: она
    // закрыта для всех, и строка «ещё ждёт» до ответа сервера читалась бы как «кнопка
    // не сработала». Откажет сервер — очередь снимет решение, строка вернётся к его
    // слову, а человеку скажут почему.
    final decision = decisions[t.id] ?? (cid == null ? null : decisions[cid]);
    if (decision?.action == 'accept') return null;
    final returning = decision?.action == 'return';

    // Подписка (#37136): личная — то, что человек меняет с телефона, и очередь
    // накладывается на неё; наблюдение подразделением сверх личной — слово сервера,
    // с телефона оно не снимается и очередь его не трогает.
    final watchAction = watches[t.id] ?? (cid == null ? null : watches[cid]);
    final following = watchAction == null
        ? t.following == true
        : watchAction == 'follow';
    final watched =
        following || (t.watched == true && t.following != true);
    // Отписался от задачи, которая была здесь только ради наблюдения, — она уходит
    // из списка сразу, в этом же кадре, а не когда сервер подтвердит: «ушла после
    // синхронизации» человек в подсобке читает как «кнопка не работает». Очередь
    // дожмёт, а подтверждённую отписку дренаж уберёт из кэша совсем.
    if (t.watchedOnly && !watched) return null;
    final ob = outbox[t.id] ?? (cid == null ? null : outbox[cid]);
    // вернул здесь — задача снова в работе, как её поставит сервер (doReturn)
    final statusId =
        returning ? DecisionSync.returnedStatusId : (ob?.statusId ?? t.statusId);
    final done = inQ(finishing);
    final closed = done || (statusById(statusId)?.closed ?? false);

    // Приёмка (#37158). Сдача, сделанная здесь: у задачи с приёмкой завершение и
    // «Выполнено» — это сдача, а не закрытие, и до ответа сервера задача уже «На
    // приёмке», а не в «Моих»; выбранный руками статус «На приёмке» — сдача у любой
    // задачи (так его понимает сервер). Отмена — закрытие, но не сдача. Самоприёмку
    // телефон заранее не видит (принимающего сервер вычисляет при сдаче): её сервер
    // закроет сразу, и строка уйдёт из списка первой же синхронизацией.
    final chosenSubmit = ob != null &&
        (ob.statusId == Task.acceptanceStatusId ||
            (t.needsAcceptance == true &&
                ob.statusId != TaskView.canceledStatusId &&
                (statusById(ob.statusId)?.closed ?? false)));
    final submittedHere = t.awaitingDecision != true &&
        decision == null &&
        ((t.needsAcceptance == true && done) || chosenSubmit);
    final onAcceptance = submittedHere ||
        (t.onAcceptance && ob == null && decision == null);
    final awaiting =
        t.awaitingDecision == true && decision == null && ob == null;
    final returned = returning || (t.returned == true && !onAcceptance);

    // Группа — по серверным флагам, поверх которых кладётся только СВОЯ очередь
    // взятий: mine не пересобирается из takenById/assigneeId (#36751). Строка без
    // единого из новых ключей пришла со старого сервера или рождена на телефоне —
    // такая выдача вся назначена лично, то есть «мои».
    final takeAction = takes[t.id];
    final taking = takeAction == 'take';
    final releasing = takeAction == 'release';
    final legacy =
        t.mine == null && t.takenById == null && t.canTake == null;
    // авторская-и-только — отдельная группа (#36844): взять её нельзя (сервер не
    // шлёт canTake), «моей» она не бывает, а в «свободные» или «взяты коллегами»
    // ей нечего делать — это не пул моего подразделения
    final authoredOnly = t.authoredOnly;
    // наблюдаемая-и-только (#37135) — тоже своя группа, и проверяется ДО legacy:
    // серверных ключей взятия у такой строки нет (mine, canTake считаются от
    // назначения), и по legacy она уехала бы в «Мои», разойдясь с плиткой главной.
    // С наложенной очередью подписок (#37136) — но появиться этим путём задача не
    // может: всё, на что можно подписаться с телефона, уже в списке по другой причине
    final watchedOnly = watched &&
        t.assigned != true &&
        t.authored != true &&
        t.reviewing != true;
    // принимающий-и-только (#37158) — та же история: ключей взятия нет, и по legacy
    // задача уехала бы в «Мои»
    final reviewingOnly = t.reviewingOnly;
    TaskGroup groupOf() {
      // ждёт моего решения — первым: принимающим бывает и автор, и исполнитель из
      // того же подразделения, а плитка «Ждут приёмки» считает их всех
      if (awaiting) return TaskGroup.awaiting;
      if (authoredOnly) return TaskGroup.authored;
      if (reviewingOnly) {
        return onAcceptance ? TaskGroup.submitted : TaskGroup.rework;
      }
      if (watchedOnly) return TaskGroup.watched;
      final TaskGroup byTake;
      if (taking) {
        byTake = TaskGroup.mine;
      } else if (releasing) {
        byTake = TaskGroup.free;
      } else if (t.mine == true || legacy) {
        byTake = TaskGroup.mine;
      } else if (t.takenById != null) {
        byTake = TaskGroup.taken;
      } else {
        byTake = TaskGroup.free;
      }
      // Сданная (#37158): сервер «моей» её не считает (mine — без приёмки), и по
      // признакам взятия она ушла бы в «Мои» старой выдачи, в «Свободные» или во
      // «взяты коллегами» под моим же именем. Взятая коллегой остаётся у коллег.
      if (onAcceptance &&
          (byTake != TaskGroup.taken || t.takenById == session.performerId)) {
        return TaskGroup.submitted;
      }
      return byTake;
    }

    final group = groupOf();

    // кэш ленты и очередь рождённой на телефоне задачи ключуются её UUID — как
    // бланк; строка после синхронизации несёт ST-номер, ищем по обоим
    final cached = commentStats[t.id] ??
        (cid == null ? null : commentStats[cid]);
    final queued = (commentQueue[t.id] ?? 0) +
        (cid == null || cid == t.id ? 0 : (commentQueue[cid] ?? 0));
    final (commentCount, unreadComments) = _commentCounts(t, cached, queued);

    return TaskView(
      t,
      statusId,
      submittedHere
          ? 'Сдана — не отправлена'
          : done
              ? 'Завершена — не отправлена'
              : returning
                  ? (statusById(statusId)?.name ?? t.status)
                  : (ob == null ? t.status : (ob.statusName ?? t.status)),
      ob != null ||
          inQ(creating) ||
          inQ(starting) ||
          done ||
          releasing ||
          decision != null,
      closed: closed,
      locallyFinished: done,
      takenById: taking
          ? session.performerId
          : (releasing ? null : t.takenById),
      takenBy: taking
          ? (session.name.isEmpty ? session.login : session.name)
          : (releasing ? null : t.takenBy),
      takenAt: taking || releasing ? null : t.takenAt,
      canTake:
          t.canTake == true && takeAction == null && !closed && !onAcceptance,
      takePending: taking,
      // сданную с себя не снимают: работа сделана, и «взял» у неё — уже история
      releasable: taking ||
          (takeAction == null &&
              t.takenById != null &&
              t.takenById == session.performerId &&
              !closed &&
              !onAcceptance),
      elsewhere: _elsewhere(t,
          exempt: watchedOnly || reviewingOnly || awaiting || returning),
      authoredOnly: authoredOnly,
      watchedOnly: watchedOnly,
      watched: watched,
      following: following,
      watchPending: watchAction != null,
      onAcceptance: onAcceptance,
      awaitingDecision: awaiting,
      reviewingOnly: reviewingOnly,
      returned: returned,
      returnReason: returning ? decision!.reason : t.returnReason,
      decisionPending: decision != null,
      commentCount: commentCount,
      unreadComments: unreadComments,
      group: group,
    );
  }

  void _sortOpen(List<TaskView> list) {
    // Задачи объекта, где человек стоит, — сверху, остальные ниже по расстоянию:
    // список читается как маршрут, а не как алфавит (#36837). Внутри «здесь» и при
    // равных расстояниях порядок серверной выдачи сохраняется — sort() нестабилен,
    // поэтому исходный индекс дотягивается до компаратора явно.
    final order = {for (var i = 0; i < list.length; i++) list[i]: i};
    list.sort((a, b) {
      if (a.elsewhere != b.elsewhere) return a.elsewhere ? 1 : -1;
      if (a.elsewhere) {
        final da = a.task.distance, db = b.task.distance;
        if (da != db) {
          // без расстояния (объект без координат) — в самый конец: ехать «неизвестно
          // куда» предлагают после всех известных адресов
          if (da == null) return 1;
          if (db == null) return -1;
          final byDistance = da.compareTo(db);
          if (byDistance != 0) return byDistance;
        }
      }
      return order[a]!.compareTo(order[b]!);
    });
  }

  /// Счётчики переписки для строки списка (#36844). Сервер сказал своё на момент
  /// fetch; телефон знает больше про «сейчас»: что прочитал (местная отметка, ещё не
  /// ушедшая) и что написал (очередь). Непрочитанное — меньшее из серверного и
  /// местного, пока кэш ленты не отстал от сервера (в кэше не меньше сообщений, чем
  /// сервер насчитал): прочитанное офлайн гасит бейдж сразу, прочитанное с другого
  /// телефона — тоже, а отставший кэш верит серверу — его число и зовёт префетч.
  static (int, int) _commentCounts(Task t, CommentStats? cached, int queued) {
    final serverCount = t.commentCount ?? 0;
    final serverUnread = t.unreadComments ?? 0;
    var count = serverCount;
    var unread = serverUnread;
    if (cached != null) {
      if (cached.total > count) count = cached.total;
      if (cached.total >= serverCount) unread = min(cached.unread, serverUnread);
    }
    return (count + queued, unread);
  }

  /// Перечитать локальное состояние без сети: лента комментариев сообщает сюда, что
  /// прочитала или отправила что-то, и бейджи на карточках должны сойтись с ней в том
  /// же кадре.
  Future<void> reloadLocal() => _reload();

  /// Pull the latest tasks + statuses from the server into the local cache.
  Future<void> refresh() async {
    if (!settings.isConfigured) {
      error = 'Не настроено подключение';
      notifyListeners();
      return;
    }
    final db = base.db;
    if (!session.isActive || db == null) return;
    loading = true;
    error = null;
    notifyListeners();
    // полосу, родившуюся под этим fetch, он не судит: его выдача может быть старше
    // самого конфликта и погасила бы сообщение, которое только что появилось
    final judged = _takeNoticeOf;
    var replaced = false;
    final failure = await drain.attempt(() async {
      final fetched = await api.fetchTasks(
          lat: location.place.latitude, lon: location.place.longitude, objectId: location.place.objectId);
      final st = await api.fetchStatuses();
      // «Выполненные» (15.10) — тем же заходом: архив и рабочий список меняются на
      // сервере одной жизнью задачи, и показывать их от разных моментов (закрытая
      // ещё в «Моих», выполненной в архиве нет) телефон не должен. Место архиву не
      // нужно, координаты не спрашиваются.
      final archive = await api.fetchArchiveTasks();
      // Сервер с #36837 отдаёт всё назначенное, где бы человек ни стоял, поэтому
      // спрашивать можно и «ниоткуда» — в дороге список нужнее всего. Единственное
      // исключение: старый сервер на «ниоткуда» отвечал пустым списком, и пустой
      // ответ без выбранного объекта кэш не затирает — у нового сервера он означал
      // бы «задач нет вообще», и почти пустой кэш переживёт это расхождение до
      // первого located-fetch.
      if (fetched.isNotEmpty ||
          !session.geoRequired ||
          location.place.objectId != null) {
        await db.tasks.replaceTasks(fetched, closed: archive);
        syncGen++;
        replaced = true;
        if (judged != null && identical(judged, _takeNoticeOf)) {
          _settleTakeNotice(judged, fetched);
        }
      }
      if (st.isNotEmpty) await db.tasks.replaceStatuses(st);
    });
    if (failure is SessionExpiredException) {
      // the session is already cleared — the app root will show the login screen
      error = 'Сессия истекла — войдите заново';
    } else if (failure != null && isNetworkFailure(failure)) {
      error = 'Нет связи с сервером — показаны сохранённые данные';
    } else if (failure != null) {
      error = 'Не удалось обновить список: ${failureReason(failure)}';
    }
    loading = false;
    await _reload();
    // список заменён словом сервера — теперь «задачи нет ни в рабочем, ни в архиве»
    // значит «закрыта больше 30 дней назад или не наша», и её кэши можно убрать
    if (replaced) await sweepGoneTasks(db);
  }

  /// Стянуть одну задачу по id — переход из уведомления по задаче, которой нет в
  /// кэше: закрытой (отменена, выполнена — из выдачи она исчезла, а запись в ленте
  /// живёт 30 дней) или отставшей от синхронизации. Закрытая ляжет в «Выполненные»,
  /// открытая — в рабочий список до ближайшего refresh. Null — сервер задачи не
  /// отдал (нет, человек не участник, сервер старый) или связи не было: вызывающий
  /// в ответ говорит своё честное «задачи нет», а не открывает пустой экран.
  Future<TaskView?> loadTaskById(String taskId) async {
    if (!settings.isConfigured) return null;
    final db = base.db;
    if (!session.isActive || db == null) return null;
    try {
      final t = await api.fetchTaskById(taskId);
      if (t == null) return null;
      await db.tasks.upsertFetched(t, closed: t.closedAt != null);
      await _reload();
    } catch (_) {
      // офлайн или отказ — кэш не тронут, а человек услышит сообщение вызывающего
      return null;
    }
    return viewOf(taskId);
  }

  /// Строка кэша бланка для карточки задачи (#37411, п. 5): «Заполнение N из M»
  /// и разделы с готовностью. При связи и протухшем кэше ([force] — возврат из
  /// бланка, там всё меняется быстрее 30 секунд) освежает её агрегатом одним
  /// кругом, без кандидатов: пикеры с карточки не показываются, тащить каталог
  /// вслед за прогрессом незачем.
  ///
  /// Запись — только когда ответ назвал поля: ответ «выполнения нет» (без полей)
  /// положил бы в кэш пустой бланк, и бланк видел бы «уже заведено» и не звал
  /// старт. Что и как ложится в строку — [FillCacheStore.saveForCard]: задачу,
  /// взятую у коллеги или начатую на другом устройстве, после одной карточки можно
  /// открыть и без связи, и её прошлая проверка уходит в префетч.
  Future<Map<String, Object?>?> fillCacheForCard(String taskId,
      {bool force = false}) async {
    final db = base.db;
    if (db == null) return null;
    final store = FillCacheStore(db);
    final c = await store.read(taskId);
    final stale = fillCacheStale(c?['fetchedAt'] as String?, DateTime.now());
    if ((c == null || stale || force) && online) {
      try {
        final b = await api.fetchExecutionBundle(taskId) ?? const {};
        // полей нет — «выполнения нет»: кэш не трогаем и показываем как есть
        if (((b['fields'] as List?) ?? const []).isNotEmpty) {
          return await store.saveForCard(taskId, b, existing: c != null);
        }
      } catch (_) {
        // не стянулся — покажем кэш как есть; следующий заход дотянется
      }
    }
    return c;
  }

  // --- очереди намерений: статус, взятие, подписка, решение (data/sync) ---
  //
  // Каждый домен отправки — свой синхронизатор; здесь — список, на который ложатся их
  // очереди, и фасад, которым их зовут экраны.

  /// Что синхронизаторам нужно от списка — см. [TaskSyncContext].
  late final TaskSyncContext _syncContext = TaskSyncContext(
    base: base,
    session: session,
    api: api,
    drain: drain,
    reload: _reload,
    refresh: refresh,
    notify: notifyListeners,
    setError: (text) => error = text,
    noteStop: _noteStop,
    notice: _setTakeNotice,
    tasks: () => tasks,
    viewOf: viewOf,
    statusById: statusById,
  );
  late final StatusSync _status = StatusSync(_syncContext);
  late final TakeSync _takes = TakeSync(_syncContext);
  late final WatchSync _watches = WatchSync(_syncContext);
  late final DecisionSync _decisions = DecisionSync(_syncContext);

  // --- смена статуса ---

  /// Очередь статусов сейчас едет — индикатор на списке.
  bool get syncing => _status.syncing;

  /// Change a task's status: record it locally (instant, offline-safe) and try
  /// to push right away — см. [StatusSync.set].
  Future<void> setStatus(String taskId, TaskStatus status) =>
      _status.set(taskId, status);

  /// Drain the status outbox — см. [StatusSync.sync]. True — очередь поговорила с
  /// сервером и кэшу нужна свежая выдача.
  Future<bool> syncOutbox() => _status.sync();

  /// Отказанная сервером смена статуса снята с очереди — полоса на списке задач до
  /// крестика.
  String? get statusNotice => _status.notice;

  /// Снять с показа плашку об отказанной смене статуса.
  void dismissStatusNotice() {
    _status.notice = null;
    notifyListeners();
  }

  /// Цепочка остановилась: обрыв связи — «не удалось синхронизировать» с причиной;
  /// потеря сессии свой текст уже поставила (onSessionLost), и очередь переживёт
  /// перевход.
  void _noteStop() {
    if (drain.lastFailure is SessionExpiredException) return;
    error = 'Не удалось синхронизировать: ${drain.lastError}';
  }

  // --- взятие задачи из пула подразделения (#36836) ---

  /// Проигранная гонка за задачу — с именем и временем того, кто успел. Показывается
  /// полосой на списке и главной до явного закрытия: перестановка строки в «взяты
  /// коллегами» не должна быть тихой. Хранится одно, последнее: конфликт — редкость,
  /// и очередь из них — уже не сообщение, а журнал.
  String? takeNotice;

  /// Кого полоса называет держателем и по какой задаче — этим обновление списка может
  /// её опровергнуть ([_settleTakeNotice]). Null — держателя у сообщения нет (отказ
  /// подписки, отказ без имени): опровергать нечем, гаснет только крестиком.
  TakeHolder? _takeNoticeOf;

  void _setTakeNotice(String? text, [TakeHolder? of]) {
    takeNotice = text;
    _takeNoticeOf = of;
  }

  void dismissTakeNotice() {
    _setTakeNotice(null);
    notifyListeners();
  }

  /// Полоса гаснет адресно: свежая выдача показала, что задачу держит уже не тот, о ком
  /// полоса, или задачи в выдаче больше нет — «Свободные — 1» и «уже взял Петров» на
  /// одном экране быть не должно. Пока сервер держателя подтверждает, полоса висит до
  /// крестика: ручное и фоновое обновление идут одним путём, и сообщение о своём
  /// нажатии не исчезает, пока оно верно.
  void _settleTakeNotice(TakeHolder of, List<Task> fetched) {
    for (final t in fetched) {
      if (t.id != of.taskId) continue;
      if (t.takenById == of.holderId) return;
      break;
    }
    _setTakeNotice(null);
  }

  /// Взять задачу на себя — см. [TakeSync.take].
  Future<void> takeTask(String taskId) => _takes.take(taskId);

  /// Снять с себя — см. [TakeSync.release].
  Future<void> releaseTask(String taskId) => _takes.release(taskId);

  /// Дренаж очереди взятий; «await вернулся» — попытка отправки состоялась.
  Future<void> syncTakes() => _takes.sync();

  // --- подписка на задачу (#37136) ---

  /// «Следить» — см. [WatchSync.follow].
  Future<void> followTask(String taskId) => _watches.follow(taskId);

  /// «Не следить» — см. [WatchSync.unfollow].
  Future<void> unfollowTask(String taskId) => _watches.unfollow(taskId);

  /// Дренаж очереди подписок.
  Future<void> syncWatches() => _watches.sync();

  // --- решение по сданной задаче (#37158) ---

  /// Принять результат — см. [DecisionSync.accept].
  Future<void> acceptTask(String taskId) => _decisions.accept(taskId);

  /// Вернуть на доработку с причиной — см. [DecisionSync.giveBack].
  Future<void> returnTask(String taskId, String reason) =>
      _decisions.giveBack(taskId, reason);

  /// Дренаж очереди решений.
  Future<void> syncDecisions() => _decisions.sync();

  // --- снимки задачи (#36914) ---

  /// Снимки этой задачи, ещё не уехавшие: карточка рисует их рядом с приехавшими,
  /// с пометкой «ожидает отправки». Пусто, если базы нет (сессия закрылась).
  Future<List<({String clientId, String path})>> pendingTaskPhotos(
      String taskId) async {
    final db = base.db;
    if (db == null) return const [];
    try {
      return [
        for (final r in await db.queues.getTaskFileOutbox(taskId))
          (clientId: r['clientId'] as String, path: r['path'] as String)
      ];
    } catch (_) {
      // база закрылась под чтением (выход из аккаунта, смена сервера) — карточке
      // это уже неинтересно, она сейчас исчезнет вместе с сессией
      return const [];
    }
  }

  /// Приложить снимок к существующей задаче — без комментария: строка в очередь
  /// (мгновенно и офлайн-безопасно), кадр виден на карточке в том же кадре, отправка —
  /// следом. Задача, ещё не уехавшая сама, кадру не помеха: очередь адресуется её
  /// UUID'ом, а дренаж держит порядок «создание → снимки».
  Future<void> attachTaskPhoto(String taskId, String photoPath) async {
    final db = base.db;
    if (db == null) return;
    await TaskFilesController.attach(db, taskId, photoPath);
    notifyListeners();
    unawaited(pushLocalTasks?.call());
  }

  /// Убрать снимок, который ещё не уехал (передумал до отправки): строка из очереди и
  /// файл с диска — на сервере он не появится и места в телефоне не займёт.
  Future<void> discardTaskPhoto(String clientId) async {
    final db = base.db;
    if (db == null) return;
    await TaskFilesController.discard(db, clientId);
    notifyListeners();
  }

  // --- задачи, рождённые на телефоне (#36716) ---

  /// UUID v4 — ключ клиента для задачи, создаваемой на месте (генератор общий с
  /// сообщениями ленты, см. data/client_id.dart).
  static String newClientId() => ids.newClientId();

  static String _isoDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// Родить задачу прямо в магазине — целиком локально, сети здесь нет и не ждут:
  /// строка в списке, тело apiCreateTask в очереди, а для бланочного пресета — ещё
  /// отложенный старт и бланк, посеянный из предзагруженного шаблона, чтобы экран
  /// заполнения открылся немедленно. Возвращает UUID задачи: им она адресуется всю
  /// жизнь, даже после того как сервер выдаст ей ST-номер.
  ///
  /// Кадры автора (#36914) копируются в каталог файлов этого пользователя и ложатся
  /// в очередь снимков той же транзакцией, что и сама задача; уезжают они СЛЕДОМ за
  /// apiCreateTask, своей ручкой и каждый со своим ключом идемпотентности. Исходные
  /// файлы из галереи/камеры не трогаем — они живут в кэше приложения.
  /// Параметры задачи, а не пресет: этим же путём создаётся задача, собранная AI
  /// (#AI-1), а у неё пресета нет и быть не может. Всё, что раньше бралось из пресета,
  /// вызывающий передаёт явно — типом, бланком, приоритетом и требованием фото.
  ///
  /// [clientId] задаётся только когда ключ уже родился раньше: у AI это ключ разговора,
  /// по которому сервер связывает созданную задачу с запросом. Обычное создание ключ
  /// минтит само.
  ///
  /// [startFilling] — открывать ли бланк сразу: внезапная проверка так и делается, а
  /// поручение, собранное AI, уходит в чужой список, и заполнять там нечего.
  ///
  /// [template] — шаблон под [templateCode] из предзагруженного кэша, если он там есть:
  /// им сеется форма, чтобы экран заполнения открылся офлайн. Его отсутствие не
  /// отменяет сам бланк у задачи: код всё равно уезжает на сервер, и с ближайшей
  /// синхронизацией форма приедет. Кэш пресетов держит HomeController, поэтому шаблон
  /// приходит параметром, а не ищется здесь.
  Future<String> createTask({
    required String typeId,
    required String objectId,
    required String name,
    String? templateCode,
    PresetTemplate? template,
    String? priorityId,
    bool requirePhoto = false,
    // вид выполнения — с сервера (#36872), и параметром, а не из пресета: у задачи,
    // собранной AI, пресета нет. Не задан — Task.opensFill падает на прежний список
    // типов, ровно то поведение, что было до #36872.
    String? executionKind,
    String? objectName,
    String? objectAddress,
    DateTime? deadline,
    String? description,
    List<String> photoPaths = const [],
    String? assigneeId,
    String? assigneeName,
    String? quickActionCode,
    String? clientId,
    bool startFilling = true,

    /// Приёмка из пресета — код AcceptancePolicy как его отдал apiQuickActions.
    String? acceptance,

    /// Исполнителя выбирает сервер по правилам назначения (пресет «По правилу», AI-черновик
    /// без исполнителя); [assigneeId] при этом не задают. Правила нет — задача создателю.
    bool assignByRule = false,

    /// Сообщение чата, из которого родилась задача (#37441): в теле создания как
    /// messageId — по нему сервер связывает задачу с сообщением и отвечает в чат.
    int? messageId,
  }) async {
    final db = this.db;
    final uuid = clientId ?? newClientId();
    final now = DateTime.now();
    final fillNow = startFilling && template != null;
    // Редакция, по которой бланк заполняют прямо сейчас (#37175), — номер из того же
    // кэша apiTemplates, которым бланк засеян. Без него сервер создаст задачу на
    // текущей редакции, а до синхронизации может выйти новая — и ответы по убранным
    // полям пропадут. Номер ложится в тело очереди сейчас, а не при отправке: к
    // отправке кэш уже может приехать новой редакцией. Поручение из AI-черновика
    // заполнят потом, и правильно — по текущей; сервер без редакций номера не отдаёт.
    final templateVersion = fillNow ? template.version : null;

    final payload = <String, dynamic>{
      'clientId': uuid,
      'typeId': typeId,
      'objectId': objectId,
      'name': name,
      // дата с телефона, не дата синхронизации: задача, созданная офлайн три дня
      // назад, должна выглядеть созданной три дня назад — от этого считается просрочка
      'created': _isoDate(now),
      if (templateCode != null) 'templateId': templateCode,
      if (templateVersion != null) 'templateVersion': templateVersion,
      if (assigneeId != null) 'assigneeId': assigneeId,
      if (quickActionCode != null) 'quickActionCode': quickActionCode,
      if (messageId != null) 'messageId': messageId,
      if (deadline != null) 'deadline': _isoDate(deadline),
      if (priorityId != null) 'priorityId': priorityId,
      if (description != null && description.isNotEmpty)
        'description': description,
      // задача из сообщения (#37441): без этого признака сервер подставит текст
      // сообщения, а человек очистил предзаполненное поле намеренно
      if (messageId != null && (description == null || description.isEmpty))
        'noDescription': true,
      if (requirePhoto) 'requirePhoto': true,
      if (acceptance != null) 'acceptance': acceptance,
      if (assignByRule) 'assignByRule': true,
    };

    final photos = <String, String>{};
    for (final path in photoPaths) {
      final (clientId, stored) =
          await TaskFilesController.storePhoto(db.userKey, path);
      photos[clientId] = stored;
    }

    // Бланочная задача начинает выполняться этим же жестом — её очередь старта несёт
    // точку момента создания (#36838): человек рождает задачу, стоя у витрины, и это
    // и есть место начала работы, какой бы ни была сеть. Без фикса координаты честно
    // пусты — создание из-за GPS не задерживается дольше [Geo.stampTimeout], не
    // спрашивает разрешения и не блокируется вовсе.
    GeoFix? startFix;
    if (fillNow) {
      final outcome = await geo.locate(stamp: true);
      if (outcome is GeoFix) startFix = outcome;
    }

    final task = Task(
      id: uuid,
      clientId: uuid,
      name: name,
      object: objectName,
      objectId: objectId,
      address: objectAddress,
      typeId: typeId,
      // вид выполнения — с сервера (#36872): без него задача, рождённая в подвале,
      // не открылась бы ничем до первой синхронизации, а именно её и надо выполнить
      // здесь и сейчас
      executionKind: executionKind,
      requirePhoto: requirePhoto ? true : null,
      status: 'Ожидает отправки',
      // по правилу исполнителя назовёт сервер: до синхронизации задача — авторская, но не
      // «моя», в «Поставленных мной»; правила не нашлось — вернётся мне с первым fetch
      assignedTo: assigneeName ??
          (assignByRule
              ? 'по правилу назначения'
              : (session.name.isEmpty ? session.login : session.name)),
      assigneeId: assigneeId ?? (assignByRule ? null : session.performerId),
      // участие (#36844): рождённая мной задача — авторская; назначенная не мне
      // ложится в «Поставленные мной» сразу, не дожидаясь серверных флагов
      authored: true,
      assigned: assigneeId == null
          ? !assignByRule
          : assigneeId == session.performerId,
      deadline: deadline == null ? null : _isoDate(deadline),
      // dueToday/overdue сознательно пусты (#36944): серверной даты у телефона нет и
      // взяться ей неоткуда, поэтому до первой синхронизации срок рождённой здесь
      // задачи читается от даты устройства — тем же откатом, что и у старого сервера
    );

    await db.queues.createLocalTask(
      task,
      payloadJson: jsonEncode(payload),
      photos: photos,
      createdAtIso: now.toIso8601String(),
      queueStart: fillNow,
      startLat: startFix?.latitude,
      startLon: startFix?.longitude,
      seedFieldsJson: template == null ? null : jsonEncode(template.fieldsRaw),
      seedOptionsJson:
          template == null ? null : jsonEncode(template.optionsRaw),
      seedColumnsJson:
          template == null ? null : jsonEncode(template.columnsRaw),
      seedInfoJson: template == null
          ? null
          : jsonEncode({
              'object': objectName,
              'template': template.name ?? template.code,
              'resolutionRequired': template.resolutionRequired,
              'finished': false,
              'total': template.fields.length,
            }),
    );
    await _reload(); // карточка видна в том же кадре — это и есть «сразу в списке»
    unawaited(pushLocalTasks?.call()); // а если сеть есть — уезжает немедленно
    return uuid;
  }
}
