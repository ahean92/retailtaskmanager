import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/task_repository.dart';
import '../models/ai_draft.dart';
import '../models/quick_create.dart';
import 'theme.dart';

/// Постановка задачи обычным текстом: «поставь Иванову завтра до 18:00 проверить
/// выкладку Pepsi в магазине на Ленина и сфотографировать нарушения».
///
/// Экран один, и состояний у него больше нет — есть лента разговора. Фраза человека
/// стоит справа, ответ AI слева, собранная задача — карточкой последним сообщением.
/// Так видно всё, что привело к результату: что было сказано, о чём переспросили, что
/// из этого вышло. Прежние три экрана (ввод → уточнение → проверка) прятали ровно это:
/// заданный вопрос исчезал, стоило на него ответить, — а уточнений бывает и несколько.
///
/// Разговор и на сервере разговор: у него есть ключ, шаги и история, и вопрос задаётся
/// один за шаг (AiDraftDecision.askClarification). Лента ничего к этому не добавляет — она
/// его показывает.
///
/// Задачу создаёт ЧЕЛОВЕК. AI ничего не создаёт и не может: он отвечает черновиком,
/// черновик показывается целиком, и только нажатие «Создать задачу» отправляет её
/// обычным путём — той же очередью и той же ручкой, что и создание по пресету.
///
/// Экран онлайновый, в отличие от создания по пресету, и это честно: за ним стоит
/// модель на сервере. Поэтому он ничего не обещает офлайн — а созданная задача уже
/// живёт по общим правилам и уедет из очереди при связи.
class AiTaskScreen extends StatefulWidget {
  const AiTaskScreen({super.key});

  @override
  State<AiTaskScreen> createState() => _AiTaskScreenState();
}

/// Кто говорит и чем. Черновик — не текст: он рисуется карточкой и правится прямо в
/// ленте, поэтому у него свой вид реплики, а не строка.
enum _Kind { hello, human, ai, draft }

class _Msg {
  final _Kind kind;
  final String text;

  /// Варианты к вопросу — их посчитал сервер тем же поиском, которым и спросил.
  final List<AiOption> options;
  final String? optionsFor;

  /// Ошибка или предупреждение: пузырь тот же, цвет тревожный.
  final bool alarm;

  const _Msg(this.kind, this.text,
      {this.options = const [], this.optionsFor, this.alarm = false});
}

class _AiTaskScreenState extends State<AiTaskScreen> {
  final _inputCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _scroll = ScrollController();

  /// Ключ разговора: с ним уходят все уточнения, и он же станет ключом созданной
  /// задачи — по нему сервер связывает задачу с запросом, из которого она выросла.
  String _dialogId = TaskRepository.newClientId();

  /// Последняя отправленная фраза — её возвращает в поле «Начать заново», чтобы
  /// переписать, а не набирать снова.
  String _asked = '';

  final List<_Msg> _thread = [const _Msg(_Kind.hello, '')];

  AiDraft? _draft;
  bool _asking = false;
  bool _creating = false;

