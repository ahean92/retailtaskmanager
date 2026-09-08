import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../models/fill.dart';
import '../theme.dart';

/// Renders one generic field by its [FillField.type] and reports edits through
/// typed callbacks. Evidence (comment/photo) is revealed on a non-conformity.
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
      if (!_textFocus.hasFocus) widget.onText!(_text.text);
      setState(() {});
    });
    _commentFocus.addListener(() {
      if (!_commentFocus.hasFocus) widget.onComment!(_comment.text);
      setState(() {});
    });
  }

  @override
  void didUpdateWidget(covariant FillFieldTile oldWidget) {
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
    _number.dispose();
    _comment.dispose();
    _textFocus.dispose();
    _commentFocus.dispose();
    for (final c in _cells.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// Контроллер ячейки живёт по КЛЮЧУ строки, а не по её индексу (#36943): строки
  /// добавляются и удаляются, индексы после этого сдвигаются — и введённое число
  /// осталось бы в поле соседней позиции.
  TextEditingController _cellCtl(FillRowData row, FillColumn col) {
    final id = row.rowKey.isNotEmpty ? row.rowKey : '#${row.rowIndex}';
    return _cells.putIfAbsent('${id}_${col.code}', () {
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
                if (!widget.readOnly && f.required)
                  _Badge('обязательное', Wms.primary),
                if (f.critical) _Badge('критичное', Wms.warn),
                if (widget.readOnly && bad) _Badge('замечание', Wms.warn),
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
              _readOnlyValue(context, f),
              if (f.hasPhoto) ...[
                const SizedBox(height: 10),
                _readOnlyPhotos(context, f),
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
          ],
        ),
      ),
    );
  }

  // --- просмотр: каждый тип поля показывается значением (#36778) ---

  Widget _readOnlyValue(BuildContext context, FillField f) {
    if (!f.answered) {
      return Text('— не отвечено',
          style: TextStyle(fontSize: 14, color: Wms.muted));
    }
    switch (f.type) {
      case 'scale':
      case 'choice':
        final o = f.selectedOption;
        return _valueText(o?.name ?? o?.code ?? f.optionCode ?? '',
            warn: o?.nonconformity ?? false);
      case 'boolean':
        return _valueText(f.boolValue == true ? 'Да' : 'Нет');
      // `answered` истинно и от одного фото, так что number здесь бывает null —
      // например, значение стёрли, а обязательный снимок остался (ревью #36778)
      case 'number':
        final n = f.number;
        if (n == null) return const SizedBox.shrink();
        final unit = f.unit == null ? '' : ' ${f.unit}';
        return Row(children: [
          _valueText('${_trimNum(n)}$unit', warn: !f.inNorm),
          const SizedBox(width: 10),
          _Badge(f.inNorm ? 'в норме' : 'вне нормы',
              f.inNorm ? Wms.ok : Wms.warn),
        ]);
      case 'score':
        final v = f.number;
        if (v == null) return const SizedBox.shrink();
        return _valueText('${_trimNum(v)} из ${_trimNum(f.weight)}',
            warn: v <= 0);
      case 'date':
        return _valueText(f.date ?? '');
      case 'photo':
        // ответ этого типа — сами снимки, галерея рисуется общим блоком ниже
        return const SizedBox.shrink();
      case 'table':
        return _tableInput(context, f); // ячейки в просмотре — подписи, см. _cell
      case 'objectref':
        // снимок на момент заполнения — ФИО не меняется после увольнения (#36841)
        return _valueText(f.refName ?? '');
      default: // text / longtext / scan
        return Text(f.text ?? '', style: const TextStyle(fontSize: 14));
    }
  }

  Widget _valueText(String text, {bool warn = false}) => Text(
        text,
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: warn ? Wms.warn : Wms.text,
        ),
      );

  /// Галерея просмотра: локальные файлы, если они на этом устройстве есть (свой
  /// завершённый бланк), иначе — миниатюры с сервера через [FillFieldTile.photoLoader];
  /// тап по миниатюре открывает полный размер. Без сети и без файла — плейсхолдер.
  Widget _readOnlyPhotos(BuildContext context, FillField f) {
    if (f.photoPaths.isNotEmpty) {
      return Wrap(
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
        ],
      );
    }
    final loader = widget.photoLoader;
    if (loader == null) {
      return Text('фото приложено: ${f.serverPhotoCount}',
          style: TextStyle(fontSize: 13, color: Wms.muted));
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        // фактические серверные индексы: после удаления они не уплотняются, и
        // «от 1 до count» промахнулся бы мимо снимков за дырой
        for (final i in f.photoGalleryIndexes)
          _ServerPhotoThumb(index: i, loader: loader),
      ],
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
      case 'objectref':
        return _refInput(context, f);
      default: // text (fallback)
        return _textInput();
    }
  }

  // --- поле-ссылка: выбор из справочника канала (#36841) ---

  /// Не выпадашка, а строка-значение, открывающая пикер с поиском: сотрудников
  /// магазина полсотни, номенклатуры тысячи. Старый сервер канала не шлёт — тогда
  /// выбора нет, показываем что есть.
  Widget _refInput(BuildContext context, FillField f) {
    if (f.refKind == null) {
      return Text(f.refName ?? '— сервер не поддерживает выбор из справочника',
          style: TextStyle(fontSize: 13, color: Wms.muted));
    }
    final has = (f.refName ?? '').isNotEmpty;
    return Row(
      children: [
        Expanded(
          child: InkWell(
            onTap: () => _pickRef(context, f),
            borderRadius: BorderRadius.circular(6),
            child: InputDecorator(
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                isDense: true,
                suffixIcon: Icon(Icons.search, size: 20),
              ),
              child: Text(
                has ? f.refName! : 'Выбрать…',
                style: has
                    ? const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600)
                    : TextStyle(fontSize: 15, color: Wms.muted),
              ),
            ),
          ),
        ),
        if (has)
          IconButton(
            tooltip: 'Очистить',
            icon: Icon(Icons.close, size: 20, color: Wms.muted),
            onPressed: () => widget.onRef!(null, null),
          ),
      ],
    );
  }

  Future<void> _pickRef(BuildContext context, FillField f) async {
    final res = await showModalBottomSheet<RefPick>(
      context: context,
      isScrollControlled: true,
      builder: (_) => RefPickerSheet(
        title: f.name ?? 'Выбор из справочника',
        allowFree: f.allowFreeSubject,
        search: widget.onRefSearch!,
      ),
    );
    if (res != null) widget.onRef!(res.id, res.name);
  }

  // a numeric cell whose column compares against another differs from it
  bool _cellMismatch(FillField f, FillRowData row, FillColumn col) {
    final other = col.compareTo;
    if (other == null) return false;
    final a = f.cellValue(row, col);
    final b = row.numbers[other];
    return a != null && b != null && a != b;
  }

  bool _rowMismatch(FillField f, FillRowData row) =>
      f.columns.any((c) => _cellMismatch(f, row, c));

  /// У строк этой таблицы есть предмет — тогда он и есть заголовок строки, а колонки
  /// остаются замерами. Проверяется по данным, а не по настройке поля: старые шаблоны
  /// держат товар текстовой колонкой, и лишняя пустая строка над ними только мешала бы.
  bool _hasSubjects(FillField f) =>
      f.rows.any((r) => (r.subject ?? '').isNotEmpty);

  /// Ширина колонки. Вводимой её нужно БОЛЬШЕ, чем показываемой, а не меньше:
  /// пересчёт на пять колонок ужимает поле ввода до пары сантиметров, и набранное
  /// число в нём уже не помещается (поймано снимком на стенде). Подписи ужимаются
  /// без потери — число в поле ввода нет.
  int _flexOf(FillColumn c) => c.editable ? 3 : 2;

  /// Заголовок колонки вместе с единицей: «Факт, шт».
  String _headerOf(FillColumn c) {
    final name = c.name ?? c.code;
    return (c.unit == null || c.unit!.isEmpty) ? name : '$name, ${c.unit}';
  }

  /// Ширина колонки жестов справа от строки: крестик удаления либо значок
  /// расхождения. Одна константа на шапку, строки и итоги — иначе они разъедутся.
  static const double _gutter = 28;

  Widget _tableInput(BuildContext context, FillField f) {
    if (f.columns.isEmpty) {
      return Text('Нет колонок',
          style: TextStyle(fontSize: 12, color: Wms.muted));
    }
    final mismatchCount = f.rows.where((r) => _rowMismatch(f, r)).length;
    final subjects = _hasSubjects(f);
    final totals = [
      for (final c in f.columns)
        if (c.totalMode != null) c
    ];
    // «+ позиция» — только у поля, которому шаблон разрешил ручные строки, и только
    // в редактируемом бланке: в просмотре состав строк уже история (#36778)
    final canAdd = !widget.readOnly && f.allowManual && widget.onAddRow != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(
            children: [
              for (final col in f.columns)
                Expanded(
                  flex: _flexOf(col),
                  // единица измерения живёт в ШАПКЕ, а не в ячейке: внутри узкой
                  // колонки суффикс встаёт в две строки и выдавливает набранное
                  // число — человек не видит, что он ввёл (снимок стенда #36943)
                  child: Text(_headerOf(col),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11,
                          color: Wms.muted,
                          fontWeight: FontWeight.w600)),
                ),
              const SizedBox(width: _gutter),
            ],
          ),
        ),
        const SizedBox(height: 4),
        for (final row in f.rows) _row(context, f, row, subjects),
        if (f.rows.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text('Нет позиций',
                style: TextStyle(fontSize: 13, color: Wms.muted)),
          ),
        if (totals.isNotEmpty && f.rows.isNotEmpty) _totals(f, totals),
        if (canAdd)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: TextButton.icon(
              onPressed: () => _addRow(context, f),
              icon: const Icon(Icons.add, size: 20),
              label: const Text('позиция'),
              style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  visualDensity: VisualDensity.compact),
            ),
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

  /// Одна строка таблицы: предмет строкой-заголовком, под ним замеры по колонкам.
  ///
  /// Удаление — и свайпом, и крестиком: свайп быстрее у полки, но он невидим, а
  /// человек, который о нём не знает, обязан найти способ убрать ошибочную позицию.
  Widget _row(
      BuildContext context, FillField f, FillRowData row, bool subjects) {
    final bad = _rowMismatch(f, row);
    final body = Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: bad ? Wms.warnTint : null,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (subjects) _subjectLine(f, row),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              for (final col in f.columns)
                Expanded(flex: _flexOf(col), child: _cell(context, f, row, col)),
              SizedBox(
                width: _gutter,
                child: _deletable(f, row)
                    ? IconButton(
                        tooltip: 'Убрать позицию',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        visualDensity: VisualDensity.compact,
                        icon: Icon(Icons.close, size: 18, color: Wms.muted),
                        onPressed: () => _confirmDelete(context, f, row),
                      )
                    : (bad
                        ? Icon(Icons.warning_amber_rounded,
                            size: 16, color: Wms.warn)
                        : null),
              ),
            ],
          ),
        ],
      ),
    );
    if (!_deletable(f, row)) return body;
    return Dismissible(
      key: ValueKey('row_${row.rowKey}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        color: Wms.warn,
        child: const Icon(Icons.delete_outline, color: Colors.white),
      ),
      confirmDismiss: (_) => _askDelete(context, f, row),
      onDismissed: (_) => widget.onDeleteRow!(row),
      child: body,
    );
  }

  bool _deletable(FillField f, FillRowData row) =>
      !widget.readOnly && widget.onDeleteRow != null && f.canDeleteRow(row);

  Widget _subjectLine(FillField f, FillRowData row) {
    final name = (row.subject ?? '').isNotEmpty ? row.subject! : 'Без предмета';
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        children: [
          Flexible(
            child: Text(name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w600)),
          ),
          // Внесистемная позиция — то, ради чего в пикере есть «показать все»: этой
          // позиции в остатках объекта нет, и находка обязана быть видна в бланке, а
          // не только в своде (#36780)
          if (row.offSystem)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: _Badge('вне системы', Wms.warn),
            ),
        ],
      ),
    );
  }

  /// Итоги по колонкам под таблицей. Считает телефон — по тем же значениям, что
  /// показаны выше, включая ещё не отправленные: итог, отстающий от строк над ним,
  /// читался бы как ошибка счёта. Сервер пересчитает своим и пришлёт при загрузке.
  Widget _totals(FillField f, List<FillColumn> totals) {
    final byCode = {for (final c in totals) c.code: f.columnTotal(c)};
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: Wms.muted.withValues(alpha: 0.3))),
        ),
        child: Row(
          children: [
            for (final col in f.columns)
              Expanded(
                flex: _flexOf(col),
                child: Text(
                  byCode.containsKey(col.code)
                      ? (byCode[col.code] == null
                          ? '—'
                          : _trimNum(byCode[col.code]!))
                      : (col == f.columns.first ? 'Итого' : ''),
                  textAlign: byCode.containsKey(col.code)
                      ? TextAlign.center
                      : TextAlign.start,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: byCode.containsKey(col.code) ? null : Wms.muted),
                ),
              ),
            const SizedBox(width: _gutter),
          ],
        ),
      ),
    );
  }

  Future<bool> _askDelete(
      BuildContext context, FillField f, FillRowData row) async {
    final name = (row.subject ?? '').isNotEmpty ? row.subject! : 'позицию';
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Убрать позицию?'),
            content: Text('«$name» исчезнет из бланка.'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('Отмена')),
              TextButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: const Text('Убрать')),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _confirmDelete(
      BuildContext context, FillField f, FillRowData row) async {
    if (await _askDelete(context, f, row)) widget.onDeleteRow!(row);
  }

  Future<void> _addRow(BuildContext context, FillField f) async {
    // Поле без канала справочника предмета не выбирает — строка у него просто
    // очередная, и спрашивать нечего
    if ((f.refKind ?? '').isEmpty) {
      await widget.onAddRow!(null, null);
      return;
    }
    final res = await showModalBottomSheet<RefPick>(
      context: context,
      isScrollControlled: true,
      builder: (_) => RowSubjectSheet(
        title: 'Добавить позицию',
        allowFree: f.allowFreeSubject,
        search: widget.onRowSubjectSearch!,
      ),
    );
    if (res != null) await widget.onAddRow!(res.id, res.name);
  }

  Widget _cell(
      BuildContext context, FillField f, FillRowData row, FillColumn col) {
    // подпись: просмотр, колонка только для чтения, вычисляемая или не число.
    // Вычисляемая считается ЗДЕСЬ, на телефоне (#36943): стоимость и расхождение
    // обязаны появиться, пока человек стоит у полки, а не после синхронизации
    if (widget.readOnly || !col.editable) {
      final v = f.cellValue(row, col);
      final txt = row.texts[col.code] ?? (v == null ? '' : _trimNum(v));
      final bad = _cellMismatch(f, row, col);
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Text(txt,
            style: TextStyle(
                fontSize: 14,
                color: bad ? Wms.warn : null,
                fontWeight: bad ? FontWeight.w600 : null)),
      );
    }
    // editable numeric cell — highlighted when it mismatches its compare column
    final bad = _cellMismatch(f, row, col);
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
          // ни суффикса, ни просторных отступов: единица ушла в шапку, а ячейка
          // отдана самому числу — оно тут единственное, что человек набирает
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
          border: const OutlineInputBorder(),
          enabledBorder: bad
              ? OutlineInputBorder(
                  borderSide: BorderSide(color: Wms.warn, width: 1.5))
              : null,
        ),
        // Расчёт следует за вводом, а не за подтверждением: расхождение и стоимость
        // пересчитываются на каждую цифру, поэтому setState — иначе человек увидел бы
        // их только уйдя с ячейки. На сервер уезжает по-прежнему готовое значение.
        onChanged: (_) => setState(() {
          row.numbers[col.code] =
              double.tryParse(_cellCtl(row, col).text.replaceAll(',', '.'));
        }),
        onEditingComplete: () {
          FocusScope.of(context).unfocus();
          widget.onCell!(row, col,
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
            onTap: () => widget.onOption!(o.code),
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
      widget.onNumber!(double.parse(snapped.toStringAsFixed(2)));
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
              widget.onNumber!(
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
            onTap: () => widget.onBool!(true),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _OptionButton(
            label: 'Нет',
            selected: f.boolValue == false,
            nonconformity: false,
            onTap: () => widget.onBool!(false),
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
            suffixIcon: scan
                ? IconButton(
                    tooltip: 'Сканировать',
                    icon: const Icon(Icons.qr_code_scanner),
                    onPressed: () {
                      // commit what was typed before the scan overwrites it
                      _textFocus.unfocus();
                      widget.onScan!();
                    },
                  )
                : null,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          onEditingComplete: () {
            FocusScope.of(context).unfocus();
            widget.onText!(_text.text);
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

  /// A field holds 0..N photos, so this is a small gallery rather than a single slot:
  /// thumbnails of what was taken here, a tile to add one more, and a clear-all.
  /// Галерея пункта покадрово: свои файлы и — миниатюрами с сервера — кадры, снятые
  /// на другом устройстве. Собранная контроллером [FillField.shots] знает про каждый
  /// снимок его серверный индекс, поэтому крестик удаляет ровно этот кадр (#36946).
  /// Модель без покадровой сборки (виджет-тесты, старый кэш) разворачивается сюда же
  /// из [FillField.photoPaths] и серверного счётчика — галерея одна на все случаи.
  List<FillShot> _galleryShots(FillField f) {
    if (f.shots.isNotEmpty) return f.shots;
    if (f.photoPaths.isNotEmpty) {
      return [
        for (var i = 0; i < f.photoPaths.length; i++)
          FillShot(path: f.photoPaths[i], localIdx: i)
      ];
    }
    return [
      for (final i in f.photoGalleryIndexes)
        FillShot(serverIndex: i, uploaded: true)
    ];
  }

  Widget _photoControl(BuildContext context, FillField f) {
    final shots = _galleryShots(f);
    if (shots.isEmpty) {
      return Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.tonalIcon(
          onPressed: widget.onPhoto,
          icon: const Icon(Icons.photo_camera, size: 18),
          label: const Text('Сделать фото'),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final shot in shots) _editableShot(context, f, shot),
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
                child: Icon(Icons.add_a_photo, size: 22, color: Wms.muted),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Text('фото: ${shots.length}',
                style: TextStyle(fontSize: 12, color: Wms.muted)),
            const Spacer(),
            TextButton.icon(
                onPressed: widget.onRemovePhoto,
                icon: Icon(Icons.delete_outline, size: 18, color: Wms.warn),
                label:
                    Text('Удалить все', style: TextStyle(color: Wms.warn))),
          ],
        ),
      ],
    );
  }

  /// Одна плитка галереи: сам кадр и крестик поверх него. Крестика нет у снимка,
  /// который нечем адресовать (уехал версией приложения, не знавшей серверных
  /// индексов, и сверка его пока не опознала) — для такого остаётся «Удалить все».
  Widget _editableShot(BuildContext context, FillField f, FillShot shot) {
    final loader = widget.photoLoader;
    final Widget image = shot.path != null
        ? ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.file(File(shot.path!),
                width: 64,
                height: 64,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _photoPlaceholder()),
          )
        : (loader == null || shot.serverIndex == null
            ? _photoPlaceholder()
            : _ServerPhotoThumb(index: shot.serverIndex!, loader: loader));
    if (!shot.canDelete || widget.onDeleteShot == null) return image;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        image,
        Positioned(
          top: -6,
          right: -6,
          child: Tooltip(
            message: 'Удалить снимок',
            child: InkWell(
              onTap: () => widget.onDeleteShot!(shot),
              customBorder: const CircleBorder(),
              child: Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: Wms.warn,
                  shape: BoxShape.circle,
                  border: Border.all(color: Wms.card, width: 2),
                ),
                child: const Icon(Icons.close, size: 13, color: Colors.white),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _photoPlaceholder() => Container(
        width: 64,
        height: 64,
        color: Wms.line,
        child: Icon(Icons.broken_image, color: Wms.muted),
      );
}

/// Миниатюра серверного снимка в просмотре: качается лениво и однажды (контроллер
/// держит дисковый кэш), тап открывает полный размер. Файла нет и сети нет —
/// честный плейсхолдер «фото недоступно офлайн».
class _ServerPhotoThumb extends StatelessWidget {
  final int index;
  final Future<File?> Function(int index, {required bool thumb}) loader;
  const _ServerPhotoThumb({required this.index, required this.loader});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<File?>(
      future: loader(index, thumb: true),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: Wms.line,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Center(
              child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          );
        }
        final file = snap.data;
        if (file == null) {
          return Tooltip(
            message: 'Фото недоступно офлайн',
            child: Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: Wms.line,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(Icons.cloud_off, size: 20, color: Wms.muted),
            ),
          );
        }
        return InkWell(
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => _PhotoViewer(index: index, loader: loader))),
          borderRadius: BorderRadius.circular(8),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            // файл могла удалить фоновая инвалидация кэша (прошлая проверка
            // сменилась под открытым экраном) — плейсхолдер, а не error-виджет
            child: Image.file(file,
                width: 64,
                height: 64,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                      width: 64,
                      height: 64,
                      color: Wms.line,
                      child: Icon(Icons.broken_image, color: Wms.muted),
                    )),
          ),
        );
      },
    );
  }
}

