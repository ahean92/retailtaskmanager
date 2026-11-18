import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../models/fill.dart';
import '../../theme.dart';
import '../pickers/ref_picker_sheet.dart';
import '../pickers/row_subject_sheet.dart';
import 'field_editor.dart';

/// Таблица (#36943): строки с предметом и замерами по колонкам, расчёт и итоги на
/// телефоне, добавление и удаление строк. В просмотре — тот же виджет с подписями
/// вместо полей ввода (см. `_cell`), поэтому [value] и [input] — одно.
class TableFieldEditor extends FillFieldEditor {
  const TableFieldEditor();

  @override
  Widget value(BuildContext context, FillField f, FieldActions actions) =>
      _TableInput(field: f, actions: actions);

  @override
  Widget input(BuildContext context, FillField f, FieldActions actions) =>
      _TableInput(field: f, actions: actions);
}

class _TableInput extends StatefulWidget {
  final FillField field;
  final FieldActions actions;
  const _TableInput({required this.field, required this.actions});

  @override
  State<_TableInput> createState() => _TableInputState();
}

class _TableInputState extends State<_TableInput> {
  final Map<String, TextEditingController> _cells = {};

  /// Узлы фокуса ячеек — тем же ключом, что контроллеры: после добавления строки
  /// курсор встаёт в её первую вводимую ячейку (#37192), а адресовать её можно только
  /// ключом строки — индексы сдвигаются.
  final Map<String, FocusNode> _focus = {};

  /// Ячейки с незакоммиченным вводом. Число уже в модели (пересчёт следует за
  /// вводом), но в ОЧЕРЕДЬ оно уезжает только по «Готово» или потере фокуса —
  /// а закрытие экрана посреди ввода фокус не отдаёт. Отсюда dirty-ключи,
  /// коммит по расфокусу ячейки и последний коммит в dispose.
  final Set<String> _dirty = {};

  /// Таблица уходит: последний коммит ячеек идёт без сообщений — показывать их уже
  /// негде.
  bool _closing = false;

  /// Число ячейки до начала правки. Модель следует за вводом, и по пути к «12.3.4»
  /// она успевает принять «12.3»: неразборчивый итог возвращает это, а не приставку.
  final Map<String, double?> _before = {};

  @override
  void dispose() {
    _closing = true;
    for (final row in widget.field.rows) {
      for (final col in widget.field.columns) {
        _commitCell(row, col);
      }
    }
    for (final c in _cells.values) {
      c.dispose();
    }
    for (final n in _focus.values) {
      n.dispose();
    }
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _TableInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Контроллер ячейки живёт дольше строки: бланк открывается из кэша, ответ
    // сервера заменяет объекты строк под открытой таблицей — и ячейка показывала
    // бы число из кэша рядом с итогом, посчитанным уже по новому. Ячейку под
    // курсором и набранное, но ещё не отправленное, не трогаем.
    for (final row in widget.field.rows) {
      for (final col in widget.field.columns) {
        final key = _cellKey(row, col);
        if (_dirty.contains(key) || (_focus[key]?.hasFocus ?? false)) continue;
        _mirrorCell(row, col);
      }
    }
  }

  @override
  Widget build(BuildContext context) => _tableInput(context, widget.field);

  /// Ключ ячейки — КЛЮЧ строки + код колонки: строки добавляются и удаляются,
  /// индексы после этого сдвигаются (см. [_cellCtl]).
  String _cellKey(FillRowData row, FillColumn col) {
    final id = row.rowKey.isNotEmpty ? row.rowKey : '#${row.rowIndex}';
    return '${id}_${col.code}';
  }

  /// Текст ячейки, каким его даёт модель.
  String _cellText(FillRowData row, FillColumn col) {
    if (!col.isNumber) return row.texts[col.code] ?? '';
    final v = row.numbers[col.code];
    return v == null ? '' : trimNum(v);
  }

  /// Число из набранного в ячейке: запятая — тот же разделитель, что и точка, пробелы
  /// между разрядами («1 000») не в счёт. Бесконечность («1e999») — не число.
  double? _cellNumber(String text) {
    final v = double.tryParse(
        text.replaceAll(RegExp(r'\s'), '').replaceAll(',', '.'));
    return v != null && v.isFinite ? v : null;
  }