  @override
  void dispose() {
    _inputCtrl.dispose();
    _nameCtrl.dispose();
    _descCtrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<TaskRepository>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('AI'),
        actions: [
          if (_thread.length > 1 && !_asking)
            IconButton(
              tooltip: 'Начать заново',
              icon: const Icon(Icons.restart_alt),
              onPressed: _startOver,
            ),
        ],
      ),
      body: Column(children: [
        Expanded(
          child: ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.all(12),
            itemCount: _thread.length + (_asking ? 1 : 0),
            itemBuilder: (context, i) =>
                i == _thread.length ? _thinking() : _bubble(repo, _thread[i]),
          ),
        ),
        _inputBar(repo),
      ]),
    );
  }

  // ================= лента =================

  Widget _bubble(TaskRepository repo, _Msg msg) => switch (msg.kind) {
        _Kind.hello => _left(_hello()),
        _Kind.human =>
          _right(Text(msg.text, style: TextStyle(color: Wms.text, height: 1.3))),
        _Kind.ai => _left(_aiSaid(msg)),
        _Kind.draft => _draftCard(repo),
      };

  Widget _hello() =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Опишите задачу словами — разберу и соберу черновик.',
            style: TextStyle(color: Wms.text, height: 1.3)),
        const SizedBox(height: 8),
        const _Hint(Icons.storefront_outlined, 'магазин — по названию или «здесь»'),
        const _Hint(Icons.person_outline, 'исполнителя — по фамилии'),
        const _Hint(Icons.schedule, 'срок — «завтра», «до пятницы», «через три дня»'),
        const _Hint(Icons.photo_camera_outlined, 'фото — если о нём сказано'),
      ]);

  Widget _aiSaid(_Msg msg) {
    // Варианты живут только у последней реплики: отвеченный вопрос переспрашивать
    // нечем, а кнопки под ним выглядели бы как незакрытый выбор.
    final live = identical(msg, _thread.last);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(msg.alarm ? Icons.error_outline : Icons.help_outline,
            size: 18, color: msg.alarm ? Wms.warn : Wms.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(msg.text,
              style: TextStyle(
                  color: msg.alarm ? Wms.warn : Wms.text,
                  fontWeight: FontWeight.w600,
                  height: 1.3)),
        ),
      ]),
      if (live && msg.options.isNotEmpty) ...[
        const SizedBox(height: 8),
        // Выбор пальцем применяется на месте: всё остальное в черновике уже разобрано
        // на этом шаге, и гонять модель второй раз незачем — это ещё десятки секунд.
        for (final option in msg.options)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: InkWell(
              onTap: () => _choose(msg.optionsFor, option),
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  border: Border.all(color: Wms.primary.withValues(alpha: 0.5)),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(children: [
                  Icon(
                      msg.optionsFor == 'performer'
                          ? Icons.person_outline
                          : Icons.storefront_outlined,
                      size: 18,
                      color: Wms.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(option.name,
                              style: TextStyle(
                                  fontWeight: FontWeight.w600, color: Wms.text)),
                          if (option.note != null)
                            Text(option.note!,
                                style: TextStyle(fontSize: 12, color: Wms.muted)),
                        ]),
                  ),
                ]),
              ),
            ),
          ),
        Text('или ответьте словами',
            style: TextStyle(fontSize: 12, color: Wms.muted)),
      ],
    ]);
  }

  Widget _left(Widget child) => Align(
        alignment: Alignment.centerLeft,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 320),
          margin: const EdgeInsets.only(bottom: 10, right: 32),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Wms.card,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(4),
              topRight: Radius.circular(14),
              bottomLeft: Radius.circular(14),
              bottomRight: Radius.circular(14),
            ),
          ),
          child: child,
        ),
      );

  Widget _right(Widget child) => Align(
        alignment: Alignment.centerRight,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 320),
          margin: const EdgeInsets.only(bottom: 10, left: 32),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Wms.primary.withValues(alpha: 0.12),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(14),
              topRight: Radius.circular(4),
              bottomLeft: Radius.circular(14),
              bottomRight: Radius.circular(14),
            ),
          ),
          child: child,
        ),
      );

  Widget _thinking() => _left(Row(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 10),
        Text('разбираю запрос…', style: TextStyle(color: Wms.muted)),
      ]));

  // ================= черновик =================

  /// Карточка задачи — последняя реплика разговора и единственная правимая. Живёт она
  /// не в самой реплике, а в [_draft]: правка поля должна быть видна сразу, а копия
  /// внутри списка разошлась бы с тем, что уйдёт на сервер.
  Widget _draftCard(TaskRepository repo) {
    final draft = _draft;
    if (draft == null) return const SizedBox.shrink();
    final missing = draft.missing;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Wms.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Wms.primary.withValues(alpha: 0.35)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _label('Задача'),
        TextField(
          controller: _nameCtrl,
          maxLength: 250,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            counterText: '',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          onChanged: (value) =>
              setState(() => _draft = draft.copyWith(name: value)),
        ),
        if (draft.typeName != null) ...[
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [
            _chip(draft.typeName!, icon: Icons.category_outlined),
            if (draft.templateName != null)
              _chip(draft.templateName!, icon: Icons.assignment_outlined),
          ]),
        ],
        const Divider(height: 20),
        _row(
          Icons.storefront_outlined,
          draft.objectName ?? draft.objectId ?? 'Объект не выбран',
          draft.objectAddress,
          onTap: () => _pickObject(repo, draft),
        ),
        const SizedBox(height: 8),
        _row(
          Icons.person_outline,
          draft.performerName ?? 'Исполнитель не выбран',
          draft.performerId == repo.session.performerId ? 'Себе' : null,
          onTap: () => _pickPerformer(repo, draft),
        ),
        const SizedBox(height: 8),
        _deadlineRow(draft),
        const SizedBox(height: 4),
        Row(children: [
          Icon(Icons.photo_camera_outlined, size: 20, color: Wms.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text('Фото при выполнении обязательно',
                style: TextStyle(fontSize: 14, color: Wms.text)),
          ),
          Switch(
            value: draft.photoRequired,
            onChanged: (value) =>
                setState(() => _draft = draft.copyWith(photoRequired: value)),
          ),
        ]),
        _label('Описание'),
        TextField(
          controller: _descCtrl,
          minLines: 1,
          maxLines: 4,
          maxLength: 500,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            counterText: '',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          onChanged: (value) => setState(() => _draft =
              draft.copyWith(description: value.trim().isEmpty ? null : value)),
        ),
        if (draft.warning != null) ...[
          const SizedBox(height: 8),
          _warnRow(draft.warning!),
        ],
        if (draft.lowConfidence) ...[
          const SizedBox(height: 8),
          _warnRow('AI не уверен в разборе — проверьте поля внимательнее'),
        ],
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed:
                _creating || missing != null ? null : () => _create(repo, draft),
            icon: const Icon(Icons.add_task),
            label: const Text('Создать задачу'),
          ),
        ),
        if (missing != null) ...[
          const SizedBox(height: 6),
          Text(missing,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Wms.muted)),
        ],
        const SizedBox(height: 6),
        Text('Можно и просто написать, что поправить, — «перенеси на пятницу».',
            style: TextStyle(fontSize: 12, color: Wms.muted)),
      ]),
    );
  }

  // ================= ввод =================

  Widget _inputBar(TaskRepository repo) {
    final empty = _inputCtrl.text.trim().isEmpty;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        decoration: BoxDecoration(
          color: Wms.card,
          border:
              Border(top: BorderSide(color: Wms.muted.withValues(alpha: 0.2))),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(
            child: TextField(
              controller: _inputCtrl,
              autofocus: true,
              minLines: 1,
              maxLines: 4,
              maxLength: 1000,
              enabled: !_asking,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                hintText: _hint(),
                counterText: '',
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (text) => _send(repo, text),
            ),
          ),
          IconButton(
            tooltip: 'Отправить',
            color: Wms.primary,
            onPressed:
                empty || _asking ? null : () => _send(repo, _inputCtrl.text),
            icon: const Icon(Icons.send),
          ),
        ]),
      ),
    );
  }

  String _hint() {
    final draft = _draft;
    if (draft == null) {
      return 'Например: поставь Иванову проверить ценники до пятницы';
    }
    if (draft.needsClarification) return 'Ответьте на вопрос';
    return 'Что поправить?';
  }

  // ================= действия =================

  /// Одна дорога для всего, что человек говорит: и для первой фразы, и для ответа на
  /// уточнение, и для правки уже собранного черновика. Сервер каждый шаг разбирает
  /// вместе со всей историей разговора, поэтому разделять их на клиенте нечем.
  Future<void> _send(TaskRepository repo, String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || _asking) return;
    setState(() {
      _thread.add(_Msg(_Kind.human, trimmed));
      _inputCtrl.clear();
      _asking = true;
      _asked = trimmed;
    });
    _toEnd();
    try {
      final draft = await repo.aiDraft(_dialogId, trimmed);
      if (!mounted) return;
      setState(() {
        _asking = false;
        _accept(draft);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _asking = false;
        _thread.add(_Msg(_Kind.ai, 'Не удалось обратиться к AI: $e', alarm: true));
        _thread.add(const _Msg(_Kind.ai, 'Проверьте связь и попробуйте ещё раз.'));
      });
    }
    _toEnd();
  }

  /// Ответ сервера — в ленту. Черновик в ней ровно один: карточка показывает текущее
  /// состояние задачи, а не её версии, и второй экземпляр рядом означал бы два разных
  /// ответа на вопрос «что создастся».
  void _accept(AiDraft draft) {
    _draft = draft;
    // Карточка всегда показывает текущий черновик, поэтому живёт ровно столько, сколько
    // он собран. Пришёл вопрос или ошибка — показывать нечего, и старая карточка,
    // оставшись в ленте, рисовала бы уже не тот черновик, что в ней написан.
    _thread.removeWhere((m) => m.kind == _Kind.draft);
    if (draft.needsClarification) {
      _thread.add(_Msg(_Kind.ai, draft.question ?? 'Уточните запрос',
          options: draft.options, optionsFor: draft.optionsFor));
      return;
    }
    if (draft.isError) {
      _thread.add(_Msg(_Kind.ai, draft.message ?? 'AI не смог обработать запрос',
          alarm: true));
      _thread.add(_Msg(_Kind.ai, _advice(draft.errorCode)));
      return;
    }
    _nameCtrl.text = draft.name ?? '';
    _descCtrl.text = draft.description ?? '';
    _thread.add(const _Msg(_Kind.draft, ''));
  }

  /// Выбранный вариант применяется к черновику на месте. Модель для этого не нужна:
  /// она уже разобрала всё остальное на этом шаге, а недостающее было ровно одно — то,
  /// о чём и спрашивали. В ленте выбор выглядит ответом человека, потому что он им и
  /// является. Если после подстановки чего-то всё ещё не хватает, [AiDraft.missing]
  /// скажет об этом в карточке, а объект и исполнитель там открываются списком.
  void _choose(String? optionsFor, AiOption option) {
    final draft = _draft;
    if (draft == null) return;
    final chosen = optionsFor == 'performer'
        ? draft.copyWith(
            outcome: 'ok', performerId: option.id, performerName: option.name)
        : draft.copyWith(
            outcome: 'ok',
            objectId: option.id,
            objectName: option.name,
            objectAddress: option.note);
    setState(() {
      _thread.add(_Msg(_Kind.human, option.name));
      _accept(chosen);
    });
    _toEnd();
  }

  /// Заново — с чистого листа: и лента, и ключ разговора. Неудачная попытка не должна
  /// оставаться в истории и сбивать модель на следующем шаге.
  void _startOver() {
    setState(() {
      _dialogId = TaskRepository.newClientId();
      _thread
        ..clear()
        ..add(const _Msg(_Kind.hello, ''));
      _draft = null;
      _inputCtrl.text = _asked;
    });
  }

  Future<void> _create(TaskRepository repo, AiDraft draft) async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _creating = true);
    try {
      await repo.createFromAiDraft(draft);
      if (!mounted) return;
      navigator.pop();
      messenger.showSnackBar(SnackBar(
        content: Text(repo.online
            ? 'Задача создана'
            : 'Создана офлайн — уедет на сервер при связи'),
        duration: const Duration(seconds: 2),
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() => _creating = false);
      messenger.showSnackBar(SnackBar(content: Text('Не удалось создать: $e')));
    }
  }

  /// Прокрутка к последней реплике — после кадра: до него список ещё не знает своей
  /// новой длины, и прокручивать некуда.
  void _toEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(_scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    });
  }

  /// Что человеку с этим делать. Коды приходят от AI-сервиса и сервера; незнакомый код
  /// — не повод молчать, поэтому у совета есть общий вариант.
  static String _advice(String? code) => switch (code) {
        // «не про задачи» — не поломка, а недоразумение: человеку нужен пример, а не
        // совет «попробуйте ещё раз»
        'unsupported' =>
          'Например: «поставь Иванову проверить ценники в магазине на Ленина до пятницы».',
        'disabled' =>
          'AI-постановка задач выключена в настройках системы — обратитесь к администратору.',
        'unavailable' || 'llmUnavailable' =>
          'Сервис AI не отвечает. Скорее всего, он не запущен на сервере.',
        'timeout' || 'llmTimeout' =>
          'Модель не успела ответить. Попробуйте ещё раз или сформулируйте короче.',
        'llmBadResponse' || 'badJson' =>
          'Модель ответила непонятно. Попробуйте переформулировать запрос.',
        _ => 'Попробуйте ещё раз; если повторяется — сообщите администратору.',
      };

  // ================= правка распознанного =================

  /// Объекты на выбор — те же, что и на экране создания по пресету: соседи по
  /// координатам для работающего по геолокации, объекты главной для остальных.
  List<({String id, String name, String? address})> _objectChoices(
      TaskRepository repo) {
    if (repo.session.geoRequired) {
      return [
        for (final o in repo.place.nearby)
          (id: o.id, name: o.name, address: o.address)
      ];
    }
    return [
      for (final o in repo.home.objects)
        (id: o.id, name: o.name, address: o.address)
    ];
  }

  Future<void> _pickObject(TaskRepository repo, AiDraft draft) async {
    final choices = _objectChoices(repo);
    if (choices.isEmpty) return;
    final chosen =
        await showModalBottomSheet<({String id, String name, String? address})>(
      context: context,
      backgroundColor: Wms.card,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          _sheetTitle('Объект'),
          for (final o in choices)
            ListTile(
              title: Text(o.name),
              subtitle: o.address == null ? null : Text(o.address!),
              trailing: o.id == draft.objectId
                  ? Icon(Icons.check, color: Wms.primary)
                  : null,
              onTap: () => Navigator.of(context).pop(o),
            ),
        ]),
      ),
    );
    if (chosen == null || !mounted) return;
    setState(() => _draft = draft.copyWith(
        objectId: chosen.id,
        objectName: chosen.name,
        objectAddress: chosen.address));
  }

  Future<void> _pickPerformer(TaskRepository repo, AiDraft draft) async {
    final people = repo.quickCreate.performers;
    if (people.isEmpty) return;
    final chosen = await showModalBottomSheet<Performer>(
      context: context,
      backgroundColor: Wms.card,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          _sheetTitle('Исполнитель'),
          for (final p in people)
            ListTile(
              title: Text(p.name),
              trailing: p.id == draft.performerId
                  ? Icon(Icons.check, color: Wms.primary)
                  : null,
              onTap: () => Navigator.of(context).pop(p),
            ),
        ]),
      ),
    );
    if (chosen == null || !mounted) return;
    setState(() => _draft =
        draft.copyWith(performerId: chosen.id, performerName: chosen.name));
  }

  Widget _deadlineRow(AiDraft draft) {
    final d = draft.deadlineDate;
    return InkWell(
      onTap: () => _pickDeadline(draft),
      child: Row(children: [
        Icon(Icons.schedule, size: 20, color: Wms.primary),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            d == null ? 'Срок не задан' : 'Срок: ${_fmtDate(d)}',
            style: TextStyle(
                fontWeight: FontWeight.w600,
                color: d == null ? Wms.muted : Wms.text),
          ),
        ),
        if (d != null)
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Без срока',
            icon: Icon(Icons.close, size: 18, color: Wms.muted),
            onPressed: () =>
                setState(() => _draft = draft.copyWith(deadline: null)),
          )
        else
          Icon(Icons.unfold_more, size: 18, color: Wms.primary),
      ]),
    );
  }

  Future<void> _pickDeadline(AiDraft draft) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: draft.deadlineDate ?? now,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year + 2),
    );
    if (picked == null || !mounted) return;
    setState(() => _draft = draft.copyWith(
        deadline: '${picked.year.toString().padLeft(4, '0')}-'
            '${picked.month.toString().padLeft(2, '0')}-'
            '${picked.day.toString().padLeft(2, '0')}'));
  }

  static String _fmtDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';

  // ================= мелкая обвязка =================

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 6),
        child: Text(text.toUpperCase(),
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: Wms.muted,
                letterSpacing: 0.6)),
      );

  Widget _row(IconData icon, String title, String? subtitle,
          {VoidCallback? onTap}) =>
      InkWell(
        onTap: onTap,
        child: Row(children: [
          Icon(icon, size: 20, color: Wms.primary),
          const SizedBox(width: 10),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  style:
                      TextStyle(fontWeight: FontWeight.w600, color: Wms.text)),
              if (subtitle != null)
                Text(subtitle, style: TextStyle(fontSize: 12, color: Wms.muted)),
            ]),
          ),
          if (onTap != null)
            Icon(Icons.unfold_more, size: 18, color: Wms.primary),
        ]),
      );

  Widget _chip(String text, {IconData? icon}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Wms.muted.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: Wms.muted),
            const SizedBox(width: 4),
          ],
          Text(text,
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w500, color: Wms.text)),
        ]),
      );

  Widget _warnRow(String text) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 18, color: Wms.warn),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: TextStyle(color: Wms.warn))),
        ],
      );

  Widget _sheetTitle(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
        child: Text(text,
            style: TextStyle(
                fontSize: 16, fontWeight: FontWeight.w700, color: Wms.text)),
      );
}

/// Строка приветствия: что именно AI умеет вытащить из фразы.
class _Hint extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Hint(this.icon, this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Row(children: [
          Icon(icon, size: 16, color: Wms.muted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: TextStyle(fontSize: 13, color: Wms.muted)),
          ),
        ]),
      );
}
