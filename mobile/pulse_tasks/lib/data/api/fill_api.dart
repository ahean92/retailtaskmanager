import 'dart:typed_data';

import '../api_client.dart';

/// Единый движок бланков (чек-лист и форма): apiStartExecution /
/// apiExecution{Info,Fields,Options,Columns,Rows} / apiSetField / apiSetCell /
/// apiSetFieldPhoto / apiSetResolution / apiFinishExecution, поля адресуются кодом.
extension FillApi on ApiClient {
  /// [lat]/[lon]/[at] — где и когда, по часам устройства, работа началась (#36838).
  /// Сняты в момент действия, а не отправки: вызов из очереди несёт значения,
  /// записанные при постановке, — офлайн-дожим не подменяет место работы местом
  /// появления сети. Отсутствующие координаты не отправляются вовсе — пусто на
  /// сервере честнее нуля.
  Future<void> startExecution(String taskId,
          {double? lat, double? lon, String? at}) =>
      postJson('apiStartExecution', {
        'id': taskId,
        if (lat != null) 'lat': lat,
        if (lon != null) 'lon': lon,
        if (at != null) 'at': at,
      });
  /// Одна тройка адресации у всех читающих ручек бланка (#36778): по задаче — её
  /// текущее заполнение; с prev — прошлая проверка того же объекта и шаблона; с
  /// objectId (без задачи) — последняя завершённая проверка объекта. Сервер отдаёт
  /// прошлое заполнение тем же JSON, что и текущее, — рендерер один.
  Map<String, String> _fillAddress(String? taskId,
          {bool prev = false, String? objectId}) =>
      {
        if (taskId != null) 'id': taskId,
        if (prev) 'prev': '1',
        if (objectId != null) 'objectId': objectId,
      };
  Future<Map<String, dynamic>?> fetchExecutionInfo(String? taskId,
      {bool prev = false, String? objectId}) async {
    final r = await get(exec('apiExecutionInfo',
        _fillAddress(taskId, prev: prev, objectId: objectId)));
    final list = decodeList(r.bodyBytes);
    return list.isEmpty ? null : list.first;
  }
  Future<List<Map<String, dynamic>>> fetchExecutionFields(String? taskId,
      {bool prev = false, String? objectId}) async {
    final r = await get(exec('apiExecutionFields',
        _fillAddress(taskId, prev: prev, objectId: objectId)));
    return decodeList(r.bodyBytes);
  }
  Future<List<Map<String, dynamic>>> fetchExecutionOptions(String? taskId,
      {bool prev = false, String? objectId}) async {
    final r = await get(exec('apiExecutionOptions',
        _fillAddress(taskId, prev: prev, objectId: objectId)));
    return decodeList(r.bodyBytes);
  }
  /// Set one field value. Exactly one typed value is normally provided; a comment
  /// may accompany any of them. Numbers/booleans go over natively.
  ///
  /// [refId]/[refName] — поле-ссылка (#36841): идентификатор предмета в канале поля и
  /// текст-снимок на момент выбора. Пустые строки — явная очистка обоих слотов на
  /// сервере, поэтому они не выбрасываются из тела, как null.
  Future<void> setField(String taskId, String fieldCode,
          {String? optionCode,
          double? number,
          String? text,
          bool? boolVal,
          String? date,
          String? comment,
          String? refId,
          String? refName}) =>
      postJson('apiSetField', {
        'id': taskId,
        'field': fieldCode,
        if (optionCode != null) 'optCode': optionCode,
        if (number != null) 'number': number,
        if (text != null) 'text': text,
        if (boolVal != null) 'bool': boolVal,
        if (date != null) 'date': date,
        if (comment != null && comment.isNotEmpty) 'comment': comment,
        if (refId != null) 'refId': refId,
        if (refName != null) 'refName': refName,
      });
  /// Кандидаты справочника для поля-ссылки или табличного поля (#36841): канал задан
  /// настройкой поля на сервере, поэтому адресация — задача + код поля. По умолчанию
  /// сервер отдаёт доступных на объекте задачи (или весь канал, если хост фильтра не
  /// дал); [query] — серверный поиск по имени, [all] — весь справочник.
  Future<List<Map<String, dynamic>>> fetchRowSubjects(
      String taskId, String fieldCode,
      {String? query, bool all = false}) async {
    final r = await get(exec('apiRowSubjects', {
      'id': taskId,
      'field': fieldCode,
      if (query != null && query.isNotEmpty) 'query': query,
      if (all) 'allItems': 'true',
    }));
    return decodeList(r.bodyBytes);
  }

