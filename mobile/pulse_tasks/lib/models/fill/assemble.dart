// Сборка бланка из плоских списков агрегата открытия (apiExecutionBundle: fields,
// options, columns, rows) и наложение на него того, что ещё не уехало на сервер. Одна
// на экран бланка, просмотр прошлой проверки, карточку задачи и шаблон пресета.

import '../json.dart';
import 'field.dart';
import 'table.dart';

/// Собирает плоские списки агрегата (поля, варианты, колонки, ячейки строк) в поля с
/// вариантами, колонками и строками — одна сборка и для текущего бланка, и для
/// просмотра прошлой проверки (#36778): формат ответов один, рендерер один. Элемент
/// списка, не являющийся объектом, пропускается, а не роняет весь бланк.
List<FillField> assembleFillFields(
    List fieldsRaw, List optionsRaw, List columnsRaw, List rowsRaw) {
  final byFieldOpt = <String, List<FillOption>>{};
  for (final o in optionsRaw.whereType<Map>()) {
    final opt = FillOption.fromJson(o.cast<String, dynamic>());
    byFieldOpt.putIfAbsent(opt.fieldCode, () => []).add(opt);
  }
  // table columns, sorted by their index
  final byFieldCol = <String, List<FillColumn>>{};
  for (final c in columnsRaw.whereType<Map>()) {
    final col = FillColumn.fromJson(c.cast<String, dynamic>());
    byFieldCol.putIfAbsent(col.fieldCode, () => []).add(col);
  }
  for (final l in byFieldCol.values) {
    l.sort((a, b) => a.colIndex.compareTo(b.colIndex));
  }
  // table rows: one JSON object per cell → group into rows per (field, rowKey)
  //
  // Ключ строки, а не индекс (#36943): индекс у двух строк, созданных офлайн на
  // разных устройствах, совпадает, и ячейки склеились бы в одну строку.
  final byFieldRow = <String, Map<String, FillRowData>>{};
  for (final c in rowsRaw.whereType<Map>()) {
    final m = c.cast<String, dynamic>();
    final fc = m['fieldCode']?.toString() ?? '';
    final ri = (m['rowIndex'] as num?)?.toInt() ?? 0;
    final key = jsonStr(m['rowKey']) ?? '';
    final col = m['colCode']?.toString() ?? '';
    final row = byFieldRow.putIfAbsent(fc, () => {}).putIfAbsent(
        key,
        () => FillRowData(ri,
            rowKey: key,
            subjectId: jsonStr(m['subjectId']),
            subject: jsonStr(m['subject']),
            offSystem: m['offSystem'] == true,
            subjectCode: jsonStr(m['subjectCode'])));
    final n = (m['number'] as num?)?.toDouble();
    if (n != null) row.numbers[col] = n;
    final p = (m['prevNumber'] as num?)?.toDouble();
    if (p != null) row.prevNumbers[col] = p;
    final t = m['text']?.toString();
    if (t != null) row.texts[col] = t;
    // ячейка-выбор: код — в тексты (им она и едет в очереди), подпись — для показа;
    // «да/нет» — числом 1/0 (11.5: раньше телефон их не читал и ячейка стояла пустой)
    final oc = jsonStr(m['optionCode']);
    if (oc != null) row.texts[col] = oc;
    final on = jsonStr(m['optionName']);
    if (on != null) row.optionNames[col] = on;
    final b = m['bool'];
    if (b is bool) row.numbers[col] = b ? 1 : 0;
    // дата ячейки — в ту же карту текстов, строкой ГГГГ-ММ-ДД (см. FillColumn.isDate)
    final d = m['date']?.toString();
    if (d != null && d.length >= 10) row.texts[col] = d.substring(0, 10);
  }
  final list = fieldsRaw.whereType<Map>().map((j) {
    final f = FillField.fromJson(j.cast<String, dynamic>());
    f.options = byFieldOpt[f.code] ?? [];
    f.columns = byFieldCol[f.code] ?? [];
    final rows = byFieldRow[f.code];
    f.rows = rows == null
        ? []
        // два офлайн-устройства дают строкам один индекс: ключ строки — запасной
        // порядок, иначе их очерёдность зависела бы от порядка ячеек в ответе
        : (rows.values.toList()
          ..sort((a, b) {
            final c = a.rowIndex.compareTo(b.rowIndex);
            return c != 0 ? c : a.rowKey.compareTo(b.rowKey);
          }));
    return f;
  }).toList();
  list.sort((a, b) {
    final c = a.sectionIndex.compareTo(b.sectionIndex);
    return c != 0 ? c : a.fieldIndex.compareTo(b.fieldIndex);
  });
  return list;
}

