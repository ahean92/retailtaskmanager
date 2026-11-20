import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'api_client.dart';
import 'client_id.dart';
import 'local_db.dart';
import 'quiet_after_dispose.dart';
import 'sync/outbox_drain.dart';

/// Общая основа переписок — ленты задачи ([TaskCommentsController]) и чата
/// ([ChatConversationController]). Рисунок у них один, и раньше он жил двумя копиями:
/// сообщение ложится строкой в очередь и показывается в ленте сразу, с пометкой «не
/// отправлено»; уезжает, когда есть сеть, — отсюда же или дренажем без экрана. clientId
/// (UUID) рождается вместе с сообщением: сервер по нему узнаёт повтор, так что ретрай
/// очереди не задваивает сообщение. Отказ сервера по одному сообщению остальных не
/// держит и подписывается под его пузырём. Уведомления после ухода экрана молча
/// гасятся ([QuietAfterDispose]).
///
/// В отличие от бланка ([SyncCoalescer]), вызовы [syncAll] не сливаются: каждый —
/// своя попытка, встающая в [drainLocked] за идущей. Сообщение, легшее в очередь
/// после старта чужого прохода, получает свою попытку сразу, а не следующим заходом.
///
/// У каждой переписки своё: адрес и тело отправки, отметка прочтения, кэш вложений.
abstract class ConversationController extends ChangeNotifier
    with QuietAfterDispose {
  ConversationController({required this.db, required this.api});

  final LocalDb db;
  final ApiClient api;

  bool loading = true;
  bool syncing = false;
  String? error;

  /// Очередь отправки и вердикт о сети — общая политика, см. [OutboxDrain].
  @protected
  OutboxDrain get drain;

  bool get online => drain.online;
  String? get lastSyncError => drain.lastError;

  /// Сервер отверг конкретное сообщение (не обрыв сети) — подпись под его пузырём:
  /// без неё застрявшее «не отправлено» объяснить нечем, а человеку решать, ждать или
  /// убрать (см. [discard]).
  @protected
  final Map<String, String> sendErrors = {};

  int get pendingCount;

  // --- что у каждой переписки своё ---

  /// Кэш и очередь — в ленту на экране.
  @protected
  Future<void> loadLocal();

  /// Куда копируется исходящий снимок до отправки.
  @protected
  Future<Directory> outgoingDirectory();

  /// Строки очереди этой переписки, старейшая первой.
  @protected
  Future<List<Map<String, Object?>>> outbox();

  @protected
  Future<void> dequeue(String clientId);

  @protected
  Future<void> deleteFiles(List<String> paths);

  /// Адрес и прочее, кроме ключа, текста и фото, в теле отправки.
  @protected
  Map<String, dynamic> bodyHead(Map<String, Object?> row);

  /// Отправить одно сообщение.
  @protected
  Future<void> post(Map<String, dynamic> body);

  /// Отложенные отметки прочтения этой переписки — на сервер.
  @protected
  Future<void> sendReadMarks();

  /// Сообщение ушло — перечитать с сервера то, что от этого поменялось (серверные
  /// время и id).
  @protected
  Future<void> refreshAfterSend();

  /// Ключ операции в «Не отправлено» (`вид:ключ`): у ленты — задача, у чата — ключ
  /// переписки, который меняется, когда диалог без связи стал серверным.
  @protected
  String get unsentTask;

  /// Ключ замка [drainLocked]: `вид:ключ`.
  @protected
  String get syncKey;

  /// Слать нечего — проход не нужен вовсе: ни индикатора, ни перерисовки.
  @protected
  Future<bool> nothingToSend() async => false;

  /// Строки очереди или кэша поменялись — кому-то снаружи пора перечитаться.
  @protected
  void queueChanged() {}

  // --- общее ---

  /// Написать: строка в очередь (мгновенно и офлайн-безопасно), пузырь в ленте в том
  /// же кадре, отправка — следом. Фото копируется в каталог этого пользователя и
  /// уходит внутри того же POST, что и текст: одно сообщение — один ретрай. [write]
  /// кладёт строку в очередь своей переписки.
  @protected
  Future<void> enqueueAndSend(String text, String? photoPath,
      Future<void> Function(String clientId, String? text, String? photoPath)
          write) async {
    final clientId = newClientId();
    final trimmed = text.trim();
    String? stored;
    if (photoPath != null) {
      final dir = await outgoingDirectory();
      if (!await dir.exists()) await dir.create(recursive: true);
      stored = p.join(dir.path, 'out_$clientId.jpg');
      await File(photoPath).copy(stored);
    }
    await write(clientId, trimmed.isEmpty ? null : trimmed, stored);
    await loadLocal();
    // экран мог уйти, пока сообщение ложилось в очередь, — уведомление погасит
    // QuietAfterDispose
    notifyListeners();
    queueChanged();
    unawaited(_sendAndRefresh());
  }

  Future<void> _sendAndRefresh() async {
    final sent = await syncAll();
    if (!sent || disposed) return;
    try {
      await refreshAfterSend();
      drain.online = true;
    } catch (_) {}
    notifyListeners();
  }

  /// Убрать из очереди сообщение, которое сервер отверг: ретраить его бесполезно, а
  /// висеть «не отправленным» вечно оно не должно. Только своё и только из очереди —
  /// отправленное не редактируется и не удаляется.
  Future<void> discard(String clientId) async {
    for (final r in await outbox()) {
      if (r['clientId'] != clientId) continue;
      final path = r['photoPath'] as String?;
      if (path != null) await deleteFiles([path]);
    }
    await dequeue(clientId);
    sendErrors.remove(clientId);
    await loadLocal();
    notifyListeners();
    queueChanged();
  }

  /// Дожать очередь этой переписки (и её отметки прочтения). Возвращает, ушло ли
  /// хоть одно сообщение. Открытая переписка и дренаж без экрана — два контроллера
  /// над одной очередью, и сообщение, которое толкнут оба, уехало бы дважды: проход
  /// встаёт в [drainLocked] за тем, кто дренит сейчас.
  Future<bool> syncAll() => drainLocked(syncKey, _drainOnce);

  Future<bool> _drainOnce() async {
    if (await nothingToSend()) return false;
    syncing = true;
    notifyListeners();
    var sent = false;
    try {
      await drain.each(await outbox(), (e) async {
        final cid = e['clientId'] as String;
        await post(await _body(e));
        await dequeue(cid);
        sendErrors.remove(cid);
        final path = e['photoPath'] as String?;
        if (path != null) await deleteFiles([path]);
        sent = true;
      }, kind: drain.kind, taskOf: (_) => unsentTask, onRefused: (e, ex) {
        // сервер ответил отказом (сеть жива): сообщение остаётся в очереди с
        // подписью, следующее пробуем — отказ по одному не блокирует остальные
        sendErrors[e['clientId'] as String] = '$ex';
      });
      await sendReadMarks();
    } finally {
      syncing = false;
      if (!disposed) {
        await loadLocal();
        notifyListeners();
      }
    }
    if (sent) queueChanged();
    return sent;
  }

  /// Тело отправки из строки очереди; фото — base64 внутри. Файл, честно пропавший с
  /// диска (очищенное хранилище), текст не останавливает: сообщение едет без него, а
  /// сообщение из одного пропавшего фото сервер отвергнет — и оно покажется с
  /// подписью, откуда его можно убрать.
  Future<Map<String, dynamic>> _body(Map<String, Object?> e) async {
    final body = <String, dynamic>{'clientId': e['clientId'], ...bodyHead(e)};
    final text = e['text'] as String?;
    if (text != null && text.isNotEmpty) body['text'] = text;
    final path = e['photoPath'] as String?;
    if (path != null) {
      try {
        body['photo'] = base64Encode(await File(path).readAsBytes());
      } on PathNotFoundException {
        // см. выше
      }
    }
    return body;
  }
}
