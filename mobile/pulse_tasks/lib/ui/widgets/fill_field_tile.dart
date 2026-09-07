import 'dart:io';

import 'package:flutter/material.dart';

import '../../models/fill.dart';
import '../theme.dart';
import 'fill/done_button.dart';
import 'fill/editors.dart';
import 'fill/photo_field.dart';

/// Renders one generic field by its [FillField.kind] and reports edits through
/// typed callbacks. Evidence (comment/photo) is revealed on a non-conformity.
///
/// Сама плитка — рамка: номер и имя, пометки, подсказка, примечание и доказательства.
/// Что рисовать в середине, решает редактор типа ([FillFieldEditor], реестр в
/// fill/editors.dart): плитка отдаёт ему поле и свои колбэки одним значением
/// ([FieldActions]) и не знает, чем шкала отличается от таблицы.
///
/// [readOnly] — тот же рендерер показывает поле значением, без единого контрола
/// ввода (#36778): просмотр прошлой проверки и завершённого бланка. Второго
/// рендерера под просмотр нет намеренно — сопровождался бы параллельно этому.
/// Колбэки редактирования в этом режиме не имеют смысла и потому необязательны:
/// экран просмотра передаёт только поле — а не десяток заглушек, в которых
/// случайно заживший контрол молча тонул бы.
class FillFieldTile extends StatefulWidget {
  final FillField field;
  final void Function(String optionCode)? onOption;
  final void Function(double? value)? onNumber;
  final void Function(String? text)? onText;
  final void Function(bool? value)? onBool;
  final VoidCallback? onDatePick;
  final VoidCallback? onScan;
  final void Function(String? comment)? onComment;
  final VoidCallback? onPhoto;
  final VoidCallback? onRemovePhoto;

  /// Убрать ОДИН кадр галереи (#36946). null — крестиков нет вовсе: экран просмотра
  /// и всякий, кто плитку только показывает.
  final void Function(FillShot shot)? onDeleteShot;
  final void Function(FillRowData row, FillColumn col, double? value)? onCell;

  /// Добавить строку табличного поля (#36943): предмет из справочника ([id]+[name]),
  /// свободный ввод (имя без id) или строка без предмета (оба null — поле без канала).
  /// null — плитка строк не заводит: просмотр и всякий, кто её только показывает.
  final Future<void> Function(String? subjectId, String? subjectName)? onAddRow;

  /// Убрать строку. null — удаления нет вовсе (тот же просмотр).
  final void Function(FillRowData row)? onDeleteRow;

  /// Кандидаты предмета строки: [allItems] — «показать все», второй эшелон поиска за
  /// пределами остатков объекта, ради находки, которой в остатках быть не должно.
  final Future<List<RefCandidate>> Function(String query, {bool allItems})?
      onRowSubjectSearch;

  /// Поле-ссылка (#36841): выбор предмета ([id]+[name]), свободный ввод (имя без id)
  /// или очистка (оба null); [onRefSearch] отдаёт кандидатов пикеру — при связи
  /// серверным поиском, офлайн из кэша бланка (см. FillController.searchSubjects).
  final void Function(String? id, String? name)? onRef;
  final Future<List<RefCandidate>> Function(String query)? onRefSearch;

  final bool readOnly;

  /// Снимок поля с сервера (просмотр прошлой проверки): миниатюра для галереи,
  /// полный размер по тапу. null — сетевых фото у этого экрана нет (текущий бланк
  /// показывает локальные файлы).
  final Future<File?> Function(int index, {required bool thumb})? photoLoader;

  /// «В прошлый раз здесь было замечание» — тап открывает просмотр на этом пункте.
  /// null — указатель не рисуется (сам экран просмотра, объект без истории).
  final VoidCallback? onOpenPast;

  const FillFieldTile({
    super.key,
    required this.field,
    this.onOption,
    this.onNumber,
    this.onText,
    this.onBool,
    this.onDatePick,
    this.onScan,
    this.onComment,
    this.onPhoto,
    this.onRemovePhoto,
    this.onDeleteShot,
    this.onCell,
    this.onAddRow,
    this.onDeleteRow,
    this.onRowSubjectSearch,
    this.onRef,
    this.onRefSearch,
    this.readOnly = false,
    this.photoLoader,
    this.onOpenPast,
  }) : assert(readOnly ||
            (onOption != null &&
                onNumber != null &&
                onText != null &&
                onBool != null &&
                onDatePick != null &&
                onScan != null &&
                onComment != null &&
                onPhoto != null &&
                onRemovePhoto != null &&
                onDeleteShot != null &&
                onCell != null &&
                onAddRow != null &&
                onDeleteRow != null &&
                onRowSubjectSearch != null &&
                onRef != null &&
                onRefSearch != null));

  @override
  State<FillFieldTile> createState() => _FillFieldTileState();
}

