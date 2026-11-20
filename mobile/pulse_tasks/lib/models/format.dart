// Как приложение пишет расстояния и даты. Отдельно от моделей: их зовут и задача,
// и место, и итоги бланка, и экраны — и никому из них ради этого не нужна задача.

/// «120 м», «1,2 км», «12 км». Метры, пока шаг в сотню метров ещё что-то значит для
/// того, кто идёт пешком; дальше километры, и десятые доли в них уже только мешают.
/// Одна на задачу и на объект из apiNearbyObjects: расстояние в шапке и на карточке
/// задачи обязано читаться одинаково.
String formatDistance(double d) {
  if (d < 1000) return '${d.round()} м';
  final km = d / 1000;
  if (km < 10) return '${km.toStringAsFixed(1).replaceAll('.', ',')} км';
  return '${km.round()} км';
}

/// «30.08.2026», а с [short] — «30.08» (в другом году и короткая — «30.08.2025»: год
/// за пределами текущего меняет вывод сильнее, чем день). Одна на строку списка,
/// карточку задачи, новости главной и «прошлую проверку»: срок в списке и в карточке
/// обязан читаться как одна и та же дата, а не как машинная строка рядом с
/// человеческой. Время, если оно есть, отбрасывается; что не разбирается как дата,
/// показывается как пришло.
String? formatDate(String? raw, {bool short = false}) {
  if (raw == null || raw.isEmpty) return null;
  final d = DateTime.tryParse(raw);
  if (d == null) return raw;
  final dm = '${d.day.toString().padLeft(2, '0')}.'
      '${d.month.toString().padLeft(2, '0')}';
  return short && d.year == DateTime.now().year ? dm : '$dm.${d.year}';
}

/// «25.09 11:00» (в другом году — «25.09.2025 11:00»): момент, а не только день, — для
/// сдачи и решения по задаче (#37158), где «когда» считают часами. Время lsFusion
/// приходит через `T` или пробел; неразобранное показывается как пришло.
String? formatDateTime(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  final d = DateTime.tryParse(raw.replaceFirst(' ', 'T'));
  if (d == null) return raw;
  String two(int v) => v.toString().padLeft(2, '0');
  return '${formatDate(d.toIso8601String(), short: true)} '
      '${two(d.hour)}:${two(d.minute)}';
}
