import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/fill.dart';
import 'api_client.dart';
import 'local_db.dart';

/// Читает одну прошлую проверку для просмотра (#36778): без очередей, без
/// синхронизации, ничего не пишет на сервер. Две адресации, как у серверных ручек:
/// по задаче — прошлая проверка того же объекта и шаблона относительно её бланка;
/// по объекту — последняя завершённая проверка объекта, вход с карточки объекта.
///
/// Кэш-первым, как весь клиент: сеть обновляет кэш, а офлайн живёт тем, что успел
/// забрать prefetch при синхронизации списка задач. Фото — отдельно и лениво:
/// миниатюры качаются при показе галереи, полный размер по явному тапу, скачанное
/// остаётся на диске и в самолётном режиме показывается оттуда.
class PastFillController extends ChangeNotifier {
  final LocalDb db;
  final ApiClient api;

  /// 'task' + id задачи или 'object' + id объекта — тот же ключ, что в past_fill_cache.
  final String kind;
  final String key;

  PastFillController.forTask(this.db, this.api, String taskId)
      : kind = 'task',
        key = taskId;

  PastFillController.forObject(this.db, this.api, String objectId)
      : kind = 'object',
        key = objectId;

  List<FillField> fields = [];
  FillSummary summary = const FillSummary();
  bool loading = true;
  bool online = true;
  String? error;

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// Прошлой проверки не существует — не ошибка, а ответ: «этот объект проверяется
  /// впервые». Говорить такое можно только с данными на руках: без сети и без кэша
  /// (error != null) верен не этот текст, а «нет данных офлайн».
  bool get empty => !loading && error == null && _hasNothing;

  bool get _hasNothing => summary.date == null && fields.isEmpty;

  int get sectionCount => fields.sectionCount;
  List<FillField> fieldsOfSection(int page) => fields.ofSection(page);
  String sectionTitle(int page) => fields.sectionTitle(page);
  int pageOfField(String fieldCode) => fields.pageOfField(fieldCode);

