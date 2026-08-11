import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_tasks/models/place.dart';
import 'package:pulse_tasks/models/task.dart';

/// Где человек стоит: что приложение считает объектом смены, как оно выбирает между
/// соседями и — главное — как оно различает три пустоты, которые нельзя схлопывать в
/// один пустой экран.

NearbyObject _object(String id,
        {String? name, double? distance, bool nearby = true}) =>
    NearbyObject(
        id: id, name: name ?? 'Магазин $id', distance: distance, nearby: nearby);

void main() {
  group('расстояние читается так, как его произносят', () {
    test('метры вблизи, километры дальше', () {
      expect(_object('a', distance: 0).distanceText, '0 м');
      expect(_object('a', distance: 119.6).distanceText, '120 м');
      expect(_object('a', distance: 999).distanceText, '999 м');
      expect(_object('a', distance: 1000).distanceText, '1,0 км');
      expect(_object('a', distance: 1240).distanceText, '1,2 км');
      // с десяти километров десятые доли — шум: «12 км», а не «12,3 км»
      expect(_object('a', distance: 12300).distanceText, '12 км');
    });

    test('без расстояния строка пустая, а не «null»', () {
      expect(_object('a').distanceText, '');
    });
  });

  group('три пустоты — три разных ответа', () {
    test('сервер не ответил — «неизвестно», а не «рядом никого нет»', () {
      expect(const Place().state, PlaceState.unknown);
      // координаты есть, ответа нет: пустой список объектов здесь не значит ничего
      expect(
        const Place(latitude: 53.9, longitude: 27.56).state,
        PlaceState.unknown,
      );
    });

    test('ответил пустым списком — объектов с координатами нет вовсе', () {
      expect(const Place(answered: true).state, PlaceState.noObjects);
    });

    test('ответил одними дальними — до ближайшего столько-то', () {
      final place = Place(
        objects: [_object('o1', distance: 12300, nearby: false)],
        objectId: Place.pick([_object('o1', distance: 12300, nearby: false)]),
        answered: true,
      );
      expect(place.state, PlaceState.far);
      expect(place.nearby, isEmpty);
      expect(place.nearest?.distanceText, '12 км');
    });

    test('объект выбран — задачи есть или их нет, и это уже другой разговор', () {
      final place = Place(
        objects: [_object('o1', distance: 120)],
        objectId: 'o1',
        answered: true,
      );
      expect(place.state, PlaceState.located);
      expect(place.object?.distanceText, '120 м');
    });
  });

  group('какой объект показать по умолчанию', () {
    final near = [
      _object('o1', distance: 40),
      _object('o2', distance: 90),
      _object('far', distance: 12000, nearby: false),
    ];

    test('ближайший, когда человек ещё не выбирал', () {
      expect(Place.pick(near), 'o1');
    });

    test('дальний по умолчанию не выбирается никогда', () {
      expect(Place.pick([_object('far', distance: 12000, nearby: false)]),
          isNull);
      expect(Place.pick(const []), isNull);
    });

    // Человек, указавший в торговом центре второй магазин из двух, не должен видеть,
    // как приложение возвращает его в первый на каждом обновлении.
    test('свой выбор переживает обновление, пока объект рядом', () {
      expect(Place.pick(near, previous: 'o2'), 'o2');
    });

    test('вышел из радиуса — значит переехал, и снова ближайший', () {
      expect(Place.pick(near, previous: 'ушедший'), 'o1');
      expect(Place.pick(near, previous: 'far'), 'o1',
          reason: 'дальний сосед — не выбор, даже если он был выбран раньше');
    });
  });

  group('список — задачи выбранного объекта', () {
    final place = Place(objects: [_object('o1')], objectId: 'o1');

    test('чужие задачи не попадают', () {
      expect(place.holds(const Task(id: 'ST1', objectId: 'o1')), isTrue);
      expect(place.holds(const Task(id: 'ST2', objectId: 'o2')), isFalse);
      // задача из кэша, пришедшая до появления objectId в выгрузке
      expect(place.holds(const Task(id: 'ST3')), isFalse);
    });

    test('пока объект не выбран, своих задач нет ни у кого', () {
      expect(const Place().holds(const Task(id: 'ST1', objectId: 'o1')),
          isFalse);
    });
  });

  group('сохранение в базе пользователя', () {
    test('переживает перезапуск целиком — с соседями и временем', () {
      final at = DateTime(2026, 8, 11, 14, 5);
      final saved = Place(
        objects: [_object('o1', distance: 40), _object('o2', distance: 90)],
        objectId: 'o2',
        latitude: 53.9,
        longitude: 27.56,
        at: at,
        answered: true,
      );

      final restored =
          Place.fromJson(jsonDecode(jsonEncode(saved.toJson())) as Map<String, dynamic>);

      expect(restored.objectId, 'o2');
      expect(restored.object?.name, 'Магазин o2');
      expect(restored.nearby.length, 2);
      expect(restored.latitude, 53.9);
      expect(restored.at, at);
      expect(restored.state, PlaceState.located);
    });

    test('свежие координаты без ответа сервера не выдаются за свежий объект', () {
      final at = DateTime(2026, 8, 11, 14, 5);
      final saved = Place(
        objects: [_object('o1', distance: 40)],
        objectId: 'o1',
        latitude: 53.9,
        longitude: 27.56,
        at: at,
        answered: true,
      );

      final moved = saved.fixedAt(54.0, 27.6);

      expect(moved.latitude, 54.0);
      expect(moved.objectId, 'o1', reason: 'выбор — всё ещё лучшее, что есть');
      expect(moved.at, at,
          reason: 'название и расстояние остались от прошлого ответа, '
              'и дата у них прошлая');
    });
  });

  test('сервер объявляет «рядом» присутствием ключа — NULL он не выгружает', () {
    expect(
      NearbyObject.fromJson({'id': 'o1', 'name': 'Магазин', 'nearby': true})
          .nearby,
      isTrue,
    );
    expect(
      NearbyObject.fromJson({'id': 'o1', 'name': 'Магазин'}).nearby,
      isFalse,
    );
  });
}
