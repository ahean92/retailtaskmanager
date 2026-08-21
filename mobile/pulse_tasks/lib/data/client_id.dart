import 'dart:math';

/// UUID v4 из системного ГСЧ — ключ клиента для всего, что рождается на телефоне и
/// уезжает на сервер с ретраем: задачи (#36714) и сообщения ленты (#36844). Сервер
/// объявляет по нему уникальность, и уникальность есть идемпотентность повтора.
/// Свой генератор на шестнадцати байтах вместо пакета uuid: формат на три строки, а
/// зависимость — навсегда.
String newClientId() {
  final rnd = Random.secure();
  final b = List<int>.generate(16, (_) => rnd.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40; // version 4
  b[8] = (b[8] & 0x3f) | 0x80; // variant 10xx
  String hex(int from, int to) => [
        for (var i = from; i < to; i++)
          b[i].toRadixString(16).padLeft(2, '0')
      ].join();
  return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
}
