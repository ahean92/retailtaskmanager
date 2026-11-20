// Generic fillable-execution models, mirroring the server's unified engine
// (apiExecution*). A field is rendered by its type; the answer lives in the
// type-appropriate value slot. Field codes are stable and used for addressing.
//
// Поле бланка и его ответ; таблица — в table.dart, итоги — в score.dart, кандидаты
// справочника — в ref_candidate.dart, сборка из ответов сервера — в assemble.dart.

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

  /// «Всегда»-режим (цеховые разделы): фото/примечание обязательны при любом ответе,
  /// а не только при несоответствии. Старый сервер ключей не шлёт — тогда false, и
  /// поведение прежнее.
  final bool requirePhotoAlways;
  final bool requireCommentAlways;

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

  /// «Макс. длина» ответа текстом (настройка поля). Телефон ограничивает ввод ею, а без
  /// неё — 500, сколько сервер хранит: длиннее он отказывает, а не обрезает молча.
  final int? maxLen;

  /// «Уникальный предмет» табличного поля: позиция не повторяется — телефон не даёт
  /// добавить её второй строкой, сервер отказывает тем же.
  final bool uniqueSubject;

  /// Признак несоответствия, как его отдал сервер. У завершённой проверки это записанное
  /// при завершении значение: справочник вариантов с тех пор могли поправить, и экраны
  /// просмотра показывают его, а не пересчёт по текущим вариантам ([nonconformity]).
  final bool? serverNonconformity;
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
    this.requirePhotoAlways = false,
    this.requireCommentAlways = false,
    this.prevNonconformity = false,
    this.weight = 1,
    this.refKind,
    this.allowFreeSubject = false,
    this.allowManual = false,
    this.rowSource,
    this.maxLen,
    this.uniqueSubject = false,
    this.serverNonconformity,
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
        requirePhotoAlways: j['requirePhotoAlways'] == true,
        requireCommentAlways: j['requireCommentAlways'] == true,
        prevNonconformity: j['prevNonconformity'] == true,
        weight: jsonNum(j['weight']) ?? 1,
        refKind: j['refKind']?.toString(),
        allowFreeSubject: j['allowFreeSubject'] == true,
        allowManual: j['allowManual'] == true,
        rowSource: jsonStr(j['rowSource']),
        maxLen: jsonInt(j['maxLen']),
        uniqueSubject: j['uniqueSubject'] == true,
        serverNonconformity: j.containsKey('nonconformity')
            ? j['nonconformity'] == true
            : null,
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

  /// Снимок — ответ только у поля «Фото» (решение 12.11): у шкалы или числа он
  /// свидетельство, и обязательная шкала со снимком, но без выбора, отвеченной не
  /// считается — ровно как `answered` на сервере.
  bool get answered {
    if (kind == FillFieldType.table) return tableAnswered;
    return optionCode != null ||
        number != null ||
        (text != null && text!.isNotEmpty) ||
        boolValue != null ||
        date != null ||
        (refId != null && refId!.isNotEmpty) ||
        (refName != null && refName!.isNotEmpty) ||
        (kind == FillFieldType.photo && hasPhoto);
  }

  /// Длина ответа текстом, которую примет сервер: «Макс. длина» поля, а без неё — 500.
  int get textLimit => (maxLen != null && maxLen! > 0) ? maxLen! : 500;

  /// В таблице есть строка без значения в обязательной колонке — бланк не завершается,
  /// даже если само поле не обязательно (`tableIncomplete` на сервере).
  bool get tableIncomplete =>
      kind == FillFieldType.table &&
      rows.any((r) => columns.any((c) => c.requiredInput && !r.hasValue(c.code)));

  /// Поле держит завершение: обязательное без ответа или таблица с пустой обязательной
  /// ячейкой. Один предикат на счётчик, маршрут прыжков и отказ «Завершить».
  bool get missingRequiredValue => (required && !answered) || tableIncomplete;

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
    // count — ячейки со значением любого вида, как columnCount на сервере: текст,
    // вариант, дата и «да/нет» раньше давали здесь 0
    if (col.totalMode == 'count') {
      return rows.where((r) => r.hasAnyValue(col)).length.toDouble();
    }
    final values = [
      for (final r in rows)
        if (cellValue(r, col) != null) cellValue(r, col)!
    ];
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

  /// Несоответствие для экрана только для чтения: записанное сервером, если он его
  /// прислал, иначе пересчёт по текущим вариантам.
  bool get shownNonconformity => serverNonconformity ?? nonconformity;

  /// Locally-derived non-conformity (option-flagged, or a numeric out of norm).
  bool get nonconformity =>
      selectedOption?.nonconformity ??
      (kind == FillFieldType.number && number != null && !inNorm);

  bool get needsPhoto =>
      (nonconformity && requirePhoto || requirePhotoAlways) && !hasPhoto;
  bool get needsComment =>
      (nonconformity && requireComment || requireCommentAlways) &&
      (comment == null || comment!.isEmpty);
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
