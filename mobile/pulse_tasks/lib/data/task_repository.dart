import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import '../ui/brand.dart';
import '../ui/theme.dart';

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

  const TaskView(this.task, this.statusId, this.statusName, this.pending);

  String get id => task.id;
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
  int pendingCount = 0;
  bool loading = false;
  bool syncing = false;
  bool online = true;
  String? error; // last network error (for the offline banner / snackbar)

  StreamSubscription<List<ConnectivityResult>>? _connSub;

  Future<void> init() async {
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
      if (ob != null) {
        return TaskView(t, ob.statusId, ob.statusName ?? t.status, true);
      }
      return TaskView(t, t.statusId, t.status, false);
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

  /// Push pending changes, then pull fresh data.
  Future<void> syncAndRefresh() async {
    await syncOutbox();
    await refresh();
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
}
