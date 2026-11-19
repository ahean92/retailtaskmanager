import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../api_client.dart';
import '../error_journal.dart';
import '../local_db.dart';
import '../unsent.dart';

/// Одна политика отправки офлайн-очередей — на бланк, отчёт поручения, переписку,
/// снимки задачи, статусы и взятия. Каждая очередь по-прежнему дренится там, где
/// написан её порядок (контроллер знает, что create идёт раньше start, а finish —
/// последним), но что делать с ответом сервера, решается здесь и только здесь:
///
///   ответ сервера                вердикт о сети   строка          цепочка
///   ушло                         связь есть       снята           дальше
///   отказ (4xx)                  связь есть       остаётся,       дальше, если шаг
///                                                 «Убрать» —      не барьер
///                                                 человеку
///   сбой сервера (5xx)           связь есть       остаётся        дальше, если шаг
///                                                                 не барьер
///   SessionExpiredException      без вердикта     остаётся        стоп
///   FileSystemException          без вердикта     по [onFileError] дальше
///   обрыв связи (сокет, таймаут) связи нет        остаётся        стоп: следующие
///                                                                 упрутся в то же
///   всё прочее (ответ не той     без вердикта     остаётся,       дальше, если шаг
///   формы, ошибка приложения)                     в журнал ошибок не барьер
///
/// Отказ от сбоя отличает сервер кодом ответа ([ApiException.refusal]): отказ на тот
/// же запрос не изменится, и человеку предлагают убрать строку; сбой пройдёт, когда
/// сервер оживёт. Ошибку приложения сеть не объясняет — «офлайн» на неё было бы
/// неправдой, а причина, которой человек ничего не сделает, уходит в [ErrorJournal].
///
/// Барьер — шаг, без которого остальным ехать некуда: создание задачи и старт
/// выполнения (#36716). Отказ по обычной строке — полю, ячейке, снимку, сообщению —
/// её не держит остальных: она остаётся в очереди с причиной в sync_errors (#36916)
/// и пробуется снова, а следующие едут. Причина неудачи пишется под ключом
/// `вид:задача` — тем же, которым экран «Не отправлено» находит свою операцию.
///
/// Тот же вердикт о сети выносится и походам вне очередей — загрузке экрана,
/// прямому «Завершить» при связи ([attempt]): «офлайн» на баннере обязан означать
/// одно и то же, откуда бы ни пришёл.
class OutboxDrain {
  /// [db] — откуда брать базу для записи причин: у контроллера экрана она одна на
  /// всю жизнь, у репозитория меняется с входом и выходом, поэтому — функция, а не
  /// значение. [kind] и [taskId] — ключ причины по умолчанию; у очередей, где каждая
  /// строка про свою задачу (статусы, взятия, снимки), задача берётся из строки.
  OutboxDrain(this._db, {this.kind, this.taskId});

  final LocalDb? Function() _db;
  final String? kind;
  final String? taskId;

  /// Последний вердикт о сети: сервер ответил (чем угодно) — связь есть.
  bool online = true;

  /// Текст последней неудачи — то, что экран показывает как «Не принято: …» и
  /// «Не синхронизировано: …». Словами ([failureReason]), не строкой исключения.
  String? lastError;

  /// Она же исключением — чтобы вызывающий мог отличить отказ от обрыва.
  Object? lastFailure;

  /// Одна отправка — старт, итог, завершение. [send] отправляет и снимает строку из
  /// очереди сам: снятие внутри одной попытки, чтобы «ушло» и «снято» не разошлись.
  Future<SendOutcome> one(Future<void> Function() send,
      {String? kind,
      String? task,
      FutureOr<void> Function(ApiException e)? onRefused}) async {
    final r = await _attempt(send, kind: kind, task: task);
    if (r.outcome == SendOutcome.refused) {
      await onRefused?.call(r.error as ApiException);
    }
    return r.outcome;
  }

  /// Прогнать очередь строка за строкой. Возвращает, можно ли продолжать цепочку:
  /// false — обрыв связи, потеря сессии или неудача барьерного шага; очередь остаётся
  /// как есть. [onFileError] — что делать со строкой, чей файл недоступен (снимок
  /// стёрт вместе с хранилищем): по умолчанию причина записывается, строка
  /// пропускается. [onRefused] — отказ по строке, если экрану нужно его показать
  /// у самой строки, а не только в общем «Не принято».
  Future<bool> each<T>(
    Iterable<T> items,
    Future<void> Function(T item) send, {
    bool barrier = false,
    String? kind,
    String Function(T item)? taskOf,
    FutureOr<void> Function(T item, FileSystemException e)? onFileError,
    void Function(T item, ApiException e)? onRefused,
  }) async {
    for (final item in items) {
      final go = await _step(item, send,
          barrier: barrier,
          kind: kind,
          taskOf: taskOf,
          onFileError: onFileError,
          onRefused: onRefused);
      if (!go) return false;
    }
    return true;
  }

