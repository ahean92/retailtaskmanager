// Generic fillable-execution models, mirroring the server's unified engine
// (apiExecution*). A field is rendered by its type; the answer lives in the
// type-appropriate value slot. Field codes are stable and used for addressing.

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
        score: _num(j['score']),
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

/// A column of a `table`-typed field (from apiExecutionColumns).
class FillColumn {
  final String fieldCode;
  final String code;
  final String? name;
  final String type; // number/text/scale/…
  final String? unit;
  final double? minNorm;
  final double? maxNorm;
  final bool readonly;
  final int colIndex;
  final String? compareTo; // code of the column this one is compared against

  const FillColumn({
    required this.fieldCode,
    required this.code,
    this.name,
    this.type = 'text',
    this.unit,
    this.minNorm,
    this.maxNorm,
    this.readonly = false,
    this.colIndex = 0,
    this.compareTo,
  });

  factory FillColumn.fromJson(Map<String, dynamic> j) => FillColumn(
        fieldCode: j['fieldCode']?.toString() ?? '',
        code: j['colCode']?.toString() ?? '',
        name: j['name']?.toString(),
        type: j['type']?.toString() ?? 'text',
        unit: j['unit']?.toString(),
        minNorm: _num(j['minNorm']),
        maxNorm: _num(j['maxNorm']),
        readonly: j['readonly'] == true,
        colIndex: _int(j['colIndex']) ?? 0,
        compareTo: j['compareTo']?.toString(),
      );
}

/// One row of a table field, holding a cell value per column code (local state).
class FillRowData {
  final int rowIndex;
  final Map<String, double?> numbers = {};
  final Map<String, String?> texts = {};

  FillRowData(this.rowIndex);

  bool hasValue(String colCode) =>
      numbers[colCode] != null ||
      (texts[colCode] != null && texts[colCode]!.isNotEmpty);
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
        sectionIndex: _int(j['sectionIndex']) ?? 0,
        section: j['section']?.toString(),
        fieldIndex: _int(j['fieldIndex']) ?? 0,
        code: j['code']?.toString() ?? '',
        name: j['name']?.toString(),
        hint: j['hint']?.toString(),
        type: j['type']?.toString() ?? 'text',
        unit: j['unit']?.toString(),
        minNorm: _num(j['minNorm']),
        maxNorm: _num(j['maxNorm']),
        step: _num(j['step']),
        required: j['required'] == true,
        requirePhoto: j['requirePhoto'] == true,
        requireComment: j['requireComment'] == true,
        critical: j['critical'] == true,
        prevNonconformity: j['prevNonconformity'] == true,
        weight: _num(j['weight']) ?? 1,
        refKind: j['refKind']?.toString(),
        allowFreeSubject: j['allowFreeSubject'] == true,
        optionCode: j['optionCode']?.toString(),
        number: _num(j['number']),
        text: j['text']?.toString(),
        boolValue: j['bool'] is bool ? j['bool'] as bool : null,
        date: j['date']?.toString(),
        comment: j['comment']?.toString(),
        refId: j['refId']?.toString(),
        refName: j['ref']?.toString(),
        serverPhotoCount:
            _int(j['photoCount']) ?? (j['hasPhoto'] == true ? 1 : 0),
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

  FillOption? get selectedOption {
    for (final o in options) {
      if (o.code == optionCode) return o;
    }
    return null;
  }

  bool get answered {
    if (type == 'table') return tableAnswered;
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
      (type == 'number' && number != null && !inNorm);

  bool get needsPhoto => nonconformity && requirePhoto && !hasPhoto;
  bool get needsComment =>
      nonconformity && requireComment && (comment == null || comment!.isEmpty);
  bool get needsEvidence => needsPhoto || needsComment;
}

/// Header + progress of a filling, from `apiExecutionInfo`.
class FillSummary {
  final String? object;
  final String? template;
  final bool hasScored;
  final double? percent;
  final String? verdict;
  final bool passed;
  final String? resolution;
  final bool resolutionRequired;
  final int answered;
  final int total;
  final int missingRequired;
  final int missingEvidence;
  final bool finished;

  /// Дата и автор этой проверки — шапка просмотра прошлой (#36778).
  final String? date;
  final String? executor;
  final int remarks;

  /// Итог прошлой проверки того же объекта и шаблона. prevDate == null — объект по
  /// этому шаблону проверяется впервые: ни строки в шапке, ни входа в просмотр.
  final String? prevDate;
  final double? prevPercent;
  final int prevRemarks;