  // --- table fields ---
  Future<List<Map<String, dynamic>>> fetchExecutionColumns(String? taskId,
      {bool prev = false, String? objectId}) async {
    final r = await get(exec('apiExecutionColumns',
        _fillAddress(taskId, prev: prev, objectId: objectId)));
    return decodeList(r.bodyBytes);
  }
  Future<List<Map<String, dynamic>>> fetchExecutionRows(String? taskId,
      {bool prev = false, String? objectId}) async {
    final r = await get(exec('apiExecutionRows',
        _fillAddress(taskId, prev: prev, objectId: objectId)));
    return decodeList(r.bodyBytes);
  }
  /// Скачать один снимок поля (#36778): миниатюру для галереи просмотра или полный
  /// размер по явному тапу. Сырые jpg-байты, не base64 — см. apiFieldPhoto.
  Future<Uint8List> fetchFieldPhoto(String? taskId, String fieldCode, int index,
      {bool thumb = false, bool prev = false, String? objectId}) async {
    final r = await get(
      exec('apiFieldPhoto', {
        ..._fillAddress(taskId, prev: prev, objectId: objectId),
        'field': fieldCode,
        'index': '$index',
        if (thumb) 'thumb': '1',
      }),
      // полный размер по мобильной сети дальнего магазина в 20 секунд не обязан
      // укладываться — тайм-аут по размеру ноши, как у createTask с фото
      timeout: thumb ? const Duration(seconds: 20) : const Duration(seconds: 60),
    );
    return r.bodyBytes;
  }
  /// Set one table cell. One typed value (number or text) per call.
  ///
  /// Строка адресуется [rowKey] — uuid, выданным телефоном (#36943). Ключ, которого
  /// сервер ещё не видел, он заводит сам, если поле разрешает ручные строки: тогда
  /// очередь не зависит от порядка, и правка ячейки, обогнавшая создание строки, не
  /// теряется. Полю без ручных строк неизвестный ключ — отказ, и это правильно:
  /// иначе опечатка молча плодила бы строки.
  Future<void> setCell(
          String taskId, String fieldCode, String rowKey, String colCode,
          {double? number, String? text}) =>
      postJson('apiSetCell', {
        'id': taskId,
        'field': fieldCode,
        'rowKey': rowKey,
        'col': colCode,
        if (number != null) 'number': number,
        if (text != null) 'text': text,
      });
  /// Добавить строку табличного поля (#36943). Идемпотентно по [rowKey]: повтор из
  /// очереди второй строки не создаёт. [subjectName] — снимок имени на момент выбора:
  /// строка обязана читаться и тогда, когда справочника под рукой нет.
  Future<void> addRow(String taskId, String fieldCode, String rowKey,
          {String? subjectId, String? subjectName}) =>
      postJson('apiAddRow', {
        'id': taskId,
        'field': fieldCode,
        'rowKey': rowKey,
        if (subjectId != null && subjectId.isNotEmpty) 'subjectId': subjectId,
        if (subjectName != null && subjectName.isNotEmpty)
          'subjectName': subjectName,
      });
  /// Удалить строку по ключу. Повтор по уже удалённой — no-op на сервере, так что
  /// очередь может отправить его второй раз и не получить отказа.
  Future<void> deleteRow(String taskId, String fieldCode, String rowKey) =>
      postJson('apiDeleteRow', {
        'id': taskId,
        'field': fieldCode,
        'rowKey': rowKey,
      });
  /// Приложить кадр к пункту; пустой [photoBase64] — команда «стереть весь набор».
  ///
  /// Ключ `photo` едет ВСЕГДА, в том числе пустой строкой: сервер стирает набор по
  /// `aPhoto() = ''`, а ОТСУТСТВИЕ ключа читает как NULL и не делает ничего — «Удалить
  /// все» стирало галерею только на телефоне, и снимки возвращались следующей
  /// загрузкой бланка (поймано на стенде приёмкой #36946).
  Future<void> setFieldPhoto(
          String taskId, String fieldCode, String? photoBase64) =>
      postJson('apiSetFieldPhoto', {
        'id': taskId,
        'field': fieldCode,
        'photo': photoBase64 ?? '',
      });
  /// Удалить ОДИН снимок пункта по его серверному индексу (#36946). Индексы после
  /// удаления не уплотняются, а повторный вызов по уже удалённому — no-op на сервере:
  /// очередь может отправить его второй раз и не получить отказа.
  Future<void> deleteFieldPhoto(String taskId, String fieldCode, int index) =>
      postJson('apiDeleteFieldPhoto', {
        'id': taskId,
        'field': fieldCode,
        'index': index,
      });
  Future<void> setResolution(String taskId, String resolution) =>
      postJson('apiSetResolution', {'id': taskId, 'resolution': resolution});
  /// [lat]/[lon]/[at] — где и когда нажато «Завершить», по часам устройства — та же
  /// механика момента действия, что у [startExecution].
  Future<void> finishExecution(String taskId,
          {double? lat, double? lon, String? at}) =>
      postJson('apiFinishExecution', {
        'id': taskId,
        if (lat != null) 'lat': lat,
        if (lon != null) 'lon': lon,
        if (at != null) 'at': at,
      });

  // --- простое выполнение: фотоотчёт с комментарием (#36872) ---
  // Вторая половина выполнения рядом с первой: у бланка apiExecution*, здесь
  // apiSimple*. Адресация та же — идентификатор ЗАДАЧИ (ST-номер или UUID телефона).
}
