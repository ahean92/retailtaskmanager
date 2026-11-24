import 'package:flutter/foundation.dart';

import '../models/notification.dart';
import 'api_client.dart';
import 'local_db.dart';
import 'quiet_after_dispose.dart';
import 'session.dart';
import 'settings.dart';
import 'user_base.dart';

/// Лента уведомлений (#36717) и бейдж над ней. Без локального кэша: журнал держит
/// сервер, а офлайн экран честно показывает последнее полученное за этот запуск.
/// Перечитывается раз в минуту и по пушу — расписание у SyncCoordinator.
class NotificationsController extends ChangeNotifier with QuietAfterDispose {
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

  /// Отметки «прочитано», не доехавшие без связи, по ключу записи: уходят
  /// следующим обновлением ленты, а до тех пор запись показывается прочитанной —
  /// тап уже был, и возвращать подсветку незачем.
  final Map<String, NotificationItem> _unsentViews = {};

  /// База сменилась: лента адресована ушедшему, следующему её не показывают.
  Future<void> _onBase(LocalDb? db) async {
    items = const [];
    _unsentViews.clear();
  }

  /// Перечитать ленту уведомлений. Ошибка тихая: таймер попробует снова через
  /// минуту, а про офлайн и так говорит баннер.
  Future<void> refresh() async {
    if (!settings.isConfigured || !session.isActive) return;
    try {
      for (final n in [..._unsentViews.values]) {
        await api.markNotificationViewed(n.event!, n.taskId, n.date!);
        _unsentViews.remove(n.key);
      }
    } catch (_) {
      // связи всё ещё нет — отметки подождут следующего обновления
    }
    try {
      final list = await api.fetchNotifications();
      // новые сверху; нечитаемая дата не роняет ленту, а падает в конец
      list.sort((a, b) {
        final x = a.when, y = b.when;
        if (x == null) return y == null ? 0 : 1;
        if (y == null) return -1;
        return y.compareTo(x);
      });
      items = [
        for (final x in list)
          _unsentViews.containsKey(x.key) ? x.copyWith(viewed: true) : x
      ];
      notifyListeners();
    } catch (_) {
      // офлайн или отказ — остаётся показанное ранее
    }
  }

  /// Одна запись прочитана — по тапу (#37125). Подсветка гаснет сразу, не дожидаясь
  /// сервера: человек уже открыл, и кадр не должен ждать сети. Не доехало — отметка
  /// уйдёт следующим обновлением ленты ([refresh]): повторный тап по уже погасшей
  /// записи сюда не доходит, и рассчитывать на него нельзя.
  Future<void> markViewed(NotificationItem n) async {
    if (n.viewed || n.event == null || n.date == null) return;
    items = [
      for (final x in items) x.key == n.key ? x.copyWith(viewed: true) : x
    ];
    notifyListeners();
    try {
      await api.markNotificationViewed(n.event!, n.taskId, n.date!);
    } catch (_) {
      _unsentViews[n.key] = n; // ручка идемпотентна — повтор безвреден
    }
  }

  /// «Отметить все прочитанными» — кнопка в шапке ленты (#37125). Нужна тем событиям,
  /// которые открывать незачем: «просрочена» и «проверка завершена» человек прочитал
  /// глазами, и заставлять его тапать по каждой, чтобы погас бейдж, — работа ради
  /// работы. Одним вызовом серверу.
  Future<void> markAllViewed() async {
    try {
      await api.markAllNotificationsViewed();
    } catch (_) {
      return; // не доехало — лента останется как была, повторит следующим нажатием
    }
    items = [for (final n in items) n.copyWith(viewed: true)];
    notifyListeners();
  }
}
