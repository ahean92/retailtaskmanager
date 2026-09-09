import 'notification.dart';

/// Разбивка ленты уведомлений по датам (#37125).
///
/// Чистая функция над списком: экран рисует то, что она вернула, а тест проверяет то,
/// ради чего всё затевалось, — заголовки считаются от СЕРВЕРНОЙ даты, а не от часов
/// телефона. Та же ловушка, что #36944 закрыл для «на сегодня» и «просрочено»: телефон
/// в чужом часовом поясе или со сдвинутой датой разложил бы записи по чужим заголовкам,
/// и два человека рядом друг с другом увидели бы одно и то же под разными подписями.
///
/// Глубже «Ранее» бакетов нет намеренно: `processNotifications` чистит журнал старше 30
/// дней, а `apiNotifications` физически не отдаёт ничего древнее, так что «в прошлом
/// месяце» и «в прошлом году» остались бы пустыми навсегда.

/// Секция ленты: заголовок и записи под ним, в том же порядке, в каком пришли.
class NotificationSection {
  final String title;
  final List<NotificationItem> items;

  const NotificationSection(this.title, this.items);
}

const _titles = <String>[
  'Сегодня',
  'Вчера',
  'На этой неделе',
  'На прошлой неделе',
  'Ранее',
];

/// «Какое сегодня» для ленты: серверное `today` из ответа, а если сервер его не шлёт
/// (версия до #37125) — дата устройства. Поле приходит в каждой строке одинаковым,
/// поэтому берётся первое непустое.
DateTime feedToday(List<NotificationItem> items, {DateTime? deviceNow}) {
  for (final n in items) {
    final t = parseServerDay(n.today);
    if (t != null) return t;
  }
  final now = deviceNow ?? DateTime.now();
  return DateTime(now.year, now.month, now.day);
}

/// Лента, разложенная по датам. Пустые секции не возвращаются, порядок записей внутри
/// секции — входной (лента приходит от новых к старым).
List<NotificationSection> notificationSections(
    List<NotificationItem> items, DateTime today) {
  final buckets = <int, List<NotificationItem>>{};
  for (final n in items) {
    buckets.putIfAbsent(_bucket(n, today), () => []).add(n);
  }
  return [
    for (var i = 0; i < _titles.length; i++)
      if (buckets[i] != null) NotificationSection(_titles[i], buckets[i]!),
  ];
}

/// Время записи под заголовком секции: внутри «Сегодня» и «Вчера» день уже назван
/// заголовком, дальше он нужен. Календарь — серверный, часы — те, что проставил сервер
/// в самой записи.
String notificationWhen(NotificationItem n, DateTime today) {
  final t = n.when;
  if (t == null) return '';
  String two(int v) => v.toString().padLeft(2, '0');
  final hm = '${two(t.hour)}:${two(t.minute)}';
  return _bucket(n, today) <= 1 ? hm : '${two(t.day)}.${two(t.month)} $hm';
}

/// Номер бакета записи: 0 — сегодня, 1 — вчера, 2 — эта неделя, 3 — прошлая, 4 — раньше.
/// День записи — серверный `date`; если его нет (строка нечитаема), в ход идёт время
/// создания, а если нет и его — запись уходит в «Ранее», где и стоит в конце списка.
int _bucket(NotificationItem n, DateTime today) {
  final t = n.when;
  final day = n.day ?? (t == null ? null : DateTime(t.year, t.month, t.day));
  if (day == null) return _titles.length - 1;
  // Счёт в UTC: разница двух местных полуночей в сутки перевода часов — 23 часа, и
  // «вчера» стало бы «сегодня» дважды в год.
  final d = DateTime.utc(day.year, day.month, day.day);
  final now = DateTime.utc(today.year, today.month, today.day);
  final diff = now.difference(d).inDays;
  if (diff <= 0) return 0;
  if (diff == 1) return 1;
  final weekStart = now.subtract(Duration(days: now.weekday - 1)); // понедельник
  if (!d.isBefore(weekStart)) return 2;
  if (!d.isBefore(weekStart.subtract(const Duration(days: 7)))) return 3;
  return 4;
}
