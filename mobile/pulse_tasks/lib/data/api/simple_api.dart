import 'dart:typed_data';

import '../api_client.dart';

/// Простое выполнение — фотоотчёт с комментарием (#36872).
extension SimpleApi on ApiClient {
  /// Начать работу: сервер заводит выполнение, если его ещё нет. [lat]/[lon]/[at] —
  /// момент действия, как у [startExecution] бланка.
  Future<void> startSimple(String taskId,
          {double? lat, double? lon, String? at}) =>
      postJson('apiStartSimple', {
        'id': taskId,
        if (lat != null) 'lat': lat,
        if (lon != null) 'lon': lon,
        if (at != null) 'at': at,
      });
  /// Состояние выполнения: завершено ли, комментарий, сколько снимков и с какими
  /// индексами. Кэшируется целиком — экран открывается по нему и без сети.
  Future<Map<String, dynamic>?> fetchSimpleInfo(String taskId) async {
    final r = await get(exec('apiSimpleInfo', {'id': taskId}));
    final list = decodeList(r.bodyBytes);
    return list.isEmpty ? null : list.first;
  }
  /// Приложить снимок — сервер дописывает его в конец набора. Пустой [photoBase64]
  /// (пустая строка) стирает весь набор, как у поля бланка. Время по размеру ноши:
  /// фото по мобильной сети дальнего магазина в общие 20 секунд не укладывается.
  /// То же, что [setFieldPhoto], для фотоотчёта простого выполнения — включая пустой
  /// `photo` как команду «стереть набор»: у apiSetSimplePhoto ровно та же развилка.
  Future<void> setSimplePhoto(String taskId, String? photoBase64) =>
      postJson('apiSetSimplePhoto', {
        'id': taskId,
        'photo': photoBase64 ?? '',
      },
          timeout: photoBase64 == null || photoBase64.isEmpty
              ? const Duration(seconds: 20)
              : const Duration(seconds: 120));
  Future<void> deleteSimplePhoto(String taskId, int index) =>
      postJson('apiDeleteSimplePhoto', {'id': taskId, 'index': index});
  /// Снимок выполнения по индексу — миниатюра для галереи или полный размер по тапу.
  /// Сырые байты, как apiFieldPhoto. Нужен для снимков, сделанных на ДРУГОМ
  /// устройстве (или на этом же до переустановки): свои лежат файлами на диске.
  Future<Uint8List> fetchSimplePhoto(String taskId, int index,
      {bool thumb = false}) async {
    final r = await get(
      exec('apiSimplePhoto', {
        'id': taskId,
        'index': '$index',
        if (thumb) 'thumb': '1',
      }),
      timeout: thumb ? const Duration(seconds: 20) : const Duration(seconds: 60),
    );
    return r.bodyBytes;
  }
  /// Комментарий выполнения — перезапись, а не дописывание: он один, и повтор из
  /// очереди обязан приводить к тому же состоянию.
  Future<void> setSimpleComment(String taskId, String? comment) =>
      postJson('apiSetSimpleComment', {
        'id': taskId,
        if (comment != null) 'comment': comment,
      });
  /// Завершить. Сервер проверяет требование фото и при отказе отвечает ошибкой с
  /// текстом констрейнта — «выполнено» без снимка не должно доезжать как успех.
  Future<void> finishSimple(String taskId,
          {double? lat, double? lon, String? at}) =>
      postJson('apiFinishSimple', {
        'id': taskId,
        if (lat != null) 'lat': lat,
        if (lon != null) 'lon': lon,
        if (at != null) 'at': at,
      });

  // --- переписка по задаче (#36844) ---
}
