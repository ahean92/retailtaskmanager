import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/task_repository.dart';
import '../models/fill.dart';
import '../models/quick_create.dart';
import 'theme.dart';

/// Заготовка задачи по пресету: объект, исполнитель и бланк — целиком из кэша,
/// который приехал при синхронизации. Ни одного обращения к серверу отсюда нет и быть
/// не может: сценарий — торговый зал без связи. Само создание задачи — следующий шаг
/// (ручка apiCreateTask), поэтому кнопка внизу пока выключена и честно говорит об этом.
class QuickCreateScreen extends StatefulWidget {
  final QuickPreset preset;
  const QuickCreateScreen({super.key, required this.preset});

  @override
  State<QuickCreateScreen> createState() => _QuickCreateScreenState();
}

class _QuickCreateScreenState extends State<QuickCreateScreen> {
  /// Выбранный вручную исполнитель (для политик pick/byRole со списком).
  Performer? _picked;

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<TaskRepository>();
    final preset = widget.preset;
    final data = repo.quickCreate;
    final object = _object(repo);
    final template = data.templateOf(preset);

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
              Row(
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
                              style:
                                  TextStyle(fontSize: 12, color: Wms.muted)),
                      ],
                    ),
                  ),
                ],
              ),
              if (preset.deadlineDays != null ||
                  preset.requirePhoto ||
                  preset.requireComment) ...[
                const SizedBox(height: 10),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  if (preset.deadlineDays != null)
                    _chip('Срок: ${preset.deadlineDays} дн.',
                        icon: Icons.schedule),
                  if (preset.requirePhoto)
                    _chip('Нужно фото', icon: Icons.photo_camera_outlined),
                  if (preset.requireComment)
                    _chip('Нужно описание', icon: Icons.notes),
                ]),
              ],
            ],
          ),
          _card(children: _assignee(repo, preset, data, object.id)),
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
                    onPressed: null,
                    icon: const Icon(Icons.add_task),
                    label: const Text('Создать задачу'),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Заготовка собрана из данных на телефоне. '
                  'Создание появится в следующем обновлении.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: Wms.muted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Объект, «где я стою»: для работающих по геолокации — определённый по координатам,
  /// иначе — выбранный на главной; свежая установка получает первый с сервера.
  ({String? id, String? name, String? address}) _object(TaskRepository repo) {
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