  /// То же, но очередь перечитывается после каждой строки: пока строка была в
  /// полёте, человек мог передумать (взятие заменено на снятие — REPLACE в очереди),
  /// и следующей должна уйти уже новая запись. Такой проход не умеет пропускать —
  /// отказ по строке его останавливает, иначе он повторял бы её без конца.
  Future<bool> eachNext<T extends Object>(
    Future<T?> Function() next,
    Future<void> Function(T item) send, {
    String? kind,
    String Function(T item)? taskOf,
  }) async {
    while (true) {
      final item = await next();
      if (item == null) return true;
      final go = await _step(item, send,
          barrier: true, kind: kind, taskOf: taskOf);
      if (!go) return false;
    }
  }

  /// Поход на сервер вне очередей — с тем же вердиктом о сети. Возвращает
  /// исключение, если было (null — ушло): что показать, решает вызывающий, а
  /// причина в sync_errors не пишется — операции в очереди за этим походом нет.
  Future<Object?> attempt(Future<void> Function() call) async =>
      (await _attempt(call, record: false)).error;

  /// Записать причину неудачи: текст — экрану, строку — в sync_errors под ключом
  /// операции. Молчит, если базы уже нет (выход из аккаунта под дренажем).
  Future<void> note(Object error, {String? kind, String? task}) async {
    lastFailure = error;
    lastError = failureReason(error);
    final db = _db();
    final k = kind ?? this.kind;
    final id = task ?? taskId;
    if (db == null || k == null || id == null) return;
    await noteSyncFailure(db, k, id, error);
  }

  Future<bool> _step<T>(
    T item,
    Future<void> Function(T item) send, {
    required bool barrier,
    String? kind,
    String Function(T item)? taskOf,
    FutureOr<void> Function(T item, FileSystemException e)? onFileError,
    void Function(T item, ApiException e)? onRefused,
  }) async {
    final r = await _attempt(() => send(item),
        kind: kind,
        task: taskOf?.call(item),
        onFileError:
            onFileError == null ? null : (e) => onFileError(item, e));
    switch (r.outcome) {
      case SendOutcome.sent || SendOutcome.dropped:
        return true;
      case SendOutcome.refused:
        onRefused?.call(item, r.error as ApiException);
        return !barrier;
      case SendOutcome.failed:
        return !barrier;
      case SendOutcome.offline || SendOutcome.signedOut:
        return false;
    }
  }

  /// Единственное место, где ответ сервера превращается в вердикт: [record] —
  /// строка очереди (причина пишется, файл без строки — не обрыв), иначе — поход
  /// вне очередей.
  Future<({SendOutcome outcome, Object? error})> _attempt(
    Future<void> Function() send, {
    bool record = true,
    String? kind,
    String? task,
    FutureOr<void> Function(FileSystemException e)? onFileError,
  }) async {
    try {
      await send();
      online = true;
      return (outcome: SendOutcome.sent, error: null);
    } on ApiException catch (e) {
      // сервер ОТВЕТИЛ — отказом или сбоем: сеть жива, и «офлайн» было бы неправдой
      online = true;
      if (record) await note(e, kind: kind, task: task);
      return (
        outcome: e.refusal ? SendOutcome.refused : SendOutcome.failed,
        error: e
      );
    } on SessionExpiredException catch (e) {
      // сессия кончилась: очередь переживает перевход, а вердикт о сети здесь ни
      // при чём — сервер ответил
      if (record) await note(e, kind: kind, task: task);
      return (outcome: SendOutcome.signedOut, error: e);
    } catch (e, stack) {
      if (record && e is FileSystemException) {
        // строка непригодна — файла нет; о сети это ничего не говорит
        if (onFileError != null) {
          await onFileError(e);
        } else {
          await note(e, kind: kind, task: task);
        }
        return (outcome: SendOutcome.dropped, error: e);
      }
      if (isNetworkFailure(e)) {
        online = false;
        if (record) await note(e, kind: kind, task: task);
        return (outcome: SendOutcome.offline, error: e);
      }
      // ответ пришёл, но не той формы, или упал сам код: вердикт о сети прежний
      final k = kind ?? this.kind;
      final id = task ?? taskId;
      ErrorJournal.record(e, stack,
          kind: record ? ErrorJournal.sync : ErrorJournal.call,
          where: k == null ? null : '$k:${id ?? ''}');
      if (record) await note(e, kind: kind, task: task);
      return (outcome: SendOutcome.failed, error: e);
    }
  }
}

