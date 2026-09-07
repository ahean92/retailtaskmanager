// Generic fillable-execution models, mirroring the server's unified engine
// (apiExecution*). A field is rendered by its type; the answer lives in the
// type-appropriate value slot. Field codes are stable and used for addressing.
//
// Поле бланка и его ответ; таблица — в table.dart, итоги — в score.dart.

import '../json.dart';
import 'table.dart';

/// Задачи, у которых есть бланк — их открывает FillScreen, и у них бывает прошлая
/// проверка (#36778). Один список на кнопку в деталях задачи и на префетч истории:
/// новый тип, добавленный в одно место, молча разъехался бы со вторым.
///
/// С #36872 это ЗАПАСНОЙ путь, а не основной: вид выполнения объявляет сервер
/// (`executionKind` в apiTasks, см. `Task.opensFill`), и список нужен только там, где
/// сервер старый и ключа не прислал. Новые типы задач сюда не дописываются — они
/// приезжают признаком с сервера.
const fillableTypeIds = {'checklist', 'form', 'recount', 'pricing'};

class FillOption {
  final String fieldCode;
  final String code;
  final String? name;
  final double? score;
  final bool nonconformity;
  final bool notApplicable;

  const FillOption({
    required this.fieldCode,
    required this.code,
    this.name,
    this.score,
    this.nonconformity = false,
    this.notApplicable = false,
  });

  factory FillOption.fromJson(Map<String, dynamic> j) => FillOption(
        fieldCode: j['fieldCode']?.toString() ?? '',
        code: j['code']?.toString() ?? '',
        name: j['name']?.toString(),
        score: jsonNum(j['score']),
        nonconformity: j['nonconformity'] == true,
        notApplicable: j['notApplicable'] == true,
      );
}

/// Кандидат справочника для поля-ссылки (#36841, из apiRowSubjects). [available] —
/// предмет доступен на объекте задачи (сотрудник этого магазина); сервер отдаёт и
/// недоступных только по явному запросу «весь справочник».
class RefCandidate {
  final String id;
  final String name;
  final bool available;

  const RefCandidate(
      {required this.id, required this.name, this.available = false});

  factory RefCandidate.fromJson(Map<String, dynamic> j) => RefCandidate(
        id: j['subjectId']?.toString() ?? '',
        name: j['name']?.toString() ?? '',
        available: j['available'] == true,
      );

  Map<String, dynamic> toJson() =>
      {'subjectId': id, 'name': name, 'available': available};
}

/// Один снимок пункта в галерее бланка (#36946): файл на этом устройстве, если он тут
/// есть, и/или индекс, под которым снимок лежит на сервере.
///
/// Пары «файл + индекс» достаточно, чтобы удалить ровно этот кадр: локальный [localIdx]
/// адресует строку очереди (файл и намерение отправить), серверный [serverIndex] —
/// `apiDeleteFieldPhoto`. Кадр, снятый на другом устройстве, приходит без файла (виден
/// миниатюрой с сервера), а снятый только что офлайн — без серверного индекса.
class FillShot {
  /// Файл на этом устройстве; null — снимок есть только на сервере.
  final String? path;

  /// Индекс строки в очереди снимков (`fill_photos.idx`); null — файла тут нет.
  final int? localIdx;

  /// Индекс снимка на сервере; null — снимок ещё не уехал (или уехал версией
  /// приложения, которая индексов не запоминала, и сверка его пока не опознала).
  final int? serverIndex;

  /// Снимок уже на сервере — очередь его не держит.
  final bool uploaded;

  const FillShot({this.path, this.localIdx, this.serverIndex, this.uploaded = false});

  /// Удалить кадр можно, когда его есть чем адресовать: не уехавший убирается из
  /// очереди, уехавший — по серверному индексу. Кадр, уехавший старой версией и не
  /// опознанный сверкой, поштучно не удаляется — для него остаётся «Удалить все».
  bool get canDelete => serverIndex != null || (localIdx != null && !uploaded);
}

