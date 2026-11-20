import 'dart:async';

import 'package:flutter/material.dart';

import '../../../models/fill.dart';
import '../../theme.dart';

/// Общее у листов поиска предмета — поля-ссылки ([RefPickerSheet]) и строки таблицы
/// ([RowSubjectSheet]): строка поиска с задержкой, защита от обогнанного ответа и
/// рамка листа — заголовок, поле, список кандидатов. Чем листы различаются (ввод
/// кода, «весь справочник», подпись кандидата), остаётся у каждого.
mixin SearchSheet<T extends StatefulWidget> on State<T> {
  final TextEditingController query = TextEditingController();
  Timer? _debounce;
  List<RefCandidate> items = const [];
  bool loading = true;

  /// Номер последнего запуска поиска: ответ обогнанного сетевого запроса не должен
  /// перетереть результат более позднего набора.
  int _searchSeq = 0;

  /// Кандидаты по строке — у каждого листа свой поиск.
  Future<List<RefCandidate>> find(String q);

  /// Сброс состояния листа перед новым поиском (внутри setState).
  void resetForSearch() {}

  @override
  void initState() {
    super.initState();
    run('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    query.dispose();
    super.dispose();
  }

  Future<void> run(String q) async {
    final seq = ++_searchSeq;
    setState(() {
      loading = true;
      resetForSearch();
    });
    final found = await find(q);
    if (!mounted || !isLatest(seq)) return;
    setState(() {
      items = found;
      loading = false;
    });
  }

  /// Номер для своего поиска мимо [run] (ввод кода): отложенный набор отменяется.
  int nextSearch() {
    _debounce?.cancel();
    return ++_searchSeq;
  }

  /// Ответ поиска [seq] не обогнан более поздним набором.
  bool isLatest(int seq) => seq == _searchSeq;

  void onQueryChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => run(q.trim()));
    setState(() {}); // строка свободного ввода следует за текстом
  }

  /// Строка «Записать текстом: «…»» по набранному тексту — свободный ввод.
  Widget freeTile(String free, VoidCallback onTap) => ListTile(
        leading: Icon(Icons.edit_note, color: Wms.muted),
        title: Text('Записать текстом: «$free»'),
        onTap: onTap,
      );

  /// Рамка листа: заголовок, [field] с отступом [fieldPadding], [extra] под ним и
  /// список кандидатов — индикатор, пустой ответ [empty] или строки [tile].
  Widget sheetFrame(
    BuildContext context, {
    required String title,
    required Widget field,
    required EdgeInsetsGeometry fieldPadding,
    List<Widget> extra = const [],
    required Widget empty,
    required Widget Function(RefCandidate c) tile,
  }) {
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
              child: Text(title,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600)),
            ),
            Padding(padding: fieldPadding, child: field),
            ...extra,
            if (loading)
              const Expanded(child: Center(child: CircularProgressIndicator()))
            else if (items.isEmpty)
              Expanded(child: Center(child: empty))
            else
              Expanded(
                child: ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (context, i) => tile(items[i]),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
