import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_tasks/data/geo.dart';

import 'fake_phone.dart';

GeoFailure? _failure(GeoOutcome outcome) =>
    outcome is GeoUnavailable ? outcome.reason : null;

void main() {
  // Все четыре способа не получить координаты кончаются одним экраном, но причина у
  // каждого своя: от неё зависит и что человеку написано, и куда ведёт «Открыть
  // настройки».
  group('четыре причины остаться без координат', () {
    test('геолокация выключена на устройстве — разрешение не спрашивают',
        () async {
      final phone = FakePhone(services: false);
      expect(_failure(await Geo(platform: phone).locate()),
          GeoFailure.servicesOff);
      expect(phone.asked, 0, reason: 'спрашивать нечего: чипу нечем ответить');
      expect(phone.measurements, 0);
    });

    test('разрешение не дано', () async {
      final phone = FakePhone(granted: GeoPermission.denied);
      expect(_failure(await Geo(platform: phone).locate()), GeoFailure.denied);
      expect(phone.asked, 1, reason: 'системный диалог всё-таки показали');
    });

    test('разрешение отозвано навсегда — системный диалог не показывают',
        () async {
      final phone = FakePhone(granted: GeoPermission.deniedForever);
      expect(_failure(await Geo(platform: phone).locate()),
          GeoFailure.deniedForever);
      expect(phone.asked, 0, reason: 'система его больше и не покажет');
    });

    test('фикс не пришёл', () async {
      final phone = FakePhone(measured: null);
      expect(_failure(await Geo(platform: phone).locate()), GeoFailure.noFix);
      expect(phone.measurements, 1);
    });
  });

  test('разрешение запрашивают один раз и сразу пользуются выданным', () async {
    final phone = FakePhone(
      granted: GeoPermission.denied,
      afterAsking: GeoPermission.granted,
      measured: fixAt(),
    );
    final outcome = await Geo(platform: phone).locate();

    expect(outcome, isA<GeoFix>());
    expect(phone.asked, 1);
  });

  test('выданное разрешение не переспрашивают', () async {
    final phone = FakePhone(measured: fixAt());
    await Geo(platform: phone).locate();
    expect(phone.asked, 0);
  });

  // Послабление от 2026-08-05: иначе в холодильной камере и в подвале работать нельзя.
  group('последняя известная позиция', () {
    test('свежую принимают, не дожидаясь замера', () async {
      final phone = FakePhone(
        remembered: fixAt(ago: const Duration(minutes: 3), lat: 55.7),
        measured: fixAt(lat: 53.9),
      );
      final outcome = await Geo(platform: phone).locate();

      expect((outcome as GeoFix).latitude, 55.7);
      expect(phone.measurements, 0, reason: 'замер не понадобился');
    });

    test('протухшую не принимают — идут за свежей', () async {
      final phone = FakePhone(
        remembered: fixAt(ago: const Duration(hours: 9), lat: 55.7),
        measured: fixAt(lat: 53.9),
      );
      final outcome = await Geo(platform: phone).locate();

      expect((outcome as GeoFix).latitude, 53.9,
          reason: 'вчерашняя позиция говорит, где телефон ночевал');
      expect(phone.measurements, 1);
    });

    test('протухшая и без замера — это отсутствие координат', () async {
      final phone = FakePhone(remembered: fixAt(ago: const Duration(hours: 9)));
      expect(_failure(await Geo(platform: phone).locate()), GeoFailure.noFix);
    });

    // «Не старше нескольких минут» из постановки: за это время человек не уходит
    // достаточно далеко, чтобы ответ изменился.
    test('окно — несколько минут', () {
      expect(Geo.lastKnownWindow, greaterThanOrEqualTo(const Duration(minutes: 1)));
      expect(Geo.lastKnownWindow, lessThanOrEqualTo(const Duration(minutes: 10)));
    });

    // Ровно тот случай, ради которого кнопку и жмут: переехал в соседний магазин
    // быстрее, чем истекло окно. С #36837 от места зависит, можно ли работать, и
    // «вы там же, где четыре минуты назад» оставило бы человека с «только для
    // чтения» на задаче, у которой он стоит ногами.
    test('«Обновить» меряет заново, даже если запомненная ещё свежа', () async {
      final phone = FakePhone(
        remembered: fixAt(ago: const Duration(minutes: 3), lat: 55.7),
        measured: fixAt(lat: 53.9),
      );
      final outcome = await Geo(platform: phone).locate(fresh: true);

      expect((outcome as GeoFix).latitude, 53.9);
      expect(phone.measurements, 1);
    });
  });

  // Гейт, упавший с исключением, — это гейт, который не пройти вообще никак.
  test('сломанный плагин — это отсутствие координат, а не исключение', () async {
    expect(_failure(await Geo(platform: FakePhone(broken: true)).locate()),
        GeoFailure.noFix);
  });

  test('«Открыть настройки» ведёт в геолокацию только когда она выключена',
      () async {
    final phone = FakePhone();
    final geo = Geo(platform: phone);

    await geo.openSettings(GeoFailure.servicesOff);
    expect(phone.openedLocationSettings, isTrue);

    for (final reason in [
      GeoFailure.denied,
      GeoFailure.deniedForever,
      GeoFailure.noFix
    ]) {
      await geo.openSettings(reason);
      expect(phone.openedLocationSettings, isFalse,
          reason: 'разрешение выдаётся в настройках самого приложения');
    }
  });
}
