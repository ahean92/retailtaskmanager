// Итог бланка: подытоги разделов (#36945), сводка проверки, варианты решения.

import '../json.dart';

/// Подытог одного раздела из `apiExecutionInfo` (#36945): балл, максимум и процент
/// посчитаны на сервере (#36709) — телефон их только показывает, как и общий процент
/// (#36782). Раздел без оценки в ответ не попадает вовсе: отсутствие записи и есть
/// «строки в шапке нет».
class SectionScore {
  final int index;
  final double score;
  final double? max;
  final double? percent;

  const SectionScore(
      {required this.index, this.score = 0, this.max, this.percent});

  factory SectionScore.fromJson(Map<String, dynamic> j) => SectionScore(
        index: jsonInt(j['index']) ?? 0,
        score: jsonNum(j['score']) ?? 0,
        max: jsonNum(j['max']),
        percent: jsonNum(j['percent']),
      );

  /// «12 из 15 · 80%» — процент тем же formatPercent, что и остальные экраны.
  /// Без процента (балл NULL при живом максимуме — вариант без настроенного
  /// балла) остаётся только «из».
  String get line {
    final base = '${_short(score)} из ${_short(max ?? 0)}';
    return percent == null
        ? base
        : '$base · ${FillSummary.formatPercent(percent!)}';
  }

  /// NUMERIC[18,4] приезжает с хвостом нулей: «12.0000» → «12», «12.5000» → «12.5»
  static String _short(double v) =>
      v.toStringAsFixed(4).replaceFirst(RegExp(r'\.?0+$'), '');
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

  /// Подытоги по разделам (#36945), ключ — серверный index раздела: тот же, что в
  /// sectionIndex у полей, — им шапка страницы находит свой подытог. Раздела без
  /// оценки здесь нет (сервер его не шлёт), у процедуры карта пуста целиком.
  final Map<int, SectionScore> sections;

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
    this.sections = const {},
  });

  factory FillSummary.fromJson(Map<String, dynamic> j) => FillSummary(
        object: j['object']?.toString(),
        template: j['template']?.toString(),
        hasScored: j['hasScored'] == true,
        percent: jsonNum(j['percent']),
        verdict: j['verdict']?.toString(),
        passed: j['passed'] == true,
        resolution: j['resolution']?.toString(),
        resolutionRequired: j['resolutionRequired'] == true,
        answered: jsonInt(j['answered']) ?? 0,
        total: jsonInt(j['total']) ?? 0,
        missingRequired: jsonInt(j['missingRequired']) ?? 0,
        missingEvidence: jsonInt(j['missingEvidence']) ?? 0,
        finished: j['finished'] == true,
        date: j['date']?.toString(),
        executor: j['executor']?.toString(),
        remarks: jsonInt(j['remarks']) ?? 0,
        prevDate: j['prevDate']?.toString(),
        prevPercent: jsonNum(j['prevPercent']),
        prevRemarks: jsonInt(j['prevRemarks']) ?? 0,
        sections: _sections(j['sections']),
      );

  static Map<int, SectionScore> _sections(Object? v) {
    if (v is! List) return const {};
    final out = <int, SectionScore>{};
    for (final e in v) {
      if (e is Map) {
        final s = SectionScore.fromJson(e.cast<String, dynamic>());
        out[s.index] = s;
      }
    }
    return out;
  }

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
