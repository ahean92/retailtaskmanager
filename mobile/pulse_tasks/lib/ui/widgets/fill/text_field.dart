import 'package:flutter/material.dart';

import '../../../models/fill.dart';
import 'done_button.dart';
import 'field_editor.dart';

/// Текст в трёх видах: строка, многострочный ([multiline]) и код со сканером
/// ([scan]) — один контрол, потому что различаются они только клавиатурой и
/// кнопкой сканера. Неизвестный сервер тип тоже падает сюда (см. FillFieldType).
class TextFieldEditor extends FillFieldEditor {
  final bool multiline;
  final bool scan;
  const TextFieldEditor({this.multiline = false, this.scan = false});

  @override
  Widget value(BuildContext context, FillField f, FieldActions actions) =>
      Text(f.text ?? '', style: const TextStyle(fontSize: 14));

  @override
  Widget input(BuildContext context, FillField f, FieldActions actions) =>
      _TextInput(field: f, actions: actions, multiline: multiline, scan: scan);
}

class _TextInput extends StatefulWidget {
  final FillField field;
  final FieldActions actions;
  final bool multiline;
  final bool scan;
  const _TextInput(
      {required this.field,
      required this.actions,
      required this.multiline,
      required this.scan});

  @override
  State<_TextInput> createState() => _TextInputState();
}

class _TextInputState extends State<_TextInput> {
  late final TextEditingController _text;

  /// A multi-line field cannot show a "done" key: Android replaces it with a newline, so
  /// the confirm affordance has to live in the form. This node drives both that button
  /// and — more importantly — a commit on focus loss, so text typed and then scrolled
  /// away from is never silently dropped.
  final FocusNode _textFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _text = TextEditingController(text: widget.field.text ?? '');
    _textFocus.addListener(() {
      if (!_textFocus.hasFocus) widget.actions.onText!(_text.text);
      setState(() {});
    });
  }

  @override
  void didUpdateWidget(covariant _TextInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The scanner (and a reload) writes text into the model from outside this
    // tile; mirror it into the controller unless the user is typing right now.
    if (!_textFocus.hasFocus) {
      final t = widget.field.text ?? '';
      if (_text.text != t) _text.text = t;
    }
  }

  @override
  void dispose() {
    _text.dispose();
    _textFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final multiline = widget.multiline;
    final scan = widget.scan;
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
            suffixIcon: scan
                ? IconButton(
                    tooltip: 'Сканировать',
                    icon: const Icon(Icons.qr_code_scanner),
                    onPressed: () {
                      // commit what was typed before the scan overwrites it
                      _textFocus.unfocus();
                      widget.actions.onScan!();
                    },
                  )
                : null,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          onEditingComplete: () {
            FocusScope.of(context).unfocus();
            widget.actions.onText!(_text.text);
          },
        ),
        DoneButton(_textFocus),
      ],
    );
  }
}
