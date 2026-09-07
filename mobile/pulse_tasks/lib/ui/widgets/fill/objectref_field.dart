import 'package:flutter/material.dart';

import '../../../models/fill.dart';
import '../../theme.dart';
import '../pickers/ref_picker_sheet.dart';
import 'field_editor.dart';

/// Поле-ссылка (#36841): выбор из справочника канала.
class ObjectRefFieldEditor extends FillFieldEditor {
  const ObjectRefFieldEditor();

  // снимок на момент заполнения — ФИО не меняется после увольнения (#36841)
  @override
  Widget value(BuildContext context, FillField f, FieldActions actions) =>
      fieldValue(f.refName ?? '');

  /// Не выпадашка, а строка-значение, открывающая пикер с поиском: сотрудников
  /// магазина полсотни, номенклатуры тысячи. Старый сервер канала не шлёт — тогда
  /// выбора нет, показываем что есть.
  @override
  Widget input(BuildContext context, FillField f, FieldActions actions) {
    if (f.refKind == null) {
      return Text(f.refName ?? '— сервер не поддерживает выбор из справочника',
          style: TextStyle(fontSize: 13, color: Wms.muted));
    }
    final has = (f.refName ?? '').isNotEmpty;
    return Row(
      children: [
        Expanded(
          child: InkWell(
            onTap: () => _pickRef(context, f, actions),
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
            onPressed: () => actions.onRef!(null, null),
          ),
      ],
    );
  }

  Future<void> _pickRef(
      BuildContext context, FillField f, FieldActions actions) async {
    final res = await showModalBottomSheet<RefPick>(
      context: context,
      isScrollControlled: true,
      builder: (_) => RefPickerSheet(
        title: f.name ?? 'Выбор из справочника',
        allowFree: f.allowFreeSubject,
        search: actions.onRefSearch!,
      ),
    );
    if (res != null) actions.onRef!(res.id, res.name);
  }
}
