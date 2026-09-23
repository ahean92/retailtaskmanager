import 'dart:async';

import 'package:flutter/material.dart';

import '../../../models/fill.dart';
import '../../theme.dart';
import 'ref_picker_sheet.dart';

/// Что нашлось по отсканированному или набранному коду (#37192): точные совпадения
/// среди доступного на объекте, а если там пусто — во всём справочнике ([fromAll]).
class CodeLookup {
  final String code;
  final List<RefCandidate> matches;

  /// Совпадения есть только за пределами остатков объекта — позиция станет строкой
  /// «вне системы», как при «показать все».
  final bool fromAll;

  const CodeLookup(this.code, this.matches, {this.fromAll = false});

  bool get none => matches.isEmpty;
  bool get single => matches.length == 1;
}

/// Поиск позиции по коду или штрихкоду — правила тикета #37192: точное совпадение
/// среди доступного на объекте, иначе сразу во всём справочнике. Без связи оба
/// эшелона отвечают кэшем бланка (FillController.searchRowSubjects), и правила те же.
Future<CodeLookup> lookupByCode(
    String code,
    Future<List<RefCandidate>> Function(String query, {bool allItems})
        search) async {
  final q = code.trim();
  final near = await search(q, allItems: false);
  final exactNear = [
    for (final c in near)
      if (c.matchesCode(q)) c
  ];
  if (exactNear.isNotEmpty) return CodeLookup(q, exactNear);
  final all = await search(q, allItems: true);
  final exactAll = [
    for (final c in all)
      if (c.matchesCode(q)) c
  ];
  return CodeLookup(q, exactAll, fromAll: true);
}

/// Пикер предмета СТРОКИ таблицы (#36943). Отличается от [RefPickerSheet] ровно
/// одним, но принципиальным: переключателем «показать все».
///
/// По умолчанию показано доступное на объекте задачи — остатки этого магазина. Но
/// самая ценная находка пересчёта — товар, которого в остатках быть не должно, и её
/// физически нечем внести, пока поиск ограничен доступным. Поэтому доступность здесь
/// подсказка, а не запрет (дизайн, раздел 12.5): второй эшелон — весь канал, и
/// найденная в нём позиция станет строкой с пометкой «вне системы».
///
/// Ввод по штрихкоду или коду (#37192): у полки товар опознают сканом или кодом, а не
/// ищут по названию. Одно поле — «Штрихкод, код или название» — с кнопкой сканера
/// ([scan]). Скан или подтверждение ввода идёт через [lookupByCode]: одно точное
/// совпадение закрывает лист сразу (строка добавится, курсор встанет в «Факт»),
/// несколько — список на выбор, нет нигде — при разрешённом свободном вводе
/// предложение внести позицию с сохранённым кодом, иначе отказ. Набор текста
/// по-прежнему ищет списком, автодобавления по ходу набора нет: код-префикс
/// сработал бы раньше, чем человек его дописал.
class RowSubjectSheet extends StatefulWidget {
  final String title;
  final bool allowFree;
  final Future<List<RefCandidate>> Function(String query, {bool allItems})
      search;

  /// Сканер: открыть камеру и вернуть код, null — человек вышел. null — кнопки
  /// сканера нет (камеры на устройстве нет, просмотр).
  final Future<String?> Function()? scan;

  const RowSubjectSheet(
      {super.key,
      required this.title,
      required this.allowFree,
      required this.search,
      this.scan});

  @override
  State<RowSubjectSheet> createState() => _RowSubjectSheetState();
}

class _RowSubjectSheetState extends State<RowSubjectSheet> {
  final TextEditingController _query = TextEditingController();

  /// Название для позиции по неизвестному коду — поле диалога. Живёт со стейтом, а не
  /// с диалогом: уничтоженный сразу после закрытия контроллер ещё нужен полю, пока
  /// диалог доигрывает анимацию ухода.
  final TextEditingController _freeName = TextEditingController();
  Timer? _debounce;
  List<RefCandidate> _items = const [];
  bool _loading = true;
  bool _all = false;

