import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/task_file_controller.dart';
import '../data/task_repository.dart';
import '../models/fill.dart';
import '../models/quick_create.dart';
import 'fill_screen.dart';
import 'theme.dart';
import 'widgets/photo_picker.dart';
import 'widgets/task_photo.dart';

/// Создание задачи по пресету: объект, исполнитель, название, срок, фото, описание и —
/// для бланочного пресета — предпросмотр бланка. Всё собирается из кэша, который приехал
/// при синхронизации; ни одного обращения к серверу отсюда нет и быть не может:
/// сценарий — торговый зал без связи. «Создать» кладёт задачу в локальную очередь
/// (#36716): поручение уходит в список и уезжает на сервер при связи, проверка сразу
/// открывает бланк из предзагруженного шаблона.
class QuickCreateScreen extends StatefulWidget {
  final QuickPreset preset;
  const QuickCreateScreen({super.key, required this.preset});

  @override
  State<QuickCreateScreen> createState() => _QuickCreateScreenState();
}

class _QuickCreateScreenState extends State<QuickCreateScreen> {
  late final TextEditingController _nameCtrl;
  final _descCtrl = TextEditingController();

  /// Срок: из deadlineDays пресета, дальше человек волен сменить.
  DateTime? _deadline;

  /// Фото от автора («вот бардак на витрине») — пути к снимкам из камеры/галереи.
  /// Кадров может быть несколько (#36914): витрина целиком, ценник крупно, срок
  /// годности — одним снимком такое не показать.
  final List<String> _photoPaths = [];

  /// Выбранный вручную исполнитель (для политик pick/byRole со списком).
  Performer? _picked;

  /// Объект, выбранный на этом экране; null — тот, что выбран в приложении.
  ({String? id, String? name, String? address})? _chosenObject;

  /// Создание уже нажато — кнопка не должна сработать дважды.
  bool _creating = false;

