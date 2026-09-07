import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/ai_draft.dart';
import '../models/external_app.dart';
import '../models/fill.dart';
import '../models/home.dart';
import '../models/quick_create.dart';
import '../models/task_view.dart';
import 'api_client.dart';
import 'local_db.dart';
import 'location_controller.dart';
import 'session.dart';
import 'settings.dart';
import 'task_repository.dart';
import 'user_base.dart';

/// Главная страница и то, чем человек создаёт задачи: блоки главной и её объект, пресеты
/// создания со справочниками, внешние приложения, разбор списка, постановка задачи
/// текстом. Всё это приезжает с сервера при синхронизации и живёт в базе вошедшего —
/// главная открывается в подвале без сети с вчерашними числами, а не со спиннером.
class HomeController extends ChangeNotifier {
  final ApiClient api;
  final Settings settings;
  final Session session;
  final UserBase base;
  final LocationController location;
  final TaskRepository repo;

  /// Человек выбрал объект главной: строка «прошлая проверка» уже перечитана из кэша,
  /// а из сети её дотянет префетч — кого звать, решает SyncCoordinator.
  Future<void> Function()? onObjectSelected;

  HomeController(
      {required this.api,
      required this.settings,
      required this.session,
      required this.base,
      required this.location,
      required this.repo}) {
    base.onChange(_onBase);
  }

  /// Главная, какой её настроили этому человеку в бэк-офисе; пустая — блока «задачи»
  /// хватит, см. HomeScreen.
  HomeLayout layout = const HomeLayout();

  /// Что этот человек может создать прямо в магазине, вместе со справочниками под это
  /// (шаблоны, исполнители). Пустое — кнопки «создать» нет; наполняется настройкой в
  /// бэк-офисе, без пересборки клиента.
  QuickCreateData quickCreate = const QuickCreateData();

  /// Внешние приложения, настроенные на сервере (#36840). Пустое — секции «Приложения»
  /// на главной нет; наполняется модулем ExternalApp, которого в сборке сервера может
  /// и не быть, — клиент обязан пережить это молча.
  List<ExternalApp> externalApps = const [];

  /// Как этот человек разобрал свой список (#36915) — из его базы, при входе. Экран
  /// «Мои задачи» стартует с этого и записывает каждое изменение через [saveListPrefs];
  /// список, открытый с плитки главной, живёт своим фильтром и сюда не пишет.
  ListPrefs listPrefs = const ListPrefs();

  /// Итог последней завершённой проверки текущего объекта — то, что рисует строка
  /// «Прошлая проверка» на главном. Держится здесь, а не читается виджетом из
  /// sqlite на каждый rebuild: главная перерисовывается каждым notifyListeners
  /// (таймер уведомлений — раз в минуту), и строка не должна дёргать базу и мигать.
  FillSummary? objectPastCheck;

  /// База сменилась: the dashboard is as personal as the tasks under it — it goes with
  /// the base; и набор «что мне разрешено создавать», и внешние приложения — они
  /// отфильтрованы по ролям ушедшего; и разбор списка — следующий раскладывает свой
  /// список сам (#36915). Из новой базы всё это читается обратно: главная, пресеты,
  /// приложения, разбор и строка «прошлая проверка» на главном — из кэша этого же
  /// пользователя, чтобы офлайн-запуск открывался с работающим входом в просмотр.
  Future<void> _onBase(LocalDb? db) async {
    layout = const HomeLayout();
    quickCreate = const QuickCreateData();
    externalApps = const [];
    listPrefs = const ListPrefs();
    if (db == null) {
      objectPastCheck = null;
      return;
    }
    await _loadHome(db);
    await _loadQuickCreate(db);
    await _loadExternalApps(db);
    await _loadListPrefs(db);
    await refreshObjectPastLine();
  }

  /// Pulls the home screen configured for this user. Silent on failure for the same
  /// reason as the brand: the cached layout is a fine answer, and an error banner about
  /// the dashboard must not push the tasks off the screen.
  Future<void> refreshHome() async {
    final db = base.db;
    if (!settings.isConfigured || !session.isActive || db == null) return;
    try {
      final j = await api.fetchHome();
      if (j == null) return;
      final layout = HomeLayout.fromJson(j);
      // An empty answer means "not configured on this server" — keep whatever we had
      // rather than replacing a working home screen with a blank one.
      if (layout.isEmpty) return;
      this.layout = layout;
      await db.cache.saveHome(
          jsonEncode(layout.toJson()), DateTime.now().toIso8601String());
      notifyListeners();
    } catch (_) {
      // offline or an older server without the endpoint — the cached layout stands
    }
  }