/// Полный размер по явному тапу — только тогда он и качается (#36778: просмотр в
/// поле не должен тянуть мегабайты фоном). Пока полный едет, показана миниатюра.
class _PhotoViewer extends StatelessWidget {
  final int index;
  final Future<File?> Function(int index, {required bool thumb}) loader;
  const _PhotoViewer({required this.index, required this.loader});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // как и просмотр снимка задачи: фон под фотографией чёрный в любой теме
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
      body: Center(
        child: FutureBuilder<File?>(
          future: loader(index, thumb: false),
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return FutureBuilder<File?>(
                future: loader(index, thumb: true),
                builder: (context, thumbSnap) => thumbSnap.data == null
                    ? const CircularProgressIndicator(color: Colors.white)
                    : Image.file(thumbSnap.data!,
                        errorBuilder: (_, __, ___) =>
                            const CircularProgressIndicator(
                                color: Colors.white)),
              );
            }
            final file = snap.data;
            if (file == null) {
              return const Text('Фото недоступно офлайн',
                  style: TextStyle(color: Colors.white70));
            }
            return InteractiveViewer(
                maxScale: 5,
                child: Image.file(file,
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const Text(
                        'Фото недоступно офлайн',
                        style: TextStyle(color: Colors.white70))));
          },
        ),
      ),
    );
  }
}

