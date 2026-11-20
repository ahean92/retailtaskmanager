import 'package:flutter/material.dart';

import '../../../models/fill.dart';
import '../../theme.dart';
import 'search_sheet.dart';

/// Результат пикера предмета: выбранный кандидат (id + имя) или свободный текст
/// (имя без id). null из showModalBottomSheet — пикер закрыт без выбора.
///
/// [code] (#37192) — отсканированный или набранный код, по которому позицию нашли
/// или, если не нашли нигде, вносят: уезжает в строку как есть.
class RefPick {
  final String? id;
  final String? name;
  final String? code;
  const RefPick({this.id, this.name, this.code});
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

class _RefPickerSheetState extends State<RefPickerSheet>
    with SearchSheet<RefPickerSheet> {
  @override
  Future<List<RefCandidate>> find(String q) => widget.search(q);

  @override
  Widget build(BuildContext context) {
    final free = widget.allowFree ? query.text.trim() : '';
    return sheetFrame(
      context,
      title: widget.title,
      fieldPadding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      field: TextField(
        controller: query,
        autofocus: true,
        onChanged: onQueryChanged,
        decoration: const InputDecoration(
          hintText: 'Поиск…',
          prefixIcon: Icon(Icons.search),
          border: OutlineInputBorder(),
          isDense: true,
        ),
      ),
      extra: [
        if (free.isNotEmpty)
          freeTile(
              free, () => Navigator.of(context).pop(RefPick(name: free))),
      ],
      empty: Text(
        widget.allowFree
            ? 'Ничего не найдено — можно записать текстом'
            : 'Ничего не найдено',
        style: TextStyle(fontSize: 13, color: Wms.muted),
      ),
      tile: (c) => ListTile(
        title: Text(c.name),
        onTap: () =>
            Navigator.of(context).pop(RefPick(id: c.id, name: c.name)),
      ),
    );
  }
}