class _FillFieldTileState extends State<FillFieldTile> {
  late final TextEditingController _comment;

  /// the note box was unfolded by the user on this tile
  bool _showComment = false;

  /// Подтверждение и — что важнее — запись примечания по потере фокуса, чтобы текст,
  /// набранный и прокрученный прочь, не пропал молча (у контролов ввода типа — свои
  /// такие же узлы, см. fill/text_field.dart).
  final FocusNode _commentFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _comment = TextEditingController(text: widget.field.comment ?? '');
    _commentFocus.addListener(() {
      if (!_commentFocus.hasFocus) widget.onComment!(_comment.text);
      setState(() {});
    });
  }

  @override
  void dispose() {
    _comment.dispose();
    _commentFocus.dispose();
    super.dispose();
  }

  /// Колбэки — редактору типа одним значением; просмотр ([FillFieldTile.readOnly]) —
  /// тоже его дело: таблица в просмотре рисует подписи вместо полей ввода.
  FieldActions get _actions => FieldActions(
        onOption: widget.onOption,
        onNumber: widget.onNumber,
        onText: widget.onText,
        onBool: widget.onBool,
        onDatePick: widget.onDatePick,
        onScan: widget.onScan,
        onPhoto: widget.onPhoto,
        onRemovePhoto: widget.onRemovePhoto,
        onDeleteShot: widget.onDeleteShot,
        onCell: widget.onCell,
        onAddRow: widget.onAddRow,
        onDeleteRow: widget.onDeleteRow,
        onRowSubjectSearch: widget.onRowSubjectSearch,
        onRef: widget.onRef,
        onRefSearch: widget.onRefSearch,
        photoLoader: widget.photoLoader,
        readOnly: widget.readOnly,
      );

  @override
  Widget build(BuildContext context) {
    final f = widget.field;
    final bad = f.nonconformity;
    final actions = _actions;

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
                if (!widget.readOnly && f.required)
                  FieldBadge('обязательное', Wms.primary),
                if (f.critical) FieldBadge('критичное', Wms.warn),
                if (widget.readOnly && bad) FieldBadge('замечание', Wms.warn),
              ],
            ),
            // Указатель: только факт прошлого замечания, без значения — прошлое
            // значение рядом с вводом притягивает ответ, поэтому за ним надо уйти
            // на экран просмотра и вернуться (#36778, «Почему на плитке нет значения»)
            if (f.prevNonconformity && widget.onOpenPast != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: InkWell(
                  onTap: widget.onOpenPast,
                  borderRadius: BorderRadius.circular(6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.history, size: 14, color: Wms.warn),
                      const SizedBox(width: 4),
                      Text('в прошлый раз — замечание',
                          style: TextStyle(fontSize: 12, color: Wms.warn)),
                      Icon(Icons.chevron_right, size: 14, color: Wms.warn),
                    ],
                  ),
                ),
              ),
            if (f.hint != null && f.hint!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(f.hint!,
                    style: TextStyle(fontSize: 12, color: Wms.muted)),
              ),
            const SizedBox(height: 12),
            if (widget.readOnly) ...[
              _readOnlyValue(context, f, actions),
              if (f.hasPhoto) ...[
                const SizedBox(height: 10),
                PhotoGalleryView(field: f, actions: actions),
              ],
              if ((f.comment ?? '').isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('Примечание',
                    style: TextStyle(
                        fontSize: 12,
                        color: Wms.muted,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(f.comment!, style: const TextStyle(fontSize: 14)),
              ],
            ] else ...[
              editorFor(f).input(context, f, actions),
              if (bad) ...[
                const SizedBox(height: 10),
                Text(_evidenceHint(f),
                    style: TextStyle(
                        fontSize: 12,
                        color: f.needsEvidence ? Wms.warn : Wms.muted)),
                if (f.requirePhoto) ...[
                  const SizedBox(height: 10),
                  PhotoGallery(field: f, actions: actions),
                ],
              ],
              // A note belongs to every item, not only to a failed one: the paper form
              // carries a «Примечание» column on every row, and an inspector uses it to
              // explain a partial score just as often as a non-conformity.
              const SizedBox(height: 8),
              _commentSection(f, mandatory: f.needsComment),
            ],
          ],
        ),
      ),
    );
  }

  // --- просмотр: каждый тип поля показывается значением (#36778) ---

  Widget _readOnlyValue(
      BuildContext context, FillField f, FieldActions actions) {
    if (!f.answered) {
      return Text('— не отвечено',
          style: TextStyle(fontSize: 14, color: Wms.muted));
    }
    return editorFor(f).value(context, f, actions);
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
          Align(alignment: Alignment.centerRight, child: DoneButton(_commentFocus)),
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
        widget.onComment!(_comment.text);
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
}