  /// Забирает пресеты создания и справочники под них (шаблоны, исполнителей) — три
  /// ручки одним заходом, потому что порознь они бессмысленны: кнопка без бланка не
  /// нарисует форму, бланк без людей не даст выбрать исполнителя.
  ///
  /// Пустой ответ, в отличие от главной, ЗАПИСЫВАЕТСЯ: пресеты выключили в бэк-офисе —
  /// кнопка обязана пропасть при следующей синхронизации. Кэш переживает только ошибку
  /// (офлайн или старый сервер без ручек) — тогда телефон продолжает жить тем, что
  /// успел забрать.
  Future<void> refreshQuickCreate() async {
    final db = base.db;
    if (!settings.isConfigured || !session.isActive || db == null) return;
    try {
      final actions = await api.fetchQuickActionsRaw();
      final templates = await api.fetchTemplatesRaw();
      final performers = await api.fetchPerformersRaw();
      quickCreate = QuickCreateData.parse(actions, templates, performers);
      await db.cache.saveQuickCreate(
          actions, templates, performers, DateTime.now().toIso8601String());
      notifyListeners();
    } catch (_) {
      // офлайн или сервер без ручек — остаётся то, что лежит в кэше
    }
  }

  /// Забирает список внешних приложений (#36840). Семантика ответов расходится с
  /// главной и повторяет пресеты, но с одним отличием — 404:
  ///  - непустой и ПУСТОЙ 200 записываются: приложения выключили в бэк-офисе — секция
  ///    обязана пропасть при следующей синхронизации;
  ///  - 404 тоже записывается пустым: ручки нет — модуль ExternalApp из сборки сервера
  ///    убран, и кэш, показывающий секцию вечно, был бы враньём;
  ///  - прочие ошибки (офлайн, 5xx) оставляют кэш — телефон живёт тем, что успел
  ///    забрать.
  Future<void> refreshExternalApps() async {
    final db = base.db;
    if (!settings.isConfigured || !session.isActive || db == null) return;
    String raw;
    try {
      raw = await api.fetchExternalAppsRaw();
    } on ApiException catch (e) {
      if (e.status != 404) return;
      raw = '';
    } catch (_) {
      return; // офлайн или невнятный отказ — остаётся то, что лежит в кэше
    }
    try {
      externalApps = ExternalApp.parseList(raw);
      await db.cache.saveApps(raw, DateTime.now().toIso8601String());
      notifyListeners();
    } catch (_) {
      // нечитаемое тело — кэш и текущий список не трогаем
    }
  }

  /// Приложения, которые этот человек забрал в прошлый раз, — из его собственной базы:
  /// секция главной работает и в подвале без сети.
  Future<void> _loadExternalApps(LocalDb db) async {
    final cached = await db.cache.getApps();
    if (cached == null) return;
    try {
      externalApps = ExternalApp.parseList(cached);
    } catch (_) {
      // нечитаемый кэш — секция появится после первой удачной синхронизации
    }
  }

  /// Разбор списка, каким этот человек его оставил (#36915), — из его базы.
  Future<void> _loadListPrefs(LocalDb db) async {
    final json = await db.cache.getListPrefs();
    if (json == null || json.isEmpty) return;
    try {
      listPrefs =
          ListPrefs.fromJson((jsonDecode(json) as Map).cast<String, dynamic>());
    } catch (_) {
      // нечитаемая настройка — список открывается как в первый раз
    }
  }

  /// Записать разбор списка (#36915): экран отдаёт сюда каждое изменение, чтобы
  /// перезапуск открыл список таким, каким человек его оставил.
  Future<void> saveListPrefs(ListPrefs p) async {
    listPrefs = p;
    final db = base.db;
    if (db == null) return;
    await db.cache.saveListPrefs(jsonEncode(p.toJson()));
  }

  // --- постановка задачи текстом (#AI-1) ---

  /// Доступен ли AI на этом сервере. Спрашивается вместе с пресетами, потому что это
  /// тот же вопрос — «чем этот человек может создать задачу», — и ответ на него так же
  /// приходит с сервера, а не зашит в сборку.
  ///
  /// Ошибка не гасит уже известное: сервер без этой ручки (сборка постарше) и офлайн
  /// выглядят одинаково, и терять из-за них пункт меню незачем.
  Future<void> refreshAi() async {
    if (!settings.isConfigured || !session.isActive) return;
    try {
      final info = await api.fetchAiInfo();
      if (info.enabled == session.aiEnabled) return;
      session.aiEnabled = info.enabled;
      await session.save();
      notifyListeners();
    } catch (_) {
      // офлайн или старый сервер — остаётся то, что телефон знал в прошлый раз
    }
  }

  /// Спросить AI о задаче. Место и координаты — те же, которыми живёт весь клиент:
  /// по ним сервер понимает «здесь» и подбирает кандидатов рядом.
  Future<AiDraft> aiDraft(String dialogId, String text) => api.aiDraft(
        dialogId,
        text,
        objectId: location.place.objectId ?? objectId,
        lat: location.place.latitude ?? session.latitude,
        lon: location.place.longitude ?? session.longitude,
      );

