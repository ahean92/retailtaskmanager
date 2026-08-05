import 'dart:io';

import 'package:flutter/material.dart';

import '../../models/fill.dart';
import '../theme.dart';

/// Renders one generic field by its [FillField.type] and reports edits through
/// typed callbacks. Evidence (comment/photo) is revealed on a non-conformity.
class FillFieldTile extends StatefulWidget {
  final FillField field;
  final void Function(String optionCode) onOption;
  final void Function(double? value) onNumber;
  final void Function(String? text) onText;
  final void Function(bool? value) onBool;
  final VoidCallback onDatePick;
  final void Function(String? comment) onComment;
  final VoidCallback onPhoto;
  final VoidCallback onRemovePhoto;
  final void Function(FillRowData row, FillColumn col, double? value) onCell;

  const FillFieldTile({
    super.key,
    required this.field,
    required this.onOption,
    required this.onNumber,
    required this.onText,
    required this.onBool,
    required this.onDatePick,
    required this.onComment,
    required this.onPhoto,
    required this.onRemovePhoto,
    required this.onCell,
  });

  @override
  State<FillFieldTile> createState() => _FillFieldTileState();
}

class _FillFieldTileState extends State<FillFieldTile> {
  late final TextEditingController _text;
  late final TextEditingController _number;
  late final TextEditingController _comment;
  final Map<String, TextEditingController> _cells = {};

  /// the note box was unfolded by the user on this tile
  bool _showComment = false;

  /// A multi-line field cannot show a "done" key: Android replaces it with a newline, so
  /// the confirm affordance has to live in the form. These nodes drive both that button
  /// and — more importantly — a commit on focus loss, so text typed and then scrolled
  /// away from is never silently dropped.
  final FocusNode _textFocus = FocusNode();
  final FocusNode _commentFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _text = TextEditingController(text: widget.field.text ?? '');
    _number = TextEditingController(
        text: widget.field.number == null ? '' : _trimNum(widget.field.number!));
    _comment = TextEditingController(text: widget.field.comment ?? '');

