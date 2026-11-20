import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'geo.dart';
import 'sync/outbox_drain.dart';

// Общее у «Завершить» бланка ([FillController]) и «Выполнено» поручения
// ([SimpleExecutionController]): момент действия, слияние повторных нажатий и решение,
// чем кончилась отправка. Две копии этого у двух экранов разошлись бы на первой же
// правке. Что показать человеку при каждом исходе — у каждого экрана своё и остаётся у
// контроллеров.

/// Точка и время действия; координат может не быть.
typedef ActionStamp = ({double? lat, double? lon, String at});

/// ISO-времена очередей и [DateTime.toIso8601String] → провод `yyyy-MM-ddTHH:mm:ss`:
/// ровно та форма, которую серверный DATETIME-парсер принимает без таймзонных
/// сюрпризов. Дробная часть отрезается, недостающие секунды дописываются.
String wireAt(String iso) {
  var s = iso.split('.').first;
  if (RegExp(r'T\d{1,2}:\d{2}$').hasMatch(s)) s = '$s:00';
  return s;
}

/// Координаты и время «прямо сейчас» — момент действия (#36838). Время устройства
/// есть всегда; координат может не быть — отказ в разрешении, подвал, склад без
/// неба над головой — и тогда их честно нет (ни нулей, ни ожидания сверх
/// [Geo.stampTimeout], ни вопроса о разрешении): отсутствие координат работу не
/// останавливает. [geo] null — у контроллера нет экрана (дренаж переподключения).
Future<ActionStamp> stampNow(Geo? geo) async {
  final at = wireAt(DateTime.now().toIso8601String());
  final fix = geo == null ? null : await geo.locate(stamp: true);
  return fix is GeoFix
      ? (lat: fix.latitude, lon: fix.longitude, at: at)
      : (lat: null, lon: null, at: at);
}

/// Завершение в полёте: повторные нажатия сливаются в один запрос. Сервер отвечает на
/// «Завершить» небыстро, и человек успевает тапнуть ещё — каждый лишний вызов шёл бы
/// на сервер вторым завершением. Кнопку на время полёта гасит [finishing]; гонку «два
/// тапа до перерисовки» закрывает слияние: второй тап получает то же будущее, а не
/// новый проход.
mixin FinishCoalescer on ChangeNotifier {
  Future<bool>? _finishInFlight;

  /// Завершение в полёте — кнопка гасится до ответа сервера, а не на секунды.
  bool get finishing => _finishInFlight != null;

  /// Возвращает, можно ли считать работу закрытой (см. [finishOnce]).
  Future<bool> finish() {
    final running = _finishInFlight;
    if (running != null) return running;
    // гасим кнопку сразу, не дожидаясь первого await внутри прохода
    notifyListeners();
    final f = finishOnce();
    _finishInFlight = f;
    unawaited(f.whenComplete(() {
      if (identical(_finishInFlight, f)) _finishInFlight = null;
    }));
    return f;
  }

  /// Один проход «Завершить»: проверки, отправка, исход для экрана.
  @protected
  Future<bool> finishOnce();
}

/// Чем кончилась отправка завершения.
enum FinishOutcome {
  /// Сервер принял завершение — само или всей цепочкой очереди.
  accepted,

  /// Связи нет: завершение лежит в очереди и уедет с сетью, на телефоне работа закрыта.
  queuedOffline,

  /// Связь есть, но сервер отказал — завершению или шагу цепочки перед ним.
  refused,
}

/// Завершение через очередь: задача, чьё создание или старт ещё едут, завершение, уже
/// лежащее в очереди (дренаж умер посередине), или неотправленное тело (#37517). Сервер
/// обязан увидеть create → start → тело → finish в этом порядке, что бы ни делала сеть:
/// завершение ложится в очередь последним шагом, [sync] дожимает цепочку, и по тому,
/// осталась ли строка ([stillQueued]), видно исход. Отказ при живой связи снимает
/// строку ([dequeue]): оставить её значило бы противоречить «не удалось» на экране.
Future<FinishOutcome> finishViaQueue({
  required OutboxDrain drain,
  required Future<void> Function() enqueue,
  required Future<void> Function() sync,
  required Future<bool> Function() stillQueued,
  required Future<void> Function() dequeue,
}) async {
  await enqueue();
  await sync();
  if (!await stillQueued()) {
    // вся цепочка прошла — завершённое держит сервер
    drain.online = true;
    return FinishOutcome.accepted;
  }
  // обещанное офлайн-поведение: закрыто на телефоне, уедет с сетью
  if (!drain.online) return FinishOutcome.queuedOffline;
  await dequeue();
  return FinishOutcome.refused;
}

/// Прямой вызов завершения по пустым очередям. Отказ или сбой сервера — его причина
/// ([ApiException]); связи не стало на самом вызове — завершение уходит в очередь
/// ([enqueue]) с точкой и временем момента нажатия, работа закрыта на телефоне.
Future<({FinishOutcome outcome, ApiException? refusal})> finishDirect({
  required OutboxDrain drain,
  required Future<void> Function() call,
  required Future<void> Function() enqueue,
}) async {
  final failure = await drain.attempt(call);
  if (failure is ApiException) {
    return (outcome: FinishOutcome.refused, refusal: failure);
  }
  if (failure != null) {
    await enqueue();
    await drain.note(failure);
    return (outcome: FinishOutcome.queuedOffline, refusal: null);
  }
  return (outcome: FinishOutcome.accepted, refusal: null);
}
