import 'task.dart';

/// Объект проверки, каким его вернула `apiNearbyObjects`: кто он, где он и как далеко
/// отсюда.
class NearbyObject {
  final String id;
  final String name;
  final String? address;

  /// Метры от человека до объекта. Меряет сервер — телефон получает готовое число и
  /// никогда не считает его сам: радиус «рядом» задан на сервере и сравнивать с ним надо
  /// то же самое расстояние, а не похожее.
  final double? distance;

  /// Внутри радиуса «рядом». Ложно ровно у одного объекта и ровно тогда, когда в радиусе
  /// не оказалось никого: сервер добавляет в ответ ближайшего из дальних, чтобы телефону
  /// было чем отличить «объектам не проставили координаты» от «до ближайшего 12 км».
  ///
  /// Считается от обратного — сервер помечает дальнего, а не ближних. Так «признака нет»
  /// означает «рядом», и это верно не только для нынешнего сервера, но и для того, что
  /// отдаёт одних только соседей внутри радиуса и ни о каком признаке не знает: иначе
  /// приложение сочло бы дальним объект в семнадцати метрах и спрятало бы весь список.
  final bool nearby;

  const NearbyObject({
    required this.id,
    required this.name,
    this.address,
    this.distance,
    this.nearby = false,
  });

  /// «120 м», «1,2 км», «12 км» — общий [formatDistance], тот же, что на карточке
  /// задачи чужого объекта: одно расстояние не должно читаться двумя способами.
  String get distanceText {
    final d = distance;
    return d == null ? '' : formatDistance(d);
  }

  factory NearbyObject.fromJson(Map<String, dynamic> j) => NearbyObject(
        id: '${j['id']}',
        name: _str(j['name']) ?? '',
        address: _str(j['address']),
        distance: _num(j['distance']),
        // помечен дальний, а не ближние: lsFusion не выгружает NULL, поэтому признака
        // «рядом» у сервера, который не умеет его слать, не отличить от отказа — а вот
        // «далеко» без пометки не бывает ни у нового сервера, ни у старого
        nearby: !(j['far'] == true || j['far'] == 1 || j['far'] == 'true'),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (address != null) 'address': address,
        if (distance != null) 'distance': distance,
        if (!nearby) 'far': true,
      };
}

/// Что приложение знает о том, где человек стоит. Четыре ответа, и ни один из них не
/// «пусто»: человек, открывший список и не увидевший задач, должен прочитать, почему их
/// нет, — на объекте их правда нет, или он в двенадцати километрах от ближайшего.
enum PlaceState {
  /// Координат нет или сервер не успел сказать, кто рядом. Пустой список объектов здесь
  /// означает «не спросили», а не «никого нет».
  unknown,

  /// Человек стоит на объекте, и задачи в списке — его.
  located,

  /// Координаты есть, а объектов с координатами нет ни одного. Чинится не на телефоне.
  noObjects,

  /// Объекты есть, но все за радиусом «рядом»: до ближайшего [Place.nearest] столько-то.
  far,
}

/// Где приложение считает человека — и, значит, чьи задачи оно ему показывает.
///
/// Живёт в базе пользователя (`LocalDb.savePlace`), а не в настройках устройства: объект
/// выбирает человек на своей смене, и следующий вошедший на этом телефоне стоит там, где
/// стоит он сам. Сохранение окупается ровно в одном месте, зато в важном: запуск без
/// сети даёт координаты (телефон помнит последнюю позицию), но не даёт ответа сервера о
/// соседях — и без сохранённого выбора человек остался бы с кэшем задач, который нечем
/// отфильтровать.
class Place {
  /// Что ответила `apiNearbyObjects` — ближайший первым, как прислал сервер.
  final List<NearbyObject> objects;

  /// На каком из них человек стоит. По умолчанию ближайший, но выбрать можно любой из
  /// тех, кто рядом: два магазина в одном торговом центре стоят в метрах друг от друга,
  /// и никакое правило не решит за человека, в котором из них он.
  final String? objectId;

  final double? latitude;
  final double? longitude;

