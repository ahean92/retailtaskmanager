// Чтение полей JSON, каким его отдаёт lsFusion: значения приходят строками так же
// часто, как числами, NULL не выгружается вовсе, а пустая строка от отсутствия не
// отличается. Одно место на все модели — раньше эти функции лежали копиями в семи
// файлах и понемногу расходились: где-то с trim, где-то без, где-то число с
// запятой читалось, а где-то нет. Здесь — самый терпимый из вариантов: лишний
// пробел и запятая вместо точки не превращают присланное значение в «нет».

/// Строка без крайних пробелов; пустая — то же, что отсутствующая.
String? jsonStr(Object? v) {
  final s = v?.toString().trim();
  return (s == null || s.isEmpty) ? null : s;
}

/// Строка как есть — для текста, где пробелы и пустота значимы (сообщение в ленте,
/// тело уведомления, поля задачи).
String? jsonText(Object? v) => v == null ? null : '$v';

int? jsonInt(Object? v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse('$v'.trim());
}

/// Число; «1,5» — тоже число: lsFusion форматирует по локали.
double? jsonNum(Object? v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse('$v'.trim().replaceAll(',', '.'));
}

/// Флаг, как его выгружает lsFusion: true, 1 или 'true'; NULL не экспортируется, так
/// что отсутствие ключа — тоже false.
bool jsonFlag(Object? v) =>
    v == true || v == 1 || (v is String && v.toLowerCase() == 'true');

/// Список объектов, каждый разобран [parse]; не список — пусто.
List<T> jsonList<T>(Object? raw, T Function(Map<String, dynamic>) parse) {
  if (raw is! List) return const [];
  return raw
      .whereType<Map>()
      .map((e) => parse(e.cast<String, dynamic>()))
      .toList();
}

/// Список объектов как есть; не список — пусто.
List<Map<String, dynamic>> jsonMaps(Object? raw) {
  if (raw is! List) return const [];
  return raw.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
}
