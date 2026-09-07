import 'package:flutter/foundation.dart';

import '../models/notification.dart';
import 'api_client.dart';
import 'local_db.dart';
import 'session.dart';
import 'settings.dart';
import 'user_base.dart';

/// Лента уведомлений (#36717) и бейдж над ней. Без локального кэша: журнал держит
/// сервер, а офлайн экран честно показывает последнее полученное за этот запуск.
/// Перечитывается раз в минуту и по пушу — расписание у SyncCoordinator.
class NotificationsController extends ChangeNotifier {
  final ApiClient api;
  final Session session;
  final Settings settings;

  NotificationsController(
      {required this.api,
      required this.session,
      required this.settings,
      required UserBase base}) {
    base.onChange(_onBase);
  }

  /// Лента уведомлений — последние 30 дней с сервера, новые сверху (#36717). Без
  /// локального кэша: журнал держит сервер, а офлайн экран честно показывает
  /// последнее полученное за этот запуск.
  List<NotificationItem> items = const [];

  /// Счётчик для бейджа считает клиент: полный список у него и так есть, отдельная
  /// ручка ради одного числа не нужна.
  int get unreadCount {
    var n = 0;
    for (final it in items) {
      if (!it.viewed) n++;
    }
    return n;
  }

  /// База сменилась: лента адресована ушедшему, следующему её не показывают.
  Future<void> _onBase(LocalDb? db) async {
    items = const [];
  }

  /// Перечитать ленту уведомлений. Ошибка тихая: таймер попробует снова через
  /// минуту, а про офлайн и так говорит баннер.
  Future<void> refresh() async {
    if (!settings.isConfigured || !session.isActive) return;
    try {
      final list = await api.fetchNotifications();
      // новые сверху; нечитаемая дата не роняет ленту, а падает в конец
      list.sort((a, b) {
        final x = a.when, y = b.when;
        if (x == null) return y == null ? 0 : 1;
        if (y == null) return -1;
        return y.compareTo(x);
      });
      items = list;
      notifyListeners();
    } catch (_) {
      // офлайн или старый сервер без ручки — остаётся показанное ранее
    }
  }

  /// Открытая лента прочитана: каждая непрочитанная помечается на сервере своим
  /// адресом (событие, задача, дата). Обрыв на середине не страшен: локально
  /// прочитанными становятся только реально отправленные, остальные допометятся
  /// при следующем открытии — сама ручка идемпотентна.
  Future<void> markAllViewed() async {
    final done = <String>{};
    for (final n in items) {
      if (n.viewed || n.event == null || n.date == null) continue;
      try {
        await api.markNotificationViewed(n.event!, n.taskId, n.date!);
        done.add(n.key);
      } catch (_) {
        break; // сеть пропала — остальные при следующем открытии
      }
    }
    if (done.isEmpty) return;
    items = [
      for (final n in items)
        done.contains(n.key) ? n.copyWith(viewed: true) : n
    ];
    notifyListeners();
  }
}
