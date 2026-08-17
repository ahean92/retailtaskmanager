import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/fill.dart';
import 'api_client.dart';
import 'local_db.dart';

/// Drives the fill state for one fillable execution (checklist or procedure).
/// Offline-first over the unified engine: typed fields addressed by code, a
/// per-field outbox, a photo outbox and a pending resolution, all synced together.
class FillController extends ChangeNotifier {
  final LocalDb db;
  final ApiClient api;
  final String taskId;

  FillController({required this.db, required this.api, required this.taskId});

  List<FillField> fields = [];
  FillSummary summary = const FillSummary();
  String? object;
  String? template;
  String? resolution; // effective (local overrides server until synced)
  bool loading = true;
  bool syncing = false;
  bool online = true;
  bool finished = false;
  int pendingCount = 0;
  String? error;
  String? lastSyncError;
  bool _resyncRequested = false;

  /// The screen is gone — and with it, possibly, the base this controller was reading:
  /// signing out closes it as soon as the screens are off the stack, while a sync started
  /// from the last tap may still be in flight. Everything that survives the screen stops
  /// here rather than querying a closed database (or notifying a disposed listener).
  bool _disposed = false;

  /// One task's queues drain from one place at a time, whichever object asks: an open
  /// fill screen and the repository's reconnect drain are two controllers over the same
  /// queues, and a photo they both push goes to the server twice — it appends there.
  /// The chain of futures per task id is the whole mutex.
  static final Map<String, Future<void>> _drains = {};

  /// Completes when the pass that is running right now has fully finished — including
  /// its `_resyncRequested` re-loop. A caller that awaited syncAll must be able to read
  /// the queues afterwards and see the result of a real attempt, not of a coalesced
  /// no-op: finish() judges «сервер отверг» by the queues, and an early return here
  /// made it yank a finish the in-flight pass was still going to send.
  Completer<void>? _syncDone;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  List<int> get _sectionIndexes {
    final seen = <int>{};
    final out = <int>[];
    for (final f in fields) {
      if (seen.add(f.sectionIndex)) out.add(f.sectionIndex);
    }
    return out;
  }

  int get sectionCount => _sectionIndexes.length;

  List<FillField> fieldsOfSection(int page) {
    final idx = _sectionIndexes;
    if (page < 0 || page >= idx.length) return const [];
    return fields.where((f) => f.sectionIndex == idx[page]).toList();
  }

  String sectionTitle(int page) {
    final list = fieldsOfSection(page);
    return list.isEmpty ? '' : (list.first.section ?? 'Раздел');
  }

  int get answeredCount => fields.where((f) => f.answered).length;
  int get totalCount => fields.length;
  int get missingRequired =>
      fields.where((f) => f.required && !f.answered).length;
  int get missingEvidence => fields.where((f) => f.needsEvidence).length;
  bool get resolutionRequired => summary.resolutionRequired;
  bool get canFinish =>
      missingRequired == 0 &&
      missingEvidence == 0 &&
      (!resolutionRequired || resolution != null);