/// Тип поля бланка — единственное место, где строка сервера становится значением.
/// Неизвестный тип читается как [text]: сервер новее приложения может прислать поле,
/// которого эта сборка не знает, и показать его текстом честнее, чем уронить бланк.
enum FillFieldType {
  scale,
  choice,
  boolean,
  number,
  score,
  date,
  photo,
  table,
  objectref,
  longtext,
  scan,
  text;

  static FillFieldType parse(String? code) => switch (code) {
        'scale' => scale,
        'choice' => choice,
        'boolean' => boolean,
        'number' => number,
        'score' => score,
        'date' => date,
        'photo' => photo,
        'table' => table,
        'objectref' => objectref,
        'longtext' => longtext,
        'scan' => scan,
        _ => text,
      };
}

class FillField {
  final int sectionIndex;
  final String? section;
  final int fieldIndex;
  final String code;
  final String? name;
  final String? hint;
  final String type; // scale/number/boolean/choice/text/longtext/date/photo/scan/objectref
  final String? unit;
  final double? minNorm;
  final double? maxNorm;

  /// Input step of a `score` field (0.5 lets the inspector put "6.5 out of 7").
  /// Only meaningful for that type; the maximum is [weight].
  final double? step;
  final bool required;
  final bool requirePhoto;
  final bool requireComment;
  final bool critical;

  /// «В прошлый раз здесь было замечание» (#36778) — только факт, без значения:
  /// прошлое значение рядом с вводом притягивает ответ, поэтому оно живёт
  /// исключительно на экране просмотра прошлой проверки.
  final bool prevNonconformity;

  /// For a `score` field this is the item's maximum — what the paper checklist
  /// calls «Норма». For the other scored types it scales the item's contribution.
  final double weight;

  /// Канал справочника поля-ссылки (#36841): 'employee' / 'object' / 'item' / … —
  /// по нему при загрузке бланка запрашиваются и кэшируются кандидаты. Старый сервер
  /// ключа не шлёт — тогда null, и objectref остаётся плиткой без выбора.
  final String? refKind;

  /// Свободный ввод предмета текстом — настройка поля («Ознакомлен» подписывает и
  /// тот, кого в справочнике нет).
  final bool allowFreeSubject;

  /// Табличное поле разрешает добавлять строки (#36943). Без него кнопки «+ позиция»
  /// нет вовсе: состав строк задан шаблоном или хостом, и трогать его нельзя. Старый
  /// сервер ключа не шлёт — тогда false, то есть кнопки нет, и это безопасная сторона.
  final bool allowManual;

  /// Откуда взялись строки: `template` / `host` / пусто. Признак внесистемной позиции
  /// имеет смысл только у хостовых — у остальных сервер его и не выставляет.
  final String? rowSource;
  List<FillOption> options;

  // table-typed field: columns + rows (assembled from apiExecutionColumns/Rows)
  List<FillColumn> columns;
  List<FillRowData> rows;

  // local value state (possibly unsynced)
  String? optionCode;
  double? number;
  String? text;
  bool? boolValue;
  String? date; // ISO yyyy-MM-dd
  String? comment;

  /// Значение поля-ссылки (#36841): идентификатор предмета в канале и текст. [refName] —
  /// снимок на момент выбора, он и показывается; свободный ввод — текст без [refId].
  String? refId;
  String? refName;

  /// How many photos the server holds for this field, and the local files taken on this
  /// device (some possibly not uploaded yet). A field carries 0..N of them.
  int serverPhotoCount;
  List<String> photoPaths;

  /// Фактические серверные индексы снимков: после удаления по индексу оставшиеся НЕ
  /// уплотняются, так что «от 1 до serverPhotoCount» промахивается мимо снимков за
  /// дырой. Старый сервер поля не шлёт — тогда честного знания нет, и галерея
  /// откатывается на плотную нумерацию.
  List<int> serverPhotoIndexes;