  /// Шаблон по коду из кэша пресетов — им сеется бланк создаваемой задачи
  /// ([TaskRepository.createTask]); null — кода нет или шаблон не забирали.
  PresetTemplate? templateByCode(String? code) =>
      code == null ? null : quickCreate.templates[code];

  /// Создать задачу по подтверждённому черновику — обычным путём, той же очередью и
  /// той же ручкой apiCreateTask, что и пресет. Ключ задачи — ключ разговора, поэтому
  /// сервер связывает её с AI-запросом сам, и отдельной ручки подтверждения не нужно.
  ///
  /// Бланк здесь не открывается, даже если он у задачи есть: поручение уходит в чужой
  /// список, и заполнять его будет исполнитель, а не автор.
  Future<String> createFromAiDraft(AiDraft draft) => repo.createTask(
        typeId: draft.typeId!,
        objectId: draft.objectId!,
        name: draft.name!.trim(),
        templateCode: draft.templateCode,
        template: templateByCode(draft.templateCode),
        priorityId: draft.priorityId,
        requirePhoto: draft.photoRequired,
        objectName: draft.objectName,
        objectAddress: draft.objectAddress,
        deadline: draft.deadlineDate,
        description: draft.description,
        assigneeId: draft.performerId,
        assigneeName: draft.performerName,
        clientId: draft.dialogId,
        startFilling: false,
      );

  /// Пресеты, которые этот человек забрал в прошлый раз, — из его собственной базы.
  /// Именно этот путь делает «создать проверку в подвале без сети» возможным.
  Future<void> _loadQuickCreate(LocalDb db) async {
    final cached = await db.cache.getQuickCreate();
    if (cached == null) return;
    try {
      quickCreate = QuickCreateData.parse(cached.$1, cached.$2, cached.$3);
    } catch (_) {
      // нечитаемый кэш — кнопка появится после первой удачной синхронизации
    }
  }

  /// The object whose numbers the home screen shows: the person's own choice while it is
  /// still valid, else the shop they are standing at, else the first one the server sent —
  /// a fresh install opens on a shop rather than on empty tiles.
  ///
  /// The located shop outranks the alphabet on purpose: for an account that works by
  /// location the task list is that shop's, and a dashboard defaulting to whichever shop
  /// sorts first would disagree with the list under every tile.
  String? get objectId {
    final saved = settings.objectId;
    if (saved.isNotEmpty && layout.objects.any((o) => o.id == saved)) return saved;
    final located = location.place.objectId;
    if (located != null && layout.objects.any((o) => o.id == located)) {
      return located;
    }
    return layout.objects.isEmpty ? null : layout.objects.first.id;
  }

  HomeObject? get currentObject {
    final id = objectId;
    if (id == null) return null;
    for (final o in layout.objects) {
      if (o.id == id) return o;
    }
    return null;
  }

  Future<void> selectObject(String id) async {
    settings.objectId = id;
    await settings.save();
    notifyListeners();
    // строка «прошлая проверка» — уже нового объекта: из кэша в этом же кадре, из
    // сети — как только префетч дотянется (иначе вход с карточки объекта появлялся
    // бы только после следующей полной синхронизации)
    await refreshObjectPastLine();
    unawaited(onObjectSelected?.call());
  }

  /// The dashboard this person last saw, straight out of their own base — so a phone
  /// opened in the aisle without a signal shows yesterday's numbers rather than a spinner,
  /// and shows *theirs*.
  Future<void> _loadHome(LocalDb db) async {
    var json = await db.cache.getHome();
    // an installation updated from the build that kept one home screen for the whole
    // device: it belongs to whoever signs in first, same as the base itself
    if (json == null) {
      json = await Settings.takeLegacyHomeJson();
      if (json != null && json.isNotEmpty) {
        await db.cache.saveHome(json, DateTime.now().toIso8601String());
      }
    }
    if (json == null || json.isEmpty) return;
    try {
      layout =
          HomeLayout.fromJson((jsonDecode(json) as Map).cast<String, dynamic>());
    } catch (_) {
      // stored layout unreadable — the app falls back to the plain task list
    }
  }

  /// Перечитать строку «прошлая проверка» текущего объекта из кэша — при смене
  /// объекта, после префетча и при входе (офлайн-старт живёт тем же кэшем).
  Future<void> refreshObjectPastLine() async {
    final db = base.db;
    final obj = objectId;
    if (db == null || obj == null) {
      objectPastCheck = null;
      notifyListeners();
      return;
    }
    FillSummary? line;
    try {
      final row = await db.cache.getPastFillCache('object', obj);
      if (row != null) {
        final info = (jsonDecode((row['infoJson'] as String?) ?? '{}') as Map)
            .cast<String, dynamic>();
        final s = FillSummary.fromJson(info);
        if (s.date != null) line = s;
      }
    } catch (_) {
      // нечитаемый кэш — строки просто нет до следующей синхронизации
    }
    objectPastCheck = line;
    notifyListeners();
  }
}