  /// Когда объект был определён — то есть когда сервер в последний раз ответил, кто
  /// рядом. То самое «время определения», которое видно в шапке; свежий замер координат
  /// его не двигает, если ответа на «кто рядом» не было: название и расстояние в шапке
  /// остались от прошлого ответа, и час их давности — это то, что человеку надо знать.
  final DateTime? at;

  /// Ответил ли сервер на последний вопрос «кто рядом». Отличает [PlaceState.unknown] от
  /// [PlaceState.noObjects] — без ответа пустой список не значит ничего.
  final bool answered;

  const Place({
    this.objects = const [],
    this.objectId,
    this.latitude,
    this.longitude,
    this.at,
    this.answered = false,
  });

  /// Объект, на котором человек стоит, или null, если не стоит ни на одном.
  NearbyObject? get object {
    final id = objectId;
    if (id == null) return null;
    for (final o in objects) {
      if (o.id == id) return o;
    }
    return null;
  }

  /// Те, между кем есть смысл выбирать: только они внутри радиуса.
  List<NearbyObject> get nearby =>
      objects.where((o) => o.nearby).toList(growable: false);

  /// Ближайший из всех, включая дальних, — им объясняется «вы в 12 км».
  NearbyObject? get nearest => objects.isEmpty ? null : objects.first;

  PlaceState get state {
    if (object != null) return PlaceState.located;
    if (!answered) return PlaceState.unknown;
    return objects.isEmpty ? PlaceState.noObjects : PlaceState.far;
  }

  /// Задача того объекта, на котором человек стоит? Пока объект не определён — ничья:
  /// показать «все подряд» здесь означало бы показать задачи чужого магазина.
  bool holds(Task t) => objectId != null && t.objectId == objectId;

  /// Какой объект показать по умолчанию: тот, что человек выбрал сам, пока он остаётся в
  /// радиусе, иначе ближайший. Выбор переживает обновление намеренно — человек, который
  /// в торговом центре указал второй магазин из двух, не должен видеть, как приложение
  /// возвращает его в первый. Ушёл из радиуса — значит переехал, и выбор начинается
  /// заново.
  static String? pick(List<NearbyObject> objects, {String? previous}) {
    NearbyObject? nearest;
    for (final o in objects) {
      if (!o.nearby) continue;
      if (o.id == previous) return previous;
      nearest ??= o;
    }
    return nearest?.id;
  }

  /// Человек сам указал, на каком из соседних объектов он стоит.
  Place select(String? id) => Place(
        objects: objects,
        objectId: id,
        latitude: latitude,
        longitude: longitude,
        at: at,
        answered: answered,
      );

  /// Координаты новые, а кто рядом — по-прежнему неизвестно: сервер не ответил. Объект и
  /// время определения остаются прежними — они всё ещё лучшее, что есть, и датировать их
  /// свежим замером значило бы выдать вчерашнее расстояние за сегодняшнее.
  Place fixedAt(double latitude, double longitude) => Place(
        objects: objects,
        objectId: objectId,
        latitude: latitude,
        longitude: longitude,
        at: at,
        answered: answered,
      );

  factory Place.fromJson(Map<String, dynamic> j) {
    final raw = j['objects'];
    return Place(
      objects: raw is! List
          ? const []
          : raw
              .whereType<Map>()
              .map((e) => NearbyObject.fromJson(e.cast<String, dynamic>()))
              .toList(),
      objectId: _str(j['objectId']),
      latitude: _num(j['latitude']),
      longitude: _num(j['longitude']),
      at: DateTime.tryParse(j['at']?.toString() ?? ''),
      answered: j['answered'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
        if (objects.isNotEmpty)
          'objects': objects.map((o) => o.toJson()).toList(),
        if (objectId != null) 'objectId': objectId,
        if (latitude != null) 'latitude': latitude,
        if (longitude != null) 'longitude': longitude,
        if (at != null) 'at': at!.toIso8601String(),
        if (answered) 'answered': true,
      };
}

String? _str(Object? v) {
  final s = v?.toString().trim();
  return (s == null || s.isEmpty) ? null : s;
}

double? _num(Object? v) {
  if (v is num) return v.toDouble();
  return double.tryParse(v?.toString().replaceAll(',', '.') ?? '');
}
