// Табличное поле бланка (#36943): колонки с расчётом и строки с предметом.

import '../json.dart';

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

  /// Вид расчёта колонки (#36943): `product` / `diff` / `sum` / `reading` /
  /// `readingCost`; null — колонка вводится, а не считается. Набор — контракт с
  /// сервером (`fillable/ColumnCalc.lsf`): та же арифметика написана здесь, чтобы
  /// стоимость и расхождение появлялись у полки, а не после синхронизации. Новый
  /// вид на сервере — это новый релиз приложения, и так задумано (дизайн, раздел 6).
  final String? calcKind;

  /// Операнды расчёта: код соседней колонки либо, если кода нет, константа колонки —
  /// «расход × тариф», где тариф один на всю таблицу, иначе не выражается.
  final String? operandA;
  final String? operandB;
  final double? constA;
  final double? constB;

  /// Итог по колонке: `sum` / `avg` / `count`; null — итога у колонки нет.
  final String? totalMode;

  /// Колонка считается, а не вводится — ввод в неё сервер всё равно перекрыл бы
  /// расчётом (`cellValue = OVERRIDE cellNumber, calcCell`).
  bool get computed => calcKind != null && calcKind!.isNotEmpty;

  /// Ячейку можно править: не помечена только для чтения, не вычисляемая и числовая.
  /// Текстовые колонки пока показываются подписью — отдельный долг дизайна (раздел 9).
  bool get editable => !readonly && !computed && type == 'number';

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
    this.calcKind,
    this.operandA,
    this.operandB,
    this.constA,
    this.constB,
    this.totalMode,
  });

  factory FillColumn.fromJson(Map<String, dynamic> j) => FillColumn(
        fieldCode: j['fieldCode']?.toString() ?? '',
        code: j['colCode']?.toString() ?? '',
        name: j['name']?.toString(),
        type: j['type']?.toString() ?? 'text',
        unit: j['unit']?.toString(),
        minNorm: jsonNum(j['minNorm']),
        maxNorm: jsonNum(j['maxNorm']),
        readonly: j['readonly'] == true,
        colIndex: jsonInt(j['colIndex']) ?? 0,
        compareTo: j['compareTo']?.toString(),
        calcKind: jsonStr(j['calcKind']),
        operandA: jsonStr(j['operandA']),
        operandB: jsonStr(j['operandB']),
        constA: jsonNum(j['constA']),
        constB: jsonNum(j['constB']),
        totalMode: jsonStr(j['totalMode']),
      );
}

/// One row of a table field, holding a cell value per column code (local state).
///
/// Адресуется [rowKey] — uuid, сгенерированный на телефоне в момент создания строки
/// (#36943), ровно как `clientId` задачи в #36714. Индекс остался только для порядка
/// показа: две строки, созданные офлайн на разных устройствах, получают один и тот же
/// индекс, и правка по нему уходит мимо строки.
class FillRowData {
  final int rowIndex;

  /// Ключ строки. Пусто — строка со старого сервера, который ключей не выдавал: её
  /// ячейки править нечем, и экран показывает её только для чтения.
  final String rowKey;

  /// Предмет строки: ссылка в справочник ([subjectId]) и имя-снимок ([subject]).
  /// Свободно введённый предмет — имя без ссылки.
  final String? subjectId;
  final String? subject;

  /// Позиции нет в остатках объекта (#36780) — находка, ради которой в пикере есть
  /// «показать все». Считает сервер: телефон остатков объекта не знает.
  final bool offSystem;

  final Map<String, double?> numbers = {};
  final Map<String, String?> texts = {};

  /// Значение той же ячейки в ПРОШЛОЙ проверке — операнд расчёта расхода прибора
  /// (`reading`): расход есть разность с прошлым показанием, и без этой карты телефон
  /// посчитать его не может. Пусто на первой проверке — тогда расход честно пуст.
  final Map<String, double?> prevNumbers = {};

  FillRowData(this.rowIndex,
      {this.rowKey = '',
      this.subjectId,
      this.subject,
      this.offSystem = false});

  bool hasValue(String colCode) =>
      numbers[colCode] != null ||
      (texts[colCode] != null && texts[colCode]!.isNotEmpty);

  /// Значение ячейки так, как его видит сервер: введённое число, а для вычисляемой
  /// колонки — результат расчёта. Одна формула на показ ячейки и на итог колонки.
  double? cellValue(FillColumn col) {
    if (!col.computed) return numbers[col.code];
    return _calc(col);
  }

  /// Та же арифметика, что `calcCell` в `fillable/ColumnCalc.lsf`. Незаполненный
  /// операнд оставляет ячейку пустой — сервер на NULL тоже не считает, и «0» вместо
  /// пусто читалось бы как «посчитано и вышел ноль».
  ///
  /// Операнд-колонка читается СЫРОЙ ячейкой, а не своим расчётом: `operandValue` на
  /// сервере тоже берёт `cellNumber`, а не `cellValue`, и расчёт по расчёту не
  /// цепляется — иначе две стороны разошлись бы на первом же таком шаблоне.
  double? _calc(FillColumn col) {
    double? operand(String? code, double? constant) {
      if (code == null) return constant;
      return numbers[code];
    }

    final a = operand(col.operandA, col.constA);
    final b = operand(col.operandB, col.constB);
    switch (col.calcKind) {
      case 'product':
        return (a == null || b == null) ? null : a * b;
      case 'diff':
        return (a == null || b == null) ? null : a - b;
      case 'sum':
        return (a == null || b == null) ? null : a + b;
      case 'reading':
        return _consumption(col);
      case 'readingCost':
        final used = _consumption(col);
        return (used == null || col.constB == null) ? null : used * col.constB!;
      default:
        // вид расчёта, которого это приложение ещё не знает: показываем пусто, а
        // после синхронизации значение приедет с сервера — молча врать хуже
        return null;
    }
  }

  /// Расход прибора: текущее показание минус показание прошлой проверки. Прошлого
  /// нет — расхода нет (первая проверка), ровно как `consumption` на сервере.
  double? _consumption(FillColumn col) {
    final readingCode = col.operandA;
    if (readingCode == null) return null;
    final now = numbers[readingCode];
    final was = prevNumbers[readingCode];
    return (now == null || was == null) ? null : now - was;
  }
}