/// Исход одной отправки — см. таблицу в [OutboxDrain].
enum SendOutcome {
  /// Ушло, строка снята из очереди.
  sent,

  /// Сервер ответил отказом: сеть жива, строка остаётся с причиной, и убрать её
  /// решает человек.
  refused,

  /// Сбой сервера или ошибка приложения: строка остаётся и пробуется снова.
  failed,

  /// Связи нет: строка остаётся, дальше идти незачем.
  offline,

  /// Сессия кончилась: строка остаётся, цепочка стоит, вердикта о сети нет.
  signedOut,

  /// Строка непригодна (файла нет) — с ней поступили по [OutboxDrain.each]'s
  /// `onFileError`; о сети ничего не известно.
  dropped,
}

final Map<String, Future<void>> _drainLocks = {};

/// Очередь одной задачи дренится из одного места за раз, кто бы ни просил: открытый
/// экран и дренаж репозитория при синхронизации — два контроллера над одними
/// очередями, и снимок, который толкнут оба, сервер припишет дважды (он дописывает
/// в конец). Вызов встаёт в очередь за тем, кто держит [key] сейчас; цепочка futures
/// на ключ — весь мьютекс. Ключ — `вид:задача`, как у причин в sync_errors.
Future<T> drainLocked<T>(String key, Future<T> Function() body) async {
  final prev = _drainLocks[key] ?? Future<void>.value();
  final run = prev.then((_) => body());
  // неудача этого прохода — его вызывающему; следующему в очереди она не помеха
  final gate = run.then<void>((_) {}, onError: (_) {});
  _drainLocks[key] = gate;
  try {
    return await run;
  } finally {
    if (identical(_drainLocks[key], gate)) _drainLocks.remove(key);
  }
}

/// Слияние вызовов синхронизации одного экрана: проход идёт — новый запрос
/// складывается в него, но вызывающий ждёт КОНЦА прохода. «syncAll вернулся»
/// всегда означает «попытка отправки состоялась»: finish() судит об отказе сервера
/// по очередям, и ранний возврат заставил бы его снять завершение, которое проход
/// ещё только собирался отправить. Ответы, положенные в очередь во время прохода,
/// не теряются — проход повторяется, пока его просят.
mixin SyncCoalescer on ChangeNotifier {
  bool syncing = false;

  /// Экран ушёл — и с ним, возможно, база, которую читал контроллер: выход из
  /// аккаунта закрывает её, как только экраны сняты со стека, а синхронизация с
  /// последнего тапа ещё может быть в полёте. Всё, что переживает экран, здесь
  /// останавливается, не трогая ни закрытую базу, ни снятых слушателей.
  bool disposed = false;

  bool _resyncRequested = false;

  /// Завершается, когда идущий сейчас проход закончился целиком — вместе с повторами.
  Completer<void>? _syncDone;

  /// Ключ замка [drainLocked]: `вид:задача`.
  String get syncKey;

  /// Один проход по очередям — явный список шагов в их порядке.
  Future<void> drainPass();

  /// После прохода, когда очереди уже говорят правду: перечитать счётчики и, если
  /// [refresh], спросить сервер о новом состоянии. Слушателей будят следом.
  Future<void> afterSync(bool refresh);

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }

  /// Экран ушёл, а дело с его последнего жеста ещё идёт: завершение на стенде отвечает
  /// 15–20 секунд, и человек успевает вернуться на список, пока «Сдать на приёмку» ждёт
  /// ответа (#37158). Уведомлять уже некого, а ChangeNotifier после dispose падает —
  /// одна проверка здесь вместо проверки у каждого вызова после await.
  @override
  void notifyListeners() {
    if (!disposed) super.notifyListeners();
  }

  Future<void> runSync({required bool refresh}) async {
    if (syncing) {
      _resyncRequested = true;
      final done = _syncDone;
      if (done != null) await done.future;
      return;
    }
    syncing = true;
    final done = _syncDone = Completer<void>();
    notifyListeners();
    try {
      await drainLocked(syncKey, () async {
        do {
          _resyncRequested = false;
          await drainPass();
        } while (_resyncRequested);
      });
    } finally {
      syncing = false;
      if (!disposed) {
        await afterSync(refresh);
        if (!disposed) notifyListeners();
      }
      // разбудить слившихся последними, когда очереди уже говорят правду
      if (identical(_syncDone, done)) _syncDone = null;
      done.complete();
    }
  }
}
