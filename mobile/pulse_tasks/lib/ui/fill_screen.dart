import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../data/fill_controller.dart';
import '../data/sync_coordinator.dart';
import '../data/task_repository.dart';
import '../models/fill.dart';
import 'past_check_screen.dart';
import 'scan_screen.dart';
import 'theme.dart';
import 'widgets/acceptance.dart';
import 'widgets/ds.dart';
import 'widgets/fill_field_tile.dart';

/// Generic schema-driven fill screen for form (procedure) tasks — one renderer for
/// every template. Sections are paged; the last page carries the resolution + finish.
///
/// Редизайн #37411 (п. 6): шапка — крестик, название задачи, «заполнено N из M»
/// и тонкая полоса прогресса; разделы — горизонтальные чипы (готовый с галочкой,
/// текущий залит); каждое поле — отдельная карточка; внизу «Назад» и
/// «Далее». Логика контроллера не менялась.
class FillScreen extends StatefulWidget {
  final String taskId;

  /// Сканер штрихкода: открыть камеру и вернуть код, null — человек вышел. По
  /// умолчанию — экран камеры (ScanScreen); подменяется там, где камеры нет, — в
  /// сквозных прогонах на эмуляторе (#37192).
  final Future<String?> Function(BuildContext context)? scanner;

  const FillScreen({super.key, required this.taskId, this.scanner});

  @override
  State<FillScreen> createState() => _FillScreenState();
}

class _FillScreenState extends State<FillScreen> {
  late final FillController _c;
  final _pager = PageController();
  int _page = 0;

  /// Ключи чипов разделов: по ним текущий чип докручивается в видимую часть
  /// горизонтальной полосы при перелистывании страниц.
  final Map<int, GlobalKey> _chipKeys = {};

  /// Ключи плиток полей: прыжок по незаполненным обязательным докручивает список
  /// раздела к цели (как _chipKeys у чипов; экран просмотра делает так же).
  final Map<String, GlobalKey> _tileKeys = {};

  /// Маршрут по незаполненным обязательным после отказа «Завершить». Включается
  /// первым отказом — не заранее, — живёт на всех страницах, пока дыры есть, и
  /// целиком гаснет с последней закрытой. Кнопка — над нижней панелью: прыжок
  /// уводит с последней страницы, и там она была бы недосягаема как раз тогда,
  /// когда нужна.
  bool _requiredJump = false;

  /// Позиция маршрута в текущем списке дыр: тап идёт по кругу, заполненные
  /// выпадают из списка, индекс живёт с зажимом.
  int _requiredCursor = 0;

  /// Плитка-цель последнего прыжка — рамка «вы здесь», пока поле не заполнено.
  String? _flashCode;

  /// load() уже запускался. Отдельно от контроллера: вне объекта задачи load()
  /// откладывается — он не только читает бланк, но и НАЧИНАЕТ выполнение на сервере
  /// (startExecution), а «открыл экран» не должно превращаться в «начал работу»
  /// не на месте (#36837). Запустится из build, когда человек снова окажется там.
  bool _loaded = false;

  /// Фокус — в каком-либо поле ввода этого экрана (Focus-обёртка Scaffold'а
  /// отслеживает и потомков: ячейки таблиц, текстовые поля). Управляет кнопкой
  /// «Готово» над клавиатурой — см. _bottomBar.
  bool _typing = false;

  /// Задача этого бланка — не того объекта, где человек стоит (#36837). Смотрит в
  /// репозиторий на каждый rebuild: полоса «вы не на этом объекте» обязана и
  /// появиться, и исчезнуть в тот же кадр, что и смена объекта в шапке списка.
  /// Задача, пропавшая из списка (закрыта, подтверждена сервером), не считается
  /// чужой — этим экраном по-прежнему занимается его собственная логика завершения.
  bool _away(TaskRepository repo) =>
      repo.viewOf(widget.taskId)?.elsewhere ?? false;

  /// Для dispose: context.read там уже нельзя, а бейдж «не отправлено» на главной
  /// обязан узнать про ответы, оставшиеся в очереди этого бланка (#36916).
  late final TaskRepository _repo;