  /// Галерея пункта покадрово (#36946): каждый снимок — своя запись, где рядом с
  /// локальным файлом лежит его индекс на сервере. Собирается контроллером бланка из
  /// очереди и серверных индексов; экран просмотра её не строит и работает по
  /// [photoPaths]/[serverPhotoIndexes], как раньше.
  List<FillShot> shots;

  FillField({
    required this.sectionIndex,
    this.section,
    required this.fieldIndex,
    required this.code,
    this.name,
    this.hint,
    required this.type,
    this.unit,
    this.minNorm,
    this.maxNorm,
    this.step,
    this.required = false,
    this.requirePhoto = false,
    this.requireComment = false,
    this.critical = false,
    this.prevNonconformity = false,
    this.weight = 1,
    this.refKind,
    this.allowFreeSubject = false,
    this.allowManual = false,
    this.rowSource,
    this.options = const [],
    this.columns = const [],
    this.rows = const [],
    this.optionCode,
    this.number,
    this.text,
    this.boolValue,
    this.date,
    this.comment,
    this.refId,
    this.refName,
    this.serverPhotoCount = 0,
    List<String>? photoPaths,
    List<int>? serverPhotoIndexes,
    List<FillShot>? shots,
  })  : photoPaths = photoPaths ?? [],
        serverPhotoIndexes = serverPhotoIndexes ?? [],
        shots = shots ?? [];

  factory FillField.fromJson(Map<String, dynamic> j) => FillField(
        sectionIndex: jsonInt(j['sectionIndex']) ?? 0,
        section: j['section']?.toString(),
        fieldIndex: jsonInt(j['fieldIndex']) ?? 0,
        code: j['code']?.toString() ?? '',
        name: j['name']?.toString(),
        hint: j['hint']?.toString(),
        type: j['type']?.toString() ?? 'text',
        unit: j['unit']?.toString(),
        minNorm: jsonNum(j['minNorm']),
        maxNorm: jsonNum(j['maxNorm']),
        step: jsonNum(j['step']),
        required: j['required'] == true,
        requirePhoto: j['requirePhoto'] == true,
        requireComment: j['requireComment'] == true,
        critical: j['critical'] == true,
        prevNonconformity: j['prevNonconformity'] == true,
        weight: jsonNum(j['weight']) ?? 1,
        refKind: j['refKind']?.toString(),
        allowFreeSubject: j['allowFreeSubject'] == true,
        allowManual: j['allowManual'] == true,
        rowSource: jsonStr(j['rowSource']),
        optionCode: j['optionCode']?.toString(),
        number: jsonNum(j['number']),
        text: j['text']?.toString(),
        boolValue: j['bool'] is bool ? j['bool'] as bool : null,
        date: j['date']?.toString(),
        comment: j['comment']?.toString(),
        refId: j['refId']?.toString(),
        refName: j['ref']?.toString(),
        serverPhotoCount:
            jsonInt(j['photoCount']) ?? (j['hasPhoto'] == true ? 1 : 0),
        serverPhotoIndexes: _indexList(j['photoIndexes']),
      );

  static List<int> _indexList(Object? v) {
    if (v == null) return [];
    return [
      for (final s in '$v'.split(','))
        if (int.tryParse(s.trim()) != null) int.parse(s.trim())
    ];
  }

  /// Индексы для галереи серверных снимков: честный список, если сервер его прислал,
  /// иначе плотная нумерация от 1 (старый сервер — дыр он и не делал показуемыми).
  List<int> get photoGalleryIndexes => serverPhotoIndexes.isNotEmpty
      ? serverPhotoIndexes
      : [for (var i = 1; i <= serverPhotoCount; i++) i];

  String get key => code;

  /// Тип поля значением; [type] остаётся строкой сервера — ей же и уезжает обратно.
  FillFieldType get kind => FillFieldType.parse(type);