/// Результат пикера предмета: выбранный кандидат (id + имя) или свободный текст
/// (имя без id). null из showModalBottomSheet — пикер закрыт без выбора.
class RefPick {
  final String? id;
  final String? name;
  const RefPick({this.id, this.name});
}

/// Пикер предмета поля-ссылки (#36841): поиск с автодополнением, не выпадашка —
/// сотрудников магазина полсотни, номенклатуры тысячи. Кандидатов отдаёт [search]
/// (при связи — сервер, офлайн — кэш бланка); свободный ввод, если поле его
/// разрешает, — первой строкой по набранному тексту.
class RefPickerSheet extends StatefulWidget {
  final String title;
  final bool allowFree;
  final Future<List<RefCandidate>> Function(String query) search;
  const RefPickerSheet(
      {super.key,
      required this.title,
      required this.allowFree,
      required this.search});

  @override
  State<RefPickerSheet> createState() => _RefPickerSheetState();
}

class _RefPickerSheetState extends State<RefPickerSheet> {
  final TextEditingController _query = TextEditingController();
  Timer? _debounce;
  List<RefCandidate> _items = const [];
  bool _loading = true;

  /// Номер последнего запуска поиска: ответ обогнанного сетевого запроса не должен
  /// перетереть результат более позднего набора.
  int _searchSeq = 0;

