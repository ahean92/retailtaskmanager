import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/task_file_controller.dart';
import '../data/home_controller.dart';
import '../data/task_repository.dart';
import '../models/quick_create.dart';
import 'fill_screen.dart';
import 'theme.dart';
import 'widgets/form_card.dart';
import 'widgets/photo_picker.dart';
import 'widgets/task_photo.dart';
import 'widgets/template_preview.dart';

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
  CreateObject? _chosenObject;

  /// Создание уже нажато — кнопка не должна сработать дважды.
  bool _creating = false;

  @override
  void initState() {
    super.initState();
    final home = context.read<HomeController>();
    final preset = widget.preset;
    final template = home.quickCreate.templateOf(preset);
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
    final home = context.watch<HomeController>();
    final preset = widget.preset;
    final data = home.quickCreate;
    final object = _chosenObject ?? home.createObject;
    final template = data.templateOf(preset);
    final draft = _draft(preset, object, template);
    final missing = draft.missing(data);

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
          FormCard(
            children: [
              FormLabel('Объект'),
              _objectRow(home, object),
              if (preset.requirePhoto || preset.requireComment) ...[
                const SizedBox(height: 10),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  if (preset.requirePhoto)
                    // требование к исполнителю: без фото работу не закрыть
                    FormChip('Фото при выполнении',
                        icon: Icons.photo_camera_outlined),
                  if (preset.requireComment)
                    FormChip('Нужно описание', icon: Icons.notes),
                ]),
              ],
            ],
          ),
          FormCard(children: _assignee(home, preset, data, object?.id)),
          FormCard(children: [
            FormLabel('Задача'),
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
            template == null
                ? FormCard(children: [
                    FormWarnRow(
                        'Бланк «${preset.templateCode}» ещё не приехал — '
                        'потяните список задач, чтобы синхронизироваться'),
                  ])
                : TemplatePreview(template: template),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Column(
              children: [
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _creating || missing != null
                        ? null
                        : () => _create(home, draft),
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

  // --- создание ---

  /// Черновик из того, что заполнено на экране: правила «чего не хватает» и «кому
  /// уйдёт» живут в нём ([PresetDraft]), экран только собирает поля.
  PresetDraft _draft(
          QuickPreset preset, CreateObject? object, PresetTemplate? template) =>
      PresetDraft(
        preset: preset,
        template: template,
        object: object,
        name: _nameCtrl.text,
        description: _descCtrl.text,
        deadline: _deadline,
        photoPaths: _photoPaths,
        picked: _picked,
      );

  Future<void> _create(HomeController home, PresetDraft draft) async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final repo = context.read<TaskRepository>();
    setState(() => _creating = true);
    try {
      final uuid = await home.createFromPreset(draft);
      if (!mounted) return;
      if (draft.template != null) {
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

  Widget _objectRow(HomeController home, CreateObject? object) {
    final choices = home.createObjectChoices;
    final switchable = choices.length > 1;
    final row = Row(
      children: [
        Icon(Icons.storefront_outlined, size: 20, color: Wms.primary),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(object?.name ?? 'Объект не выбран',
                  style: TextStyle(
                      fontWeight: FontWeight.w600, color: Wms.text)),
              if (object?.address != null)
                Text(object!.address!,
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

  Future<void> _pickObject(List<CreateObject> from) async {
    final current = _chosenObject;
    final chosen = await showModalBottomSheet<CreateObject>(
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
                title: Text(o.name),
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
                            color: Wms.scrim,
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

  List<Widget> _assignee(HomeController home, QuickPreset preset,
      QuickCreateData data, String? objectId) {
    final rows = <Widget>[FormLabel('Исполнитель')];
    switch (preset.assign) {
      case 'self':
        rows.add(_personRow(
            home.session.name.isEmpty ? home.session.login : home.session.name,
            'Себе'));
      case 'pick':
        rows.add(_pickRow(data.performers, 'Из списка исполнителей'));
      case 'byRole':
        // кандидаты — люди с нужной ролью на этом объекте, из предзагруженного кэша
        final candidates = objectId == null || preset.roleId == null
            ? const <Performer>[]
            : data.byRole(objectId, preset.roleId!);
        if (candidates.isEmpty) {
          rows.add(FormWarnRow('На этом объекте нет исполнителя с нужной ролью'));
        } else if (candidates.length == 1) {
          rows.add(_personRow(candidates.first.name, 'По роли на объекте'));
        } else {
          rows.add(_pickRow(candidates, 'По роли на объекте'));
        }
      default:
        rows.add(FormWarnRow('Неизвестный способ назначения «${preset.assign}»'));
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

  // --- мелкая обвязка ---
}
