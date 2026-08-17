/// Запись журнала уведомлений, как её отдаёт `StoreTask.apiNotifications` (#36717):
/// что произошло, когда и про какую задачу. Тройка (event, taskId, date) — адрес
/// отметки прочтения, тот же структурный ключ, которым сервер запись дедуплицирует;
/// внутренние идентификаторы объектов наружу не ходят.
class NotificationItem {
  final String? event; // код события, e.g. 'taskAssigned'
  final String? dateTime; // момент создания, как экспортирует lsFusion
  final String? date; // 'YYYY-MM-DD' — серверная половина адреса прочтения
  final String? title;
  final String? body;
  final String? taskId; // ST-номер задачи; открывается тапом по записи
  final bool viewed;

  const NotificationItem({
    this.event,
    this.dateTime,
    this.date,
    this.title,
    this.body,
    this.taskId,
    this.viewed = false,
  });

  factory NotificationItem.fromJson(Map<String, dynamic> j) => NotificationItem(
        event: _str(j['event']),
        dateTime: _str(j['dateTime']),
        date: _str(j['date']),
        title: _str(j['title']),
        body: _str(j['body']),
        taskId: _str(j['taskId']),
        viewed: _flag(j['viewed']),
      );

  NotificationItem copyWith({bool? viewed}) => NotificationItem(
        event: event,
        dateTime: dateTime,
        date: date,
        title: title,
        body: body,
        taskId: taskId,
        viewed: viewed ?? this.viewed,
      );

  /// Момент создания как время — для сортировки и подписи; null, если строка
  /// нечитаема (такая запись не роняет ленту, а падает в конец).
  DateTime? get when => dateTime == null ? null : DateTime.tryParse(dateTime!);

  /// Ключ записи в ленте — тот же адрес, что уходит в отметку прочтения.
  String get key => '$event|$taskId|$date';

  static String? _str(Object? v) => v == null ? null : '$v';

  // lsFusion не экспортирует NULL: флаг либо true, либо ключа нет вовсе
  static bool _flag(Object? v) =>
      v == true || v == 1 || (v is String && v.toLowerCase() == 'true');
}
