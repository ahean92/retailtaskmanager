import 'dart:async';

import 'package:flutter/material.dart';

import '../../../models/fill.dart';
import '../../theme.dart';

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
