import 'package:flutter/material.dart';

import '../../models/fill.dart';
import '../../models/quick_create.dart';
import '../theme.dart';
import 'form_card.dart';

/// Предпросмотр бланка на экране создания по пресету: разделы, поля с типом, нормой и
/// вариантами — чтобы человек видел, что его ждёт, до «Начать проверку». Только
/// чтение и только из кэша шаблона.
class TemplatePreview extends StatelessWidget {
  final PresetTemplate template;
  const TemplatePreview({super.key, required this.template});

  @override
  Widget build(BuildContext context) {
    final t = template;
    final widgets = <Widget>[
      FormCard(children: [
        FormLabel('Бланк'),
        Text(t.name ?? t.code,
            style: TextStyle(
                fontSize: 16, fontWeight: FontWeight.w700, color: Wms.text)),
        if (t.note != null)
          Text(t.note!, style: TextStyle(fontSize: 12, color: Wms.muted)),
        if (t.passThreshold != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: FormChip('Проходной порог: ${_fmt(t.passThreshold!)}%',
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
    return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch, children: widgets);
  }

  Widget _field(FillField f) => FormCard(children: [
        Text(f.name ?? f.code,
            style: TextStyle(fontWeight: FontWeight.w600, color: Wms.text)),
        if (f.hint != null)
          Text(f.hint!, style: TextStyle(fontSize: 12, color: Wms.muted)),
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 6, children: [
          FormChip(_typeLabel(f.type)),
          if (_norm(f) != null) FormChip(_norm(f)!),
          if (f.required) FormChip('обязательное', color: Wms.primary),
          if (f.critical) FormChip('критичное', color: Wms.warn),
          if (f.requirePhoto)
            FormChip('фото при несоотв.', icon: Icons.photo_camera_outlined),
        ]),
        if (f.options.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final o in f.options)
              FormChip(
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
              FormChip(
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
}
