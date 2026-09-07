// Локальная база бланка для модульных тестов контроллера заполнения.
//
// Реализует ровно то, что FillController трогает при загрузке, ответе и синке:
// кэш бланка, очередь полей и исход — в бланке (FillDao), «жизненного цикла нет» —
// в очередях (QueueDao). Всё остальное — UnimplementedError с именем метода: если
// контроллер полез куда-то ещё, тест скажет куда.

import 'package:pulse_tasks/data/local_db.dart';

class FakeFillDb implements LocalDb {
  final fieldOutbox = <String, Map<String, Object?>>{};
  Map<String, Object?>? fillCache;

  @override
  String get userKey => 'test';

  @override
  late final FillDao fill = _FakeFill(this);

  @override
  late final QueueDao queues = _FakeQueues();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// Бланк: кэш и очередь полей живут в [FakeFillDb], чтобы тест читал их напрямую.
class _FakeFill implements FillDao {
  _FakeFill(this.owner);
  final FakeFillDb owner;

  @override
  Future<Map<String, Object?>?> getFillCache(String taskId) async => owner.fillCache;

  @override
  Future<void> saveFillCache(String taskId, String fieldsJson,
      String optionsJson, String infoJson, String fetchedAtIso,
      {String columnsJson = '[]',
      String rowsJson = '[]',
      String subjectsJson = '{}'}) async {
    owner.fillCache = {
      'taskId': taskId,
      'fieldsJson': fieldsJson,
      'optionsJson': optionsJson,
      'infoJson': infoJson,
      'columnsJson': columnsJson,
      'rowsJson': rowsJson,
      'subjectsJson': subjectsJson,
      'fetchedAt': fetchedAtIso,
    };
  }

  @override
  Future<void> saveFillInfo(String taskId, String infoJson) async {
    owner.fillCache?['infoJson'] = infoJson;
  }

  @override
  Future<void> enqueueField(String taskId, String fieldCode,
      {required String type,
      String? optionCode,
      double? number,
      String? text,
      bool? boolVal,
      String? dateVal,
      String? comment,
      String? refId,
      String? refName,
      required String createdAtIso}) async {
    owner.fieldOutbox[fieldCode] = {
      'taskId': taskId,
      'fieldCode': fieldCode,
      'type': type,
      'optionCode': optionCode,
      'number': number,
      'text': text,
      'boolVal': boolVal == null ? null : (boolVal ? 1 : 0),
      'dateVal': dateVal,
      'comment': comment,
      'refId': refId,
      'refName': refName,
      'createdAt': createdAtIso,
    };
  }

  @override
  Future<List<Map<String, Object?>>> getFieldOutbox(String taskId) async =>
      owner.fieldOutbox.values.toList();

  @override
  Future<void> dequeueField(String taskId, String fieldCode) async {
    owner.fieldOutbox.remove(fieldCode);
  }

  @override
  Future<List<Map<String, Object?>>> getCellOutbox(String taskId) async =>
      const [];

  @override
  Future<List<Map<String, Object?>>> getRowOutbox(String taskId) async =>
      const [];

  @override
  Future<List<Map<String, Object?>>> getFillPhotos(String taskId) async =>
      const [];

  @override
  Future<List<Map<String, Object?>>> getPendingFillPhotos(
          String taskId) async =>
      const [];

  @override
  Future<List<Map<String, Object?>>> getPhotoDeletes(String taskId) async =>
      const [];

  @override
  Future<String?> getResolutionOutbox(String taskId) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// Обычная серверная задача: жизненного цикла «рождена на телефоне» (#36716) у неё нет.
class _FakeQueues implements QueueDao {
  @override
  Future<bool> lifecyclePending(String taskId) async => false;

  @override
  Future<Map<String, Object?>?> getCreateEntry(String taskId) async => null;

  @override
  Future<bool> hasStart(String taskId) async => false;

  @override
  Future<bool> hasFinish(String taskId) async => false;

  @override
  Future<Map<String, Object?>?> getStartEntry(String taskId) async => null;

  @override
  Future<Map<String, Object?>?> getFinishEntry(String taskId) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