  FillOption? get selectedOption {
    for (final o in options) {
      if (o.code == optionCode) return o;
    }
    return null;
  }

  bool get answered {
    if (kind == FillFieldType.table) return tableAnswered;
    return optionCode != null ||
        number != null ||
        (text != null && text!.isNotEmpty) ||
        boolValue != null ||
        date != null ||
        (refId != null && refId!.isNotEmpty) ||
        (refName != null && refName!.isNotEmpty) ||
        hasPhoto;
  }

  /// A table is answered once any editable (non-readonly) cell has a value.
  bool get tableAnswered {
    final editable = {
      for (final c in columns)
        if (!c.readonly) c.code
    };
    return rows.any((r) => editable.any(r.hasValue));
  }

  /// Значение ячейки с учётом расчёта (#36943) — одна точка на показ и на итог.
  double? cellValue(FillRowData row, FillColumn col) => row.cellValue(col);

  /// Итог по колонке, посчитанный на телефоне: `columnTotal` из `ColumnCalc.lsf`
  /// теми же тремя режимами. Считается по ТЕКУЩИМ значениям строк, включая ещё не
  /// отправленные, — иначе итог под таблицей отставал бы от того, что видно над ним.
  /// null — у колонки нет режима итога или считать нечего.
  double? columnTotal(FillColumn col) {
    if (col.totalMode == null) return null;
    final values = [
      for (final r in rows)
        if (cellValue(r, col) != null) cellValue(r, col)!
    ];
    if (col.totalMode == 'count') return values.length.toDouble();
    if (values.isEmpty) return null;
    final sum = values.reduce((a, b) => a + b);
    switch (col.totalMode) {
      case 'sum':
        return sum;
      case 'avg':
        return sum / values.length;
      default:
        return null;
    }
  }

  /// Строку можно удалить — состав строк этого поля разрешено менять. Строку без
  /// ключа удалить нечем: сервер адресует удаление ровно им.
  bool canDeleteRow(FillRowData row) => allowManual && row.rowKey.isNotEmpty;

  bool get hasPhoto =>
      shots.isNotEmpty || photoPaths.isNotEmpty || serverPhotoCount > 0;

  /// What to show as the field's photo count: покадровая галерея, когда она собрана
  /// (экран бланка — там она знает и про снимки соседнего устройства, и про очередь
  /// удалений); иначе локальные файлы, а за их отсутствием — счётчик сервера.
  int get photoCount => shots.isNotEmpty
      ? shots.length
      : (photoPaths.isNotEmpty ? photoPaths.length : serverPhotoCount);

  bool get inNorm =>
      number != null &&
      (minNorm == null || number! >= minNorm!) &&
      (maxNorm == null || number! <= maxNorm!);

  /// Locally-derived non-conformity (option-flagged, or a numeric out of norm).
  bool get nonconformity =>
      selectedOption?.nonconformity ??
      (kind == FillFieldType.number && number != null && !inNorm);

  bool get needsPhoto => nonconformity && requirePhoto && !hasPhoto;
  bool get needsComment =>
      nonconformity && requireComment && (comment == null || comment!.isEmpty);
  bool get needsEvidence => needsPhoto || needsComment;
}

/// Секционная пагинация бланка — одна на редактор (FillController) и просмотр
/// (PastFillController): любая правка группировки, сделанная в одном из них,
/// молча развела бы нумерацию страниц у двух экранов одного шаблона.
extension FillSections on List<FillField> {
  List<int> get sectionIndexes {
    final seen = <int>{};
    final out = <int>[];
    for (final f in this) {
      if (seen.add(f.sectionIndex)) out.add(f.sectionIndex);
    }
    return out;
  }

  int get sectionCount => sectionIndexes.length;

