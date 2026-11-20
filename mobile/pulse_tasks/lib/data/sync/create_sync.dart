import 'dart:convert';

import '../api_client.dart';
import '../local_db.dart';
import '../unsent.dart';
import 'outbox_drain.dart';

/// Отправка задачи, рождённой на телефоне (#36716): apiCreateTask из её очереди.
/// Ставит задачу в очередь [TaskRepository.createTask]; отправляет — это.
///
/// Общий барьер обоих видов выполнения (#36872): пока сервер не знает задачу, ехать не
/// может ничего по ней — ни ответ бланка, ни фото отчёта («Filling not found» /
/// «Execution not found»). Поэтому его зовут первым шагом проходы бланка и поручения:
/// вторая копия этой отправки разошлась бы с первой на первом же изменении тела запроса.
class TaskCreateSync {
  TaskCreateSync._();

  /// Возвращает, известна ли задача серверу: true — очереди создания не было или она
  /// только что ушла; false — отказ или обрыв связи, и вердикт о сети с причиной
  /// учтены в [via] — дренаже того, кто спрашивает. Без него (дренаж без экрана)
  /// причина всё равно ложится в sync_errors под `create:задача`.
  ///
  /// Отказ создания задачу с телефона не стирает, каким бы ни был: он может быть
  /// следствием временно снятой роли, а вместе с задачей ушли бы её ответы и снимки.
  /// Задача остаётся в «Не отправлено» с причиной — повторить или убрать её решает
  /// человек.
  static Future<bool> push(LocalDb db, ApiClient api, String taskId,
      {OutboxDrain? via}) async {
    final entry = await db.queues.getCreateEntry(taskId);
    if (entry == null) return true;
    final sync = via ?? OutboxDrain(() => db);
    final outcome = await sync.one(() async {
      // Задача из сообщения чата (#37441) уезжает своей ручкой: messageId в теле —
      // и сервер собирает ту же задачу плюс sourceMessage и ответ в чат. Тело одно,
      // очередь одна, идемпотентность одна (clientId).
      final body = _body(entry);
      if (body.containsKey('messageId')) {
        await api.createTaskFromMessage(body);
      } else {
        await api.createTask(body);
      }
      await db.queues.dequeueCreate(taskId);
    }, kind: UnsentKind.create, task: taskId);
    return outcome == SendOutcome.sent;
  }

  /// The queued apiCreateTask body as it was written. Фото автора внутри этого POST
  /// больше не едет (#36914): кадров стало 0..N, и все они уходят своей очередью
  /// (TaskFilesController) сразу после создания — одной ручкой с дозагрузкой к готовой
  /// задаче, каждый со своим ключом идемпотентности.
  static Map<String, dynamic> _body(Map<String, Object?> entry) =>
      (jsonDecode(entry['payload'] as String) as Map).cast<String, dynamic>();
}