  @override
  void initState() {
    super.initState();
    final repo = context.read<TaskRepository>();
    final preset = widget.preset;
    final template = repo.quickCreate.templateOf(preset);
    // у проверки имя есть заранее — имя бланка; поручение заведующий называет сам
    _nameCtrl = TextEditingController(
        text: preset.templateCode == null
            ? ''
            : (template?.name ?? preset.title));
    if (preset.deadlineDays != null) {
      final now = DateTime.now();
      _deadline =
          DateTime(now.year, now.month, now.day + preset.deadlineDays!);
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<TaskRepository>();
    final preset = widget.preset;
    final data = repo.quickCreate;
    final object = _object(repo);
    final template = data.templateOf(preset);
    final missing = _missing(repo, object, template);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          '${preset.icon == null ? '' : '${preset.icon} '}${preset.title}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          _card(
            children: [
              _label('Объект'),
              _objectRow(repo, object),
              if (preset.requirePhoto || preset.requireComment) ...[
                const SizedBox(height: 10),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  if (preset.requirePhoto)
                    // требование к исполнителю: без фото работу не закрыть
                    _chip('Фото при выполнении',
                        icon: Icons.photo_camera_outlined),
                  if (preset.requireComment)
                    _chip('Нужно описание', icon: Icons.notes),
                ]),
              ],
            ],
          ),
          _card(children: _assignee(repo, preset, data, object.id)),
          _card(children: [
            _label('Задача'),
            TextField(
              controller: _nameCtrl,
              textCapitalization: TextCapitalization.sentences,
              maxLength: 250,
              decoration: const InputDecoration(
                labelText: 'Название',
                counterText: '',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 10),
            _deadlineRow(),
            const SizedBox(height: 10),
            TextField(
              controller: _descCtrl,
              minLines: 2,
              maxLines: 5,
              maxLength: 500,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: preset.requireComment
                    ? 'Описание (обязательно)'
                    : 'Описание',
                counterText: '',
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 10),
            _photoRow(),
          ]),
          if (preset.templateCode != null)
            ...(template == null
                ? [
                    _card(children: [
                      _warnRow(
                          'Бланк «${preset.templateCode}» ещё не приехал — '
                          'потяните список задач, чтобы синхронизироваться'),
                    ])
                  ]
                : _blank(template)),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Column(
              children: [
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _creating || missing != null
                        ? null
                        : () => _create(repo, object, template),
                    icon: Icon(
                        template != null ? Icons.play_arrow : Icons.add_task),
                    label: Text(
                        template != null ? 'Начать проверку' : 'Создать задачу'),
                  ),
                ),
                if (missing != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    missing,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: Wms.muted),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  // --- что мешает создать ---

  /// Первая недостающая вещь — подпись под выключенной кнопкой. NULL — можно создавать.
  String? _missing(
      TaskRepository repo,
      ({String? id, String? name, String? address}) object,
      PresetTemplate? template) {
    final preset = widget.preset;
    if (preset.typeId == null) {
      // сервер отвергнет такой create ('typeId required'), а очередь создания не
      // имеет пути отмены — лучше не дать создать вовсе; чинится в бэк-офисе
      return 'Пресет настроен без типа задачи — сообщите администратору';
    }
    if (object.id == null) return 'Не выбран объект';
    if (preset.templateCode != null && template == null) {
      return 'Бланк ещё не приехал с сервера';
    }
    if (_nameCtrl.text.trim().isEmpty) return 'Укажите название';
    switch (preset.assign) {
      case 'self':
        break;
      case 'pick':
        if (_assigneeFor(repo, object.id) == null) {
          return 'Выберите исполнителя';
        }
      case 'byRole':
        if (_assigneeFor(repo, object.id) == null) {
          return 'На этом объекте нет исполнителя с нужной ролью';
        }
      default:
        // политика из будущей версии сервера: рисовать нечего, создавать — тем более
        return 'Неизвестный способ назначения «${preset.assign}»';
    }
    if (preset.requireComment && _descCtrl.text.trim().isEmpty) {
      return 'Опишите, что нужно сделать';
    }
    return null;
  }

  /// Кому уйдёт задача. NULL при политике self — сервер сам назначит на создателя,
  /// и это надёжнее, чем пересылать ему его же идентификатор.
  Performer? _assigneeFor(TaskRepository repo, String? objectId) {
    final preset = widget.preset;
    final data = repo.quickCreate;
    switch (preset.assign) {
      case 'pick':
        final all = data.performers;
        return _picked != null && all.any((c) => c.id == _picked!.id)
            ? _picked
            : null;
      case 'byRole':
        if (objectId == null || preset.roleId == null) return null;
        final candidates = data.byRole(objectId, preset.roleId!);
        if (candidates.length == 1) return candidates.first;
        return _picked != null && candidates.any((c) => c.id == _picked!.id)
            ? _picked
            : null;
      default:
        return null;
    }
  }

  // --- создание ---

  Future<void> _create(
      TaskRepository repo,
      ({String? id, String? name, String? address}) object,
      PresetTemplate? template) async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _creating = true);
    try {
      final uuid = await repo.createTask(
        preset: widget.preset,
        objectId: object.id!,
        objectName: object.name,
        objectAddress: object.address,
        name: _nameCtrl.text.trim(),
        deadline: _deadline,
        description:
            _descCtrl.text.trim().isEmpty ? null : _descCtrl.text.trim(),
        photoPaths: _photoPaths,
        assignee: _assigneeFor(repo, object.id),
      );
      if (!mounted) return;
      // задача на соседний объект без переключения была бы «не здесь» — видимой,
      // но только для чтения (#36837), — и бланк ниже не открылся бы; выбор соседа
      // на этом экране и есть ответ «я стою там», контекст переезжает за ним
      if (repo.session.geoRequired &&
          object.id != repo.place.objectId &&
          repo.place.objects.any((o) => o.id == object.id)) {
        await repo.selectNearby(object.id!);
        if (!mounted) return;
      }
      if (template != null) {
        // внезапная проверка: задача создана на себя и выполнение уже в очереди —
        // человек попадает прямо в бланк, как будто открыл плановую задачу
        navigator.pushReplacement(
          MaterialPageRoute(builder: (_) => FillScreen(taskId: uuid)),
        );
      } else {
        navigator.pop();
        messenger.showSnackBar(SnackBar(
          content: Text(repo.online
              ? 'Задача создана'
              : 'Создана офлайн — уедет на сервер при связи'),
          duration: const Duration(seconds: 2),
        ));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _creating = false);
      messenger.showSnackBar(SnackBar(content: Text('Не удалось создать: $e')));
    }
  }

  // --- объект ---

  /// Объект, «где я стою»: выбранный на этом экране, иначе — для работающих по
  /// геолокации определённый по координатам, иначе выбранный на главной; свежая
  /// установка получает первый с сервера.
  ({String? id, String? name, String? address}) _object(TaskRepository repo) {
    final chosen = _chosenObject;
    if (chosen != null) return chosen;
    final located = repo.place.object;
    if (repo.session.geoRequired && located != null) {
      return (id: located.id, name: located.name, address: located.address);
    }
    final home = repo.currentObject;
    if (home != null) {
      return (id: home.id, name: home.name, address: home.address);
    }
    if (located != null) {
      return (id: located.id, name: located.name, address: located.address);
    }
    return (id: null, name: null, address: null);
  }

  /// Между чем можно переключиться: для работающего по геолокации — соседи по
  /// координатам, для остальных — объекты его главного экрана.
  List<({String? id, String? name, String? address})> _objectChoices(
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

  Widget _objectRow(TaskRepository repo,
      ({String? id, String? name, String? address}) object) {
    final choices = _objectChoices(repo);
    final switchable = choices.length > 1;
    final row = Row(
      children: [
        Icon(Icons.storefront_outlined, size: 20, color: Wms.primary),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(object.name ?? 'Объект не выбран',
                  style: TextStyle(
                      fontWeight: FontWeight.w600, color: Wms.text)),
              if (object.address != null)
                Text(object.address!,
                    style: TextStyle(fontSize: 12, color: Wms.muted)),
            ],
          ),
        ),
        if (switchable) Icon(Icons.unfold_more, size: 18, color: Wms.primary),
      ],
    );
    if (!switchable) return row;
    return InkWell(onTap: () => _pickObject(choices), child: row);
  }

  Future<void> _pickObject(
      List<({String? id, String? name, String? address})> from) async {
    final current = _chosenObject;
    final chosen = await showModalBottomSheet<
        ({String? id, String? name, String? address})>(
      context: context,
      backgroundColor: Wms.card,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('Объект',
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: Wms.text)),
            ),
            for (final o in from)
              ListTile(
                title: Text(o.name ?? o.id ?? ''),
                subtitle: o.address == null ? null : Text(o.address!),
                trailing: o.id == current?.id
                    ? Icon(Icons.check, color: Wms.primary)
                    : null,
                onTap: () => Navigator.of(context).pop(o),
              ),
          ],
        ),
      ),
    );
    if (chosen != null) {
      // сменился объект — сменились и кандидаты «по роли»; старый выбор не переносим
      setState(() {
        _chosenObject = chosen;
        _picked = null;
      });
    }
  }

  // --- срок ---

  Widget _deadlineRow() {
    final d = _deadline;
    return InkWell(
      onTap: _pickDeadline,
      child: Row(children: [
        Icon(Icons.schedule, size: 20, color: Wms.primary),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            d == null
                ? 'Срок не задан'
                : 'Срок: ${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}',
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
            onPressed: () => setState(() => _deadline = null),
          )
        else
          Icon(Icons.unfold_more, size: 18, color: Wms.primary),
      ]),
    );
  }

  Future<void> _pickDeadline() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _deadline ?? now,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year + 2),
    );
    if (picked != null) setState(() => _deadline = picked);
  }

  // --- фото ---

  /// Кадры автора: кнопка добавления и лента превью с удалением до отправки. Удалённый
  /// кадр стирается с диска здесь же — обещание «не занимает место на телефоне»
  /// выполняется в момент отказа, а не когда-нибудь потом.
  Widget _photoRow() {
    final left = TaskFilesController.maxPerTask - _photoPaths.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          OutlinedButton.icon(
            onPressed: left <= 0 ? null : _pickPhotos,
            icon: const Icon(Icons.photo_camera_outlined),
            label: Text(_photoPaths.isEmpty ? 'Фото' : 'Добавить фото'),
          ),
          const SizedBox(width: 10),
          if (_photoPaths.isNotEmpty)
            Expanded(
              child: Text(
                left <= 0
                    ? 'Снимков: ${_photoPaths.length} — это предел'
                    : 'Снимков: ${_photoPaths.length}',
                style: TextStyle(fontSize: 13, color: Wms.muted),
              ),
            ),
        ]),
        if (_photoPaths.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final path in _photoPaths)
                Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.file(File(path),
                          width: 72,
                          height: 72,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => brokenPhoto(72)),
                    ),
                    Positioned(
                      right: 0,
                      top: 0,
                      child: InkWell(
                        onTap: () => _removePhoto(path),
                        child: Container(
                          decoration: const BoxDecoration(
                            color: Colors.black54,
                            shape: BoxShape.circle,
                          ),
                          padding: const EdgeInsets.all(2),
                          child: const Icon(Icons.close,
                              size: 14, color: Colors.white),
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ],
      ],
    );
  }

  Future<void> _pickPhotos() async {
    final picked = await pickTaskPhotos(context,
        limit: TaskFilesController.maxPerTask - _photoPaths.length);
    if (picked.isEmpty || !mounted) return;
    setState(() => _photoPaths.addAll(picked));
  }

  /// Кадр, от которого отказались до отправки: из списка и с диска. Файл — копия,
  /// сделанная камерой или выбирателем во временном каталоге; оригинал в галерее
  /// не трогается.
  Future<void> _removePhoto(String path) async {
    setState(() => _photoPaths.remove(path));
    await TaskFilesController.deleteFile(path);
  }

  // --- исполнитель ---

  List<Widget> _assignee(TaskRepository repo, QuickPreset preset,
      QuickCreateData data, String? objectId) {
    final rows = <Widget>[_label('Исполнитель')];
    switch (preset.assign) {
      case 'self':
        rows.add(_personRow(
            repo.session.name.isEmpty ? repo.session.login : repo.session.name,
            'Себе'));
      case 'pick':
        rows.add(_pickRow(data.performers, 'Из списка исполнителей'));
      case 'byRole':
        // кандидаты — люди с нужной ролью на этом объекте, из предзагруженного кэша
        final candidates = objectId == null || preset.roleId == null
            ? const <Performer>[]
            : data.byRole(objectId, preset.roleId!);
        if (candidates.isEmpty) {
          rows.add(_warnRow('На этом объекте нет исполнителя с нужной ролью'));
        } else if (candidates.length == 1) {
          rows.add(_personRow(candidates.first.name, 'По роли на объекте'));
        } else {
          rows.add(_pickRow(candidates, 'По роли на объекте'));
        }
      default:
        rows.add(_warnRow('Неизвестный способ назначения «${preset.assign}»'));
    }
    return rows;
  }

  Widget _personRow(String name, String note) => Row(children: [
        Icon(Icons.person_outline, size: 20, color: Wms.primary),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name,
                style: TextStyle(fontWeight: FontWeight.w600, color: Wms.text)),
            Text(note, style: TextStyle(fontSize: 12, color: Wms.muted)),
          ]),
        ),
      ]);

  Widget _pickRow(List<Performer> from, String note) {
    final chosen = _picked != null && from.any((p) => p.id == _picked!.id)
        ? _picked
        : null;
    return InkWell(
      onTap: () => _pick(from),
      child: Row(children: [
        Icon(Icons.person_search_outlined, size: 20, color: Wms.primary),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(chosen?.name ?? 'Выбрать исполнителя…',
                style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: chosen == null ? Wms.primary : Wms.text)),
            Text(note, style: TextStyle(fontSize: 12, color: Wms.muted)),
          ]),
        ),
        Icon(Icons.unfold_more, size: 18, color: Wms.primary),
      ]),
    );
  }

  Future<void> _pick(List<Performer> from) async {
    final chosen = await showModalBottomSheet<Performer>(
      context: context,
      backgroundColor: Wms.card,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('Исполнитель',
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: Wms.text)),
            ),
            for (final p in from)
              ListTile(
                title: Text(p.name),
                trailing: p.id == _picked?.id
                    ? Icon(Icons.check, color: Wms.primary)
                    : null,
                onTap: () => Navigator.of(context).pop(p),
              ),
          ],
        ),
      ),
    );
    if (chosen != null) setState(() => _picked = chosen);
  }

  // --- бланк ---

  List<Widget> _blank(PresetTemplate t) {
    final widgets = <Widget>[
      _card(children: [
        _label('Бланк'),
        Text(t.name ?? t.code,
            style: TextStyle(
                fontSize: 16, fontWeight: FontWeight.w700, color: Wms.text)),
        if (t.note != null)
          Text(t.note!, style: TextStyle(fontSize: 12, color: Wms.muted)),
        if (t.passThreshold != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: _chip('Проходной порог: ${_fmt(t.passThreshold!)}%',
                icon: Icons.percent),
          ),
      ]),
    ];
    String? section;
    for (final f in t.fields) {
      if (f.section != section) {
        section = f.section;
        widgets.add(Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text('${f.sectionIndex}. ${section ?? ''}',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Wms.muted,
                  letterSpacing: 0.3)),
        ));
      }
      widgets.add(_field(f));
    }
    return widgets;
  }

  Widget _field(FillField f) => _card(children: [
        Text(f.name ?? f.code,
            style: TextStyle(fontWeight: FontWeight.w600, color: Wms.text)),
        if (f.hint != null)
          Text(f.hint!, style: TextStyle(fontSize: 12, color: Wms.muted)),
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 6, children: [
          _chip(_typeLabel(f.type)),
          if (_norm(f) != null) _chip(_norm(f)!),
          if (f.required) _chip('обязательное', color: Wms.primary),
          if (f.critical) _chip('критичное', color: Wms.warn),
          if (f.requirePhoto)
            _chip('фото при несоотв.', icon: Icons.photo_camera_outlined),
        ]),
        if (f.options.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final o in f.options)
              _chip(
                  o.score == null || o.notApplicable
                      ? (o.name ?? o.code)
                      : '${o.name ?? o.code} · ${_fmt(o.score!)}',
                  color: o.nonconformity ? Wms.warn : null),
          ]),
        ],
        if (f.columns.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final c in f.columns)
              _chip(
                  '${c.name ?? c.code}'
                  '${c.readonly ? ' (только чтение)' : ''}',
                  icon: Icons.table_chart_outlined),
          ]),
        ],
      ]);

  /// «2–6 °C» из нормы и единицы; половинки — как «от 2» / «до 6».
  String? _norm(FillField f) {
    final unit = f.unit == null ? '' : ' ${f.unit}';
    if (f.minNorm != null && f.maxNorm != null) {
      return '${_fmt(f.minNorm!)}–${_fmt(f.maxNorm!)}$unit';
    }
    if (f.minNorm != null) return 'от ${_fmt(f.minNorm!)}$unit';
    if (f.maxNorm != null) return 'до ${_fmt(f.maxNorm!)}$unit';
    return f.unit;
  }

  static String _typeLabel(String type) => switch (type) {
        'scale' => 'шкала',
        'number' => 'число',
        'score' => 'баллы',
        'boolean' => 'да / нет',
        'choice' => 'выбор',
        'text' => 'текст',
        'longtext' => 'длинный текст',
        'date' => 'дата',
        'photo' => 'фото',
        'scan' => 'сканирование',
        'table' => 'таблица',
        'objectref' => 'объект',
        _ => type,
      };

  static String _fmt(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  // --- мелкая обвязка ---

  Widget _card({required List<Widget> children}) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Material(
          color: Wms.card,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: children),
          ),
        ),
      );

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text.toUpperCase(),
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: Wms.muted,
                letterSpacing: 0.6)),
      );

  Widget _chip(String text, {IconData? icon, Color? color}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: (color ?? Wms.muted).withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: color ?? Wms.muted),
            const SizedBox(width: 4),
          ],
          Text(text,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: color ?? Wms.text)),
        ]),
      );

  Widget _warnRow(String text) => Row(children: [
        Icon(Icons.error_outline, size: 18, color: Wms.warn),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: TextStyle(color: Wms.warn))),
      ]);
}