  List<FillField> ofSection(int page) {
    final idx = sectionIndexes;
    if (page < 0 || page >= idx.length) return const [];
    return where((f) => f.sectionIndex == idx[page]).toList();
  }

  String sectionTitle(int page) {
    final list = ofSection(page);
    return list.isEmpty ? '' : (list.first.section ?? 'Раздел');
  }

  /// Страница секции, на которой живёт пункт, — для «просмотр открывается
  /// прокрученным к этому пункту».
  int pageOfField(String fieldCode) {
    for (final f in this) {
      if (f.code == fieldCode) {
        final page = sectionIndexes.indexOf(f.sectionIndex);
        return page < 0 ? 0 : page;
      }
    }
    return 0;
  }
}

/// Собирает плоские ответы `apiExecution{Fields,Options,Columns,Rows}` в поля с
/// вариантами, колонками и строками — одна сборка и для текущего бланка, и для
/// просмотра прошлой проверки (#36778): формат ответов один, рендерер один.
List<FillField> assembleFillFields(
    List fieldsRaw, List optionsRaw, List columnsRaw, List rowsRaw) {
  final byFieldOpt = <String, List<FillOption>>{};
  for (final o in optionsRaw) {
    final opt = FillOption.fromJson((o as Map).cast<String, dynamic>());
    byFieldOpt.putIfAbsent(opt.fieldCode, () => []).add(opt);
  }
  // table columns, sorted by their index
  final byFieldCol = <String, List<FillColumn>>{};
  for (final c in columnsRaw) {
    final col = FillColumn.fromJson((c as Map).cast<String, dynamic>());
    byFieldCol.putIfAbsent(col.fieldCode, () => []).add(col);
  }
  for (final l in byFieldCol.values) {
    l.sort((a, b) => a.colIndex.compareTo(b.colIndex));
  }
  // table rows: one JSON object per cell → group into rows per (field, rowKey)
  //
  // Ключ строки, а не индекс (#36943): индекс у двух строк, созданных офлайн на
  // разных устройствах, совпадает, и ячейки склеились бы в одну строку. Строка со
  // старого сервера ключа не имеет — для неё индекс остаётся единственным
  // различителем, и синтетический ключ ниже ровно это и означает: «править нечем».
  final byFieldRow = <String, Map<String, FillRowData>>{};
  for (final c in rowsRaw) {
    final m = (c as Map).cast<String, dynamic>();
    final fc = m['fieldCode']?.toString() ?? '';
    final ri = (m['rowIndex'] as num?)?.toInt() ?? 0;
    final key = jsonStr(m['rowKey']);
    final col = m['colCode']?.toString() ?? '';
    final row = byFieldRow.putIfAbsent(fc, () => {}).putIfAbsent(
        key ?? '#$ri',
        () => FillRowData(ri,
            rowKey: key ?? '',
            subjectId: jsonStr(m['subjectId']),
            subject: jsonStr(m['subject']),
            offSystem: m['offSystem'] == true));
    final n = (m['number'] as num?)?.toDouble();
    if (n != null) row.numbers[col] = n;
    final p = (m['prevNumber'] as num?)?.toDouble();
    if (p != null) row.prevNumbers[col] = p;
    final t = m['text']?.toString();
    if (t != null) row.texts[col] = t;
  }
  final list = fieldsRaw.map((j) {
    final f = FillField.fromJson((j as Map).cast<String, dynamic>());
    f.options = byFieldOpt[f.code] ?? [];
    f.columns = byFieldCol[f.code] ?? [];
    final rows = byFieldRow[f.code];
    f.rows = rows == null
        ? []
        : (rows.values.toList()
          ..sort((a, b) => a.rowIndex.compareTo(b.rowIndex)));
    return f;
  }).toList();
  list.sort((a, b) {
    final c = a.sectionIndex.compareTo(b.sectionIndex);
    return c != 0 ? c : a.fieldIndex.compareTo(b.fieldIndex);
  });
  return list;
}
