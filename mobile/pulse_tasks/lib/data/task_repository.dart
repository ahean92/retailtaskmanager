import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import '../ui/brand.dart';
import '../ui/theme.dart';

import '../models/home.dart';
import '../models/task.dart';
import '../models/task_status.dart';
import 'api_client.dart';
import 'local_db.dart';
import 'settings.dart';

/// A task as shown in the UI: the cached server snapshot plus the *effective*
/// status (an unsynced outbox change overrides the server status) and a flag
/// telling whether a change is still pending sync.
class TaskView {
  final Task task;
  final String? statusId; // effective
  final String? statusName; // effective
  final bool pending;

  /// Effective closedness — the outbox status wins here too, so a task the worker has
  /// just marked done stops counting as overdue before the server has heard about it.
  final bool closed;

  const TaskView(this.task, this.statusId, this.statusName, this.pending,
      {this.closed = false});

  String get id => task.id;

  /// Past its deadline and still open. A closed task is never overdue — the deadline
  /// stopped mattering the moment the work was done.
  bool get overdue {
    final d = task.deadlineDate;
    if (closed || d == null) return false;
    final now = DateTime.now();
    return d.isBefore(DateTime(now.year, now.month, now.day));
  }

  bool get dueToday {
    final d = task.deadlineDate;
    if (closed || d == null) return false;
    final now = DateTime.now();
    return d == DateTime(now.year, now.month, now.day);
  }
}

/// The task lists the home screen can drill into. Mirrors HomeTaskFilter on the server;
/// an unknown value falls back to «all», because a newer server offering a filter this
/// build does not know is not a reason to show nothing.
/// «Выполненные» is deliberately absent: `apiTasks` only ever sends open tasks, so such
/// a filter would always show an empty list.
enum TaskFilter {
  all('Все задачи'),
  open('Открытые'),
  today('На сегодня'),
  overdue('Просроченные');

  final String title;
  const TaskFilter(this.title);

  static TaskFilter parse(String? code) => switch (code) {
        'open' => TaskFilter.open,
        'today' => TaskFilter.today,
        'overdue' => TaskFilter.overdue,
        _ => TaskFilter.all,
      };

  bool matches(TaskView v) => switch (this) {
        TaskFilter.all => true,
        TaskFilter.open => !v.closed,
        TaskFilter.today => v.dueToday,
        TaskFilter.overdue => v.overdue,
      };
}

/// Offline-first repository. Reads always come from the local DB, so the app is
/// fully usable without connectivity. Writes (status changes) are recorded in an
/// outbox and pushed to the server opportunistically (immediately if online,
/// otherwise on the next reconnect / manual sync).
class TaskRepository extends ChangeNotifier {
  final LocalDb db;
  final ApiClient api;
  Settings settings;

  TaskRepository({required this.db, required this.api, required this.settings});

  List<TaskView> tasks = const [];
  List<TaskStatus> statuses = const [];
  HomeLayout home = const HomeLayout();
  int pendingCount = 0;
  bool loading = false;
  bool syncing = false;
  bool online = true;
  String? error; // last network error (for the offline banner / snackbar)

  StreamSubscription<List<ConnectivityResult>>? _connSub;

  Future<void> init() async {
    _restoreHome();
    await _reload();
    try {
      // connectivity_plus 6.x emits a list of active transports; empty or
      // [none] means offline.
      _connSub = Connectivity().onConnectivityChanged.listen((results) {
        final nowOnline =
            results.any((r) => r != ConnectivityResult.none);
        final wasOffline = !online;
        online = nowOnline;
        notifyListeners();
        if (nowOnline && wasOffline) {
          unawaited(syncAndRefresh());
        }
      });
    } catch (_) {
      // connectivity_plus unavailable (e.g. desktop/test) — ignore, offline
      // detection then falls back to failed network calls.
    }
    if (settings.isConfigured) {
      unawaited(refreshBrand());
      unawaited(refreshHome());
      unawaited(syncAndRefresh());
    }
  }

  @override
  void dispose() {
    _connSub?.cancel();
    super.dispose();
  }

