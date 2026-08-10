import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Домашний экран переехал из shared_preferences в базу пользователя: он показывает
/// задачи и цифры конкретного человека, и одному на устройство ему быть нельзя.
/// Здесь — только переезд старого кэша; куда он ложится дальше, проверяет
/// integration_test/local_db_isolation_test.dart.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized(); // мок shared_preferences требует его

  test('старый кэш главного экрана забирается один раз и стирается', () async {
    SharedPreferences.setMockInitialValues({
      'homeJson': '{"blocks":[]}',
      'baseUrl': 'http://10.0.2.2:9080',
    });

    expect(await Settings.takeLegacyHomeJson(), '{"blocks":[]}');
    expect(await Settings.takeLegacyHomeJson(), isNull,
        reason: 'второму вошедшему наследовать уже нечего');

    // адрес принадлежит установке и переезжать никуда не должен
    final sp = await SharedPreferences.getInstance();
    expect(sp.getString('baseUrl'), 'http://10.0.2.2:9080');
  });

  test('на чистой установке забирать нечего', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await Settings.takeLegacyHomeJson(), isNull);
  });

  test('сохранение настроек больше не пишет домашний экран', () async {
    SharedPreferences.setMockInitialValues({});
    await Settings(baseUrl: 'http://10.0.2.2:9080', brandJson: '{}').save();
    final sp = await SharedPreferences.getInstance();
    expect(sp.getKeys(), isNot(contains('homeJson')));
  });
}
