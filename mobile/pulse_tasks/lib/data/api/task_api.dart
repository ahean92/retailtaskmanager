import 'dart:convert';
import 'dart:typed_data';

import '../../models/place.dart';
import '../../models/task.dart';
import '../../models/task_status.dart';
import '../api_client.dart';

/// Задачи: список и статусы, взятие из пула (#36836), подписка (#37136), рождённые на
/// телефоне (#36716), снимки задачи (#36914).
extension TaskApi on ApiClient {
  /// Fetches the open tasks assigned to the signed-in user. The server filters by
  /// `currentUser()`, so what arrives is already this person's list.
  ///
  /// Место выдачу НЕ сужает (#36837): сервер отдаёт всё назначенное, а «здесь или не
  /// здесь» телефон решает сам ([TaskView.elsewhere]). Координаты и [objectId] всё же
  /// уезжают: по ним сервер считает `distance` каждой строки и ведёт гео-журнал.
  /// Старый сервер по этим же параметрам ещё фильтрует — про его пустой ответ
  /// «ниоткуда» см. страховку в `TaskRepository.refresh`.
  Future<List<Task>> fetchTasks(
      {double? lat, double? lon, String? objectId}) async {
    final params = {
      if (lat != null) 'lat': '$lat',
      if (lon != null) 'lon': '$lon',
      if (objectId != null && objectId.isNotEmpty) 'objectId': objectId,
    };
    final r = await get(exec('apiTasks', params.isEmpty ? null : params));
    return decodeList(r.bodyBytes).map(Task.fromJson).toList();
  }
  /// Which objects are near a point, nearest first.
  ///
  /// When nothing is inside the server's radius the answer still carries one object — the
  /// nearest there is, with `nearby` absent — so «рядом объектов с координатами нет» and
  /// «до ближайшего 12 км» stay two different answers instead of one empty list. An empty
  /// list therefore means the first of those; an empty *body* (which lsFusion sends when
  /// the coordinates are missing) means neither, and is never asked for here: this is
  /// called with a fix in hand or not at all.
  Future<List<NearbyObject>> fetchNearbyObjects(double lat, double lon) async {
    final r = await get(
      exec('apiNearbyObjects', {'lat': '$lat', 'lon': '$lon'}),
      timeout: const Duration(seconds: 15),
    );
    return decodeList(r.bodyBytes).map(NearbyObject.fromJson).toList();
  }
  Future<List<TaskStatus>> fetchStatuses() async {
    final r = await get(exec('apiStatuses'));
    return decodeList(r.bodyBytes).map(TaskStatus.fromJson).toList();
  }
  Future<void> setStatus(String id, String statusId) =>
      postJson('apiSetStatus', {'id': id, 'statusId': statusId});

  // --- взятие задачи из пула подразделения (#36836) ---
  /// Взять задачу на себя. null — принято (в том числе повтор своего же взятия и
  /// no-op по уже закрытой), [TakeRefusal] — задачу держит другой или в праве
  /// отказано; прочие статусы — исключение, как у любой ручки.
  Future<TakeRefusal?> takeTask(String id) => _takeCall('apiTakeTask', id);
  /// Вернуть задачу в пул. Те же исходы; несуществующий id и ничья задача отвечают
  /// пустым 200 — очередь ретраит снятие и не должна на них застревать.
  Future<TakeRefusal?> releaseTask(String id) => _takeCall('apiReleaseTask', id);
  Future<TakeRefusal?> _takeCall(String action, String id) async {
    final r =
        await postJson(action, {'id': id}, accept: const {403, 409});
    if (r.statusCode < 400) return null;
    Map<String, dynamic> j;
    try {
      j = (json.decode(utf8.decode(r.bodyBytes, allowMalformed: true)) as Map)
          .cast<String, dynamic>();
    } catch (_) {
      j = const {}; // нечитаемое тело не делает отказ менее внятным исходом
    }
    return TakeRefusal.fromJson(r.statusCode, j);
  }
  // --- подписка на задачу (#37136) ---
  /// Следить за задачей. null — принято (в том числе повтор уже принятой подписки и
  /// no-op по закрытой задаче); строка — отказ по существу (403: задача больше не видна),
  /// который от повтора не изменится: очередь по нему снимает строку и говорит человеку,
  /// а не ретраит вечно. Прочие статусы — исключение, как у любой ручки.
  Future<String?> followTask(String id) async {
    final r = await postJson('apiFollowTask', {'id': id}, accept: const {403});
    if (r.statusCode < 400) return null;
    final human = ApiClient.humanError(
        utf8.decode(r.bodyBytes, allowMalformed: true).trim());
    return human.isEmpty ? 'Нет доступа к задаче' : human;
  }

  /// Перестать следить. Отказов по существу у ручки нет: не подписан (и несуществующий
  /// id) — тот же пустой 200, поэтому ретрай уже принятой отписки безопасен.
  Future<void> unfollowTask(String id) =>
      postJson('apiUnfollowTask', {'id': id});

  /// Создать задачу, рождённую на телефоне (#36716). Тело — отложенный payload из
  /// task_outbox: clientId (UUID, на нём держится идемпотентность повторов), typeId,
  /// objectId, name и опциональные created/deadline/priorityId/description/assigneeId/
  /// templateId/requirePhoto/photo (base64 от автора). Повтор уже созданного clientId —
  /// тот же 200 без тела, поэтому ретраи безопасны.
  /// Тело с base64-фото на канале дальнего магазина не укладывается в общие 20 секунд,
  /// а недоехавший create — барьер, стопорящий всю цепочку задачи: таких телам даётся
  /// время по размеру ноши.
  Future<void> createTask(Map<String, dynamic> body) =>
      postJson('apiCreateTask', body,
          timeout: body.containsKey('photo')
              ? const Duration(seconds: 120)
              : const Duration(seconds: 20));
  /// Приложить снимок к самой задаче — без комментария (#36914). Одна ручка на оба
  /// места: кадры, снятые при создании (уезжают следом за apiCreateTask), и дозагрузка
  /// к задаче, которая давно на сервере. clientId — ключ идемпотентности: повтор уже
  /// принятого снимка сервер отвечает пустым 200, поэтому ретрай очереди безопасен.
  /// Тайм-аут — как у создания с фото: base64 на канале дальнего магазина в общие
  /// двадцать секунд не укладывается.
  Future<void> addTaskFile(String taskId, String clientId, String photoBase64) =>
      postJson(
          'apiAddTaskFile',
          {'id': taskId, 'clientId': clientId, 'photo': photoBase64},
          timeout: const Duration(seconds: 120));

  // --- unified fillable engine (checklist + form tasks) ---
  /// Файл задачи по id (#36844, общая ручка с файлами задачи #36842): миниатюра для
  /// ленты или полный размер по явному тапу. Сырые байты, не base64 — см. apiTaskFile.
  Future<Uint8List> fetchTaskFile(String fileId, {bool thumb = false}) async {
    final r = await get(
      exec('apiTaskFile', {'id': fileId, if (thumb) 'thumb': '1'}),
      timeout: thumb ? const Duration(seconds: 20) : const Duration(seconds: 60),
    );
    return r.bodyBytes;
  }
}
