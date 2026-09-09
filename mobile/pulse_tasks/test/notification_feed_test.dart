import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_tasks/models/notification.dart';
import 'package:pulse_tasks/models/notification_feed.dart';

/// Разбивка ленты уведомлений по датам (#37125).
///
/// Проверяется то, ради чего всё затевалось: заголовки «Сегодня», «Вчера», «На этой
/// неделе» считаются от СЕРВЕРНОЙ даты, а не от часов телефона. Образец — тесты
/// признаков срока (`due_flags_test.dart`, #36944): там ровно так же доказано, что
/// состав списков не зависит от даты устройства. Здесь дата устройства намеренно
/// разъезжается с серверной — «сегодня» у сервера 9 сентября, а тест гоняется в любой
/// день и в любом часовом поясе, и разбивка обязана быть одной и той же.

/// Запись ленты, как её отдаёт `apiNotifications`: серверные `date` и `today`.
NotificationItem _n(String date,
        {String? today = '2026-09-09',
        String time = '10:00:00',
        String? event = 'taskComment',
        String? imageId,
        String title = 'Комментарий'}) =>
    NotificationItem.fromJson({
      'event': event,
      'dateTime': '${date}T$time',
      'date': date,
      'title': title,
      'taskId': 'ST000001',
      if (today != null) 'today': today,
      if (imageId != null) 'imageId': imageId,
    });

List<String> _titles(List<NotificationSection> s) =>
    [for (final x in s) x.title];

void main() {
  group('заголовки от серверной даты', () {
    // Среда 9 сентября 2026: неделя началась в понедельник 7-го, прошлая — 31 августа.
    final today = DateTime(2026, 9, 9);

    test('пять бакетов и ни одного лишнего', () {
      final items = [
        _n('2026-09-09'),
        _n('2026-09-08'),
        _n('2026-09-07'), // понедельник этой недели
        _n('2026-09-06'), // воскресенье прошлой
        _n('2026-08-31'), // понедельник прошлой
        _n('2026-08-20'), // раньше
      ];
      final s = notificationSections(items, today);
      expect(_titles(s), [
        'Сегодня',
        'Вчера',
        'На этой неделе',
        'На прошлой неделе',
        'Ранее',
      ]);
      expect(s[3].items.length, 2, reason: 'воскресенье и понедельник прошлой');
      expect(s.every((x) => x.items.isNotEmpty), isTrue,
          reason: 'пустых секций в ленте не бывает');
    });

    test('телефон с датой на сутки вперёд раскладывает записи так же', () {
      final items = [_n('2026-09-09'), _n('2026-09-08'), _n('2026-09-02')];
      // «Сегодня» берётся из ответа сервера, а не из часов устройства: смещённая на
      // сутки дата телефона (какой бы она ни была в момент прогона) на разбивку не
      // влияет — feedToday даже не спрашивает DateTime.now(), пока сервер прислал today.
      final server = feedToday(items,
          deviceNow: DateTime(2026, 9, 10, 3)); // телефон уже «завтра»
      expect(server, DateTime(2026, 9, 9));
      expect(_titles(notificationSections(items, server)),
          ['Сегодня', 'Вчера', 'На прошлой неделе']);
      // тот же список, разложенный по дате телефона, уехал бы на бакет вниз
      expect(
          _titles(notificationSections(items, DateTime(2026, 9, 10))),
          ['Вчера', 'На этой неделе', 'На прошлой неделе'],
          reason: 'ровно та ошибка, которой поле today и не даёт случиться');
    });

    test('старый сервер без today — считаем по устройству, лента не ломается', () {
      final items = [_n('2026-09-09', today: null), _n('2026-09-08', today: null)];
      final fallback = feedToday(items, deviceNow: DateTime(2026, 9, 9, 23, 30));
      expect(fallback, DateTime(2026, 9, 9));
      expect(_titles(notificationSections(items, fallback)),
          ['Сегодня', 'Вчера']);
    });

    test('понедельник: вчера остаётся «Вчера», а суббота — прошлой неделей', () {
      final monday = DateTime(2026, 9, 14);
      final items = [
        _n('2026-09-14', today: '2026-09-14'),
        _n('2026-09-13', today: '2026-09-14'), // воскресенье
        _n('2026-09-12', today: '2026-09-14'), // суббота
        _n('2026-09-07', today: '2026-09-14'), // понедельник прошлой недели
        _n('2026-09-06', today: '2026-09-14'), // и уже «Ранее»
      ];
      expect(_titles(notificationSections(items, monday)),
          ['Сегодня', 'Вчера', 'На прошлой неделе', 'Ранее']);
    });

    test('порядок записей внутри секции — входной, лента приходит новыми вверх', () {
      final items = [
        _n('2026-09-09', time: '18:00:00', title: 'позже'),
        _n('2026-09-09', time: '09:00:00', title: 'раньше'),
      ];
      final s = notificationSections(items, today);
      expect(s.single.items.map((n) => n.title), ['позже', 'раньше']);
    });

    test('нечитаемая дата не роняет ленту, а уходит в «Ранее»', () {
      final items = [
        _n('2026-09-09'),
        NotificationItem.fromJson(
            {'event': 'overdue', 'title': 'без даты', 'today': '2026-09-09'}),
      ];
      expect(_titles(notificationSections(items, today)), ['Сегодня', 'Ранее']);
    });

    test('время под записью: внутри «Сегодня» и «Вчера» — только часы', () {
      expect(notificationWhen(_n('2026-09-09', time: '07:05:00'), today),
          '07:05');
      expect(notificationWhen(_n('2026-09-08', time: '23:40:00'), today),
          '23:40');
      expect(notificationWhen(_n('2026-09-02', time: '08:00:00'), today),
          '02.09 08:00');
    });
  });

  group('модель записи', () {
    test('imageId и today читаются из ответа и переживают отметку прочтения', () {
      final n = _n('2026-09-09', imageId: '4210');
      expect(n.imageId, '4210');
      expect(n.today, '2026-09-09');
      expect(n.day, DateTime(2026, 9, 9));
      final read = n.copyWith(viewed: true);
      expect(read.viewed, isTrue);
      expect(read.imageId, '4210', reason: 'иначе миниатюра исчезнет по прочтении');
      expect(read.today, '2026-09-09');
    });

    test('числовой imageId приходит числом — читается строкой', () {
      final n = NotificationItem.fromJson(
          {'event': 'taskComment', 'date': '2026-09-09', 'imageId': 4210});
      expect(n.imageId, '4210');
    });

    test('без вложения поля нет — миниатюры не будет', () {
      expect(_n('2026-09-09').imageId, isNull);
    });
  });
}
