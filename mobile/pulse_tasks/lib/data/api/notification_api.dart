import '../../models/notification.dart';
import '../api_client.dart';

/// Лента уведомлений (#36717): журнал за 30 дней и отметки прочтения.
extension NotificationApi on ApiClient {
  /// Журнал уведомлений вызывающего исполнителя за последние 30 дней (#36717).
  Future<List<NotificationItem>> fetchNotifications() async {
    final r = await get(exec('apiNotifications'));
    return decodeList(r.bodyBytes).map(NotificationItem.fromJson).toList();
  }

  /// Отметить уведомление прочитанным — адресом (событие, задача, дата), тем же,
  /// каким сервер запись дедуплицирует. Идемпотентна: повтор по уже прочитанному —
  /// тот же 200, поэтому пачка на открытие ленты и ретраи безопасны.
  Future<void> markNotificationViewed(
          String event, String? taskId, String date) =>
      postJson('apiMarkNotificationViewed', {
        'event': event,
        if (taskId != null) 'taskId': taskId,
        'date': date,
      });

  /// «Отметить все прочитанными» одним вызовом: сервер помечает весь непрочитанный
  /// журнал вызывающего в одной транзакции. Прежде кнопка гоняла построчные
  /// отметки — N непрочитанных означали N последовательных запросов.
  Future<void> markAllNotificationsViewed() =>
      postJson('apiMarkAllNotificationsViewed', {});
}
