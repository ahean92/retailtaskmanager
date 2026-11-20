import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/fill.dart';
import 'api_client.dart';
import 'client_id.dart';
import 'execution_finish.dart';
import 'fill_cache_store.dart';
import 'fill_shots.dart';
import 'geo.dart';
import 'local_db.dart';
import 'sync/create_sync.dart';
import 'sync/outbox_drain.dart';
import 'unsent.dart';

/// Drives the fill state for one fillable execution (checklist or procedure).
/// Offline-first over the unified engine: typed fields addressed by code, a
/// per-field outbox, a photo outbox and a pending resolution, all synced together.
class FillController extends ChangeNotifier
    with SyncCoalescer, FinishCoalescer {
  final LocalDb db;
  final ApiClient api;
  final String taskId;

  /// Откуда взять координаты момента действия (#36838): первый старт и завершение
  /// уносят на сервер точку, где человек стоял. null — у контроллера нет экрана
  /// (дренаж переподключения): он только дожимает очереди, а в них координаты уже
  /// лежат с момента действия — мерить на дожиме значило бы записать место
  /// появления сети.
  final Geo? geo;

  /// Задача возвращена на доработку, и её последнее выполнение, по выдаче задач, —
  /// сданное (#37158): старт откроет новое (сервер — Execution.restartable). По выдаче, а
  /// не по кэшу бланка: кэш «завершено» не помнит, если ответ на завершение потерялся и
  /// завершение дожал фоновый проход.
  final bool restartHint;

  /// performerId вошедшего из apiCurrentUser — кем решается «этот бланк заполняю не
  /// я» (#37349): executorId заполнения сравнивается с ним, имена не уникальны.
  /// Пустой (дренаж без экрана) read-only не включает — тому контроллеру UI нет.
  final String performerId;

  FillController(
      {required this.db,
      required this.api,
      required this.taskId,
      this.geo,
      this.restartHint = false,
      this.performerId = ''});

  List<FillField> fields = [];

  /// Кандидаты справочника по коду поля-ссылки (#36841): приезжают при загрузке бланка
  /// и кэшируются вместе с ним — «Ознакомлен» заполняют там, где связи может не быть.
  Map<String, List<RefCandidate>> subjectsByField = {};
  FillSummary summary = const FillSummary();
  String? object;
  String? template;
  String? resolution; // effective (local overrides server until synced)
  bool loading = true;
  bool finished = false;
  int pendingCount = 0;
  String? error;

  /// Отправка очередей и вердикт о сети — общая политика, см. [OutboxDrain]; причины
  /// ложатся под `fill:задача`. Замок «одна очередь дренится из одного места» и
  /// слияние повторных syncAll — [SyncCoalescer].
  late final OutboxDrain _sync =
      OutboxDrain(() => db, kind: UnsentKind.fill, taskId: taskId);

  bool get online => _sync.online;
  set online(bool v) => _sync.online = v;
  String? get lastSyncError => _sync.lastError;
  set lastSyncError(String? v) => _sync.lastError = v;

  @override
  String get syncKey => '${UnsentKind.fill}:$taskId';

  int get sectionCount => fields.sectionCount;
  List<FillField> fieldsOfSection(int page) => fields.ofSection(page);
  String sectionTitle(int page) => fields.sectionTitle(page);

  /// Подытог раздела страницы [page] (#36945). Считает сервер, приезжает в
  /// apiExecutionInfo тем же путём, что общий процент (#36782): после ухода
  /// очереди [_refreshSummary] привозит свежие значения и шапка перерисовывается,
  /// офлайн число помечается неактуальным по pendingCount. null — у раздела
  /// оценки нет, строки в шапке нет.
  SectionScore? sectionScore(int page) {
    final idx = fields.sectionIndexes;
    if (page < 0 || page >= idx.length) return null;
    return summary.sections[idx[page]];
  }

  /// Завершённость, подтверждённая сервером (summary — это apiExecutionInfo или его
  /// кэш). Локально-завершённая офлайн проверка (finish ещё в очереди) сюда НЕ
  /// входит: пока сервер не принял всю цепочку, бланк остаётся редактируемым —
  /// отвергнутый на дожиме ответ иначе было бы нечем исправить (ревью #36778).
  bool get confirmedFinished => summary.finished;

  /// Бланк заполняет другой сотрудник (#37349): сервер его записям отвечает 409, и
  /// экран обязан не предлагать правок, а показать, кто держит бланк. По слову
  /// сервера (summary или его кэш) — как confirmedFinished; пустой executorId
  /// (старый сервер, заполнение без исполнителя) бланк не запирает. Офлайн-правки
  /// такого бланка не теряются: очередь дойдёт — и останется в «Не отправлено»
  /// с причиной «Бланк заполняет …».
  bool get filledByOther =>
      summary.executorId != null &&
      performerId.isNotEmpty &&
      summary.executorId != performerId;

  /// Экран только читает: подтверждённо завершённая проверка (#36778) или чужое
  /// заполнение (#37349). Локально-завершённое офлайн сюда НЕ входит — пока сервер
  /// не принял цепочку, бланк редактируем (см. confirmedFinished).
  bool get viewOnly => confirmedFinished || filledByOther;

  int get answeredCount => fields.where((f) => f.answered).length;
  int get totalCount => fields.length;
  int get missingRequired => fields.where((f) => f.missingRequiredValue).length;
  int get missingEvidence => fields.where((f) => f.needsEvidence).length;

  /// Незаполненные обязательные в порядке бланка — маршрут прыжков после отказа
  /// «Завершить». Предикат тот же, что у первого отказа в finish(), поэтому
  /// маршрут не может привести к полю, за которое отказ не приходит.
  List<FillField> get missingRequiredFields =>
      fields.where((f) => f.missingRequiredValue).toList(growable: false);

  /// Страница раздела, где живёт поле, — прыжок листает пейджер к ней.
  int pageOfField(String fieldCode) => fields.pageOfField(fieldCode);

  /// Бланк загружен, и в нём есть что завершать — по нему экран гасит «Завершить».
  /// Пока ответ сервера в пути, на экране кэш, и проверки обязательных шли бы по
  /// нему; без полей — по пустому списку, где им нечего найти, и кнопка закрывала
  /// бы бланк, которого человек не видел.
  bool get ready => !loading && fields.isNotEmpty;
  bool get resolutionRequired => summary.resolutionRequired;
  bool get canFinish =>
      missingRequired == 0 &&
      missingEvidence == 0 &&
      (!resolutionRequired || resolution != null);

  Future<void> load() async {
    loading = true;
    notifyListeners();
    final startedOnServer = await _loadFromCache();
    // Перевыполнение после возврата (#37158): старт зовётся, что бы ни помнил кэш, —
    // новое выполнение заведёт сервер (Execution.restartable), а если оно уже есть,
    // вызов пустой.
    final restart = restartHint;
    final cachedDate = summary.date;
    final failure = await _sync.attempt(() async {
      // A task born on this phone must not be started before it is created: while its
      // own creation/start are still queued, syncAll below performs both in their
      // order. Only a task the server already knows gets the plain direct start — and
      // never a finished one: the server refuses to shadow a completed filling with a
      // fresh empty one, so the call would be a wasted round trip.
      //
      // Непустой кэш с датой заполнения и это не перевыполнение — старт
      // пропускается: заполнение на сервере уже заведено, и повторный вызов был
      // бы гарантированным no-op — круг ради круга. Пустая или бездатая строка
      // кэша такого доказательства не даёт (карточка задачи раньше писала и
      // ответы без полей): бланк стартует и перезаписывает её. Первый вход без
      // кэша и возврат с приёмки стартуют по-прежнему.
      if ((!finished || restart) &&
          (!startedOnServer || restart) &&
          !await db.queues.lifecyclePending(taskId)) {
        // Блок достижим, когда кэш не доказывает заведённого выполнения, или при
        // перевыполнении — обычно этот вызов и создаёт выполнение, и координаты места
        // должны уехать в нём (#36838). Сервер пишет их только при создании, поэтому
        // на открытиях с доказанным выполнением геопозицию не меряем: жгла бы батарею
        // и ждала фикса ради значений, которые всё равно не запишутся. Один пустой
        // вызов с замером — у задачи, созданной на телефоне: её засеянный кэш без
        // даты, а старт мог уехать фоном; ответ ниже кладёт кэш уже с датой.
        final stamp = await stampNow(geo);
        await api.startExecution(
            taskId, lat: stamp.lat, lon: stamp.lon, at: stamp.at);
      }
      // Push what the last visit left unsent before reading anything back, so the
      // answers and the score below describe the same state. Reading first would
      // both show a filling the server hasn't been told about and freeze its score
      // one opening behind. Its own summary refresh is skipped — the load fetches
      // `info` a few lines down anyway.
      await syncAll(refreshSummary: false);
      // Агрегат: шапка, поля, варианты, колонки, строки и кандидаты каналов — ОДИН
      // запрос вместо пяти с погоней кандидатов поле за полем; бланк применяется
      // одним снимком. Кандидаты (#36841, #36943) — первый эшелон, доступный на
      // объекте: офлайн-выбор собирается из этого кэша, «показать все» без связи не
      // работает и работать не может.
      final bundle = await api.fetchExecutionBundle(taskId, subjects: true);
      final info =
          (bundle?['info'] as Map?)?.cast<String, dynamic>() ?? const {};
      final fieldsRaw =
          ((bundle?['fields'] as List?) ?? const []).cast<dynamic>();
      // Ответ без полей — «выполнения нет» (6.2 так отвечает по задаче без
      // заполнения): о бланке он ничего не говорит, и кэш с полями не
      // перезаписывается пустым (как refreshHome отбрасывает такой ответ).
      // Кэша не было — поля так и пусты, экран честно скажет «Полей нет».
      if (fieldsRaw.isNotEmpty) {
        final optionsRaw =
            ((bundle?['options'] as List?) ?? const []).cast<dynamic>();
        final columnsRaw =
            ((bundle?['columns'] as List?) ?? const []).cast<dynamic>();
        final rowsRaw =
            ((bundle?['rows'] as List?) ?? const []).cast<dynamic>();
        final subjectsRaw = <String, List<Map<String, dynamic>>>{};
        for (final j in (bundle?['subjects'] as List?) ?? const []) {
          final m = (j as Map).cast<String, dynamic>();
          final code = m['fieldCode']?.toString() ?? '';
          if (code.isNotEmpty) {
            subjectsRaw.putIfAbsent(code, () => []).add(m);
          }
        }
        summary = FillSummary.fromJson(info);
        // Ответ назвал не тот бланк, что помнит кэш, — сервер завёл новое выполнение
        // (перевыполнение после возврата): снимки прежнего, уехавшие с этого телефона,
        // ему не принадлежат, и без этого показались бы кадрами нового. Кэш без даты
        // (засеянный из шаблона офлайн) ни о каком бланке не говорит — его не трогаем.
        if (cachedDate != null &&
            summary.date != null &&
            summary.date != cachedDate) {
          await _shots.dropSent();
        }
        object = summary.object;
        template = summary.template;
        resolution = summary.resolution;
        await FillCacheStore(db).saveBundle(taskId,
            fields: fieldsRaw,
            options: optionsRaw,
            info: info,
            columns: columnsRaw,
            rows: rowsRaw,
            subjects: subjectsRaw);
        fields = assembleFillFields(fieldsRaw, optionsRaw, columnsRaw, rowsRaw);
        subjectsByField = {
          for (final e in subjectsRaw.entries)
            e.key: e.value.map(RefCandidate.fromJson).toList()
        };
        finished = summary.finished;
      }
      await _overlayOutbox();
    });
    if (failure != null && fields.isEmpty) {
      // отказ сервера — его словами (сеть жива); обрыв связи — про кэш, которого нет;
      // ответ, который бланк не разобрал, — ни то ни другое (loadFailureText)
      error = loadFailureText(failure,
          offline: 'Нет данных офлайн — откройте задачу один раз при связи');
    }
    loading = false;
    // экран мог закрыться, не дождавшись загрузки, — как в syncAll: уведомлять
    // уже некого, а notifyListeners по disposed роняет приложение
    if (!disposed) notifyListeners();
  }

  /// Возвращает, доказывает ли кэш, что заполнение на сервере уже заведено:
  /// непустой бланк с датой заполнения. Голой строки кэша для этого мало —
  /// карточка задачи раньше писала и ответы без полей, а кэш без даты
  /// (засеянный из шаблона офлайн) ни о каком бланке не говорит. Отсутствие
  /// доказательства — признак самого первого открытия бланка, единственного,
  /// на котором меряется точка начала работы (см. [load]).
  Future<bool> _loadFromCache() async {
    final c = await db.fill.getFillCache(taskId);
    if (c == null) return false;
    try {
      final fieldsRaw =
          (jsonDecode(c['fieldsJson'] as String) as List).cast<dynamic>();
      final optionsRaw =
          (jsonDecode(c['optionsJson'] as String) as List).cast<dynamic>();
      final info =
          (jsonDecode(c['infoJson'] as String) as Map).cast<String, dynamic>();
      final columnsRaw =
          jsonDecode((c['columnsJson'] as String?) ?? '[]') as List;
      final rowsRaw = jsonDecode((c['rowsJson'] as String?) ?? '[]') as List;
      summary = FillSummary.fromJson(info);
      object = summary.object;
      template = summary.template;
      resolution = summary.resolution;
      fields = assembleFillFields(fieldsRaw, optionsRaw, columnsRaw, rowsRaw);
      final subjects =
          (jsonDecode((c['subjectsJson'] as String?) ?? '{}') as Map)
              .cast<String, dynamic>();
      subjectsByField = {
        for (final e in subjects.entries)
          e.key: [
            for (final j in (e.value as List))
              RefCandidate.fromJson((j as Map).cast<String, dynamic>())
          ]
      };
      finished = summary.finished;
      await _overlayOutbox();
      return fields.isNotEmpty && summary.date != null;
    } catch (_) {
      // Нечитаемый кэш — считаем, что его нет (как FillShots._forgetInCache):
      // загрузка пойдёт на сервер и перепишет строку целиком, а не роняет
      // экран вечной загрузкой.
      fields = const [];
      subjectsByField = const {};
      return false;
    }
  }

  Future<void> _overlayOutbox() async {
    // Значения — общим наложением с карточкой задачи (overlayOutbox): один код
    // на оба экрана, чтобы счётчик «Заполнение N из M» не разъехался с бланком.
    // Снимки сюда не входят — их собирает ниже [FillShots.rebuild] по своей логике
    // (сверка серверных индексов), а не простым списком очереди.
    overlayOutbox(
      fields,
      fieldOutbox: await db.fill.getFieldOutbox(taskId),
      rowOutbox: await db.fill.getRowOutbox(taskId),
      cellOutbox: await db.fill.getCellOutbox(taskId),
    );
    await _shots.rebuild();
    final pendingRes = await db.fill.getResolutionOutbox(taskId);
    if (pendingRes != null) resolution = pendingRes;
    // завершение, сделанное офлайн, живёт в очереди, а не в кэше сервера: без этого
    // переоткрытый бланк выглядел бы незавершённым, противореча списку
    if (!finished && await db.queues.hasFinish(taskId)) finished = true;
    await _refreshPending();
  }

  /// Содержимое бланка, ещё не ушедшее на сервер. Единственный подсчёт этой суммы:
  /// её же читает гвард finish-шага — новая очередь, добавленная сюда, автоматически
  /// начнёт удерживать finish, вместо того чтобы быть забытой в инлайн-копии.
  Future<int> _bodyQueueCount() async =>
      (await db.fill.getFieldOutbox(taskId)).length +
      (await db.fill.getRowOutbox(taskId)).length +
      (await db.fill.getCellOutbox(taskId)).length +
      (await db.fill.getPendingFillPhotos(taskId)).length +
      (await db.fill.getPhotoDeletes(taskId)).length +
      (await db.fill.getResolutionOutbox(taskId) != null ? 1 : 0);

  Future<void> _refreshPending() async {
    // the task's own lifecycle counts too: a created-offline task with every field
    // synced is still «не отправлено», because the task itself is
    final lifecycle = (await db.queues.getCreateEntry(taskId) != null ? 1 : 0) +
        (await db.queues.hasStart(taskId) ? 1 : 0) +
        (await db.queues.hasFinish(taskId) ? 1 : 0);
    pendingCount = await _bodyQueueCount() + lifecycle;
  }

  Future<void> _enqueue(FillField f) async {
    await db.fill.enqueueField(
      taskId,
      f.code,
      type: f.type,
      optionCode: f.optionCode,
      number: f.number,
      text: f.text,
      boolVal: f.boolValue,
      dateVal: f.date,
      comment: f.comment,
      // у поля-ссылки оба ключа едут всегда, пустыми при очистке: отсутствие ключа
      // сервер читает как «очистить», и недосланное значение стёрло бы выбранное
      refId: f.kind == FillFieldType.objectref ? (f.refId ?? '') : null,
      refName: f.kind == FillFieldType.objectref ? (f.refName ?? '') : null,
      createdAtIso: DateTime.now().toIso8601String(),
    );
    await _refreshPending();
  }

  /// Записи значений, ещё не легшие в очередь. В модели значение появляется сразу,
  /// а в очереди — после записи в базу. Поле отдаёт набранное, когда теряет фокус,
  /// и при «Завершить» это происходит тем же нажатием: [finish] сначала дожидается
  /// этих записей, иначе решал бы по очереди без последнего ответа и отправил бы
  /// завершение раньше него.
  final Set<Future<void>> _writes = {};

  Future<void> _write(Future<void> Function() body) {
    final w = body();
    _writes.add(w);
    w.whenComplete(() => _writes.remove(w)).ignore();
    return w;
  }

  Future<void> _commit(FillField f) => _write(() async {
        await _enqueue(f);
        notifyListeners();
        unawaited(syncAll());
      });

  /// null — ответ снят (повторное нажатие выбранного варианта).
  Future<void> setOption(FillField f, String? code) async {
    f.optionCode = code;
    await _commit(f);
  }

  Future<void> setNumber(FillField f, double? v) async {
    f.number = v;
    await _commit(f);
  }

  Future<void> setText(FillField f, String? v) async {
    f.text = (v == null || v.isEmpty) ? null : v;
    await _commit(f);
  }

  Future<void> setBool(FillField f, bool? v) async {
    f.boolValue = v;
    await _commit(f);
  }

  Future<void> setDate(FillField f, String? iso) async {
    f.date = iso;
    await _commit(f);
  }

  Future<void> setComment(FillField f, String? text) async {
    f.comment = (text == null || text.isEmpty) ? null : text;
    await _commit(f);
  }

  /// Значение поля-ссылки (#36841): выбор кандидата ([id] + его имя-снимок), свободный
  /// ввод ([name] без [id]) или очистка (оба пусты). Имя едет всегда — это снимок на
  /// момент выбора, и акт не меняется, если справочник потом переименуют.
  Future<void> setRef(FillField f, {String? id, String? name}) async {
    f.refId = (id == null || id.isEmpty) ? null : id;
    f.refName = (name == null || name.isEmpty) ? null : name;
    await _commit(f);
  }

  /// Кандидаты для пикера поля-ссылки: при связи — серверный поиск (большие
  /// справочники целиком в кэш не едут), офлайн — фильтр по кэшу бланка.
  Future<List<RefCandidate>> searchSubjects(FillField f, String query) async {
    if (online) {
      try {
        final raw = await api.fetchRowSubjects(taskId, f.code,
            query: query.isEmpty ? null : query);
        return raw.map(RefCandidate.fromJson).toList();
      } catch (_) {
        // обрыв связи не делает пикер пустым — ниже кэш; online поправит ближайший синк
      }
    }
    final cached = subjectsByField[f.code] ?? const <RefCandidate>[];
    if (query.isEmpty) return cached;
    final q = query.toLowerCase();
    return [
      for (final c in cached)
        if (c.name.toLowerCase().contains(q)) c
    ];
  }

  /// Кандидаты предмета строки табличного поля (#36943). Тот же двухэшелонный поиск,
  /// что у поля-ссылки, плюс [allItems]: по умолчанию — доступное на объекте задачи,
  /// «показать все» — весь канал. Офлайн оба эшелона сходятся в один — кэш бланка;
  /// это честно: остатков объекта телефон не знает и притвориться не может.
  ///
  /// Без связи ищется по тем же правилам, что на сервере (#37192): подстрокой по
  /// названию и коду, точно по коду и штрихкоду — кэш возит их вместе с названием, —
  /// и точные совпадения идут первыми.
  Future<List<RefCandidate>> searchRowSubjects(FillField f, String query,
      {bool allItems = false}) async {
    if (online) {
      try {
        final raw = await api.fetchRowSubjects(taskId, f.code,
            query: query.isEmpty ? null : query, all: allItems);
        return raw.map(RefCandidate.fromJson).toList();
      } catch (_) {
        // обрыв связи не делает пикер пустым — ниже кэш
      }
    }
    final cached = subjectsByField[f.code] ?? const <RefCandidate>[];
    return rankSubjects(
        [for (final c in cached) if (c.matchesQuery(query)) c], query);
  }

  /// Добавить строку табличного поля. Ключ строки — uuid этого телефона: он рождается
  /// здесь, живёт в локальной базе и после синхронизации не меняется, поэтому повтор
  /// отправки второй строки не создаёт. [subjectName] уезжает снимком имени; [code]
  /// (#37192) — отсканированный или набранный код, по которому позицию внесли, как
  /// есть: и у найденной в справочнике, и у неизвестной без ссылки.
  ///
  /// Возвращает созданную строку — экрану она нужна, чтобы сразу поставить курсор в
  /// её первую вводимую ячейку.
  Future<FillRowData> addRow(FillField f,
      {String? subjectId, String? subjectName, String? code}) async {
    final key = newClientId();
    final row = FillRowData(
      f.rows.isEmpty ? 1 : f.rows.last.rowIndex + 1,
      rowKey: key,
      subjectId: subjectId,
      subject: subjectName,
      subjectCode: (code == null || code.trim().isEmpty) ? null : code.trim(),
    );
    f.rows.add(row);
    await db.fill.enqueueAddRow(taskId, f.code, key,
        subjectId: subjectId,
        subjectName: subjectName,
        subjectCode: row.subjectCode,
        createdAtIso: DateTime.now().toIso8601String());
    await _refreshPending();
    notifyListeners();
    unawaited(syncAll());
    return row;
  }

  /// Убрать строку. С экрана она уходит сразу — и не возвращается после
  /// синхронизации: удаление живёт очередью, как и всё остальное содержимое бланка.
  Future<void> deleteRow(FillField f, FillRowData row) async {
    f.rows.remove(row);
    await db.fill.enqueueDeleteRow(taskId, f.code, row.rowKey,
        createdAtIso: DateTime.now().toIso8601String());
    await _refreshPending();
    notifyListeners();
    unawaited(syncAll());
  }

  /// Set a numeric cell of a table field.
  Future<void> setCellNumber(
      FillField f, FillRowData row, FillColumn col, double? v) {
    row.numbers[col.code] = v;
    return _write(() async {
      await db.fill.enqueueCell(taskId, f.code, row.rowKey, col.code,
          number: v, createdAtIso: DateTime.now().toIso8601String());
      await _refreshPending();
      notifyListeners();
      unawaited(syncAll());
    });
  }

  /// Текстовая ячейка или ячейка-дата (дата — строкой ГГГГ-ММ-ДД). Пустое значение —
  /// очистка: в очередь уходит пустая строка, сервер ставит ячейке NULL.
  Future<void> setCellText(
      FillField f, FillRowData row, FillColumn col, String? v) {
    final value = (v == null || v.isEmpty) ? null : v;
    row.texts[col.code] = value;
    return _write(() async {
      await db.fill.enqueueCell(taskId, f.code, row.rowKey, col.code,
          text: value ?? '', createdAtIso: DateTime.now().toIso8601String());
      await _refreshPending();
      notifyListeners();
      unawaited(syncAll());
    });
  }

  /// Колонка табличного поля по кодам — чтобы очередь ячеек, где лежат только число и
  /// текст, отправляла дату ключом date. Нет колонки (бланк ещё не загружен) — уедет
  /// текстом, сервер примет и так.
  FillColumn? _columnOf(String fieldCode, String colCode) {
    for (final f in fields) {
      if (f.code != fieldCode) continue;
      for (final c in f.columns) {
        if (c.code == colCode) return c;
      }
    }
    return null;
  }

  Future<void> setResolution(String code) async {
    resolution = code;
    await db.fill.setResolutionOutbox(
        taskId, code, DateTime.now().toIso8601String());
    await _refreshPending();
    notifyListeners();
    unawaited(syncAll());
  }

  // --- photos (0..N per field) — галерея в [FillShots] ---

  late final FillShots _shots = FillShots(
      db: db,
      api: api,
      taskId: taskId,
      fields: () => fields,
      photoDirectory: () => photoDirectory(db.userKey),
      serverPhotoDirectory: () => serverPhotoDirectory(db.userKey));

  /// Appends a shot — see [FillShots.add].
  Future<void> addPhoto(FillField f, String sourcePath) async {
    await _shots.add(f, sourcePath);
    await _refreshPending();
    notifyListeners();
    unawaited(syncAll());
  }

  /// Убрать ОДИН кадр пункта (#36946) — см. [FillShots.delete].
  Future<void> deleteShot(FillField f, FillShot shot) async {
    if (!shot.canDelete) return;
    await _shots.delete(f, shot);
    await _refreshPending();
    notifyListeners();
    unawaited(syncAll());
  }

  /// Removes every photo of a field — see [FillShots.clear].
  Future<void> clearPhotos(FillField f) async {
    await _shots.clear(f);
    await _refreshPending();
    notifyListeners();
    unawaited(syncAll());
  }

  /// Кадр, которого на этом устройстве нет, — с сервера, на время экрана
  /// ([FillShots.serverFile]).
  Future<File?> serverPhotoFile(FillField f, int index,
          {required bool thumb}) =>
      _shots.serverFile(f, index, thumb: thumb);

  /// Кадр удалён или его байты не декодировались — оба размера с диска долой.
  Future<void> evictServerPhoto(FillField f, int index) =>
      _shots.evictServer(f, index);

  /// Where one person's evidence photos live: a subdirectory per user, keyed exactly as
  /// their base is (see [LocalDb.keyFor]). The file name inside is made of the task and
  /// the field, so two people sent to the same task on the same phone would otherwise be
  /// overwriting each other's evidence.
  ///
  /// Static because the directory outlives the controller: signing out with a wipe has to
  /// remove it when no task screen is open to ask.
  static Future<Directory> photoDirectory(String userKey) async {
    final dir = await getApplicationDocumentsDirectory();
    return Directory(p.join(dir.path, 'fill_photos', userKey));
  }

  /// Скачанные на время экрана снимки с сервера — бланка и поручения: временный
  /// каталог, который система вправе чистить сама. Свой на пользователя, как и
  /// [photoDirectory].
  static Future<Directory> serverPhotoDirectory(String userKey) async {
    final dir = await getTemporaryDirectory();
    return Directory(p.join(dir.path, 'srv_photos', userKey));
  }

  /// Remove one person's photos — the file half of «выйти и удалить данные»; the rows that
  /// point at these files go with the base itself. Nothing outside their own directory is
  /// touched.
  static Future<void> deletePhotos(String userKey) async {
    for (final dir in [
      await photoDirectory(userKey),
      await serverPhotoDirectory(userKey),
    ]) {
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  }

  /// Re-reads `apiExecutionInfo` and the cache behind it. The score, verdict and
  /// outcome are computed only on the server, so this is the sole way the figure
  /// on screen ever moves; call it whenever the server has seen new state. On
  /// failure the previous summary stays — the next sync or reload catches up.
  Future<void> _refreshSummary() async {
    try {
      final info = await api.fetchExecutionInfo(taskId);
      if (disposed || info == null) return;
      summary = FillSummary.fromJson(info);
      object = summary.object;
      template = summary.template;
      resolution = summary.resolution;
      finished = summary.finished;
      await FillCacheStore(db).saveInfo(taskId, info);
    } catch (_) {}
  }

  /// Дожать очереди этой задачи. Слияние повторных вызовов и замок — в
  /// [SyncCoalescer]; [refreshSummary] — спросить ли после чистого прохода новый
  /// балл (load() читает info следом сам и не просит).
  Future<void> syncAll({bool refreshSummary = true}) =>
      runSync(refresh: refreshSummary);

  @override
  Future<void> afterSync(bool refresh) async {
    await _refreshPending();
    if (pendingCount == 0) lastSyncError = null;
    // The queue is through, so the server has now seen these answers and has
    // rescored the filling: ask it for the new figure instead of waiting for
    // the screen to be opened again.
    if (refresh && pendingCount == 0 && online) await _refreshSummary();
  }

  /// Один проход по очередям: порядок шагов — здесь и только здесь. Что делать с
  /// ответом сервера на каждом шаге, решает [OutboxDrain]: барьеры (создание,
  /// старт) на отказе останавливают цепочку, обычная строка на отказе остаётся в
  /// очереди и пропускается, обрыв связи останавливает всё.
  @override
  Future<void> drainPass() async {
    // 0) the task itself (#36716). An offline-born task goes up FIRST, and nothing
    // else of it goes until it is through: a field sent ahead of its task answers
    // «Filling not found» — so the order is written here, not hoped for. The server
    // refusing the task (an ApiException, not a lost network) blocks the chain the
    // same way: fields of a task that does not exist have nowhere to go.
    if (!await TaskCreateSync.push(db, api, taskId, via: _sync)) return;

    // 0b) the queued start — right behind creation, ahead of every answer: the
    // answers land in the Filling this start creates. Its lat/lon/createdAt travel
    // from the queue row: they were taken when the work began, and taking them here
    // would stamp the task with wherever the network came back (#36838).
    final startEntry = await db.queues.getStartEntry(taskId);
    if (startEntry != null) {
      final started = await _sync.one(() async {
        await api.startExecution(taskId,
            lat: (startEntry['lat'] as num?)?.toDouble(),
            lon: (startEntry['lon'] as num?)?.toDouble(),
            at: wireAt(startEntry['createdAt'] as String));
        await db.queues.dequeueStart(taskId);
      });
      if (started != SendOutcome.sent) return;
    }

    // 1) field values
    if (!await _sync.each(await db.fill.getFieldOutbox(taskId), (e) async {
      final code = e['fieldCode'] as String;
      final b = e['boolVal'] as int?;
      await api.setField(
        taskId,
        code,
        optionCode: e['optionCode'] as String?,
        number: (e['number'] as num?)?.toDouble(),
        text: e['text'] as String?,
        boolVal: b == null ? null : b != 0,
        date: e['dateVal'] as String?,
        comment: e['comment'] as String?,
        refId: e['refId'] as String?,
        refName: e['refName'] as String?,
      );
      await db.fill
          .dequeueField(taskId, code, createdAt: e['createdAt'] as String);
    })) {
      return;
    }

    // 1b) созданные строки — ДО их ячеек (#36943)
    //
    // Сервер завёл бы строку и по правке ячейки (upsert по ключу), но тогда она
    // приехала бы без предмета: имя товара живёт в apiAddRow, а не в apiSetCell.
    // Удаления идут отдельным проходом ниже — строка, созданная и удалённая в одном
    // самолётном перегоне, из очереди ушла ещё на телефоне и сюда не попадает.
    if (!await _sync.each(
        [for (final e in await db.fill.getRowOutbox(taskId)) if (e['op'] == 'add') e],
        (e) async {
      final fc = e['fieldCode'] as String;
      final key = e['rowKey'] as String;
      await api.addRow(taskId, fc, key,
          subjectId: e['subjectId'] as String?,
          subjectName: e['subjectName'] as String?,
          code: e['subjectCode'] as String?);
      if (await db.fill.dequeueRow(taskId, fc, key,
              createdAt: e['createdAt'] as String) ==
          0) {
        // Строку убрали, пока её создание ехало: удаление сочло его неотправленным и
        // просто сняло, а на сервере строка уже есть — удалить её там (шаг 1d)
        await db.fill.enqueueDeleteRow(taskId, fc, key,
            createdAtIso: DateTime.now().toIso8601String());
      }
    })) {
      return;
    }

    // 1c) table cells
    if (!await _sync.each(await db.fill.getCellOutbox(taskId), (e) async {
      final fc = e['fieldCode'] as String;
      final key = e['rowKey'] as String;
      final col = e['colCode'] as String;
      final text = e['text'] as String?;
      final asDate =
          text != null && text.isNotEmpty && (_columnOf(fc, col)?.isDate ?? false);
      await api.setCell(taskId, fc, key, col,
          number: (e['number'] as num?)?.toDouble(),
          text: asDate ? null : text,
          date: asDate ? text : null);
      await db.fill.dequeueCell(taskId, fc, key, col,
          createdAt: e['createdAt'] as String);
    })) {
      return;
    }

    // 1d) удалённые строки — ПОСЛЕ ячеек: правка, поставленная в очередь до
    // удаления, уже снята вместе с ним (enqueueDeleteRow), а порядок «сначала всё,
    // что строку наполняет, потом её удаление» оставляет очередь одинаковой и при
    // повторной отправке. Повтор удаления уже удалённой строки сервер принимает.
    if (!await _sync.each(
        [for (final e in await db.fill.getRowOutbox(taskId)) if (e['op'] == 'delete') e],
        (e) async {
      final fc = e['fieldCode'] as String;
      final key = e['rowKey'] as String;
      await api.deleteRow(taskId, fc, key);
      await db.fill
          .dequeueRow(taskId, fc, key, createdAt: e['createdAt'] as String);
    })) {
      return;
    }

    // 2) resolution
    final res = await db.fill.getResolutionEntry(taskId);
    if (res != null &&
        !await _sync.each([res], (r) async {
          await api.setResolution(taskId, r['resolution'] as String);
          await db.fill.clearResolutionOutbox(taskId,
              createdAt: r['createdAt'] as String);
        })) {
      return;
    }

    // 3) photos
    if (!await _sync.each(await db.fill.getPendingFillPhotos(taskId), (e) async {
      final code = e['fieldCode'] as String;
      final idx = e['idx'] as int? ?? 0;
      final path = e['path'] as String?;
      String? b64;
      if (path != null) b64 = base64Encode(await File(path).readAsBytes());
      // the server appends, so each queued shot becomes its own photo there; a
      // retried shot goes by its client key and is not appended twice (#37348),
      // rows from the old queue go without a key, as before
      await api.setFieldPhoto(taskId, code, b64,
          clientId: e['clientId'] as String?);
      if (path == null) {
        await db.fill.deleteFillPhoto(taskId, code, idx);
        _shots.clearedOnServer(code);
      } else {
        final serverIdx = await _shots.nextIndexOnServer(code);
        if (await db.fill.markFillPhotoUploaded(taskId, code, idx,
                serverIdx: serverIdx) ==
            0) {
          // Кадр убрали, пока он ехал: удаление сочло его неотправленным и стёрло
          // строку, а на сервере он уже лёг — удалить его там по индексу (шаг 3b)
          await db.fill.enqueuePhotoDelete(
              taskId, code, serverIdx, DateTime.now().toIso8601String());
        }
        await _shots.rebuild();
      }
    }, onFileError: (e, ex) async {
      // файл честно пропал (очищенное хранилище) — держать строку вечно незачем
      lastSyncError = 'Файл фото недоступен: ${ex.message}';
      await db.fill.deleteFillPhoto(
          taskId, e['fieldCode'] as String, e['idx'] as int? ?? 0);
    })) {
      return;
    }

    // 3b) удаления отдельных кадров (#36946) — ПОСЛЕ загрузок, а не до: сервер
    // нумерует новый снимок как «максимум + 1», и удаление, обогнавшее отправку,
    // освободило бы номер, который отправитель уже посчитал своим. Повторная
    // отправка по уже удалённому индексу ошибкой не отвечает — сервер её глотает,
    // так что застрявшая очередь дожимается без особых случаев.
    if (!await _sync.each(await db.fill.getPhotoDeletes(taskId), (e) async {
      final code = e['fieldCode'] as String;
      final serverIdx = e['serverIdx'] as int;
      await api.deleteFieldPhoto(taskId, code, serverIdx);
      await db.fill.dequeuePhotoDelete(taskId, code, serverIdx);
    })) {
      return;
    }

    // 4) the queued finish (#36716) — strictly last, and only over empty queues:
    // the server validates the filling as a whole, and a finish overtaking a
    // photo would close a half-filled check. Unlike the barrier steps above, a
    // failure here does not stop anything — this is the pass's last step anyway.
    // lat/lon/createdAt — из строки очереди, по той же причине, что у шага 0b.
    final finishEntry = await db.queues.getFinishEntry(taskId);
    if (finishEntry != null && await _bodyQueueCount() == 0) {
      await _sync.one(() async {
        await api.finishExecution(taskId,
            lat: (finishEntry['lat'] as num?)?.toDouble(),
            lon: (finishEntry['lon'] as num?)?.toDouble(),
            at: wireAt(finishEntry['createdAt'] as String));
        await db.queues.dequeueFinish(taskId);
        finished = true;
      });
    }
  }

  /// «Завершить»: повторные нажатия сливает [FinishCoalescer].
  @override
  Future<bool> finishOnce() async {
    error = null;
    // ответ, отданный полем этим же нажатием, ещё пишется в очередь: сначала он,
    // потом проверки и отправка (см. [_writes])
    while (_writes.isNotEmpty) {
      await Future.wait([for (final w in _writes) w.catchError((_) {})]);
    }
    if (missingRequired > 0) {
      error = 'Заполните обязательные поля ($missingRequired)';
      notifyListeners();
      return false;
    }
    if (missingEvidence > 0) {
      error = 'Добавьте фото/комментарий по несоответствиям';
      notifyListeners();
      return false;
    }
    if (resolutionRequired && resolution == null) {
      error = 'Укажите исход';
      notifyListeners();
      return false;
    }
    // Момент нажатия «Завершить» — момент завершения работы: точка снимается здесь,
    // до всякой отправки, и дальше едет с завершением — очередью или прямым вызовом
    // (#36838). После валидаций: отказ «заполните обязательные» GPS не трогает.
    final stamp = await stampNow(geo);
    Future<void> enqueue() =>
        db.queues.enqueueFinish(taskId, stamp.at, lat: stamp.lat, lon: stamp.lon);
    // A task born on this phone whose creation or start is still queued cannot be
    // finished directly: the server must see create → start → answers → finish in
    // that order, whatever the network does. The finish is queued as the chain's last
    // step; the syncAll right here uses the network if there is one, and the
    // reconnect drain picks the chain up otherwise (#36716). A finish already sitting
    // in the queue (a drain died between start and finish) takes this branch too —
    // the direct call below would send it a second time on top of step 4. A non-empty
    // body — unsent answers or photos — queues the finish the same way (#37517),
    // symmetric to simple execution: without network the check closes locally and
    // goes up with the first connection, and the drain keeps finish strictly last,
    // only over empty queues, so the server never sees it ahead of the answers.
    if (await db.queues.lifecyclePending(taskId) ||
        await db.queues.hasFinish(taskId) ||
        pendingCount > 0) {
      switch (await finishViaQueue(
          drain: _sync,
          enqueue: enqueue,
          sync: () => syncAll(refreshSummary: false),
          stillQueued: () => db.queues.hasFinish(taskId),
          dequeue: () => db.queues.dequeueFinish(taskId))) {
        case FinishOutcome.accepted:
          finished = true;
          await _refreshSummary();
          notifyListeners();
          return true;
        case FinishOutcome.queuedOffline:
          finished = true;
          notifyListeners();
          return true;
        case FinishOutcome.refused:
          await _refreshPending();
          error = lastSyncError != null
              ? 'Не синхронизировано: $lastSyncError'
              : 'Не удалось завершить';
          notifyListeners();
          return false;
      }
    }
    await syncAll(refreshSummary: false);
    if (pendingCount > 0) {
      // сюда ведёт только гонка: тело было пусто при проверке выше и пополнилось,
      // пока летела синхронизация (человек правил бланк под идущим завершением).
      // Повторный тап уйдёт уже веткой очереди — она теперь честно закрывает бланк
      // с несинхронизированным телом (#37517)
      error = lastSyncError != null
          ? 'Не синхронизировано: $lastSyncError'
          : 'Часть данных не синхронизирована — попробуйте ещё раз';
      notifyListeners();
      return false;
    }
    final direct = await finishDirect(
        drain: _sync,
        call: () => api.finishExecution(taskId,
            lat: stamp.lat, lon: stamp.lon, at: stamp.at),
        enqueue: enqueue);
    switch (direct.outcome) {
      case FinishOutcome.refused:
        // сервер ответил отказом или сбоем — показать причину, а не «завершено»
        error = failureReason(direct.refusal!);
        notifyListeners();
        return false;
      case FinishOutcome.queuedOffline:
        // Связи не стало на самом вызове — завершение ушло в очередь, бланк закрыт на
        // телефоне: без связи он закрывается одинаково при пустой и непустой очереди
        // тела, как и поручение. Точка и время — момента нажатия.
        finished = true;
        await _refreshPending();
        notifyListeners();
        return true;
      case FinishOutcome.accepted:
        finished = true;
        // Finishing is what the verdict and the outcome are computed from, so the
        // completed screen shows the server's word on them, not the pre-finish one.
        await _refreshSummary();
        notifyListeners();
        return true;
    }
  }
}
