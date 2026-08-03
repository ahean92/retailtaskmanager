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
      await api.startExecution(taskId);
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
    final photos = await db.getFillPhotos(taskId);
    final pByKey = {for (final e in photos) e['fieldCode'] as String: e};
    for (final f in fields) {
      final e = pByKey[f.code];
      if (e == null) continue;
      final path = e['path'] as String?;
      f.photoPath = path;
      if (path == null && (e['uploaded'] as int? ?? 0) == 0) {
        f.hasServerPhoto = false;
      }
    }
    final pendingRes = await db.getResolutionOutbox(taskId);
    if (pendingRes != null) resolution = pendingRes;
    await _refreshPending();
  }

  Future<void> _refreshPending() async {
    final fo = await db.getFieldOutbox(taskId);
    final cells = await db.getCellOutbox(taskId);
    final ph = await db.getPendingFillPhotos(taskId);
    final res = await db.getResolutionOutbox(taskId);
    pendingCount = fo.length + cells.length + ph.length + (res != null ? 1 : 0);
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

  // --- photos ---
  Future<void> setPhoto(FillField f, String sourcePath) async {
    final saved = await _persistPhoto(sourcePath, f);
    f.photoPath = saved;
    f.hasServerPhoto = false;
    await db.saveFillPhoto(
        taskId, f.code, saved, DateTime.now().toIso8601String());
    await _refreshPending();
    notifyListeners();
    unawaited(syncAll());
  }

  Future<void> removePhoto(FillField f) async {
    final old = f.photoPath;
    final wasOnServer = f.hasServerPhoto;
    f.photoPath = null;
    f.hasServerPhoto = false;
    if (wasOnServer) {
      await db.saveFillPhoto(
          taskId, f.code, null, DateTime.now().toIso8601String());
    } else {
      await db.deleteFillPhoto(taskId, f.code);
    }
    if (old != null) {
      try {
        await File(old).delete();
      } catch (_) {}
    }
    await _refreshPending();
    notifyListeners();
    unawaited(syncAll());
  }

  Future<String> _persistPhoto(String sourcePath, FillField f) async {
    final dir = await getApplicationDocumentsDirectory();
    final photoDir = Directory(p.join(dir.path, 'fill_photos'));
    if (!await photoDir.exists()) await photoDir.create(recursive: true);
    final dest = p.join(photoDir.path, '${taskId}_${f.code}.jpg');
    await File(sourcePath).copy(dest);
    return dest;
  }

  void _markServerPhoto(String fieldCode) {
    for (final f in fields) {
      if (f.code == fieldCode) f.hasServerPhoto = true;
    }
  }

  Future<void> syncAll() async {
    if (syncing) {
      _resyncRequested = true;
      return;
    }
    syncing = true;
    notifyListeners();
    try {
      do {
        _resyncRequested = false;
        var networkFailed = false;

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
          final path = e['path'] as String?;
          try {
            String? b64;
            if (path != null) {
              b64 = base64Encode(await File(path).readAsBytes());
            }
            await api.setFieldPhoto(taskId, code, b64);
            if (path == null) {
              await db.deleteFillPhoto(taskId, code);
            } else {
              await db.markFillPhotoUploaded(taskId, code);
              _markServerPhoto(code);
            }
            online = true;
          } on ApiException catch (ex) {
            lastSyncError = '$ex';
            online = true;
          } on FileSystemException catch (ex) {
            lastSyncError = 'Файл фото недоступен: ${ex.message}';
            await db.deleteFillPhoto(taskId, code);
          } catch (ex) {
            lastSyncError = '$ex';
            online = false;
            networkFailed = true;
            break;
          }
        }
        if (networkFailed) break;
      } while (_resyncRequested);
    } finally {
      syncing = false;
      await _refreshPending();
      if (pendingCount == 0) lastSyncError = null;
      notifyListeners();
    }
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
    await syncAll();
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
      notifyListeners();
      return true;
    } catch (e) {
      error = '$e';
      notifyListeners();
      return false;
    }
  }
}