  /// Контроллер ячейки живёт по КЛЮЧУ строки, а не по её индексу (#36943): строки
  /// добавляются и удаляются, индексы после этого сдвигаются — и введённое число
  /// осталось бы в поле соседней позиции.
  TextEditingController _cellCtl(FillRowData row, FillColumn col) {
    return _cells.putIfAbsent(_cellKey(row, col),
        () => TextEditingController(text: _cellText(row, col)));
  }

  /// Модель → ячейка. Число сверяется значением, а не записью: «10,5», набранное
  /// человеком, — то же 10.5, и переписывать его на свой лад незачем.
  void _mirrorCell(FillRowData row, FillColumn col) {
    final ctl = _cells[_cellKey(row, col)];
    if (ctl == null) return;
    if (col.isNumber && _cellNumber(ctl.text) == row.numbers[col.code]) return;
    final t = _cellText(row, col);
    if (ctl.text != t) ctl.text = t;
  }

  FocusNode _cellFocus(FillRowData row, FillColumn col) {
    final id = row.rowKey.isNotEmpty ? row.rowKey : '#${row.rowIndex}';
    final key = _cellKey(row, col);
    return _focus.putIfAbsent(key, () {
      final node = FocusNode(debugLabel: 'cell $id ${col.code}');
      // Фокус ушёл из ячейки — значение уезжает в очередь: набранное у полки
      // не должно зависеть от того, нажал ли человек «Готово» (и от связи).
      node.addListener(() {
        if (!node.hasFocus) _leaveCell(key);
      });
      return node;
    });
  }

  /// Ячейку покинули: набранное — в очередь, а нетронутая показывает то, что пришло,
  /// пока в ней стоял курсор. Строка берётся по ключу из ТЕКУЩЕГО поля, а не та, с
  /// которой создан узел фокуса: ответ сервера заменяет объекты строк, и запись в
  /// строку первой сборки до модели не доходила — итоги и «заполнено» её не видели.
  void _leaveCell(String key) {
    for (final row in widget.field.rows) {
      for (final col in widget.field.columns) {
        if (_cellKey(row, col) != key) continue;
        if (_dirty.contains(key)) {
          _commitCell(row, col);
        } else {
          _mirrorCell(row, col);
        }
        return;
      }
    }
  }

  /// Отдаёт ячейку в очередь — ровно то, что делало «Готово», но с guard'ом
  /// dirty, чтобы повторный коммит (расфокус + Done, dispose без ввода) не
  /// поднимал «не отправлено» на пустом месте.
  void _commitCell(FillRowData row, FillColumn col) {
    final key = _cellKey(row, col);
    if (!_dirty.contains(key)) return;
    _dirty.remove(key);
    final text = _cellCtl(row, col).text;
    if (col.isText) {
      widget.actions.onCellText?.call(row, col, text.trim());
      return;
    }
    final n = _cellNumber(text);
    final before = _before.remove(key);
    if (n == null && text.trim().isNotEmpty) {
      // Неразборчивое не стирает записанное: раньше в очередь молча уезжала
      // очистка. Ячейка и расчёт возвращаются к числу до правки, человек узнаёт
      // почему.
      row.numbers[col.code] = before;
      _cellCtl(row, col).text = _cellText(row, col);
      if (!_closing) {
        setState(() {});
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(const SnackBar(content: Text('Это не число')));
      }
      return;
    }
    widget.actions.onCell!(row, col, n);
  }

  // a numeric cell whose column compares against another differs from it
  //
  // Обе стороны — через cellValue, как mismatch на сервере: расчётная колонка-образец
  // раньше читалась сырым числом (пусто), а расчёт 1,1 × 3 без округления не совпадал
  // с 3,3 и давал ложное расхождение.
  bool _cellMismatch(FillField f, FillRowData row, FillColumn col) {
    final other = col.compareTo;
    if (other == null) return false;
    FillColumn? oc;
    for (final c in f.columns) {
      if (c.code == other) oc = c;
    }
    final a = f.cellValue(row, col);
    final b = oc == null ? row.numbers[other] : f.cellValue(row, oc);
    return a != null && b != null && a != b;
  }

  bool _rowMismatch(FillField f, FillRowData row) =>
      f.columns.any((c) => _cellMismatch(f, row, c));

