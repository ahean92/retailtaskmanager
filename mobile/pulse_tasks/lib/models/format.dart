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
/// сдачи и решения по задаче (#37158), где «когда» считают часами. С `short: false`
/// год пишется всегда — так подписаны снимки «было» и «стало» и выполнения карточки.
/// Время lsFusion приходит через `T` или пробел; неразобранное показывается как пришло.
String? formatDateTime(String? raw, {bool short = true}) {
  if (raw == null || raw.isEmpty) return null;
  final d = DateTime.tryParse(raw.replaceFirst(' ', 'T'));
  if (d == null) return raw;
  return '${formatDate(d.toIso8601String(), short: short)} ${_hhmm(d)}';
}

/// «10:42», если сегодня, иначе «25.09 10:42»: когда случилось то, о чём говорят
/// сейчас, — взятие задачи, решение по приёмке. Неразобранное — null.
String? formatMoment(String? iso) {
  if (iso == null) return null;
  final t = DateTime.tryParse(iso);
  if (t == null) return null;
  final now = DateTime.now();
  final sameDay =
      t.year == now.year && t.month == now.month && t.day == now.day;
  if (sameDay) return _hhmm(t);
  return '${t.day.toString().padLeft(2, '0')}.'
      '${t.month.toString().padLeft(2, '0')} ${_hhmm(t)}';
}

String _hhmm(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:'
    '${d.minute.toString().padLeft(2, '0')}';
