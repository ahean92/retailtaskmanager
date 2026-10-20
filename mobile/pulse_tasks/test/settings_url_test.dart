import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_tasks/data/settings.dart';

/// Адрес сервера набирают на телефоне при развёртывании, и набирают так, как его
/// знают — «192.168.1.10:9080». Протокол выбирается сегментом на экране настроек,
/// поэтому адрес хранится целиком, а разбирается и собирается двумя частями:
/// схема и host:port.
void main() {
  test('сохранённый адрес разбирается на схему и host:port', () {
    expect(Settings.splitUrl('http://192.168.1.10:9080'),
        (scheme: 'http', host: '192.168.1.10:9080'));
    expect(Settings.splitUrl('https://pulse.example.com'),
        (scheme: 'https', host: 'pulse.example.com'));
  });

  test('голый host:port — не схема: без схемы разбирается как есть', () {
    expect(Settings.splitUrl('localhost:9080'),
        (scheme: null, host: 'localhost:9080'));
    expect(
        Settings.splitUrl('192.168.1.10'), (scheme: null, host: '192.168.1.10'));
  });

  test('схема регистронезависима, пробелы по краям снимаются', () {
    expect(Settings.splitUrl('  HTTPS://pulse.example.com  '),
        (scheme: 'https', host: 'pulse.example.com'));
    expect(Settings.splitUrl('   '), (scheme: null, host: ''));
  });

  test('адрес для клиента собирается из сегмента и поля', () {
    expect(Settings.composeUrl(https: true, host: 'pulse.example.com'),
        'https://pulse.example.com');
    expect(Settings.composeUrl(https: false, host: '192.168.1.10:9080'),
        'http://192.168.1.10:9080');
    expect(Settings.composeUrl(https: true, host: '  pulse.example.com  '),
        'https://pulse.example.com');
  });

  test('пустое поле остаётся пустым — его ловит валидатор формы', () {
    expect(Settings.composeUrl(https: true, host: ''), '');
    expect(Settings.composeUrl(https: false, host: '   '), '');
  });

  test('опечатанная схема проходит насквозь — её поймает валидация адреса', () {
    expect(Settings.composeUrl(https: false, host: 'htp://192.168.1.10:9080'),
        'htp://192.168.1.10:9080');
  });
}