  Future<void> load() async {
    loading = true;
    notifyListeners();
    await _loadFromCache();
    try {
      // A task born on this phone must not be started before it is created: while its
      // own creation/start are still queued, syncAll below performs both in their
      // order. Only a task the server already knows gets the plain direct start — and
      // never a finished one: the server refuses to shadow a completed filling with a
      // fresh empty one, so the call would be a wasted round trip.
      if (!finished && !await db.lifecyclePending(taskId)) {
        await api.startExecution(taskId);
      }
      // Push what the last visit left unsent before reading anything back, so the
      // answers and the score below describe the same state. Reading first would
      // both show a filling the server hasn't been told about and freeze its score
      // one opening behind. Its own summary refresh is skipped — the load fetches
      // `info` a few lines down anyway.
      await syncAll(refreshSummary: false);
      final fieldsRaw = await api.fetchExecutionFields(taskId);
      final optionsRaw = await api.fetchExecutionOptions(taskId);
      final columnsRaw = await api.fetchExecutionColumns(taskId);
      final rowsRaw = await api.fetchExecutionRows(taskId);
      final info = await api.fetchExecutionInfo(taskId);
      summary = FillSummary.fromJson(info ?? const {});
      object = summary.object;
      template = summary.template;
      resolution = summary.resolution;
      await db.saveFillCache(
        taskId,
        jsonEncode(fieldsRaw),
        jsonEncode(optionsRaw),
        jsonEncode(info ?? {}),
        DateTime.now().toIso8601String(),
        columnsJson: jsonEncode(columnsRaw),
        rowsJson: jsonEncode(rowsRaw),
      );
      fields = _assemble(fieldsRaw, optionsRaw, columnsRaw, rowsRaw);
      finished = summary.finished;
      await _overlayOutbox();
      online = true;
    } catch (_) {
      online = false;
      if (fields.isEmpty) {
        error = 'Нет данных офлайн — откройте задачу один раз при связи';
      }
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> _loadFromCache() async {
    final c = await db.getFillCache(taskId);
    if (c == null) return;
    final fieldsRaw =
        (jsonDecode(c['fieldsJson'] as String) as List).cast<dynamic>();
    final optionsRaw =
        (jsonDecode(c['optionsJson'] as String) as List).cast<dynamic>();
    final info =
        (jsonDecode(c['infoJson'] as String) as Map).cast<String, dynamic>();
    final columnsRaw = jsonDecode((c['columnsJson'] as String?) ?? '[]') as List;
    final rowsRaw = jsonDecode((c['rowsJson'] as String?) ?? '[]') as List;
    summary = FillSummary.fromJson(info);
    object = summary.object;
    template = summary.template;
    resolution = summary.resolution;
    fields = _assemble(fieldsRaw, optionsRaw, columnsRaw, rowsRaw);
    finished = summary.finished;
    await _overlayOutbox();
  }

  List<FillField> _assemble(
      List fieldsRaw, List optionsRaw, List columnsRaw, List rowsRaw) {
    final byFieldOpt = <String, List<FillOption>>{};
    for (final o in optionsRaw) {
      final opt = FillOption.fromJson((o as Map).cast<String, dynamic>());
      byFieldOpt.putIfAbsent(opt.fieldCode, () => []).add(opt);
    }
    // table columns, sorted by their index
    final byFieldCol = <String, List<FillColumn>>{};
    for (final c in columnsRaw) {
      final col = FillColumn.fromJson((c as Map).cast<String, dynamic>());
      byFieldCol.putIfAbsent(col.fieldCode, () => []).add(col);
    }
    for (final l in byFieldCol.values) {
      l.sort((a, b) => a.colIndex.compareTo(b.colIndex));
    }
    // table rows: one JSON object per cell → group into rows per (field, rowIndex)
    final byFieldRow = <String, Map<int, FillRowData>>{};
    for (final c in rowsRaw) {
      final m = (c as Map).cast<String, dynamic>();
      final fc = m['fieldCode']?.toString() ?? '';
      final ri = (m['rowIndex'] as num?)?.toInt() ?? 0;
      final col = m['colCode']?.toString() ?? '';
      final row = byFieldRow
          .putIfAbsent(fc, () => {})
          .putIfAbsent(ri, () => FillRowData(ri));
      final n = (m['number'] as num?)?.toDouble();
      if (n != null) row.numbers[col] = n;
      final t = m['text']?.toString();
      if (t != null) row.texts[col] = t;
    }
    final list = fieldsRaw.map((j) {
      final f = FillField.fromJson((j as Map).cast<String, dynamic>());
      f.options = byFieldOpt[f.code] ?? [];
      f.columns = byFieldCol[f.code] ?? [];
      final rows = byFieldRow[f.code];
      f.rows = rows == null
          ? []
          : (rows.values.toList()
            ..sort((a, b) => a.rowIndex.compareTo(b.rowIndex)));
      return f;
    }).toList();
    list.sort((a, b) {
      final c = a.sectionIndex.compareTo(b.sectionIndex);
      return c != 0 ? c : a.fieldIndex.compareTo(b.fieldIndex);
    });
    return list;
  }

  Future<void> _overlayOutbox() async {
    final ob = await db.getFieldOutbox(taskId);
    final byKey = {for (final e in ob) e['fieldCode'] as String: e};
    for (final f in fields) {
      final e = byKey[f.code];
      if (e != null) {
        f.optionCode = e['optionCode'] as String?;
        f.number = (e['number'] as num?)?.toDouble();
        f.text = e['text'] as String?;
        final b = e['boolVal'] as int?;
        f.boolValue = b == null ? null : b != 0;
        f.date = e['dateVal'] as String?;
        f.comment = e['comment'] as String?;
      }
    }
    // overlay pending table-cell edits onto their rows (editable cells only)
    final rowLookup = <String, Map<int, FillRowData>>{};
    for (final f in fields) {
      if (f.type == 'table') {
        rowLookup[f.code] = {for (final r in f.rows) r.rowIndex: r};
      }
    }
    for (final e in await db.getCellOutbox(taskId)) {
      final row = rowLookup[e['fieldCode'] as String]?[e['rowIndex'] as int];
      if (row == null) continue;
      final col = e['colCode'] as String;
      final t = e['text'] as String?;
      if (t != null) {
        row.texts[col] = t;
      } else {
        row.numbers[col] = (e['number'] as num?)?.toDouble();
      }
    }
    // photos are per (field, idx) now — collect them per field in index order
    final photos = await db.getFillPhotos(taskId);
    final byField = <String, List<String>>{};
    for (final e in photos) {
      final path = e['path'] as String?;
      if (path == null) continue; // a pending "clear all" intent, nothing to show
      byField.putIfAbsent(e['fieldCode'] as String, () => []).add(path);
    }
    for (final f in fields) {
      f.photoPaths = byField[f.code] ?? [];
    }
    final pendingRes = await db.getResolutionOutbox(taskId);
    if (pendingRes != null) resolution = pendingRes;
    // завершение, сделанное офлайн, живёт в очереди, а не в кэше сервера: без этого
    // переоткрытый бланк выглядел бы незавершённым, противореча списку
    if (!finished && await db.hasFinish(taskId)) finished = true;
    await _refreshPending();
  }

  /// Содержимое бланка, ещё не ушедшее на сервер. Единственный подсчёт этой суммы:
  /// её же читает гвард finish-шага — новая очередь, добавленная сюда, автоматически
  /// начнёт удерживать finish, вместо того чтобы быть забытой в инлайн-копии.
  Future<int> _bodyQueueCount() async =>
      (await db.getFieldOutbox(taskId)).length +
      (await db.getCellOutbox(taskId)).length +
      (await db.getPendingFillPhotos(taskId)).length +
      (await db.getResolutionOutbox(taskId) != null ? 1 : 0);

  Future<void> _refreshPending() async {
    // the task's own lifecycle counts too: a created-offline task with every field
    // synced is still «не отправлено», because the task itself is
    final lifecycle = (await db.getCreateEntry(taskId) != null ? 1 : 0) +
        (await db.hasStart(taskId) ? 1 : 0) +
        (await db.hasFinish(taskId) ? 1 : 0);
    pendingCount = await _bodyQueueCount() + lifecycle;
  }

  Future<void> _enqueue(FillField f) async {
    await db.enqueueField(
      taskId,
      f.code,
      type: f.type,
      optionCode: f.optionCode,
      number: f.number,
      text: f.text,
      boolVal: f.boolValue,
      dateVal: f.date,
      comment: f.comment,
      createdAtIso: DateTime.now().toIso8601String(),
    );
    await _refreshPending();
  }

  Future<void> _commit(FillField f) async {
    await _enqueue(f);
    notifyListeners();
    unawaited(syncAll());
  }

  Future<void> setOption(FillField f, String code) async {
    f.optionCode = code;
    await _commit(f);
  }

  Future<void> setNumber(FillField f, double? v) async {
    f.number = v;
    await _commit(f);
  }

  Future<void> setText(FillField f, String? v) async {
    f.text = (v == null || v.isEmpty) ? null : v;
    await _commit(f);
  }

  Future<void> setBool(FillField f, bool? v) async {
    f.boolValue = v;
    await _commit(f);
  }

  Future<void> setDate(FillField f, String? iso) async {
    f.date = iso;
    await _commit(f);
  }

  Future<void> setComment(FillField f, String? text) async {
    f.comment = (text == null || text.isEmpty) ? null : text;
    await _commit(f);
  }

  /// Set a numeric cell of a table field (the only editable cell kind for now).
  Future<void> setCellNumber(
      FillField f, FillRowData row, FillColumn col, double? v) async {
    row.numbers[col.code] = v;
    await db.enqueueCell(taskId, f.code, row.rowIndex, col.code,
        number: v, createdAtIso: DateTime.now().toIso8601String());
    await _refreshPending();
    notifyListeners();
    unawaited(syncAll());
  }

  Future<void> setResolution(String code) async {
    resolution = code;
    await db.setResolutionOutbox(
        taskId, code, DateTime.now().toIso8601String());
    await _refreshPending();
    notifyListeners();
    unawaited(syncAll());
  }

  // --- photos (0..N per field) ---
  /// Appends a shot. Each one gets its own local index and its own queue entry, so a
  /// second photo never overwrites the first — on the device or on the server.
  Future<void> addPhoto(FillField f, String sourcePath) async {
    final idx = await db.nextPhotoIndex(taskId, f.code);
    final saved = await _persistPhoto(sourcePath, f, idx);
    f.photoPaths = [...f.photoPaths, saved];
    await db.saveFillPhoto(
        taskId, f.code, idx, saved, DateTime.now().toIso8601String());
    await _refreshPending();
    notifyListeners();
    unawaited(syncAll());
  }

  /// Removes every photo of a field. Per-shot deletion on the server needs the server
  /// index, which this device only knows for shots it uploaded itself; clearing the set
  /// and re-taking is the honest behaviour until the API hands back per-photo ids.
  Future<void> clearPhotos(FillField f) async {
    final old = [...f.photoPaths];
    final wasOnServer = f.serverPhotoCount > 0;
    f.photoPaths = [];
    f.serverPhotoCount = 0;

    final rows = await db.getFillPhotos(taskId);
    for (final e in rows) {
      if (e['fieldCode'] == f.code) {
        await db.deleteFillPhoto(taskId, f.code, e['idx'] as int);
      }
    }
    if (wasOnServer) {
      // an empty photo tells the server to drop the whole set for this field
      await db.saveFillPhoto(
          taskId, f.code, 0, null, DateTime.now().toIso8601String());
    }
    for (final path in old) {
      try {
        await File(path).delete();
      } catch (_) {}
    }
    await _refreshPending();
    notifyListeners();
    unawaited(syncAll());
  }

  /// Where one person's evidence photos live: a subdirectory per user, keyed exactly as
  /// their base is (see [LocalDb.keyFor]). The file name inside is made of the task and
  /// the field, so two people sent to the same task on the same phone would otherwise be
  /// overwriting each other's evidence.
  ///
  /// Static because the directory outlives the controller: signing out with a wipe has to
  /// remove it when no task screen is open to ask.
  static Future<Directory> photoDirectory(String userKey) async {
    final dir = await getApplicationDocumentsDirectory();
    return Directory(p.join(dir.path, 'fill_photos', userKey));
  }

  /// Remove one person's photos — the file half of «выйти и удалить данные»; the rows that
  /// point at these files go with the base itself. Nothing outside their own directory is
  /// touched.
  static Future<void> deletePhotos(String userKey) async {
    final dir = await photoDirectory(userKey);
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  Future<String> _persistPhoto(String sourcePath, FillField f, int idx) async {
    final photoDir = await photoDirectory(db.userKey);
    if (!await photoDir.exists()) await photoDir.create(recursive: true);
    final dest = p.join(photoDir.path, '${taskId}_${f.code}_$idx.jpg');
    await File(sourcePath).copy(dest);
    return dest;
  }

  void _markServerPhoto(String fieldCode) {
    for (final f in fields) {
      if (f.code == fieldCode) f.serverPhotoCount = f.photoPaths.length;
    }
  }

  /// Re-reads `apiExecutionInfo` and the cache behind it. The score, verdict and
  /// outcome are computed only on the server, so this is the sole way the figure
  /// on screen ever moves; call it whenever the server has seen new state. On
  /// failure the previous summary stays — the next sync or reload catches up.
  Future<void> _refreshSummary() async {
    try {
      final info = await api.fetchExecutionInfo(taskId);
      if (_disposed || info == null) return;
      summary = FillSummary.fromJson(info);
      object = summary.object;
      template = summary.template;
      resolution = summary.resolution;
      finished = summary.finished;
      await db.saveFillInfo(taskId, jsonEncode(info));
    } catch (_) {}
  }

  Future<void> syncAll({bool refreshSummary = true}) async {
    if (syncing) {
      // the request folds into the in-flight pass — but the caller still waits for
      // that pass to END, so «syncAll returned» always means «a sync actually ran»
      _resyncRequested = true;
      final done = _syncDone;
      if (done != null) await done.future;
      return;
    }
    syncing = true;
    final done = _syncDone = Completer<void>();
    notifyListeners();
    try {
      // queue up behind whoever is draining this task right now — see [_drains]
      final prev = _drains[taskId] ?? Future<void>.value();
      final run = prev.catchError((_) {}).then((_) => _syncBody());
      _drains[taskId] = run;
      try {
        await run;
      } finally {
        if (identical(_drains[taskId], run)) _drains.remove(taskId);
      }
    } finally {
      syncing = false;
      if (!_disposed) {
        await _refreshPending();
        if (pendingCount == 0) lastSyncError = null;
        // The queue is through, so the server has now seen these answers and has
        // rescored the filling: ask it for the new figure instead of waiting for
        // the screen to be opened again.
        if (refreshSummary && pendingCount == 0 && online) {
          await _refreshSummary();
        }
        if (!_disposed) notifyListeners();
      }
      // wake the coalesced callers last, when the queues already tell the truth
      if (identical(_syncDone, done)) _syncDone = null;
      done.complete();
    }
  }

  Future<void> _syncBody() async {
    do {
      _resyncRequested = false;
      var networkFailed = false;

      // 0) the task itself (#36716). An offline-born task goes up FIRST, and nothing
      // else of it goes until it is through: a field sent ahead of its task answers
      // «Filling not found» — so the order is written here, not hoped for. The server
      // refusing the task (an ApiException, not a lost network) blocks the chain the
      // same way: fields of a task that does not exist have nowhere to go.
      final create = await db.getCreateEntry(taskId);
      if (create != null) {
        final sent = await _push(() async {
          await api.createTask(await _createBody(create));
          await db.dequeueCreate(taskId);
          await _dropCreatePhoto(create);
        });
        if (!sent) break;
      }

      // 0b) the queued start — right behind creation, ahead of every answer: the
      // answers land in the Filling this start creates
      if (await db.hasStart(taskId)) {
        final started = await _push(() async {
          await api.startExecution(taskId);
          await db.dequeueStart(taskId);
        });
        if (!started) break;
      }

      // 1) field values
      for (final e in await db.getFieldOutbox(taskId)) {
        final code = e['fieldCode'] as String;
        try {
          final b = e['boolVal'] as int?;
          await api.setField(
            taskId,
            code,
            optionCode: e['optionCode'] as String?,
            number: (e['number'] as num?)?.toDouble(),
            text: e['text'] as String?,
            boolVal: b == null ? null : b != 0,
            date: e['dateVal'] as String?,
            comment: e['comment'] as String?,
          );
          await db.dequeueField(taskId, code);
          online = true;
        } on ApiException catch (ex) {
          lastSyncError = '$ex';
          online = true;
        } catch (ex) {
          lastSyncError = '$ex';
          online = false;
          networkFailed = true;
          break;
        }
      }
      if (networkFailed) break;

      // 1b) table cells
      for (final e in await db.getCellOutbox(taskId)) {
        final fc = e['fieldCode'] as String;
        final ri = e['rowIndex'] as int;
        final col = e['colCode'] as String;
        try {
          await api.setCell(taskId, fc, ri, col,
              number: (e['number'] as num?)?.toDouble(),
              text: e['text'] as String?);
          await db.dequeueCell(taskId, fc, ri, col);
          online = true;
        } on ApiException catch (ex) {
          lastSyncError = '$ex';
          online = true;
        } catch (ex) {
          lastSyncError = '$ex';
          online = false;
          networkFailed = true;
          break;
        }
      }
      if (networkFailed) break;

      // 2) resolution
      final res = await db.getResolutionOutbox(taskId);
      if (res != null) {
        try {
          await api.setResolution(taskId, res);
          await db.clearResolutionOutbox(taskId);
          online = true;
        } on ApiException catch (ex) {
          lastSyncError = '$ex';
          online = true;
        } catch (ex) {
          lastSyncError = '$ex';
          online = false;
          networkFailed = true;
        }
      }
      if (networkFailed) break;

      // 3) photos
      for (final e in await db.getPendingFillPhotos(taskId)) {
        final code = e['fieldCode'] as String;
        final idx = e['idx'] as int? ?? 0;
        final path = e['path'] as String?;
        try {
          String? b64;
          if (path != null) {
            b64 = base64Encode(await File(path).readAsBytes());
          }
          // the server appends, so each queued shot becomes its own photo there
          await api.setFieldPhoto(taskId, code, b64);
          if (path == null) {
            await db.deleteFillPhoto(taskId, code, idx);
          } else {
            await db.markFillPhotoUploaded(taskId, code, idx);
            _markServerPhoto(code);
          }
          online = true;
        } on ApiException catch (ex) {
          lastSyncError = '$ex';
          online = true;
        } on FileSystemException catch (ex) {
          lastSyncError = 'Файл фото недоступен: ${ex.message}';
          await db.deleteFillPhoto(taskId, code, idx);
        } catch (ex) {
          lastSyncError = '$ex';
          online = false;
          networkFailed = true;
          break;
        }
      }
      if (networkFailed) break;

      // 4) the queued finish (#36716) — strictly last, and only over empty queues:
      // the server validates the filling as a whole, and a finish overtaking a
      // photo would close a half-filled check. Unlike the barrier steps above, a
      // failure here does not break — this is the loop's last step anyway.
      if (await db.hasFinish(taskId) && await _bodyQueueCount() == 0) {
        await _push(() async {
          await api.finishExecution(taskId);
          await db.dequeueFinish(taskId);
          finished = true;
        });
      }
    } while (_resyncRequested);
  }

  /// Одна отправка жизненного цикла задачи: true — ушло; false — не ушло, и причина
  /// уже учтена. ApiException — сервер ответил отказом (сеть жива, online = true),
  /// всё прочее — обрыв связи. Прерывать ли цепочку — решает вызывающий шаг.
  Future<bool> _push(Future<void> Function() send) async {
    try {
      await send();
      online = true;
      return true;
    } on ApiException catch (ex) {
      lastSyncError = '$ex';
      online = true;
      return false;
    } catch (ex) {
      lastSyncError = '$ex';
      online = false;
      return false;
    }
  }

  /// The queued apiCreateTask body, with the author photo (if one was taken) folded
  /// in as base64: the photo travels inside the same POST as the task itself, so a
  /// retry retries them together and the clientId idempotency covers both.
  Future<Map<String, dynamic>> _createBody(Map<String, Object?> entry) async {
    final body =
        (jsonDecode(entry['payload'] as String) as Map).cast<String, dynamic>();
    final path = entry['photoPath'] as String?;
    if (path != null) {
      try {
        body['photo'] = base64Encode(await File(path).readAsBytes());
      } on PathNotFoundException {
        // the file is honestly gone (cleared storage) — the task still has to go up.
        // Any OTHER read failure propagates into step 0's retry path: swallowing it
        // would create the task photo-less and then delete the only copy.
      }
    }
    return body;
  }

  Future<void> _dropCreatePhoto(Map<String, Object?> entry) async {
    final path = entry['photoPath'] as String?;
    if (path == null) return;
    try {
      await File(path).delete();
    } catch (_) {}
  }

  Future<bool> finish() async {
    error = null;
    if (missingRequired > 0) {
      error = 'Заполните обязательные поля ($missingRequired)';
      notifyListeners();
      return false;
    }
    if (missingEvidence > 0) {
      error = 'Добавьте фото/комментарий по несоответствиям';
      notifyListeners();
      return false;
    }
    if (resolutionRequired && resolution == null) {
      error = 'Укажите исход';
      notifyListeners();
      return false;
    }
    // A task born on this phone whose creation or start is still queued cannot be
    // finished directly: the server must see create → start → answers → finish in
    // that order, whatever the network does. The finish is queued as the chain's last
    // step; the syncAll right here uses the network if there is one, and the
    // reconnect drain picks the chain up otherwise (#36716). A finish already sitting
    // in the queue (a drain died between start and finish) takes this branch too —
    // the direct call below would send it a second time on top of step 4.
    if (await db.lifecyclePending(taskId) || await db.hasFinish(taskId)) {
      await db.enqueueFinish(taskId, DateTime.now().toIso8601String());
      await syncAll(refreshSummary: false);
      if (!await db.hasFinish(taskId)) {
        // the whole chain went through — the server holds the finished check
        finished = true;
        online = true;
        await _refreshSummary();
        notifyListeners();
        return true;
      }
      if (!online) {
        // the promised offline behaviour: finished locally, goes up with the network
        finished = true;
        notifyListeners();
        return true;
      }
      // online, yet something up the chain was refused — undo the queued finish and
      // say why; leaving it queued would contradict the «не удалось» on the screen
      await db.dequeueFinish(taskId);
      await _refreshPending();
      error = lastSyncError != null
          ? 'Не синхронизировано: $lastSyncError'
          : 'Не удалось завершить';
      notifyListeners();
      return false;
    }
    await syncAll(refreshSummary: false);
    if (pendingCount > 0) {
      error = lastSyncError != null
          ? 'Не синхронизировано: $lastSyncError'
          : 'Часть данных не синхронизирована — завершите при связи';
      notifyListeners();
      return false;
    }
    try {
      await api.finishExecution(taskId);
      finished = true;
      online = true;
      // Finishing is what the verdict and the outcome are computed from, so the
      // completed screen shows the server's word on them, not the pre-finish one.
      await _refreshSummary();
      notifyListeners();
      return true;
    } catch (e) {
      error = '$e';
      notifyListeners();
      return false;
    }
  }
}
