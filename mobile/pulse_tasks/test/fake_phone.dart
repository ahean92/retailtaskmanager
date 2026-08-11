import 'package:pulse_tasks/data/geo.dart';

/// Телефон, каким его видит гейт: включена ли геолокация, что отвечает система про
/// разрешение, что устройство помнит и что оно намерит, если попросить.
///
/// Общий для двух проверок — самого поиска координат (geo_test.dart) и экрана-гейта
/// (geo_gate_test.dart).
class FakePhone implements GeoPlatform {
  FakePhone({
    this.services = true,
    this.granted = GeoPermission.granted,
    this.afterAsking,
    this.remembered,
    this.measured,
    this.broken = false,
  });

  bool services;
  GeoPermission granted;

  /// Что система ответит на системный диалог (null — то же, что и до него).
  GeoPermission? afterAsking;
  GeoFix? remembered;
  GeoFix? measured;

  /// Плагина на этом устройстве как будто нет — любой вопрос кидает исключение.
  bool broken;

  int asked = 0; // сколько раз показали системный диалог
  int measurements = 0; // сколько раз запускали замер
  bool? openedLocationSettings; // true — настройки геолокации, false — приложения

  @override
  Future<bool> servicesEnabled() async {
    if (broken) throw Exception('нет плагина');
    return services;
  }

  @override
  Future<GeoPermission> permission() async => granted;

  @override
  Future<GeoPermission> requestPermission() async {
    asked++;
    return granted = afterAsking ?? granted;
  }

  @override
  Future<GeoFix?> lastKnown() async => remembered;

  @override
  Future<GeoFix?> fix(Duration timeout) async {
    measurements++;
    return measured;
  }

  @override
  Future<void> openSettings({required bool locationServices}) async =>
      openedLocationSettings = locationServices;
}

/// Координаты «здесь и сейчас», если не сказано иное.
GeoFix fixAt({Duration ago = Duration.zero, double lat = 53.9}) =>
    GeoFix(lat, 27.56, DateTime.now().subtract(ago));
