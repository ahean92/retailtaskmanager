import 'package:flutter/material.dart';

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

  @override
  void dispose() {
    for (final c in _cells.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _tableInput(context, widget.field);

  /// Контроллер ячейки живёт по КЛЮЧУ строки, а не по её индексу (#36943): строки
  /// добавляются и удаляются, индексы после этого сдвигаются — и введённое число
  /// осталось бы в поле соседней позиции.
  TextEditingController _cellCtl(FillRowData row, FillColumn col) {
    final id = row.rowKey.isNotEmpty ? row.rowKey : '#${row.rowIndex}';
    return _cells.putIfAbsent('${id}_${col.code}', () {
      final v = row.numbers[col.code];
      return TextEditingController(text: v == null ? '' : trimNum(v));
    });
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
    if (await _askDelete(context, f, row)) widget.actions.onDeleteRow!(row);
  }

  Future<void> _addRow(BuildContext context, FillField f) async {
    // Поле без канала справочника предмета не выбирает — строка у него просто
    // очередная, и спрашивать нечего
    if ((f.refKind ?? '').isEmpty) {
      await widget.actions.onAddRow!(null, null);
      return;
    }
    final res = await showModalBottomSheet<RefPick>(
      context: context,
      isScrollControlled: true,
      builder: (_) => RowSubjectSheet(
        title: 'Добавить позицию',
        allowFree: f.allowFreeSubject,
        search: widget.actions.onRowSubjectSearch!,
      ),
    );
    if (res != null) await widget.actions.onAddRow!(res.id, res.name);
  }

  Widget _cell(
      BuildContext context, FillField f, FillRowData row, FillColumn col) {
    // подпись: просмотр, колонка только для чтения, вычисляемая или не число.
    // Вычисляемая считается ЗДЕСЬ, на телефоне (#36943): стоимость и расхождение
    // обязаны появиться, пока человек стоит у полки, а не после синхронизации
    if (widget.actions.readOnly || !col.editable) {
      final v = f.cellValue(row, col);
      final txt = row.texts[col.code] ?? (v == null ? '' : trimNum(v));
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
          widget.actions.onCell!(row, col,
              double.tryParse(_cellCtl(row, col).text.replaceAll(',', '.')));
        },
      ),
    );
  }
}