  @override
  void initState() {
    super.initState();
    _run('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  Future<void> _run(String q) async {
    final seq = ++_searchSeq;
    setState(() => _loading = true);
    final items = await widget.search(q);
    if (!mounted || seq != _searchSeq) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  void _onChanged(String q) {
    _debounce?.cancel();
    _debounce =
        Timer(const Duration(milliseconds: 300), () => _run(q.trim()));
  }

  @override
  Widget build(BuildContext context) {
    final free = widget.allowFree ? _query.text.trim() : '';
    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.6,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
              child: Text(widget.title,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
              child: TextField(
                controller: _query,
                autofocus: true,
                onChanged: (q) {
                  _onChanged(q);
                  setState(() {}); // строка свободного ввода следует за текстом
                },
                decoration: const InputDecoration(
                  hintText: 'Поиск…',
                  prefixIcon: Icon(Icons.search),
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            if (free.isNotEmpty)
              ListTile(
                leading: Icon(Icons.edit_note, color: Wms.muted),
                title: Text('Записать текстом: «$free»'),
                onTap: () => Navigator.of(context).pop(RefPick(name: free)),
              ),
            if (_loading)
              const Expanded(
                  child: Center(child: CircularProgressIndicator()))
            else if (_items.isEmpty)
              Expanded(
                child: Center(
                  child: Text(
                    widget.allowFree
                        ? 'Ничего не найдено — можно записать текстом'
                        : 'Ничего не найдено',
                    style: TextStyle(fontSize: 13, color: Wms.muted),
                  ),
                ),
              )
            else
              Expanded(
                child: ListView.builder(
                  itemCount: _items.length,
                  itemBuilder: (context, i) {
                    final c = _items[i];
                    return ListTile(
                      title: Text(c.name),
                      onTap: () => Navigator.of(context)
                          .pop(RefPick(id: c.id, name: c.name)),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Пикер предмета СТРОКИ таблицы (#36943). Отличается от [RefPickerSheet] ровно
/// одним, но принципиальным: переключателем «показать все».
///
/// По умолчанию показано доступное на объекте задачи — остатки этого магазина. Но
/// самая ценная находка пересчёта — товар, которого в остатках быть не должно, и её
/// физически нечем внести, пока поиск ограничен доступным. Поэтому доступность здесь
/// подсказка, а не запрет (дизайн, раздел 12.5): второй эшелон — весь канал, и
/// найденная в нём позиция станет строкой с пометкой «вне системы».
class RowSubjectSheet extends StatefulWidget {
  final String title;
  final bool allowFree;
  final Future<List<RefCandidate>> Function(String query, {bool allItems})
      search;
  const RowSubjectSheet(
      {super.key,
      required this.title,
      required this.allowFree,
      required this.search});

  @override
  State<RowSubjectSheet> createState() => _RowSubjectSheetState();
}

class _RowSubjectSheetState extends State<RowSubjectSheet> {
  final TextEditingController _query = TextEditingController();
  Timer? _debounce;
  List<RefCandidate> _items = const [];
  bool _loading = true;
  bool _all = false;

  /// Номер последнего запуска поиска: ответ обогнанного запроса не должен перетереть
  /// результат более позднего набора (та же защита, что в [RefPickerSheet]).
  int _searchSeq = 0;

  @override
  void initState() {
    super.initState();
    _run('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  Future<void> _run(String q) async {
    final seq = ++_searchSeq;
    setState(() => _loading = true);
    final items = await widget.search(q, allItems: _all);
    if (!mounted || seq != _searchSeq) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  void _onChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _run(q.trim()));
  }

  @override
  Widget build(BuildContext context) {
    final free = widget.allowFree ? _query.text.trim() : '';
    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.6,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
              child: Text(widget.title,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: TextField(
                controller: _query,
                autofocus: true,
                onChanged: (q) {
                  _onChanged(q);
                  setState(() {}); // строка свободного ввода следует за текстом
                },
                decoration: const InputDecoration(
                  hintText: 'Поиск…',
                  prefixIcon: Icon(Icons.search),
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 16, 0),
              child: Row(
                children: [
                  Switch(
                    value: _all,
                    onChanged: (v) {
                      setState(() => _all = v);
                      _run(_query.text.trim());
                    },
                  ),
                  Expanded(
                    child: Text(
                      _all
                          ? 'Весь справочник'
                          : 'Только то, что числится на объекте',
                      style: TextStyle(fontSize: 13, color: Wms.muted),
                    ),
                  ),
                ],
              ),
            ),
            if (free.isNotEmpty)
              ListTile(
                leading: Icon(Icons.edit_note, color: Wms.muted),
                title: Text('Записать текстом: «$free»'),
                onTap: () => Navigator.of(context).pop(RefPick(name: free)),
              ),
            if (_loading)
              const Expanded(child: Center(child: CircularProgressIndicator()))
            else if (_items.isEmpty)
              Expanded(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Text(
                      _all
                          ? (widget.allowFree
                              ? 'Ничего не найдено — можно записать текстом'
                              : 'Ничего не найдено')
                          : 'На объекте не числится — включите «весь справочник»',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 13, color: Wms.muted),
                    ),
                  ),
                ),
              )
            else
              Expanded(
                child: ListView.builder(
                  itemCount: _items.length,
                  itemBuilder: (context, i) {
                    final c = _items[i];
                    return ListTile(
                      title: Text(c.name),
                      // позиция, которой на объекте нет, помечена уже в выборе:
                      // человек должен знать, что вносит находку, ДО того как внёс
                      subtitle: c.available
                          ? null
                          : Text('нет в остатках объекта',
                              style:
                                  TextStyle(fontSize: 12, color: Wms.warn)),
                      onTap: () => Navigator.of(context)
                          .pop(RefPick(id: c.id, name: c.name)),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
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
      bg = Wms.warnTint;
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
