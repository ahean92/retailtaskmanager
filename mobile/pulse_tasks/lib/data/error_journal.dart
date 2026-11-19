import 'dart:async';
import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';

import 'api_client.dart';
import 'client_id.dart';
import 'local_db.dart';

/// Журнал ошибок приложения: исключение, которое никто не поймал, ответ сервера, который
/// приложение не смогло разобрать, падение строки очереди не по вине сети. Человек видит
/// такое как «не работает» — раньше ещё и баннером «офлайн», — а без журнала об этом не
/// узнает никто. Записи копятся в базе вошедшего и уходят на сервер подсистемы пачкой
/// ([upload], ручка apiClientErrors — форма «Ошибки телефонов»).
///
/// Отказы сервера сюда не пишутся: их причину человек видит сам в «Не отправлено».
///
/// Журнал один на приложение и статический: писать в него нужно из мест, которым
/// контроллеры не передаются, — обработчиков ошибок фреймворка и платформы
/// (main.dart). До входа базы нет — записи ждут в памяти и ложатся в базу вошедшего,
/// как только её откроют ([attach]). Сам журнал не падает: ошибка записи ошибки
/// теряется молча, иначе он звал бы сам себя.
class ErrorJournal {
  ErrorJournal._();

  /// Вид записи — где поймано: flutter — ошибка отрисовки и фреймворка; platform —
  /// непойманная асинхронная; sync — строка очереди; call — поход вне очереди
  /// (загрузка экрана, прямое завершение).
  static const flutter = 'flutter', platform = 'platform', sync = 'sync', call = 'call';

  /// Пачка на отправку: журнал ограничен [ErrorsDao.cap], и четыре прохода
  /// синхронизации вывозят его целиком, не раздувая один запрос.
  static const batch = 50;

  static LocalDb? _db;
  static final List<Map<String, Object?>> _early = [];
  static const _earlyCap = 50;

  /// Сервер без ручки журнала (старее телефона): до перезапуска приложения его не
  /// спрашиваем — ответ не изменится, а запрос шёл бы с каждой синхронизацией.
  static bool _unsupported = false;

  static Future<({String? app, String? device})>? _meta;

  /// Записи ложатся в базу по очереди, одной цепочкой: [upload] читает журнал после
  /// всех уже сделанных записей, и тесту есть чего дождаться ([flushed]).
  static Future<void> _writes = Future.value();

  /// Записать ошибку. [where] — место: экран и задача, строка очереди (`fill:ST1`).
  static void record(Object error, StackTrace? stack,
      {required String kind, String? where}) {
    try {
      final message = _clip('$error', 1000);
      final trace = stack == null ? null : _clip('$stack', 4000);
      final entry = <String, Object?>{
        'id': newClientId(),
        // одна и та же ошибка на каждом кадре — одна запись с числом, а не сотня
        'sig': '$kind|${where ?? ''}|${error.runtimeType}|${_clip(message, 200)}|'
            '${trace?.split('\n').first ?? ''}',
        // провод `yyyy-MM-ddTHH:mm:ss` — как у времён очередей (FillController.wireAt)
        'atIso': DateTime.now().toIso8601String().split('.').first,
        'kind': kind,
        'where': where == null ? null : _clip(where, 100),
        'message': message,
        'stack': trace,
      };
      final db = _db;
      if (db == null) {
        if (_early.length < _earlyCap) _early.add(entry);
        return;
      }
      _chain(db, entry);
    } catch (_) {}
  }

  /// Дождаться записей, сделанных до этого вызова.
  static Future<void> flushed() => _writes;

  /// База вошедшего открыта (или закрыта — null): записи, накопленные до входа,
  /// ложатся в неё. Подключается к [UserBase.onChange].
  static Future<void> attach(LocalDb? db) async {
    _db = db;
    if (db == null || _early.isEmpty) return;
    for (final e in _early) {
      _chain(db, e);
    }
    _early.clear();
    await _writes;
  }

  /// Отправить самую старую пачку. Неудача — ничего страшного: записи остаются и
  /// уедут со следующей синхронизацией; отказ сервера в приёме (404 — сервер
  /// старее телефона) выключает отправку до перезапуска.
  static Future<void> upload(ApiClient api) async {
    final db = _db;
    if (db == null || _unsupported) return;
    try {
      await _writes;
      final rows = await db.errors.oldest(batch);
      if (rows.isEmpty) return;
      final meta = await (_meta ??= _readMeta());
      await api.postJson('apiClientErrors', [
        for (final r in rows)
          {
            'id': r['id'],
            'at': r['at'],
            'kind': r['kind'],
            if (r['place'] != null) 'where': r['place'],
            'message': r['message'],
            if (r['stack'] != null) 'stack': r['stack'],
            'count': r['count'],
            if (meta.app != null) 'app': meta.app,
            if (meta.device != null) 'device': meta.device,
          }
      ], timeout: const Duration(seconds: 30));
      await db.errors.remove(rows.map((r) => r['id'] as String));
    } on ApiException catch (e) {
      if (e.status == 404) _unsupported = true;
    } catch (_) {
      // нет сети, сессии или база закрылась под отправкой — журнал подождёт
    }
  }

  /// Для тестов: забыть базу, ожидающие записи и выключенную отправку.
  static void reset() {
    _db = null;
    _early.clear();
    _unsupported = false;
    _meta = null;
    _writes = Future.value();
  }

  static void _chain(LocalDb db, Map<String, Object?> e) =>
      _writes = _writes.then((_) => _write(db, e));

  static Future<void> _write(LocalDb db, Map<String, Object?> e) async {
    try {
      await db.errors.add(
        id: e['id'] as String,
        sig: e['sig'] as String,
        atIso: e['atIso'] as String,
        kind: e['kind'] as String,
        where: e['where'] as String?,
        message: e['message'] as String,
        stack: e['stack'] as String?,
      );
    } catch (_) {}
  }

  static Future<({String? app, String? device})> _readMeta() async {
    String? app;
    try {
      final info = await PackageInfo.fromPlatform();
      app = _clip('${info.version}+${info.buildNumber}', 30);
    } catch (_) {}
    String? device;
    try {
      device = _clip(
          '${Platform.operatingSystem} ${Platform.operatingSystemVersion}', 100);
    } catch (_) {}
    return (app: app, device: device);
  }

  static String _clip(String s, int max) =>
      s.length > max ? '${s.substring(0, max - 1)}…' : s;
}
