import '../../models/ai_draft.dart';
import '../api_client.dart';

/// Постановка задачи текстом (AI): включён ли он и черновик по фразе человека.
extension AiApi on ApiClient {
  /// Включён ли AI на этом сервере и какая за ним модель. Спрашивается при
  /// синхронизации: пункт «AI» в меню создания появляется только после «включён» —
  /// на стенде без AI-сервиса человек упирался бы в ошибку вместо ответа.
  Future<AiInfo> fetchAiInfo() async {
    final r = await get(exec('apiAiInfo'), timeout: ApiTimeouts.quick);
    final list = decodeList(r.bodyBytes);
    return list.isEmpty ? const AiInfo() : AiInfo.fromJson(list.first);
  }

  /// Черновик задачи по фразе человека. [dialogId] — ключ разговора: один и тот же во
  /// всех уточнениях и он же станет clientId созданной задачи.
  ///
  /// Время ожидания — своё: за ручкой стоит языковая модель, которая на сервере без
  /// GPU думает секунды, а изредка и полминуты; общие 20 секунд обрывали бы её на
  /// полуслове. Ошибка модели приезжает не статусом, а полем `outcome` в теле — экран
  /// показывает человеку фразу, а не «HTTP 503».
  ///
  /// [card] — черновик, который человек видит на карточке, с его правками и выбором
  /// пальцем. Уходит целиком (пустое поле — тоже правка): сервер отдаёт его модели как
  /// «уже собрано», и правка переживает фразу, которая её не касается.
  Future<AiDraft> aiDraft(String dialogId, String text,
      {String? objectId, double? lat, double? lon, AiDraft? card}) async {
    final r = await postJson('apiAiDraft', {
      'dialogId': dialogId,
      'text': text,
      if (objectId != null && objectId.isNotEmpty) 'objectId': objectId,
      if (lat != null) 'lat': lat,
      if (lon != null) 'lon': lon,
      if (card != null) ...{
        'withDraft': true,
        'draftName': card.name,
        'draftTypeId': card.typeId,
        'draftObjectId': card.objectId,
        'draftPerformerId': card.performerId,
        'draftTemplateCode': card.templateCode,
        'draftDeadline': card.deadline,
        'draftPhoto': card.photoRequired,
        'draftDescription': card.description,
      },
    }, timeout: ApiTimeouts.ai);
    final list = decodeList(r.bodyBytes);
    if (list.isEmpty) {
      // пустое тело от lsFusion — «ответить нечем»; для экрана это ошибка, а не «ok»
      return AiDraft(
        dialogId: dialogId,
        outcome: 'error',
        errorCode: 'emptyResponse',
        message: 'Сервер не вернул ответ AI',
      );
    }
    return AiDraft.fromJson(list.first);
  }
}