/// Наложить на собранный бланк то, что ещё не уехало на сервер: ответы полей,
/// состав строк таблиц и их ячейки. Одна функция на экран бланка и карточку
/// задачи: счётчик «Заполнение N из M» на карточке обязан считать теми же
/// значениями, что видел человек в бланке, — две копии наложения разошлись бы
/// тихо и не на тесте, а на жалобе «цифра не та».
///
/// [pendingPhotoPaths] — пути кадров, ждущих отправки: у поля-фото снимок и есть
/// ответ, поэтому такой пункт считается заполненным ещё до связи. Экрану бланка
/// это не нужно — его галерею строит контроллер из той же очереди (shots);
/// карточке — да.
void overlayOutbox(
  List<FillField> fields, {
  required List<Map<String, Object?>> fieldOutbox,
  required List<Map<String, Object?>> rowOutbox,
  required List<Map<String, Object?>> cellOutbox,
  Map<String, List<String>> pendingPhotoPaths = const {},
}) {
  final byKey = {for (final e in fieldOutbox) e['fieldCode'] as String: e};
  for (final f in fields) {
    final e = byKey[f.code];
    if (e != null) {
      f.optionCode = e['optionCode'] as String?;
      f.number = (e['number'] as num?)?.toDouble();
      f.text = e['text'] as String?;
      final b = e['boolVal'] as int?;
      f.boolValue = b == null ? null : b != 0;
      f.date = e['dateVal'] as String?;
      f.comment = e['comment'] as String?;
      // пустая строка в очереди — намеренная очистка ссылки, на экране это «пусто»
      final rid = e['refId'] as String?;
      final rname = e['refName'] as String?;
      f.refId = (rid == null || rid.isEmpty) ? null : rid;
      f.refName = (rname == null || rname.isEmpty) ? null : rname;
    }
    final pending = pendingPhotoPaths[f.code];
    if (pending != null && pending.isNotEmpty) f.photoPaths.addAll(pending);
  }
  // Строки и ячейки, ещё не уехавшие на сервер (#36943), — поверх того, что он
  // прислал. Порядок здесь тот же, что в очереди: сперва состав строк, потом их
  // ячейки. Без первого шага строка, добавленная в самолётном режиме, исчезала бы
  // с экрана при первом же переоткрытии бланка — а вместе с ней и внесённый факт.
  final byField = {for (final f in fields) f.code: f};
  for (final e in rowOutbox) {
    final f = byField[e['fieldCode'] as String];
    if (f == null || f.kind != FillFieldType.table) continue;
    final key = e['rowKey'] as String;
    if (e['op'] == 'delete') {
      f.rows.removeWhere((r) => r.rowKey == key);
      continue;
    }
    if (f.rows.any((r) => r.rowKey == key)) continue;
    f.rows.add(FillRowData(
      // индекс — только порядок показа: местная строка становится последней, ровно
      // там, где человек её и создал
      f.rows.isEmpty ? 1 : f.rows.last.rowIndex + 1,
      rowKey: key,
      subjectId: e['subjectId'] as String?,
      subject: e['subjectName'] as String?,
      subjectCode: e['subjectCode'] as String?,
    ));
  }
  // overlay pending table-cell edits onto their rows (editable cells only)
  final rowLookup = <String, Map<String, FillRowData>>{};
  for (final f in fields) {
    if (f.kind == FillFieldType.table) {
      rowLookup[f.code] = {for (final r in f.rows) r.rowKey: r};
    }
  }
  for (final e in cellOutbox) {
    final row = rowLookup[e['fieldCode'] as String]?[e['rowKey'] as String];
    if (row == null) continue;
    final col = e['colCode'] as String;
    final t = e['text'] as String?;
    if (t != null) {
      row.texts[col] = t;
    } else {
      row.numbers[col] = (e['number'] as num?)?.toDouble();
    }
  }
}
