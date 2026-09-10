import 'json.dart';

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

  /// Вложение, из-за которого уведомление пришло (#37125): качается той же ручкой
  /// `apiTaskFile?id=&thumb=1`, что и снимки задачи. Клиент про виды событий не знает —
  /// пришёл идентификатор, значит на пузыре есть миниатюра.
  final String? imageId;

  /// Пришло по подписке (#37136): задача не моя, я за ней лишь наблюдаю. Это причина,
  /// а не вид события — вида клиент по-прежнему не различает (#36717). Фиксируется
  /// сервером при создании записи, поэтому переживает отписку и закрытие задачи.
  /// Старый сервер ключа не шлёт — пометки нет.
  final bool watching;

  /// «Какое сегодня» по серверу на момент ответа, 'YYYY-MM-DD' (#37125). Приходит в
  /// каждой строке; заголовки ленты считаются от него, а не от часов телефона. Старый
  /// сервер поля не шлёт — тогда лента считает по устройству, как считала.
  final String? today;

  const NotificationItem({
    this.event,
    this.dateTime,
    this.date,
    this.title,
    this.body,
    this.taskId,
    this.viewed = false,
    this.imageId,
    this.watching = false,
    this.today,
  });

  factory NotificationItem.fromJson(Map<String, dynamic> j) => NotificationItem(
        event: jsonText(j['event']),
        dateTime: jsonText(j['dateTime']),
        date: jsonText(j['date']),
        title: jsonText(j['title']),
        body: jsonText(j['body']),
        taskId: jsonText(j['taskId']),
        viewed: jsonFlag(j['viewed']),
        imageId: j['imageId'] == null ? null : '${j['imageId']}',
        watching: jsonFlag(j['watching']),
        today: jsonText(j['today']),
      );

  NotificationItem copyWith({bool? viewed}) => NotificationItem(
        event: event,
        dateTime: dateTime,
        date: date,
        title: title,
        body: body,
        taskId: taskId,
        viewed: viewed ?? this.viewed,
        imageId: imageId,
        watching: watching,
        today: today,
      );

  /// Момент создания как время — для сортировки и подписи; null, если строка
  /// нечитаема (такая запись не роняет ленту, а падает в конец).
  DateTime? get when => dateTime == null ? null : DateTime.tryParse(dateTime!);

  /// Серверный день записи — по нему лента разложена на «Сегодня», «Вчера» и дальше
  /// (#37125). Именно `date`, а не время устройства: это та же половина адреса, которой
  /// сервер запись дедуплицирует, и часы телефона на неё не влияют. Пусто, если строка
  /// нечитаема или поля нет.
  DateTime? get day => parseServerDay(date);

  /// Ключ записи в ленте — тот же адрес, что уходит в отметку прочтения.
  String get key => '$event|$taskId|$date';

}

/// Серверная дата 'YYYY-MM-DD' как день без времени. Одна на модель и на ленту: и
/// `date` записи, и `today` ответа приходят одним форматом, и разбирать их по-разному
/// значило бы завести две трактовки одного поля.
DateTime? parseServerDay(String? iso) {
  if (iso == null || iso.isEmpty) return null;
  final t = DateTime.tryParse(iso);
  return t == null ? null : DateTime(t.year, t.month, t.day);
}