  @override
  void initState() {
    super.initState();
    final repo = _repo = context.read<TaskRepository>();
    // geo — чтобы первый старт и завершение унесли точку момента действия (#36838);
    // возврат на доработку — чтобы по сданному бланку завелось новое выполнение (#37158)
    _c = FillController(
      db: repo.db,
      api: repo.api,
      taskId: widget.taskId,
      geo: repo.geo,
      restartHint: repo.viewOf(widget.taskId)?.restartsExecution == true,
    );
    if (!_away(repo)) {
      _loaded = true;
      _c.load();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    _pager.dispose();
    // очереди этого бланка изменились — счётчик «не отправлено» пересчитывается
    // по уходу с экрана, а не ждёт ближайшей синхронизации (#36916). Молча: база
    // могла закрыться прямо под экраном (выход из аккаунта), счётчик ей уже не нужен
    unawaited(_repo.reloadLocal().catchError((_) {}));
    super.dispose();
  }

  /// Задача с приёмкой (#37158): «Завершить» здесь — сдача, а не конец, и кнопка с
  /// сообщением говорят это прямо.
  bool get _submits =>
      _repo.viewOf(widget.taskId)?.task.needsAcceptance == true;

  Future<void> _finish() async {
    final sync = context.read<SyncCoordinator>();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final submits = _submits;
    final ok = await _c.finish();
    // список обязан узнать о завершении, даже если экран уже сняли крестиком:
    // без этого карточка навсегда остаётся с «Продолжить» при завершённой на
    // сервере задаче. Снятым экранам — ни снекбара, ни pop: второй тап по ещё
    // не погашенной кнопке дождался того же будущего, первый уже всё показал
    if (ok) unawaited(sync.syncAndRefresh());
    if (!mounted) return;
    if (ok) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            _c.online
                ? (submits ? 'Сдано на приёмку' : 'Задача завершена')
                : (submits
                    ? 'Сдано — уедет на сервер при связи'
                    : 'Завершено — уедет на сервер при связи'),
          ),
        ),
      );
      navigator.pop();
    } else {
      messenger.showSnackBar(
        SnackBar(content: Text(_c.error ?? 'Не удалось завершить')),
      );
      // Отказ из-за обязательных включает маршрут по дырам и сразу ведёт к
      // первой: листать весь бланк с последней страницы руками — ровно то,
      // ради чего маршрут заводится. Другие причины отказа кнопки не включают.
      if (_c.missingRequired > 0) {
        setState(() {
          _requiredJump = true;
          _requiredCursor = 0;
        });
        unawaited(_jumpToRequired(0));
      }
    }
  }

  Future<void> _pickDate(FillField f) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(now.year - 2),
      lastDate: DateTime(now.year + 2),
    );
    if (picked == null) return;
    final iso =
        '${picked.year.toString().padLeft(4, '0')}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
    await _c.setDate(f, iso);
  }

  /// Один сканер на поле «Скан» и на лист «Добавить позицию» (#37192).
  Future<String?> _scanBarcode() {
    final scan = widget.scanner;
    if (scan != null) return scan(context);
    return Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const ScanScreen()));
  }

  Future<void> _scanCode(FillField f) async {
    final code = await _scanBarcode();
    if (code == null || !mounted) return;
    await _c.setText(f, code);
  }

  /// Кадр для поля: источник приезжает с плитки «Камера» или «Галерея» напрямую
  /// (#37411, п. 6) — лист-выбор между ними больше не нужен.
  Future<void> _pickPhoto(FillField f, ImageSource source) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final file = await ImagePicker().pickImage(
        source: source,
        maxWidth: 1280,
        maxHeight: 1280,
        imageQuality: 70,
      );
      if (file == null) return;
      await _c.addPhoto(f, file.path);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Не удалось получить фото: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // watch, а не read: отъезд и возвращение перекрашивают открытый бланк сами —
    // гвард только на входе оставлял бы лазейку «открыл на месте, дозаполнил из дома»
    final repo = context.watch<TaskRepository>();
    if (_away(repo)) return _awayScreen(context);
    if (!_loaded) {
      // человек вернулся на объект, не закрывая бланка, — загрузка, отложенная в
      // initState, стартует теперь (из post-frame: build не место для side effects)
      _loaded = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _c.load();
      });
    }
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) {
        // Клавиатура поднимает весь бланк, а не только его содержимое: панель
        // из bottomNavigationBar прижата к полу Scaffold'а, и при обычном
        // resize-инсете она остаётся за клавиатурой, невидимкой. Инсет у
        // Scaffold'а снят — сжатие делает внешний Padding, и панель «Готово»
        // оказывается прямо над клавиатурой.
        final keyboard = MediaQuery.of(context).viewInsets.bottom;
        // Подложка цвета бланка — на всю высоту, включая зону под клавиатурой:
        // у iOS-клавиатуры скруглённые верхние углы, и за ними без подложки
        // виден чёрный хост-фон окна — «пятна» по краям под панелью «Готово».
        return ColoredBox(
          color: Theme.of(context).scaffoldBackgroundColor,
          child: MediaQuery.removeViewInsets(
            removeBottom: true,
            context: context,
            child: Padding(
              padding: EdgeInsets.only(bottom: keyboard),
              // сам нод не фокусируем — ловим только фокус полей-потомков;
              // их потеря (кнопка «Готово», тап мимо) гасит _typing в том же кадре
              child: Focus(
                canRequestFocus: false,
                skipTraversal: true,
                onFocusChange: (has) => setState(() => _typing = has),
                child: Scaffold(
                  appBar: AppBar(
                    leading: IconButton(
                      tooltip: 'К задаче',
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    actions: [
                      // вход в прошлую проверку — из шапки, рядом с крестиком (п. 6);
                      // объект без истории её не предлагает: смотреть там нечего
                      if (_c.summary.prevDate != null)
                        TextButton(
                          onPressed: _openPast,
                          child: const Text('Прошлая проверка'),
                        ),
                      if (_c.syncing)
                        Padding(
                          padding: const EdgeInsets.only(right: 16),
                          child: Center(
                            child: SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Wms.text2,
                              ),
                            ),
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
                  body:
                      _c.loading && _c.fields.isEmpty
                          ? const Center(child: CircularProgressIndicator())
                          : _c.fields.isEmpty
                          ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Text(
                                _c.error ?? 'Полей нет',
                                textAlign: TextAlign.center,
                              ),
                            ),
                          )
                          : Column(
                            children: [
                              _header(context, repo),
                              // почему задача снова здесь (#37158) — словами принимающего
                              if (repo.viewOf(widget.taskId)?.returned == true)
                                DsBanner(
                                  Icons.undo,
                                  returnedLine(repo.viewOf(widget.taskId)!),
                                ),
                              // перевыполнение заводит сервер, и без связи его не начать:
                              // на экране пока сданный бланк, и это надо сказать
                              if (_c.restartHint && _c.finished && !_c.online)
                                const DsBanner(
                                  Icons.cloud_off,
                                  'Начать заново можно при связи — сейчас показан '
                                  'сданный бланк',
                                ),
                              if (!_c.online)
                                const DsBanner(
                                  Icons.cloud_off,
                                  'Офлайн — данные сохраняются и синхронизируются позже',
                                ),
                              if (_c.online && _c.lastSyncError != null)
                                DsBanner(
                                  Icons.sync_problem,
                                  'Не принято: ${_c.lastSyncError}',
                                  tone: DsTone.danger,
                                ),
                              _sectionChips(),
                              Expanded(child: _pages(context)),
                            ],
                          ),
                  bottomNavigationBar: _bottomBar(context),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// Шапка бланка (п. 6): название задачи, «заполнено N из M», тонкая полоса
  /// прогресса. Оценка и обещание геометки — маленькими строками под полосой:
  /// терять их нельзя, а заголовком они не являются.
  Widget _header(BuildContext context, TaskRepository repo) {
    final ratio = _c.totalCount == 0 ? 0.0 : _c.answeredCount / _c.totalCount;
    final task = repo.viewOf(widget.taskId)?.task;
    final title = task?.name ?? task?.object ?? _c.object ?? _c.template ?? '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              height: 1.2,
              color: Wms.text,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'заполнено ${_c.answeredCount} из ${_c.totalCount}'
            '${_c.missingEvidence > 0 ? ' · нужно свидетельство: ${_c.missingEvidence}' : ''}',
            style: TextStyle(fontSize: 12, color: Wms.text2),
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 4,
              backgroundColor: Wms.chipBg,
            ),
          ),
          if (_c.summary.hasScored && _c.summary.percent != null) ...[
            const SizedBox(height: 8),
            _score(context),
          ],
          // Сказать вслух, а не умолчать (#36838): в задачу пишутся две точки —
          // где работа начата и где завершена. Строка дешевле любого разговора
          // постфактум; на завершённом — хоть локально, хоть подтверждённо —
          // запись уже позади, и обещать её строка не вправе.
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
    );
  }

  void _openPast({String? fieldCode}) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder:
            (_) => PastCheckScreen.forTask(
              widget.taskId,
              initialFieldCode: fieldCode,
            ),
      ),
    );
  }

  /// Current score and grade. Both come from the server: the scoring rules and the
  /// grade boundaries live there, and duplicating them here would be a second source
  /// of truth that drifts. So while there are unsynced answers the figure is openly
  /// labelled as stale rather than quietly recomputed.
  Widget _score(BuildContext context) {
    final s = _c.summary;
    final pct = s.percent!;
    final stale = _c.pendingCount > 0;
    final color = stale ? Wms.muted : (s.passed ? Wms.ok : Wms.warn);

    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            '${FillSummary.formatPercent(pct)}'
            '${s.verdict != null ? ' · ${s.verdict}' : ''}',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ),
        if (stale)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(
                'обновится после синхронизации',
                style: TextStyle(fontSize: 11, color: Wms.muted),
              ),
            ),
          ),
      ],
    );
  }

  /// Чипы разделов вместо строки «Раздел N из M» (п. 6): готовый — галочка на
  /// подложке «готово», текущий — залит фирменным, остальные — контурные. Тап
  /// листает бланк к разделу; текущий чип докручивается в полосу сам.
  ///
  /// Полоса лежит в общих полях экрана (16), как заголовок и карточки полей:
  /// и обрезается она границей этого поля, а не краем экрана — скролл
  /// сохраняется, просто чипы не заходят в поле, отведённое остальным блокам.
  Widget _sectionChips() {
    final sections = [
      for (var i = 0; i < _c.sectionCount; i++)
        (
          index: i,
          title: _c.sectionTitle(i),
          complete: _c.fieldsOfSection(i).every((f) => f.answered),
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SizedBox(
            key: const ValueKey('sectionChipStrip'),
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.zero,
              children: [
                for (final s in sections)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: _SectionChip(
                      key: _chipKeys.putIfAbsent(s.index, () => GlobalKey()),
                      label: s.title,
                      complete: s.complete,
                      current: s.index == _page,
                      onTap: () => _goToSection(s.index),
                    ),
                  ),
              ],
            ),
          ),
        ),
        // подытог раздела (#36945): «12 из 15 · 80%». Нет оценки — нет строки
        // (процедура выглядит ровно как раньше). Пока есть неотправленное, число
        // приглушается так же, как общий процент в шапке. Вердикт отдельного итога
        // красит строку: свой порог раздела важнее общего процента бланка.
        if (_c.sectionScore(_page) case final sub?)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 2, 20, 0),
            child: Text(
              sub.line,
              key: const ValueKey('sectionSubtotal'),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: _subtotalColor(sub),
              ),
            ),
          ),
      ],
    );
  }

  Color _subtotalColor(SectionScore sub) {
    if (_c.pendingCount > 0) return Wms.muted;
    if (sub.verdict == null) return Wms.text2;
    return sub.verdict == 'Пройдено' ? Wms.ok : Wms.warn;
  }

  void _goToSection(int index) {
    if (index == _page) return;
    // Чипы видны и при открытой клавиатуре, а коммит набранного идёт только
    // по потере фокуса: без явного расфокуса ответ жил бы в контроллере, пока
    // человек не тапнет другое поле — и «Завершить» с последней страницы ушёл
    // бы без него (обязательное блокировало бы финиш, необязательное — терялось
    // молча). Сначала отдаём фокус и коммитим, потом листаем.
    FocusManager.instance.primaryFocus?.unfocus();
    _pager.animateToPage(
      index,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  /// Прыжок к i-й незаполненной обязательной: страница раздела — анимацией
  /// пейджера, плитка — докруткой. Список дыр живой (заполненное выпадает), так
  /// что индекс зажимается. Расфокус первым — по той же причине, что у чипов:
  /// набранный ответ обязан попасть в список ДО прыжка, иначе маршрут укажет на
  /// уже заполненное поле. Пейджер перенацеливается всегда: прыжок во время
  /// чужой незавершённой анимации обязан развернуть её, а не «уже и так тут».
  Future<void> _jumpToRequired(int i) async {
    final miss = _c.missingRequiredFields;
    if (miss.isEmpty) return;
    final idx = i.clamp(0, miss.length - 1);
    final f = miss[idx];
    setState(() {
      _requiredCursor = idx;
      _flashCode = f.code;
    });
    FocusManager.instance.primaryFocus?.unfocus();
    await _pager.animateToPage(
      _c.pageOfField(f.code),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
    if (!mounted) return;
    await _revealTile(f);
  }

  /// Следующая дыра по кругу: после последней — снова первая.
  void _jumpNextRequired() {
    final miss = _c.missingRequiredFields;
    if (miss.isEmpty) return;
    unawaited(_jumpToRequired((_requiredCursor + 1) % miss.length));
  }

  /// Докрутить страницу раздела к плитке поля. Список секции строится
  /// builder'ом (редактор тяжелее просмотра), и цель за краем окна построения
  /// ещё не имеет контекста: пока ключа нет, листаем в её сторону экранами —
  /// каждый шаг достраивает поля, — а ensureVisible доводит уже точно.
  Future<void> _revealTile(FillField f) async {
    for (var attempt = 0; attempt < 12; attempt++) {
      final ctx = _tileKeys[f.code]?.currentContext;
      if (ctx != null) {
        await Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          alignment: 0.15,
        );
        return;
      }
      final items = _c.fieldsOfSection(_c.pageOfField(f.code));
      final target = items.indexWhere((it) => it.code == f.code);
      int? firstBuilt;
      for (var i = 0; i < items.length; i++) {
        if (_tileKeys[items[i].code]?.currentContext != null) {
          firstBuilt ??= i;
        }
      }
      final anchor =
          firstBuilt == null || target < 0
              ? null
              : _tileKeys[items[firstBuilt].code]?.currentContext;
      final pos = anchor == null ? null : Scrollable.maybeOf(anchor)?.position;
      if (pos == null) return;
      final up = target < firstBuilt!;
      final next = (up
              ? pos.pixels - pos.viewportDimension
              : pos.pixels + pos.viewportDimension)
          .clamp(pos.minScrollExtent, pos.maxScrollExtent);
      if (up ? next >= pos.pixels : next <= pos.pixels) return;
      await pos.animateTo(
        next,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
      );
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
    }
  }

  @override
  void didUpdateWidget(covariant FillScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    _revealCurrentChip();
  }

  /// Докрутить чип текущего раздела в полосу — после кадра, когда чип уже стоит.
  void _revealCurrentChip() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _chipKeys[_page]?.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 200),
          alignment: 0.5,
          curve: Curves.easeOut,
        );
      }
    });
  }

  Widget _pages(BuildContext context) {
    return PageView.builder(
      controller: _pager,
      itemCount: _c.sectionCount,
      onPageChanged: (p) {
        setState(() => _page = p);
        _revealCurrentChip();
      },
      itemBuilder: (context, page) {
        final items = _c.fieldsOfSection(page);
        return ListView.builder(
          padding: const EdgeInsets.only(top: 12),
          itemCount: items.length,
          itemBuilder: (context, i) {
            final f = items[i];
            return FillFieldTile(
              key: _tileKeys.putIfAbsent(f.code, GlobalKey.new),
              field: f,
              // Цель последнего прыжка: рамка живёт, пока поле не заполнено —
              // заполненное из маршрута само выпадает, рамка с него сходит
              flash: _flashCode == f.code && !f.answered,
              // завершённая проверка — просмотр, а не редактор (#36778).
              // По ПОДТВЕРЖДЁННОМУ завершению: закрытую офлайн держим
              // редактируемой, пока цепочка не дожалась, — отвергнутый
              // сервером ответ иначе было бы нечем исправить
              readOnly: _c.confirmedFinished,
              onOpenPast:
                  f.prevNonconformity
                      ? () => _openPast(fieldCode: f.code)
                      : null,
              onOption: (c) => _c.setOption(f, c),
              onNumber: (v) => _c.setNumber(f, v),
              onText: (t) => _c.setText(f, t),
              onBool: (b) => _c.setBool(f, b),
              onDatePick: () => _pickDate(f),
              onScan: () => _scanCode(f),
              onComment: (t) => _c.setComment(f, t),
              onPhoto: () => _pickPhoto(f, ImageSource.camera),
              onPhotoSource: (source) => _pickPhoto(f, source),
              onRemovePhoto: () => _c.clearPhotos(f),
              onDeleteShot: (shot) => _c.deleteShot(f, shot),
              // кадр, снятый на другом устройстве, своего файла тут не имеет —
              // галерея показывает его миниатюрой с сервера (#36946)
              photoLoader:
                  (i, {required thumb}) =>
                      _c.serverPhotoFile(f, i, thumb: thumb),
              onCell: (row, col, v) => _c.setCellNumber(f, row, col, v),
              onCellText: (row, col, v) => _c.setCellText(f, row, col, v),
              onAddRow:
                  (id, name, {code}) => _c.addRow(
                    f,
                    subjectId: id,
                    subjectName: name,
                    code: code,
                  ),
              onDeleteRow: (row) => _c.deleteRow(f, row),
              scanCode: _scanBarcode,
              onRowSubjectSearch:
                  (q, {allItems = false}) =>
                      _c.searchRowSubjects(f, q, allItems: allItems),
              onRef: (id, name) => _c.setRef(f, id: id, name: name),
              onRefSearch: (q) => _c.searchSubjects(f, q),
            );
          },
        );
      },
    );
  }

  Widget _bottomBar(BuildContext context) {
    // Клавиатура поднята — панель навигации заменяется одной кнопкой «Готово»:
    // цифровая клавиатура iOS не имеет своей кнопки завершения, и человеку
    // нечем её согнать; заодно «Назад/Далее» у пальца во время набора не зовут
    // перепрыгнуть раздел на полуслове — набор и листание остаются разными
    // режимами, показывается только тот, что в работе.
    //
    // Показ — пока фокус в поле ввода: сняли фокус (кнопка, тап мимо ячейки) —
    // панель исчезает этим же кадром, а не уезжает вниз вслед за клавиатурой,
    // чья высота ещё анимируется.
    if (MediaQuery.of(context).viewInsets.bottom > 0) {
      if (!_typing) return const SizedBox.shrink();
      // Фон обязателен: при сжатии под клавиатуру контент страницы доезжает
      // под панель, и без подложки поле просвечивало бы сквозь кнопку.
      return Material(
        key: const ValueKey('keyboardDoneBar'),
        color: Theme.of(context).scaffoldBackgroundColor,
        child: Align(
          alignment: Alignment.centerRight,
          // высота панели — по кнопке: без heightFactor Align растягивается на
          // весь остаток над клавиатурой и выдавливает содержимое бланка с экрана
          heightFactor: 1,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
            child: FilledButton.tonalIcon(
              onPressed: () => FocusManager.instance.primaryFocus?.unfocus(),
              icon: const Icon(Icons.check, size: 18),
              label: const Text('Готово'),
              style: FilledButton.styleFrom(minimumSize: const Size(0, 38)),
            ),
          ),
        ),
      );
    }

    final last = _page >= _c.sectionCount - 1;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // завершённой проверке исход не выбирают — он показан текстом
        if (last && _c.resolutionRequired && !_c.confirmedFinished)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: _resolutionPicker(),
          ),
        if (last && _c.confirmedFinished && _c.resolution != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: Row(
              children: [
                Text(
                  'Исход: ',
                  style: TextStyle(fontSize: 13, color: Wms.muted),
                ),
                Text(
                  ResolutionOption.labelOf(_c.resolution) ?? '',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        // Маршрут по незаполненным обязательным: над панелью на каждой странице
        // (прыжок уводит с последней — там кнопка была бы недосягаема), прячется
        // вместе с панелью при открытой клавиатуре — прыгать во время набора
        // не нужно, и «поверх» набранного текста кнопка не нужна.
        if (_requiredJump && _c.missingRequired > 0) _requiredJumpBar(),
        DsBottomActionBar(
          secondaryLabel: _page > 0 ? 'Назад' : null,
          onSecondary:
              _page > 0
                  ? () => _pager.previousPage(
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOut,
                  )
                  : null,
          primaryLabel:
              !last
                  // без названия следующего раздела: длинные имена раздували кнопку
                  // до неопрятных размеров, а короткое «Далее» читается одинаково
                  ? 'Далее'
                  // пока «Завершить» в полёте, кнопка гасится и говорит, чем занята:
                  // молчащая серая кнопка звала бы дотапывать «на всякий случай»
                  : _c.finishing
                  ? 'Завершение…'
                  : _submits
                  ? (_c.finished ? 'Сдано на приёмку' : 'Сдать на приёмку')
                  : (_c.finished ? 'Завершено' : 'Завершить'),
          // завершённая (в том числе офлайн, с finish в очереди) проверка
          // не завершается второй раз — иначе экран противоречил бы списку;
          // идущее завершение тоже не тапается повторно — запрос один
          onPrimary:
              !last
                  ? () => _pager.nextPage(
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOut,
                  )
                  : (_c.finished || _c.finishing ? null : _finish),
        ),
      ],
    );
  }

  /// Кнопка-маршрут: «текущее/всего» по незаполненным обязательным, тап — к
  /// следующей по кругу. Квадратная и справа — над главным действием панели, не
  /// спорит с «Назад» слева. Отступ от панели — как от края экрана: кнопка
  /// висит над панелью, а не прилипает к ней.
  Widget _requiredJumpBar() {
    final miss = _c.missingRequiredFields;
    final idx = _requiredCursor.clamp(0, miss.length - 1);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Row(
        children: [
          const Spacer(),
          _RequiredJumpButton(
            label: '${idx + 1}/${miss.length}',
            onTap: _jumpNextRequired,
          ),
        ],
      ),
    );
  }

  /// «Вы не на этом объекте» — вместо бланка, а не поверх него (#36837). Полей не
  /// видно намеренно: read-only-бланк с живыми на вид контролами звал бы заполнять
  /// дальше. Введённое на месте цело и синхронизируется как обычно — экран это
  /// говорит прямо, потому что «нельзя продолжать» без этого читается как «пропало».
  Widget _awayScreen(BuildContext context) {
    final view = context.read<TaskRepository>().viewOf(widget.taskId);
    final d = view?.task.distanceText;
    return Scaffold(
      appBar: AppBar(title: const Text('Заполнение')),
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
                decoration: BoxDecoration(
                  color: Wms.chipBg,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.near_me_disabled_outlined,
                  size: 32,
                  color: Wms.text2,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Вы не на этом объекте',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  height: 1.2,
                  color: Wms.text,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'Заполнять можно только на объекте задачи'
                '${d == null ? '' : ' — до него $d'}. '
                'Всё введённое на месте сохранено и синхронизируется как обычно.',
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

  Widget _resolutionPicker() {
    return Row(
      children: [
        Text('Исход:', style: TextStyle(fontSize: 13, color: Wms.muted)),
        const SizedBox(width: 10),
        Expanded(
          child: DropdownButtonFormField<String>(
            initialValue: _c.resolution,
            isExpanded: true,
            decoration: const InputDecoration(
              isDense: true,
              hintText: 'выберите',
            ),
            items: [
              for (final r in ResolutionOption.all)
                DropdownMenuItem(value: r.code, child: Text(r.label)),
            ],
            onChanged: (v) {
              if (v != null) _c.setResolution(v);
            },
          ),
        ),
      ],
    );
  }
}

/// Чип раздела бланка: залитый текущий, «готово» с галочкой, контурный прочий.
class _SectionChip extends StatelessWidget {
  final String label;
  final bool complete;
  final bool current;
  final VoidCallback? onTap;
  const _SectionChip({
    super.key,
    required this.label,
    required this.complete,
    required this.current,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final (bg, fg, border) =
        current
            ? (Wms.primary, Wms.on(Wms.primary), Wms.primary)
            : complete
            ? (Wms.doneTint, Wms.done, Wms.doneTint)
            : (Colors.transparent, Wms.text2, Wms.line);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (complete && !current) ...[
              Icon(Icons.check, size: 14, color: Wms.done),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: fg,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Квадратная кнопка прыжка по незаполненным обязательным: счётчик «текущее/
/// всего» прямо на кнопке — по нему видно и сколько дыр, и что тапы идут по
/// кругу. Красная, как и отказ, из-за которого появилась: это «завершение
/// заблокировано», а не подсказка.
class _RequiredJumpButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _RequiredJumpButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'К незаполненным обязательным полям',
      child: SizedBox(
        key: const ValueKey('requiredJumpButton'),
        height: 52,
        width: 52,
        child: FilledButton(
          onPressed: onTap,
          style: FilledButton.styleFrom(
            backgroundColor: Wms.danger,
            foregroundColor:
                Wms.isDark ? const Color(0xFF3B2220) : Colors.white,
            padding: EdgeInsets.zero,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.priority_high, size: 16),
              const SizedBox(height: 2),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