  Future<void> load() async {
    loading = true;
    notifyListeners();
    await _loadFromCache();
    try {
      await _refresh(db, api, kind, key);
      online = true;
      error = null;
      await _loadFromCache(); // перечитать то, что _refresh только что записал
    } on ApiException catch (e) {
      // сервер ОТВЕТИЛ отказом — сеть жива, и «офлайн» было бы неправдой
      online = true;
      if (_hasNothing) error = '$e';
    } catch (_) {
      online = false;
      if (_hasNothing) {
        error = 'Нет данных офлайн — прошлая проверка ещё не загружалась';
      }
    } finally {
      loading = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> _loadFromCache() async {
    final c = await db.getPastFillCache(kind, key);
    if (c == null) return;
    try {
      final fieldsRaw = jsonDecode((c['fieldsJson'] as String?) ?? '[]') as List;
      final optionsRaw =
          jsonDecode((c['optionsJson'] as String?) ?? '[]') as List;
      final columnsRaw =
          jsonDecode((c['columnsJson'] as String?) ?? '[]') as List;
      final rowsRaw = jsonDecode((c['rowsJson'] as String?) ?? '[]') as List;
      final info =
          (jsonDecode((c['infoJson'] as String?) ?? '{}') as Map)
              .cast<String, dynamic>();
      summary = FillSummary.fromJson(info);
      fields = assembleFillFields(fieldsRaw, optionsRaw, columnsRaw, rowsRaw);
    } catch (_) {
      // нечитаемый кэш — поведём себя как при его отсутствии
    }
  }

  /// Забрать прошлую проверку с сервера и положить в кэш. Статический костяк и для
  /// load() открытого экрана, и для prefetch при синхронизации задач: офлайн-просмотр
  /// работает только если кто-то заранее сходил в сеть.
  ///
  /// Сначала одна лёгкая ручка info: если дата проверки совпала с кэшем — остальные
  /// четыре не тянутся вовсе (прошлая проверка меняется только новым завершением, а
  /// prefetch бегает каждую синхронизацию). Пустой ответ (date отсутствует) кэш
  /// ПЕРЕЗАПИСЫВАЕТ: заполнения не удаляются, так что пустота — это смена адресации
  /// (другая задача под тем же номером), и прежний кэш честнее стереть.
  static Future<void> _refresh(
      LocalDb db, ApiClient api, String kind, String key) async {
    final taskId = kind == 'task' ? key : null;
    final objectId = kind == 'object' ? key : null;
    final prev = kind == 'task';

    final info = await api.fetchExecutionInfo(taskId,
        prev: prev, objectId: objectId);
    final newDate = info?['date']?.toString();

    final old = await db.getPastFillCache(kind, key);
    String? oldDate;
    if (old != null) {
      try {
        oldDate = ((jsonDecode((old['infoJson'] as String?) ?? '{}') as Map)
                .cast<String, dynamic>())['date']
            ?.toString();
      } catch (_) {}
    }
    if (old != null && oldDate != null && oldDate == newDate) return;

    // Прошлая проверка сменилась (объект перепроверили) — скачанные фото прежней
    // неотличимы по имени файла от фото новой, поэтому уходят вместе с ней.
    if (old != null && oldDate != newDate) {
      await _dropPhotoFiles(db.userKey, kind, key);
    }

    final rest = await Future.wait([
      api.fetchExecutionFields(taskId, prev: prev, objectId: objectId),
      api.fetchExecutionOptions(taskId, prev: prev, objectId: objectId),
      api.fetchExecutionColumns(taskId, prev: prev, objectId: objectId),
      api.fetchExecutionRows(taskId, prev: prev, objectId: objectId),
    ]);

    await db.savePastFillCache(
      kind,
      key,
      jsonEncode(rest[0]),
      jsonEncode(rest[1]),
      jsonEncode(info ?? {}),
      DateTime.now().toIso8601String(),
      columnsJson: jsonEncode(rest[2]),
      rowsJson: jsonEncode(rest[3]),
    );
  }

  /// Тихий вариант для синхронизации: ошибка не всплывает — офлайн-просмотр просто
  /// останется со старым кэшем (или без него), следующая синхронизация догонит.
  static Future<void> prefetch(LocalDb db, ApiClient api,
      {String? taskId, String? objectId}) async {
    try {
      if (taskId != null) await _refresh(db, api, 'task', taskId);
      if (objectId != null) await _refresh(db, api, 'object', objectId);
    } catch (_) {}
  }

  // --- фото: дисковый кэш + ленивое скачивание ---

  /// Скачивания в полёте, чтобы галерея из шести миниатюр не тянула одно и то же
  /// шестью параллельными запросами при перерисовках.
  final Map<(String, int, bool), Future<File?>> _downloads = {};

  /// Файл снимка поля: с диска, если уже скачан, иначе из сети (и на диск). null —
  /// ни файла, ни сети: галерея показывает «фото недоступно офлайн».
  Future<File?> photoFile(FillField f, int index, {required bool thumb}) {
    return _downloads.putIfAbsent((f.code, index, thumb), () async {
      final target =
          File(await _photoPath(db.userKey, kind, key, f.code, index, thumb));
      if (await target.exists()) return target;
      try {
        final bytes = await api.fetchFieldPhoto(
          kind == 'task' ? key : null,
          f.code,
          index,
          thumb: thumb,
          prev: kind == 'task',
          objectId: kind == 'object' ? key : null,
        );
        await target.parent.create(recursive: true);
        await target.writeAsBytes(bytes);
        return target;
      } catch (_) {
        // неудача не должна запомниться до конца экрана
        _downloads.remove((f.code, index, thumb));
        return null;
      }
    });
  }

  /// Каталог скачанных фото прошлых проверок — свой на пользователя, как база и
  /// фото-свидетельства (см. FillController.photoDirectory), и стирается вместе
  /// с ними при «выйти и удалить данные».
  static Future<Directory> photoDirectory(String userKey) async {
    final dir = await getApplicationDocumentsDirectory();
    return Directory(p.join(dir.path, 'past_photos', userKey));
  }

  static String _fileSafe(String s) => s.replaceAll(RegExp(r'[^\w.-]'), '_');

  static Future<String> _photoPath(String userKey, String kind, String key,
      String fieldCode, int index, bool thumb) async {
    final dir = await photoDirectory(userKey);
    final name = '${kind}_${_fileSafe(key)}_${_fileSafe(fieldCode)}_$index'
        '${thumb ? '_t' : ''}.jpg';
    return p.join(dir.path, name);
  }

  static Future<void> _dropPhotoFiles(
      String userKey, String kind, String key) async {
    final dir = await photoDirectory(userKey);
    if (!await dir.exists()) return;
    final prefix = '${kind}_${_fileSafe(key)}_';
    await for (final e in dir.list()) {
      if (e is File && p.basename(e.path).startsWith(prefix)) {
        try {
          await e.delete();
        } catch (_) {}
      }
    }
  }

  /// Удалить кэш фото одного пользователя — файловая половина «выйти и удалить
  /// данные»; строки past_fill_cache уходят вместе с самой базой.
  static Future<void> deletePhotos(String userKey) async {
    final dir = await photoDirectory(userKey);
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}
