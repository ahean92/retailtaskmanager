// Локальная база бланка для модульных тестов контроллера заполнения.
//
// Реализует ровно то, что FillController трогает при загрузке, ответе и синке:
// кэш бланка, очередь полей, исход. Всё остальное — UnimplementedError с именем
// метода: если контроллер полез куда-то ещё, тест скажет куда.

import 'package:pulse_tasks/data/local_db.dart';

class FakeFillDb implements LocalDb {
  final fieldOutbox = <String, Map<String, Object?>>{};
  Map<String, Object?>? cache;

  @override
  String get userKey => 'test';

  @override
  Future<Map<String, Object?>?> getFillCache(String taskId) async => cache;

  @override
  Future<void> saveFillCache(String taskId, String fieldsJson,
      String optionsJson, String infoJson, String fetchedAtIso,
      {String columnsJson = '[]',
      String rowsJson = '[]',
      String subjectsJson = '{}'}) async {
    cache = {
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
    cache?['infoJson'] = infoJson;
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
    fieldOutbox[fieldCode] = {
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
      fieldOutbox.values.toList();

  @override
  Future<void> dequeueField(String taskId, String fieldCode) async {
    fieldOutbox.remove(fieldCode);
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

  // обычная серверная задача: жизненного цикла «рождена на телефоне» (#36716) у неё нет
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