  /// У строк этой таблицы есть предмет — тогда он и есть заголовок строки, а колонки
  /// остаются замерами. Проверяется по данным, а не по настройке поля: старые шаблоны
  /// держат товар текстовой колонкой, и лишняя пустая строка над ними только мешала бы.
  bool _hasSubjects(FillField f) =>
      f.rows.any((r) => (r.title ?? '').isNotEmpty);

  /// Ширина колонки. Вводимой её нужно БОЛЬШЕ, чем показываемой, а не меньше:
  /// пересчёт на пять колонок ужимает поле ввода до пары сантиметров, и набранное
  /// число в нём уже не помещается (поймано снимком на стенде). Подписи ужимаются
  /// без потери — число в поле ввода нет.
  int _flexOf(FillColumn c) => c.editable ? 3 : 2;

  /// Заголовок колонки вместе с единицей: «Факт, шт». Обязательная — со звёздочкой:
  /// пустая ячейка в ней держит завершение бланка.
  String _headerOf(FillColumn c) {
    final name = c.name ?? c.code;
    final head = (c.unit == null || c.unit!.isEmpty) ? name : '$name, ${c.unit}';
    return c.requiredInput ? '$head *' : head;
  }

  /// Текст ячейки для показа: вариант — подписью, «да/нет» — словом, дата — коротко,
  /// число — после расчёта.
  String _cellLabel(FillField f, FillRowData row, FillColumn col) {
    if (col.isBool) {
      final b = row.numbers[col.code];
      return b == null ? '' : (b != 0 ? 'Да' : 'Нет');
    }
    final t = row.texts[col.code];
    if (col.isChoice) {
      return t == null
          ? ''
          : (col.optionName(t) ?? row.optionNames[col.code] ?? t);
    }
    if (t != null) return col.isDate ? _dateLabel(t) : t;
    final v = f.cellValue(row, col);
    return v == null ? '' : trimNum(v);
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
    final canAdd = !widget.actions.readOnly && f.allowManual && widget.actions.onAddRow != null;
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
      onDismissed: (_) => widget.actions.onDeleteRow!(row),
      child: body,
    );
  }

  bool _deletable(FillField f, FillRowData row) =>
      !widget.actions.readOnly && widget.actions.onDeleteRow != null && f.canDeleteRow(row);

  Widget _subjectLine(FillField f, FillRowData row) {
    // позиция без названия подписана кодом, по которому её внесли (#37192)
    final name = row.title ?? 'Без предмета';
    final code = row.subjectCode ?? '';
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
          // код, по которому внесли, — рядом с названием: у полки сверяют именно его
          if (code.isNotEmpty && code != name)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Text(code,
                  style: TextStyle(fontSize: 12, color: Wms.muted)),
            ),
          // Внесистемная позиция — то, ради чего в пикере есть «показать все»: этой
          // позиции в остатках объекта нет, и находка обязана быть видна в бланке, а
          // не только в своде (#36780)
          if (row.offSystem)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: FieldBadge('вне системы', Wms.warn),
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
                          : trimNum(byCode[col.code]!))
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
    final name = row.title ?? 'позицию';
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
    if (await _askDelete(context, f, row)) widget.actions.onDeleteRow!(row);
  }

  Future<void> _addRow(BuildContext context, FillField f) async {
    // Поле без канала справочника предмета не выбирает — строка у него просто
    // очередная, и спрашивать нечего
    if ((f.refKind ?? '').isEmpty) {
      _focusFirstCell(f, await widget.actions.onAddRow!(null, null));
      return;
    }
    final res = await showModalBottomSheet<RefPick>(
      context: context,
      isScrollControlled: true,
      builder: (_) => RowSubjectSheet(
        title: 'Добавить позицию',
        allowFree: f.allowFreeSubject,
        search: widget.actions.onRowSubjectSearch!,
        scan: widget.actions.scanCode,
      ),
    );
    if (res == null) return;
    if (f.uniqueSubject) {
      final same = _sameSubject(f, res);
      if (same != null) {
        // «Уникальный предмет»: вторая строка той же позиции раздвоила бы её счёт —
        // ведём в уже внесённую, сервер повтор всё равно не примет
        if (context.mounted) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(
              content: Text('Эта позиция уже есть в таблице')));
        }
        _focusFirstCell(f, same);
        return;
      }
    }
    _focusFirstCell(
        f, await widget.actions.onAddRow!(res.id, res.name, code: res.code));
  }

  /// Строка с той же позицией: та же ссылка в справочник, а у свободной — то же
  /// название без учёта регистра (так же сравнивает сервер).
  FillRowData? _sameSubject(FillField f, RefPick res) {
    for (final r in f.rows) {
      if (res.id != null && res.id!.isNotEmpty) {
        if (r.subjectId == res.id) return r;
      } else if ((r.subjectId ?? '').isEmpty &&
          (r.subject ?? '').toLowerCase() == (res.name ?? '').toLowerCase()) {
        return r;
      }
    }
    return null;
  }

  /// Курсор — в первую вводимую ячейку только что добавленной строки (#37192): у полки
  /// после скана следующий жест — набрать факт, а не искать ячейку пальцем. Строка
  /// строится следующим кадром, поэтому фокус запрашивается после него.
  void _focusFirstCell(FillField f, FillRowData? row) {
    if (row == null || !mounted) return;
    FillColumn? first;
    for (final c in f.columns) {
      // дата, вариант и «да/нет» вводятся касанием, а не клавиатурой — курсору в них
      // делать нечего
      if (c.editable && !c.isDate && !c.isChoice && !c.isBool) {
        first = c;
        break;
      }
    }
    if (first == null) return;
    final node = _cellFocus(row, first);
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      node.requestFocus();
      final ctx = node.context;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx,
            alignment: 0.3, duration: const Duration(milliseconds: 200));
      }
    });
  }

  Widget _cell(
      BuildContext context, FillField f, FillRowData row, FillColumn col) {
    // подпись: просмотр, колонка только для чтения, вычисляемая или не число.
    // Вычисляемая считается ЗДЕСЬ, на телефоне (#36943): стоимость и расхождение
    // обязаны появиться, пока человек стоит у полки, а не после синхронизации
    if (widget.actions.readOnly || !col.editable) {
      final txt = _cellLabel(f, row, col);
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
    if (col.isDate) return _dateCell(context, row, col);
    if (col.isChoice) return _choiceCell(context, f, row, col);
    if (col.isBool) return _boolCell(context, row, col);
    if (col.isText) return _textCell(context, row, col);
    // editable numeric cell — highlighted when it mismatches its compare column
    final bad = _cellMismatch(f, row, col);
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: TextField(
        controller: _cellCtl(row, col),
        focusNode: _cellFocus(row, col),
        // со знаком: расхождение, возврат и списание бывают отрицательными
        keyboardType:
            const TextInputType.numberWithOptions(decimal: true, signed: true),
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
        onChanged: (text) {
          final key = _cellKey(row, col);
          if (!_dirty.contains(key)) _before[key] = row.numbers[col.code];
          // неразборчивое (недонабранное «-», опечатка) модель не трогает —
          // расчёт стоит на последнем числе; пустая ячейка — очистка
          final n = _cellNumber(text);
          if (n != null || text.trim().isEmpty) {
            setState(() => row.numbers[col.code] = n);
          }
          _dirty.add(key);
        },
        // Цифровая клавиатура iOS не имеет «Готово» — тап мимо ячейки там
        // единственный жест «закончил»; коммит сработает листенером фокуса.
        onTapOutside: (_) => FocusScope.of(context).unfocus(),
        onEditingComplete: () {
          FocusScope.of(context).unfocus();
          _commitCell(row, col);
        },
      ),
    );
  }

  /// Текстовая ячейка: код, пометка, серия. Уезжает по «Готово», как и число.
  Widget _textCell(BuildContext context, FillRowData row, FillColumn col) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: TextField(
        controller: _cellCtl(row, col),
        focusNode: _cellFocus(row, col),
        textAlign: TextAlign.center,
        // 250 — сколько хранит ячейка на сервере; длиннее он откажет, а не обрежет
        inputFormatters: [LengthLimitingTextInputFormatter(250)],
        decoration: const InputDecoration(
          isDense: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 10),
          border: OutlineInputBorder(),
        ),
        onChanged: (_) => _dirty.add(_cellKey(row, col)),
        onEditingComplete: () {
          FocusScope.of(context).unfocus();
          _commitCell(row, col);
        },
      ),
    );
  }

  /// Ячейка-выбор: нажатие — список вариантов колонки, выбранный код уезжает сразу
  /// (текстом, как и в офлайн-очереди ячеек). Долгое нажатие стирает, как у даты.
  Widget _choiceCell(
      BuildContext context, FillField f, FillRowData row, FillColumn col) {
    final code = row.texts[col.code];
    final label = _cellLabel(f, row, col);
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: InkWell(
        onTap: () => _pickCellOption(context, row, col),
        onLongPress: code == null
            ? null
            : () => widget.actions.onCellText?.call(row, col, null),
        child: InputDecorator(
          decoration: const InputDecoration(
            isDense: true,
            contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 10),
            border: OutlineInputBorder(),
          ),
          child: Text(code == null ? '—' : label,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 14, color: code == null ? Wms.muted : null)),
        ),
      ),
    );
  }

  Future<void> _pickCellOption(
      BuildContext context, FillRowData row, FillColumn col) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final o in col.options)
              ListTile(
                title: Text(o.name),
                trailing: row.texts[col.code] == o.code
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.of(ctx).pop(o.code),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    widget.actions.onCellText?.call(row, col, picked);
  }

  /// Ячейка «да/нет»: нажатие ставит «Да», следующее — «Нет», дальше переключает;
  /// долгое нажатие стирает. Значение — 1/0 числом, им же едет в очереди ячеек.
  Widget _boolCell(BuildContext context, FillRowData row, FillColumn col) {
    final b = row.numbers[col.code];
    final label = b == null ? '—' : (b != 0 ? 'Да' : 'Нет');
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: InkWell(
        onTap: () =>
            widget.actions.onCell?.call(row, col, (b == null || b == 0) ? 1 : 0),
        onLongPress:
            b == null ? null : () => widget.actions.onCell?.call(row, col, null),
        child: InputDecorator(
          decoration: const InputDecoration(
            isDense: true,
            contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 10),
            border: OutlineInputBorder(),
          ),
          child: Text(label,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: b == null ? Wms.muted : null)),
        ),
      ),
    );
  }

  /// Ячейка-дата («годен до» у изъятого товара): нажатие — календарь, выбранный день
  /// уезжает сразу. Долгое нажатие стирает — ошибочно поставленный срок иначе ничем
  /// не убрать: календарь умеет только выбрать другой день.
  Widget _dateCell(BuildContext context, FillRowData row, FillColumn col) {
    final iso = row.texts[col.code];
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: InkWell(
        onTap: () => _pickCellDate(context, row, col),
        onLongPress: iso == null
            ? null
            : () => widget.actions.onCellText?.call(row, col, null),
        child: InputDecorator(
          decoration: const InputDecoration(
            isDense: true,
            contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 10),
            border: OutlineInputBorder(),
          ),
          child: Text(iso == null ? '—' : _dateLabel(iso),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: iso == null ? Wms.muted : null)),
        ),
      ),
    );
  }

  Future<void> _pickCellDate(
      BuildContext context, FillRowData row, FillColumn col) async {
    final now = DateTime.now();
    final first = DateTime(now.year - 5);
    final last = DateTime(now.year + 5, 12, 31);
    final cur = DateTime.tryParse(row.texts[col.code] ?? '');
    final picked = await showDatePicker(
      context: context,
      initialDate:
          (cur != null && !cur.isBefore(first) && !cur.isAfter(last)) ? cur : now,
      firstDate: first,
      lastDate: last,
    );
    if (picked == null || !mounted) return;
    final iso = '${picked.year.toString().padLeft(4, '0')}-'
        '${picked.month.toString().padLeft(2, '0')}-'
        '${picked.day.toString().padLeft(2, '0')}';
    widget.actions.onCellText?.call(row, col, iso);
  }

  /// ГГГГ-ММ-ДД → ДД.ММ.ГГ: в узкой ячейке таблицы полная дата не помещается.
  static String _dateLabel(String iso) {
    final d = DateTime.tryParse(iso);
    if (d == null) return iso;
    return '${d.day.toString().padLeft(2, '0')}.'
        '${d.month.toString().padLeft(2, '0')}.'
        '${(d.year % 100).toString().padLeft(2, '0')}';
  }
}
