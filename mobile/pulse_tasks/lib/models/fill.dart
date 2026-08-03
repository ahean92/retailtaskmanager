// Generic fillable-execution models, mirroring the server's unified engine
// (apiExecution*). A field is rendered by its type; the answer lives in the
// type-appropriate value slot. Field codes are stable and used for addressing.

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
  final bool required;
  final bool requirePhoto;
  final bool requireComment;
  final bool critical;
  final double weight;
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
  bool hasServerPhoto;
  String? photoPath;

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
    this.required = false,
    this.requirePhoto = false,
    this.requireComment = false,
    this.critical = false,
    this.weight = 1,
    this.options = const [],
    this.columns = const [],
    this.rows = const [],
    this.optionCode,
    this.number,
    this.text,
    this.boolValue,
    this.date,
    this.comment,
    this.hasServerPhoto = false,
    this.photoPath,
  });

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
        required: j['required'] == true,
        requirePhoto: j['requirePhoto'] == true,
        requireComment: j['requireComment'] == true,
        critical: j['critical'] == true,
        weight: _num(j['weight']) ?? 1,
        optionCode: j['optionCode']?.toString(),
        number: _num(j['number']),
        text: j['text']?.toString(),
        boolValue: j['bool'] is bool ? j['bool'] as bool : null,
        date: j['date']?.toString(),
        comment: j['comment']?.toString(),
        hasServerPhoto: j['hasPhoto'] == true,
      );

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

  bool get hasPhoto => photoPath != null || hasServerPhoto;

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
      );
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
