import '../api_client.dart';

/// Реестр устройств для пуш-уведомлений (#36720).
extension DeviceApi on ApiClient {
  /// Зарегистрировать телефон для пуш-уведомлений (#36720). Владельца сервер берёт из
  /// сессии, а не из тела: параметр «чьё устройство» позволил бы подписать свой телефон
  /// на чужие уведомления. Идемпотентна — клиент шлёт её на каждом запуске.
  Future<void> registerDevice(
          String token, String platform, String appVersion) =>
      postJson('apiRegisterDevice', {
        'token': token,
        'platform': platform,
        'appVersion': appVersion,
      });

  /// Снять регистрацию — при выходе из аккаунта. Не сделать этого значит отправить
  /// уведомления следующего сотрудника на телефон предыдущего.
  Future<void> unregisterDevice(String token) =>
      postJson('apiUnregisterDevice', {'token': token});
}
