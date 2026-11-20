import 'dart:convert';

import 'local_db.dart';

/// Кэш бланка задачи (fill_cache) — запись только отсюда. Его пишут бланк, карточка
/// задачи и галерея снимков, и у каждого своё правило; держать правила в одном месте
/// — значит не дать одному писателю стереть то, что положил другой:
/// - ответ бланка ([saveBundle]) — строка целиком, с кандидатами справочника;
/// - ответ для карточки ([saveForCard]) — без кандидатов: карточка их не читает, а
///   полная перезапись пустыми стёрла бы офлайн-справочник бланка;
/// - удалённый кадр ([forgetShot]) — вычеркнуть из полей строки;
/// - оценка после отправки ([saveInfo]) — только она, строку не заводит.
///
/// Строку задачи, созданной на телефоне, сеет очередь создания в своей транзакции
/// (QueueDao.createTask): кэш и очередь появляются вместе или не появляются вовсе.
class FillCacheStore {
  FillCacheStore(LocalDb db) : _dao = db.fill;

  final FillDao _dao;

  Future<Map<String, Object?>?> read(String taskId) => _dao.getFillCache(taskId);

  /// Ответ бланка: строка целиком, вместе с кандидатами справочника по пунктам.
  Future<void> saveBundle(String taskId,
      {required List<dynamic> fields,
      required List<dynamic> options,
      required Map<dynamic, dynamic> info,
      required List<dynamic> columns,
      required List<dynamic> rows,
      required Map<String, List<Map<String, dynamic>>> subjects}) {
    return _dao.saveFillCache(
      taskId,
      jsonEncode(fields),
      jsonEncode(options),
      jsonEncode(info),
      DateTime.now().toIso8601String(),
      columnsJson: jsonEncode(columns),
      rowsJson: jsonEncode(rows),
      subjectsJson: jsonEncode(subjects),
    );
  }

  /// Ответ агрегата для карточки — [bundle] с полями. Существующую строку
  /// обновляет без кандидатов. Новую заводит только по уже заведённому выполнению —
  /// полям с датой заполнения, тому же доказательству, по которому бланк пропускает
  /// старт: ответ без даты карточка показывает из памяти, не кладя в базу.
  /// Возвращает строку для показа — перечитанную: её мог тем временем завести бланк,
  /// и она свежее.
  Future<Map<String, Object?>> saveForCard(
      String taskId, Map<dynamic, dynamic> bundle,
      {required bool existing}) async {
    List<dynamic> list(Object? v) => ((v as List?) ?? const []).cast<dynamic>();
    final info = (bundle['info'] as Map?) ?? const {};
    final fieldsJson = jsonEncode(list(bundle['fields']));
    final optionsJson = jsonEncode(list(bundle['options']));
    final infoJson = jsonEncode(info);
    final columnsJson = jsonEncode(list(bundle['columns']));
    final rowsJson = jsonEncode(list(bundle['rows']));
    final fetchedAt = DateTime.now().toIso8601String();
    if (existing) {
      await _dao.updateFillCache(taskId,
          fieldsJson: fieldsJson,
          optionsJson: optionsJson,
          infoJson: infoJson,
          columnsJson: columnsJson,
          rowsJson: rowsJson,
          fetchedAtIso: fetchedAt);
    } else if (info['date'] != null) {
      await _dao.insertFillCacheIfAbsent(taskId,
          fieldsJson: fieldsJson,
          optionsJson: optionsJson,
          infoJson: infoJson,
          columnsJson: columnsJson,
          rowsJson: rowsJson,
          fetchedAtIso: fetchedAt);
    }
    return await _dao.getFillCache(taskId) ??
        {
          'taskId': taskId,
          'fieldsJson': fieldsJson,
          'optionsJson': optionsJson,
          'infoJson': infoJson,
          'columnsJson': columnsJson,
          'rowsJson': rowsJson,
          'fetchedAt': fetchedAt,
        };
  }

  /// Вычеркнуть удалённый кадр из кэша. Очередь удалений держит его вне галереи,
  /// пока не уедет, — а потом строка уходит, и кэш (снятый до удаления) снова
  /// называет этот индекс. Офлайн бланк, открытый после успешного удаления,
  /// показывал бы призрак: плитку «фото недоступно офлайн» вместо удалённого кадра.
  /// Кэш чинится сразу при удалении: следующая онлайн-загрузка всё равно перепишет
  /// его ответом сервера. [index] = null — уходят все снимки пункта («Удалить все»).
  Future<void> forgetShot(String taskId, String fieldCode, int? index) async {
    final c = await _dao.getFillCache(taskId);
    if (c == null) return;
    try {
      final fieldsRaw =
          (jsonDecode(c['fieldsJson'] as String) as List).cast<dynamic>();
      var touched = false;
      for (final j in fieldsRaw) {
        if (j is! Map || j['code'] != fieldCode) continue;
        final left = index == null
            ? const <int>[]
            : [
                for (final s in '${j['photoIndexes'] ?? ''}'.split(','))
                  if (int.tryParse(s.trim()) != null &&
                      int.parse(s.trim()) != index)
                    int.parse(s.trim())
              ];
        j['photoIndexes'] = left.join(',');
        j['photoCount'] = left.length;
        j['hasPhoto'] = left.isNotEmpty;
        touched = true;
      }
      if (!touched) return;
      await _dao.saveFillCache(
        taskId,
        jsonEncode(fieldsRaw),
        c['optionsJson'] as String,
        c['infoJson'] as String,
        DateTime.now().toIso8601String(),
        columnsJson: (c['columnsJson'] as String?) ?? '[]',
        rowsJson: (c['rowsJson'] as String?) ?? '[]',
        subjectsJson: (c['subjectsJson'] as String?) ?? '{}',
      );
    } catch (_) {
      // кэш — оптимизация: испорченный или неожиданной формы он чинится загрузкой
    }
  }

  /// Свежая оценка (`apiExecutionInfo`) после отправки правки: она движется с
  /// каждой правкой, а поля и варианты — только с загрузкой. Строки нет — не
  /// заводится: полкэша хуже, чем никакого.
  Future<void> saveInfo(String taskId, Map<dynamic, dynamic> info) =>
      _dao.saveFillInfo(taskId, jsonEncode(info));
}