  /// Код, по которому построен текущий список (несколько совпадений): выбор из него
  /// уезжает в строку вместе с этим кодом. Набор нового текста его сбрасывает.
  String? _enteredCode;

  /// Строка над списком: «несколько совпадений», «не найден».
  String? _notice;

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
    _freeName.dispose();
    super.dispose();
  }

  Future<void> _run(String q) async {
    final seq = ++_searchSeq;
    setState(() {
      _loading = true;
      _enteredCode = null;
      _notice = null;
    });
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

  /// Ввод кода — сканом или подтверждением набранного (#37192).
  Future<void> _enterCode(String raw) async {
    final code = raw.trim();
    if (code.isEmpty) return;
    _debounce?.cancel();
    final seq = ++_searchSeq;
    setState(() {
      _loading = true;
      _enteredCode = null;
      _notice = null;
    });
    final res = await lookupByCode(code, widget.search);
    if (!mounted || seq != _searchSeq) return;
    if (res.single) {
      // точное совпадение добавляет позицию сразу, без выбора из списка
      final c = res.matches.single;
      Navigator.of(context).pop(RefPick(id: c.id, name: c.name, code: code));
      return;
    }
    if (!res.none) {
      setState(() {
        _items = res.matches;
        _loading = false;
        _enteredCode = code;
        _notice = 'Несколько совпадений по «$code» — выберите';
      });
      return;
    }
    setState(() {
      _items = const [];
      _loading = false;
    });
    if (widget.allowFree) {
      await _offerFree(code);
    } else {
      setState(() => _notice = 'Товар с кодом «$code» не найден');
    }
  }

  /// Неизвестный код при разрешённом свободном вводе: предложить внести позицию,
  /// сохранив код в строке. Название по желанию — код неизвестного товара и есть то,
  /// что нужно при разборе расхождения, без названия строка подписана кодом.
  Future<void> _offerFree(String code) async {
    _freeName.clear();
    final add = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Товар не найден'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Код «$code» не найден ни на объекте, ни в справочнике. '
                'Внести позицию с этим кодом?'),
            const SizedBox(height: 12),
            TextField(
              controller: _freeName,
              autofocus: true,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => Navigator.of(ctx).pop(true),
              decoration: const InputDecoration(
                labelText: 'Название (необязательно)',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Отмена')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Внести')),
        ],
      ),
    );
    final name = _freeName.text.trim();
    if (!mounted) return;
    if (add == true) {
      Navigator.of(context)
          .pop(RefPick(name: name.isEmpty ? null : name, code: code));
    } else {
      setState(() => _notice = 'Товар с кодом «$code» не найден');
    }
  }

  Future<void> _scan() async {
    final code = await widget.scan!();
    if (!mounted || code == null || code.trim().isEmpty) return;
    _query.text = code.trim(); // человек видит, что отсканировалось
    await _enterCode(code);
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
                textInputAction: TextInputAction.search,
                onChanged: (q) {
                  _onChanged(q);
                  setState(() {}); // строка свободного ввода следует за текстом
                },
                onSubmitted: _enterCode,
                decoration: InputDecoration(
                  hintText: 'Штрихкод, код или название',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: widget.scan == null
                      ? null
                      : IconButton(
                          tooltip: 'Сканировать штрихкод',
                          icon: const Icon(Icons.qr_code_scanner),
                          onPressed: _scan,
                        ),
                  border: const OutlineInputBorder(),
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
            if (_notice != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: Text(_notice!,
                    style: TextStyle(
                        fontSize: 13,
                        color: Wms.warn,
                        fontWeight: FontWeight.w600)),
              ),
            if (free.isNotEmpty && _enteredCode == null)
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
                      _notice != null
                          ? (widget.allowFree
                              ? 'Можно записать текстом'
                              : 'Позиции вносятся только из справочника')
                          : _all
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
                      // код кандидата — им и различают совпадения по штрихкоду
                      trailing: Text(c.id,
                          style: TextStyle(fontSize: 12, color: Wms.muted)),
                      onTap: () => Navigator.of(context).pop(
                          RefPick(id: c.id, name: c.name, code: _enteredCode)),
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
