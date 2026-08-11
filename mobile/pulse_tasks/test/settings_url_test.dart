import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_tasks/data/settings.dart';

/// Адрес сервера набирают на телефоне при развёртывании, и набирают так, как его знают —
/// «192.168.1.10:9080». Без схемы это не URL: запрос падал, не выйдя с устройства.
void main() {
  test('голый ip с портом получает http://', () {
    expect(Settings.normalizeUrl('192.168.1.10:9080'),
        'http://192.168.1.10:9080');
  });

  test('ip без порта тоже', () {
    expect(Settings.normalizeUrl('192.168.1.10'), 'http://192.168.1.10');
  });

  test('имя хоста с портом не принимается за схему', () {
    expect(Settings.normalizeUrl('localhost:9080'), 'http://localhost:9080');
  });

  test('явную схему не трогаем', () {
    expect(Settings.normalizeUrl('https://pulse.example.com'),
        'https://pulse.example.com');
    expect(Settings.normalizeUrl('http://10.0.2.2:9080/'),
        'http://10.0.2.2:9080/');
  });

  test('пробелы по краям снимаются, пустая строка остаётся пустой', () {
    expect(Settings.normalizeUrl('  192.168.1.10:9080  '),
        'http://192.168.1.10:9080');
    expect(Settings.normalizeUrl('   '), '');
  });
}