    _textFocus.addListener(() {
      if (!_textFocus.hasFocus) widget.onText(_text.text);
      setState(() {});
    });
    _commentFocus.addListener(() {
      if (!_commentFocus.hasFocus) widget.onComment(_comment.text);
      setState(() {});
    });
  }

  @override
  void dispose() {
    _text.dispose();
    _number.dispose();
    _comment.dispose();
    _textFocus.dispose();
    _commentFocus.dispose();
    for (final c in _cells.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _cellCtl(FillRowData row, FillColumn col) {
    return _cells.putIfAbsent('${row.rowIndex}_${col.code}', () {
      final v = row.numbers[col.code];
      return TextEditingController(text: v == null ? '' : _trimNum(v));
    });
  }

  static String _trimNum(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  @override
  Widget build(BuildContext context) {
    final f = widget.field;
    final bad = f.nonconformity;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: bad ? Wms.warn : Wms.line,
          width: bad ? 1.5 : 0.5,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text('${f.fieldIndex}. ${f.name ?? ''}',
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600)),
                if (f.required) _Badge('обязательное', Wms.primary),
                if (f.critical) _Badge('критичное', Wms.warn),
              ],
            ),
            if (f.hint != null && f.hint!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(f.hint!,
                    style: TextStyle(fontSize: 12, color: Wms.muted)),
              ),
            const SizedBox(height: 12),
            _input(context, f),
            if (bad) ...[
              const SizedBox(height: 10),
              Text(_evidenceHint(f),
                  style: TextStyle(
                      fontSize: 12,
                      color: f.needsEvidence ? Wms.warn : Wms.muted)),
              if (f.requirePhoto) ...[
                const SizedBox(height: 10),
                _photoControl(context, f),
              ],
            ],
            // A note belongs to every item, not only to a failed one: the paper form
            // carries a «Примечание» column on every row, and an inspector uses it to
            // explain a partial score just as often as a non-conformity.
            const SizedBox(height: 8),
            _commentSection(f, mandatory: f.needsComment),
          ],
        ),
      ),
    );
  }

  Widget _input(BuildContext context, FillField f) {
    switch (f.type) {
      case 'scale':
      case 'choice':
        return _options(f);
      case 'number':
        return _numberInput(f);
      case 'score':
        return _scoreInput(f);
      case 'boolean':
        return _boolInput(f);
      case 'date':
        return _dateInput(f);
      case 'photo':
        return _photoControl(context, f);
      case 'longtext':
        return _textInput(multiline: true);
      case 'scan':
        return _textInput(scan: true);
      case 'table':
        return _tableInput(context, f);
      default: // text / objectref (fallback)
        return _textInput();
    }
  }

  // a numeric cell whose column compares against another differs from it
  bool _cellMismatch(FillRowData row, FillColumn col) {
    final other = col.compareTo;
    if (other == null) return false;
    final a = row.numbers[col.code];
    final b = row.numbers[other];
    return a != null && b != null && a != b;
  }

  bool _rowMismatch(FillField f, FillRowData row) =>
      f.columns.any((c) => _cellMismatch(row, c));

  Widget _tableInput(BuildContext context, FillField f) {
    if (f.columns.isEmpty) {
      return Text('Нет колонок',
          style: TextStyle(fontSize: 12, color: Wms.muted));
    }
    int flexOf(FillColumn c) => c.readonly ? 3 : 2;
    final mismatchCount = f.rows.where((r) => _rowMismatch(f, r)).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(
            children: [
              for (final col in f.columns)
                Expanded(
                  flex: flexOf(col),
                  child: Text(col.name ?? col.code,
                      style: TextStyle(
                          fontSize: 12,
                          color: Wms.muted,
                          fontWeight: FontWeight.w600)),
                ),
              const SizedBox(width: 20),
            ],
          ),
        ),
        const SizedBox(height: 4),
        for (final row in f.rows)
          Container(
            margin: const EdgeInsets.symmetric(vertical: 2),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            decoration: BoxDecoration(
              color: _rowMismatch(f, row) ? const Color(0xFFFBE9E7) : null,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                for (final col in f.columns)
                  Expanded(flex: flexOf(col), child: _cell(context, row, col)),
                SizedBox(
                  width: 20,
                  child: _rowMismatch(f, row)
                      ? Icon(Icons.warning_amber_rounded,
                          size: 16, color: Wms.warn)
                      : null,
                ),
              ],
            ),
          ),
        if (f.rows.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text('Нет позиций',
                style: TextStyle(fontSize: 13, color: Wms.muted)),
          ),
        if (mismatchCount > 0)
          Padding(
            padding: const EdgeInsets.only(top: 8, left: 6),
            child: Text('Расхождений: $mismatchCount из ${f.rows.length}',
                style: TextStyle(
                    fontSize: 13, color: Wms.warn, fontWeight: FontWeight.w600)),
          ),
      ],
    );
  }

  Widget _cell(BuildContext context, FillRowData row, FillColumn col) {
    // read-only (or non-numeric) cell → plain label
    if (col.readonly || col.type != 'number') {
      final txt = row.texts[col.code] ??
          (row.numbers[col.code] == null ? '' : _trimNum(row.numbers[col.code]!));
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Text(txt, style: const TextStyle(fontSize: 14)),
      );
    }
    // editable numeric cell — highlighted when it mismatches its compare column
    final bad = _cellMismatch(row, col);
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: TextField(
        controller: _cellCtl(row, col),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        textAlign: TextAlign.center,
        style: bad
            ? TextStyle(color: Wms.warn, fontWeight: FontWeight.w600)
            : null,
        decoration: InputDecoration(
          isDense: true,
          suffixText: col.unit,
          border: const OutlineInputBorder(),
          enabledBorder: bad
              ? OutlineInputBorder(
                  borderSide: BorderSide(color: Wms.warn, width: 1.5))
              : null,
        ),
        onEditingComplete: () {
          FocusScope.of(context).unfocus();
          widget.onCell(row, col,
              double.tryParse(_cellCtl(row, col).text.replaceAll(',', '.')));
        },
      ),
    );
  }

  Widget _options(FillField f) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final o in f.options)
          _OptionButton(
            label: o.name ?? o.code,
            selected: f.optionCode == o.code,
            nonconformity: o.nonconformity,
            onTap: () => widget.onOption(o.code),
          ),
      ],
    );
  }

  /// A `score` field: the inspector awards points out of the item's maximum.
  /// Deliberately a stepper and not a text field — this is filled in standing on
  /// the shop floor with a phone in one hand, and a free numeric input would also
  /// let a value through that the server then rejects for being over the maximum.
  Widget _scoreInput(FillField f) {
    final max = f.weight;
    final step = (f.step != null && f.step! > 0) ? f.step! : 0.5;
    final v = f.number;

    void award(double raw) {
      final clamped = raw < 0 ? 0.0 : (raw > max ? max : raw);
      // snap to the step so the value always matches what the buttons can produce
      final snapped = (clamped / step).round() * step;
      widget.onNumber(double.parse(snapped.toStringAsFixed(2)));
    }

    final full = v != null && v >= max;

    // Wms.warn is the palette's red — a zero on a checklist item is a loss, not a
    // warning, so it gets the red; a partial award is merely informational.
    final Color valueColor = v == null
        ? Wms.muted
        : (full ? Wms.ok : (v <= 0 ? Wms.warn : Wms.primary));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            IconButton(
              iconSize: 34,
              onPressed: (v ?? 0) <= 0 && v != null
                  ? null
                  : () => award((v ?? 0) - step),
              icon: const Icon(Icons.remove_circle_outline),
              color: Wms.muted,
            ),
            Expanded(
              child: Column(
                children: [
                  Text(
                    v == null ? '—' : '${_trimNum(v)} из ${_trimNum(max)}',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: valueColor,
                    ),
                  ),
                  Text('максимум ${_trimNum(max)}',
                      style: TextStyle(fontSize: 11, color: Wms.muted)),
                ],
              ),
            ),
            IconButton(
              iconSize: 34,
              onPressed: full ? null : () => award((v ?? 0) + step),
              icon: const Icon(Icons.add_circle_outline),
              color: Wms.muted,
            ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            TextButton(
              onPressed: () => award(0),
              child: const Text('0'),
            ),
            TextButton(
              onPressed: () => award(max),
              child: const Text('Полный балл'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _numberInput(FillField f) {
    final norm = [
      if (f.minNorm != null) 'от ${_trimNum(f.minNorm!)}',
      if (f.maxNorm != null) 'до ${_trimNum(f.maxNorm!)}',
    ].join(' ');
    return Row(
      children: [
        SizedBox(
          width: 120,
          child: TextField(
            controller: _number,
            keyboardType: const TextInputType.numberWithOptions(
                decimal: true, signed: true),
            textAlign: TextAlign.center,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              isDense: true,
              suffixText: f.unit,
            ),
            onEditingComplete: () {
              FocusScope.of(context).unfocus();
              widget.onNumber(
                  double.tryParse(_number.text.replaceAll(',', '.')));
            },
          ),
        ),
        const SizedBox(width: 10),
        if (norm.isNotEmpty)
          Text('Норма: $norm',
              style: TextStyle(fontSize: 12, color: Wms.muted)),
        const Spacer(),
        if (f.number != null)
          _Badge(f.inNorm ? 'в норме' : 'вне нормы',
              f.inNorm ? Wms.ok : Wms.warn),
      ],
    );
  }

  Widget _boolInput(FillField f) {
    return Row(
      children: [
        Expanded(
          child: _OptionButton(
            label: 'Да',
            selected: f.boolValue == true,
            nonconformity: false,
            onTap: () => widget.onBool(true),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _OptionButton(
            label: 'Нет',
            selected: f.boolValue == false,
            nonconformity: false,
            onTap: () => widget.onBool(false),
          ),
        ),
      ],
    );
  }

  Widget _textInput({bool multiline = false, bool scan = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        TextField(
          controller: _text,
          focusNode: _textFocus,
          minLines: multiline ? 2 : 1,
          maxLines: multiline ? 4 : 1,
          textInputAction:
              multiline ? TextInputAction.newline : TextInputAction.done,
          decoration: InputDecoration(
            hintText:
                scan ? 'Отсканируйте или введите код…' : 'Введите…',
            prefixIcon:
                scan ? const Icon(Icons.qr_code_scanner, size: 20) : null,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          onEditingComplete: () {
            FocusScope.of(context).unfocus();
            widget.onText(_text.text);
          },
        ),
        _doneButton(_textFocus),
      ],
    );
  }

  /// Confirm button for a text box, shown only while it has focus. On a multi-line field
  /// the keyboard offers a newline rather than a done key, so this is the only place the
  /// user can say "finished" — and the hand does reach for something.
  Widget _doneButton(FocusNode node) {
    if (!node.hasFocus) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: FilledButton.tonalIcon(
        onPressed: () => node.unfocus(), // the listener commits the value
        icon: const Icon(Icons.check, size: 18),
        label: const Text('Готово'),
        style: FilledButton.styleFrom(minimumSize: const Size(0, 38)),
      ),
    );
  }

  Widget _dateInput(FillField f) {
    return OutlinedButton.icon(
      onPressed: widget.onDatePick,
      icon: const Icon(Icons.event, size: 18),
      label: Text(f.date ?? 'Выбрать дату'),
    );
  }

  /// The note is always available but not always in the way: with 40 items on screen a
  /// permanently open text box per item turns the form into a wall. So an empty note is a
  /// one-line link, and it unfolds on tap — or immediately when it is required or filled.
  Widget _commentSection(FillField f, {required bool mandatory}) {
    final filled = (f.comment ?? '').isNotEmpty;
    if (_showComment || filled || mandatory) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(mandatory ? 'Примечание (обязательно)' : 'Примечание',
              style: TextStyle(
                  fontSize: 12,
                  color: mandatory ? Wms.warn : Wms.muted,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          _commentField(),
          Align(alignment: Alignment.centerRight, child: _doneButton(_commentFocus)),
        ],
      );
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: () => setState(() => _showComment = true),
        icon: Icon(Icons.notes, size: 18, color: Wms.muted),
        label: Text('Примечание',
            style: TextStyle(fontSize: 13, color: Wms.muted)),
        style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            minimumSize: const Size(0, 32)),
      ),
    );
  }

  Widget _commentField() {
    return TextField(
      controller: _comment,
      focusNode: _commentFocus,
      minLines: 1,
      maxLines: 3,
      textInputAction: TextInputAction.done,
      decoration: const InputDecoration(
        hintText: 'Комментарий…',
        border: OutlineInputBorder(),
        isDense: true,
      ),
      onEditingComplete: () {
        FocusScope.of(context).unfocus();
        widget.onComment(_comment.text);
      },
    );
  }

  String _evidenceHint(FillField f) {
    final needs = <String>[
      if (f.needsComment) 'комментарий',
      if (f.needsPhoto) 'фото',
    ];
    if (needs.isEmpty) return 'Несоответствие зафиксировано';
    return 'Несоответствие — добавьте ${needs.join(' и ')}';
  }

  /// A field holds 0..N photos, so this is a small gallery rather than a single slot:
  /// thumbnails of what was taken here, a tile to add one more, and a clear-all.
  Widget _photoControl(BuildContext context, FillField f) {
    if (f.photoPaths.isNotEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final path in f.photoPaths)
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.file(File(path),
                      width: 64,
                      height: 64,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _photoPlaceholder()),
                ),
              InkWell(
                onTap: widget.onPhoto,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    border: Border.all(color: Wms.line),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(Icons.add_a_photo,
                      size: 22, color: Wms.muted),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Text('фото: ${f.photoCount}',
                  style: TextStyle(fontSize: 12, color: Wms.muted)),
              const Spacer(),
              TextButton.icon(
                  onPressed: widget.onRemovePhoto,
                  icon: Icon(Icons.delete_outline,
                      size: 18, color: Wms.warn),
                  label: Text('Удалить все',
                      style: TextStyle(color: Wms.warn))),
            ],
          ),
        ],
      );
    }
    // photos exist on the server but were taken elsewhere — this device has no copies
    if (f.serverPhotoCount > 0) {
      return Wrap(
        spacing: 10,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.check_circle, size: 18, color: Colors.green.shade700),
            const SizedBox(width: 6),
            Text('фото приложено: ${f.serverPhotoCount}',
                style: const TextStyle(fontSize: 13)),
          ]),
          OutlinedButton.icon(
              onPressed: widget.onPhoto,
              icon: const Icon(Icons.add_a_photo, size: 18),
              label: const Text('Добавить')),
          TextButton.icon(
              onPressed: widget.onRemovePhoto,
              icon: Icon(Icons.delete_outline, size: 18, color: Wms.warn),
              label: Text('Удалить все',
                  style: TextStyle(color: Wms.warn))),
        ],
      );
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: FilledButton.tonalIcon(
        onPressed: widget.onPhoto,
        icon: const Icon(Icons.photo_camera, size: 18),
        label: const Text('Сделать фото'),
      ),
    );
  }

  Widget _photoPlaceholder() => Container(
        width: 64,
        height: 64,
        color: Wms.line,
        child: Icon(Icons.broken_image, color: Wms.muted),
      );
}

class _OptionButton extends StatelessWidget {
  final String label;
  final bool selected;
  final bool nonconformity;
  final VoidCallback onTap;
  const _OptionButton({
    required this.label,
    required this.selected,
    required this.nonconformity,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final Color bg, fg, border;
    if (selected && nonconformity) {
      bg = const Color(0xFFFBE9E7);
      fg = Wms.warn;
      border = Wms.warn;
    } else if (selected) {
      bg = Wms.active;
      fg = Wms.primaryDark;
      border = Wms.primary;
    } else {
      bg = Wms.card;
      fg = Wms.muted;
      border = Wms.line;
    }
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        constraints: const BoxConstraints(minHeight: 44, minWidth: 72),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: border, width: selected ? 1.5 : 0.5),
        ),
        child: Text(label,
            textAlign: TextAlign.center,
            style: TextStyle(
                color: fg,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400)),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final String text;
  final Color color;
  const _Badge(this.text, this.color);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(text, style: TextStyle(fontSize: 11, color: color)),
    );
  }
}