  const FillSummary({
    this.object,
    this.template,
    this.hasScored = false,
    this.percent,
    this.verdict,
    this.passed = false,
    this.resolution,
    this.resolutionRequired = false,
    this.answered = 0,
    this.total = 0,
    this.missingRequired = 0,
    this.missingEvidence = 0,
    this.finished = false,
    this.date,
    this.executor,
    this.remarks = 0,
    this.prevDate,
    this.prevPercent,
    this.prevRemarks = 0,
  });

  factory FillSummary.fromJson(Map<String, dynamic> j) => FillSummary(
        object: j['object']?.toString(),
        template: j['template']?.toString(),
        hasScored: j['hasScored'] == true,
        percent: _num(j['percent']),
        verdict: j['verdict']?.toString(),
        passed: j['passed'] == true,
        resolution: j['resolution']?.toString(),
        resolutionRequired: j['resolutionRequired'] == true,
        answered: _int(j['answered']) ?? 0,
        total: _int(j['total']) ?? 0,
        missingRequired: _int(j['missingRequired']) ?? 0,
        missingEvidence: _int(j['missingEvidence']) ?? 0,
        finished: j['finished'] == true,
        date: j['date']?.toString(),
        executor: j['executor']?.toString(),
        remarks: _int(j['remarks']) ?? 0,
        prevDate: j['prevDate']?.toString(),
        prevPercent: _num(j['prevPercent']),
        prevRemarks: _int(j['prevRemarks']) ?? 0,
      );

  /// «12.07», а в другом году — «12.07.2025»: без даты «в прошлый раз» бесполезно,
  /// а год за пределами текущего меняет вывод сильнее, чем день.
  static String? shortDate(String? iso) {
    if (iso == null || iso.isEmpty) return null;
    final d = DateTime.tryParse(iso);
    if (d == null) return null;
    final dm = '${d.day.toString().padLeft(2, '0')}.'
        '${d.month.toString().padLeft(2, '0')}';
    return d.year == DateTime.now().year ? dm : '$dm.${d.year}';
  }

  /// «78%» или «78.33%» — один формат процента на все экраны (пилюля бланка, шапка
  /// просмотра, строка «прошлая проверка»): правка округления в одном месте.
  static String formatPercent(double pct) =>
      '${pct.toStringAsFixed(pct % 1 == 0 ? 0 : 2)}%';

  /// «12.07 — 78%, 3 замечания» — одна и та же строка в шапке бланка и на главном
  /// экране; без процента (нечего считать) остаются дата и замечания. Дата
  /// обязательна: оба вызова гейтятся на её наличие.
  static String pastLine(String dateIso, double? percent, int remarks) {
    final r = remarks > 0
        ? '$remarks замечани${_pluralEnding(remarks)}'
        : 'без замечаний';
    final date = shortDate(dateIso) ?? '';
    return percent == null
        ? '$date, $r'
        : '$date — ${formatPercent(percent)}, $r';
  }

  static String _pluralEnding(int n) {
    final m = n % 100;
    if (m >= 11 && m <= 14) return 'й';
    return switch (n % 10) { 1 => 'е', 2 || 3 || 4 => 'я', _ => 'й' };
  }
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
  // table rows: one JSON object per cell → group into rows per (field, rowIndex)
  final byFieldRow = <String, Map<int, FillRowData>>{};
  for (final c in rowsRaw) {
    final m = (c as Map).cast<String, dynamic>();
    final fc = m['fieldCode']?.toString() ?? '';
    final ri = (m['rowIndex'] as num?)?.toInt() ?? 0;
    final col = m['colCode']?.toString() ?? '';
    final row = byFieldRow
        .putIfAbsent(fc, () => {})
        .putIfAbsent(ri, () => FillRowData(ri));
    final n = (m['number'] as num?)?.toDouble();
    if (n != null) row.numbers[col] = n;
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

/// The fixed resolution enum, mirrored for the client picker.
class ResolutionOption {
  final String code;
  final String label;
  const ResolutionOption(this.code, this.label);

  static const all = [
    ResolutionOption('done', 'Выполнено'),
    ResolutionOption('doneWithIssues', 'Выполнено с замечаниями'),
    ResolutionOption('needsParts', 'Нужна запчасть'),
    ResolutionOption('revisit', 'Требуется повторный визит'),
    ResolutionOption('failed', 'Не выполнено'),
  ];

  static String? labelOf(String? code) {
    for (final r in all) {
      if (r.code == code) return r.label;
    }
    return code;
  }
}

int? _int(Object? v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse('$v');
}

double? _num(Object? v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse('$v');
}
