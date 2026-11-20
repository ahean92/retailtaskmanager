import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/fill.dart';
import '../theme.dart';
import 'ds.dart';
import 'fill/done_button.dart';
import 'fill/editors.dart';
import 'fill/photo_field.dart';

export 'fill/field_editor.dart' show FieldActions;

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

  /// Что бланк умеет делать с полем — колбэки экрана заполнения одним значением, их
  /// же плитка отдаёт редактору типа. Просмотр — `FieldActions(readOnly: true)`:
  /// без колбэков редактирования, в которых случайно заживший контрол молча тонул бы.
  final FieldActions actions;

  /// Примечание к полю — его пишет сама плитка, редактору типа оно не нужно.
  final void Function(String? comment)? onComment;

  /// «В прошлый раз здесь было замечание» — тап открывает просмотр на этом пункте.
  /// null — указатель не рисуется (сам экран просмотра, объект без истории).
  final VoidCallback? onOpenPast;

  /// Плитка — цель прыжка по незаполненным обязательным после отказа «Завершить»:
  /// рамка «вы здесь» живёт, пока поле не заполнено или прыжок не ушёл дальше.
  /// Просмотр плитки не подсвечивает вовсе.
  final bool flash;

  bool get readOnly => actions.readOnly;

  const FillFieldTile({
    super.key,
    required this.field,
    required this.actions,
    this.onComment,
    this.onOpenPast,
    this.flash = false,
  });

  @override
  State<FillFieldTile> createState() => _FillFieldTileState();
}

class _FillFieldTileState extends State<FillFieldTile> {
  late final TextEditingController _comment;

  /// the note box was unfolded by the user on this tile
  bool _showComment = false;

  /// Человек менял примечание, и оно ещё не записано. Пишется только такое. Сравнивать
  /// текст с моделью нельзя: бланк открывается из кэша, ответ сервера приходит позже,
  /// и пустое поле при непустой модели — ещё не правка. Запись «по отличию» уносила
  /// на сервер пустое примечание и стирала сохранённое в прошлый заход.
  bool _commentEdited = false;