  TaskStatus? statusById(String? id) {
    if (id == null) return null;
    for (final s in statuses) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// Rebuild the in-memory view from the local DB (tasks + statuses + outbox),
  /// applying the client-side assignee filter and the outbox status overlay.
  Future<void> _reload() async {
    final all = await db.getTasks();
    final outbox = await db.getOutbox();
    statuses = await db.getStatuses();

    final assignee = settings.assignee.trim();
    final filtered = assignee.isEmpty
        ? all
        : all.where((t) => t.assigneeId == assignee).toList();

    tasks = filtered.map((t) {
      final ob = outbox[t.id];
      final statusId = ob?.statusId ?? t.statusId;
      return TaskView(
        t,
        statusId,
        ob == null ? t.status : (ob.statusName ?? t.status),
        ob != null,
        closed: statusById(statusId)?.closed ?? false,
      );
    }).toList();

    pendingCount = outbox.length;
    notifyListeners();
  }

  /// Pull the latest tasks + statuses from the server into the local cache.
  Future<void> refresh() async {
    if (!settings.isConfigured) {
      error = 'Не настроено подключение';
      notifyListeners();
      return;
    }
    loading = true;
    error = null;
    notifyListeners();
    try {
      final fetched = await api.fetchTasks();
      final st = await api.fetchStatuses();
      await db.replaceTasks(fetched);
      if (st.isNotEmpty) await db.replaceStatuses(st);
      online = true;
    } catch (e) {
      online = false;
      error = 'Нет связи с сервером — показаны сохранённые данные';
    } finally {
      loading = false;
      await _reload();
    }
  }

  /// Change a task's status: record it locally (instant, offline-safe) and try
  /// to push right away.
  Future<void> setStatus(String taskId, TaskStatus status) async {
    await db.enqueue(
        taskId, status.id, status.name, DateTime.now().toIso8601String());
    await _reload();
    unawaited(syncOutbox());
  }

  /// Drain the outbox to the server, oldest first. Stops on the first network
  /// failure and keeps the remaining entries for a later retry.
  Future<void> syncOutbox() async {
    if (syncing) return;
    syncing = true;
    notifyListeners();
    try {
      final outbox = await db.getOutbox();
      for (final entry in outbox.values) {
        try {
          await api.setStatus(entry.taskId, entry.statusId);
          await db.updateTaskStatus(
              entry.taskId, entry.statusId, entry.statusName);
          await db.dequeue(entry.taskId);
          online = true;
        } catch (e) {
          online = false;
          error = 'Не удалось синхронизировать: $e';
          break; // keep this and later entries queued
        }
      }
    } finally {
      syncing = false;
      await _reload();
    }
  }

  /// Push pending changes, then pull fresh data. The home screen rides along: its numbers
  /// are as perishable as the task list, and a pull-to-refresh that updates one but not
  /// the other would leave the two halves of the same screen disagreeing.
  Future<void> syncAndRefresh() async {
    await syncOutbox();
    await refresh();
    await refreshHome();
  }

  void updateSettings(Settings s) {
    settings = s;
    api.settings = s;
    notifyListeners();
  }

  /// Pulls the customer's branding and applies it. Called as soon as the server address
  /// is known — a failure is silent by design: a wrong palette must never stand between
  /// the inspector and their tasks, the app simply keeps the look it already had.
  Future<void> refreshBrand() async {
    if (!settings.isConfigured) return;
    try {
      final j = await api.fetchBrand();
      if (j == null || j.isEmpty) return;
      settings.brandJson = jsonEncode(j);
      await settings.save();
      Wms.brand = Brand.fromJson(j);
    } catch (_) {
      // offline, older server without the endpoint, malformed palette — keep the current
    }
  }

  /// Pulls the home screen configured for this user. Silent on failure for the same
  /// reason as the brand: the cached layout is a fine answer, and an error banner about
  /// the dashboard must not push the tasks off the screen.
  Future<void> refreshHome() async {
    if (!settings.isConfigured) return;
    try {
      final j = await api.fetchHome();
      if (j == null) return;
      final layout = HomeLayout.fromJson(j);
      // An empty answer means "not configured on this server" — keep whatever we had
      // rather than replacing a working home screen with a blank one.
      if (layout.isEmpty) return;
      home = layout;
      settings.homeJson = jsonEncode(layout.toJson());
      await settings.save();
      notifyListeners();
    } catch (_) {
      // offline or an older server without the endpoint — the cached layout stands
    }
  }

  /// The object whose numbers the home screen shows. Falls back to the first one the
  /// server sent, so a fresh install opens on a shop rather than on empty tiles.
  String? get objectId {
    final saved = settings.objectId;
    if (saved.isNotEmpty && home.objects.any((o) => o.id == saved)) return saved;
    return home.objects.isEmpty ? null : home.objects.first.id;
  }

  HomeObject? get currentObject {
    final id = objectId;
    if (id == null) return null;
    for (final o in home.objects) {
      if (o.id == id) return o;
    }
    return null;
  }

  Future<void> selectObject(String id) async {
    settings.objectId = id;
    await settings.save();
    notifyListeners();
  }

  void _restoreHome() {
    if (settings.homeJson.isEmpty) return;
    try {
      home = HomeLayout.fromJson(
          (jsonDecode(settings.homeJson) as Map).cast<String, dynamic>());
    } catch (_) {
      // stored layout unreadable — the app falls back to the plain task list
    }
  }
}
