import '../../models/comment.dart';
import '../api_client.dart';

/// Переписка по задаче (#36844).
extension CommentApi on ApiClient {
  /// Лента комментариев задачи, старые сверху. Сервер пускает участников задачи —
  /// назначенного (с иерархией) и автора; чужая задача и несуществующий id отвечают
  /// одним и тем же 403.
  Future<List<TaskComment>> fetchTaskComments(String taskId) async {
    final r = await get(exec('apiTaskComments', {'id': taskId}));
    return decodeList(r.bodyBytes).map(TaskComment.fromJson).toList();
  }
  /// Отправить сообщение: тело — строка очереди как есть (id задачи, clientId — UUID,
  /// по которому сервер узнаёт повтор, text и/или photo в base64). Повтор того же
  /// clientId — тот же 200 без тела, поэтому ретраи безопасны. Телу с фото — время по
  /// размеру ноши, как у createTask.
  Future<void> addTaskComment(Map<String, dynamic> body) =>
      postJson('apiAddTaskComment', body,
          timeout: body.containsKey('photo')
              ? const Duration(seconds: 120)
              : const Duration(seconds: 20));
  /// Прочитано до [upTo] — серверного времени последнего показанного сообщения.
  /// Идемпотентна и монотонна на сервере: повтор и отставшая отметка безвредны.
  Future<void> markTaskCommentsRead(String taskId, String? upTo) =>
      postJson('apiMarkTaskCommentsRead', {
        'id': taskId,
        if (upTo != null) 'upTo': upTo,
      });
}