  /// Подтверждение и — что важнее — запись примечания по потере фокуса, чтобы текст,
  /// набранный и прокрученный прочь, не пропал молча (у контролов ввода типа — свои
  /// такие же узлы, см. fill/text_field.dart).
  final FocusNode _commentFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    // редактор без колбэков молча глотал бы ввод — ловится при сборке экрана
    assert(widget.readOnly ||
        (widget.onComment != null &&
            widget.actions.onOption != null &&
            widget.actions.onNumber != null &&
            widget.actions.onText != null &&
            widget.actions.onBool != null &&
            widget.actions.onDatePick != null &&
            widget.actions.onScan != null &&
            widget.actions.onPhoto != null &&
            widget.actions.onRemovePhoto != null &&
            widget.actions.onDeleteShot != null &&
            widget.actions.onCell != null &&
            widget.actions.onAddRow != null &&
            widget.actions.onDeleteRow != null &&
            widget.actions.onRowSubjectSearch != null &&
            widget.actions.onRef != null &&
            widget.actions.onRefSearch != null));
    _comment = TextEditingController(text: widget.field.comment ?? '');
    _commentFocus.addListener(() {
      if (!_commentFocus.hasFocus) {
        // без правки писать нечего — зато пора показать то, что пришло, пока в поле
        // стоял курсор (didUpdateWidget его тогда не трогал)
        if (_commentEdited) {
          _commitComment();
        } else {
          _mirrorComment();
        }
      }
      setState(() {});
    });
  }

  @override
  void didUpdateWidget(covariant FillFieldTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Ответ сервера заменяет объект поля, а плитка живёт дальше (экран держит её по
    // GlobalKey): примечание обязано прийти следом. Текст под курсором не трогаем.
    if (!_commentFocus.hasFocus) _mirrorComment();
  }

  void _mirrorComment() {
    final t = widget.field.comment ?? '';
    if (_comment.text != t) _comment.text = t;
  }

  /// Записать примечание, если человек его менял. Просмотр не пишет никогда.
  void _commitComment() {
    if (!_commentEdited || widget.readOnly) return;
    _commentEdited = false;
    widget.onComment!(_comment.text);
  }

  @override
  void dispose() {
    // Тот же последний шанс, что у полей ввода (fill/text_field.dart):
    // закрытие экрана с открытым примечанием не запускает листенер расфокуса —
    // текст обязан уехать в черновик отсюда.
    _commitComment();
    _comment.dispose();
    _commentFocus.dispose();
    super.dispose();
  }

  /// Колбэки — редактору типа тем же значением; просмотр ([FillFieldTile.readOnly]) —
  /// тоже его дело: таблица в просмотре рисует подписи вместо полей ввода.
  FieldActions get _actions => widget.actions;

  @override
  Widget build(BuildContext context) {
    final f = widget.field;
    // просмотр — записанным сервером признаком: справочник вариантов с завершения могли
    // поправить, а замечание проверки от этого не исчезает (11.6)
    final bad = widget.readOnly ? f.shownNonconformity : f.nonconformity;
    final actions = _actions;

    // Карточка поля (#37411, п. 6): белая, радиус 16, рамка 1 px, без тени —
    // та же DsCard, но с рамкой «внимание» у несоответствия (единственная
    // цветная рамка на экране: просрочку карточек списка уже не красит ничто,
    // а здесь рамка — сигнал «это уйдёт в несоответствие», не стиль). Цель
    // прыжка по обязательным — та же рамка, но красным: это «суда», не «тревога».
    final pointed = widget.flash && !bad;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.all(16),
      decoration: dsCardDecoration(
        border: bad ? Wms.warn : (pointed ? Wms.danger : Wms.line),
        borderWidth: (bad || pointed) ? 1.5 : 1,
      ),
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
              // «Всегда»-режим (цеховые разделы): свидетельство обязательно при любом
              // ответе — бейдж виден до ответа, а не только на несоответствии
              if (!widget.readOnly && f.requirePhotoAlways && f.requireCommentAlways)
                FieldBadge('фото и примечание', Wms.warn)
              else if (!widget.readOnly &&
                  (f.requirePhotoAlways || f.requireCommentAlways))
                FieldBadge(
                    f.requirePhotoAlways
                        ? 'фото обязательно'
                        : 'примечание обязательно',
                    Wms.warn),
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
            ] else if (f.needsEvidence) ...[
              // «всегда»-режим без несоответствия: подсказка та же, но без слова
              // «несоответствие» — пункт отвечен нормально, свидетельство требует
              // настройка цехового раздела
              const SizedBox(height: 10),
              Text(_alwaysHint(f),
                  style: TextStyle(fontSize: 12, color: Wms.warn)),
            ],
            // галерея нужна и «всегда»-пункту при полном соответствии: без неё снять
            // требование фотографии на месте нельзя. И пункту со снимком, которому
            // ответ сменили на норму: снимок остаётся в проверке, и убрать его можно
            // только отсюда. У поля-фото галерея и есть редактор — вторая не нужна
            if (f.kind != FillFieldType.photo &&
                (f.requirePhotoAlways || (bad && f.requirePhoto) || f.hasPhoto)) ...[
              const SizedBox(height: 10),
              PhotoGallery(field: f, actions: actions),
            ],
            // A note belongs to every item, not only to a failed one: the paper form
            // carries a «Примечание» column on every row, and an inspector uses it to
            // explain a partial score just as often as a non-conformity.
            const SizedBox(height: 8),
            _commentSection(f, mandatory: f.needsComment),
          ],
        ],
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
      // 500 — сколько хранит сервер; длиннее он откажет, а не обрежет
      inputFormatters: [LengthLimitingTextInputFormatter(500)],
      textInputAction: TextInputAction.done,
      decoration: const InputDecoration(
        hintText: 'Комментарий…',
        border: OutlineInputBorder(),
        isDense: true,
      ),
      onChanged: (_) => _commentEdited = true,
      onEditingComplete: () {
        FocusScope.of(context).unfocus();
        _commitComment();
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

  String _alwaysHint(FillField f) {
    final needs = <String>[
      if (f.needsComment) 'примечание',
      if (f.needsPhoto) 'фото',
    ];
    return 'Добавьте ${needs.join(' и ')}';
  }
}
