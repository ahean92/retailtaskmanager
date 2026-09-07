import 'dart:async';

import 'package:flutter/material.dart';

import '../../../models/fill.dart';
import '../../theme.dart';
import 'ref_picker_sheet.dart';

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
