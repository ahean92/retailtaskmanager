import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'api_client.dart';

/// Почему «Проверить подключение» не прошла: что случилось ([what]) и что с этим
/// делать ([hint]). Адрес на экране настроек вводит тот, кто выдаёт телефон, и строка
/// исполняющей среды — «TimeoutException after 0:00:10.000000: Future not completed» —
/// не говорит ему, куда смотреть: на адрес, на порт, на Wi-Fi или на сам сервер.
/// Поэтому случаи разведены по действию, к которому зовут, а не по классу исключения.
typedef ConnectionFailure = ({String what, String hint});

const _sameNetwork =
    'Проверьте адрес, включён ли сервер и в одной ли сети с ним телефон — '
    'например, в Wi-Fi магазина';

const ConnectionFailure _noAnswer =
    (what: 'Сервер не отвечает', hint: _sameNetwork);
const ConnectionFailure _noNetwork = (
  what: 'Телефон не подключён к сети',
  hint: 'Включите Wi-Fi или мобильный интернет и повторите проверку',
);
const ConnectionFailure _unknownHost = (
  what: 'Сервер с таким именем не найден',
  hint: 'Проверьте, нет ли в адресе опечатки и есть ли на телефоне сеть',
);
const ConnectionFailure _refused = (
  what: 'На этом порту сервер не работает',
  hint: 'Проверьте порт после двоеточия (например, :9080) и запущен ли сервер',
);
const ConnectionFailure _notOurServer = (
  what: 'По этому адресу отвечает не сервер задач',
  hint: 'Проверьте адрес и порт — похоже, они ведут к другой программе',
);
const ConnectionFailure _tls = (
  what: 'Не удалось установить защищённое соединение',
  hint: 'Проверьте начало адреса: http:// или https://',
);
const ConnectionFailure _malformed = (
  what: 'Адрес записан с ошибкой',
  hint: 'Пример: 192.168.1.10:9080 — без пробелов, порт после двоеточия',
);
const ConnectionFailure _unknown = (
  what: 'Не удалось подключиться к серверу',
  hint: 'Проверьте адрес и сеть телефона',
);

/// Адрес, который HTTP-клиент не наберёт вовсе, отсеивается до запроса: иначе он
/// падает FormatException или ArgumentError, и первое читалось бы как «чужой ответ».
/// Пробел и кириллица в имени хоста доходят из [Uri] процентами, а порт за 65535
/// [Uri] пропускает — отказывает уже сокет.
ConnectionFailure? addressFailure(String url) {
  final u = Uri.tryParse(url);
  final dialable = u != null &&
      (u.scheme == 'http' || u.scheme == 'https') &&
      u.host.isNotEmpty &&
      !u.host.contains('%') &&
      u.port <= 65535;
  return dialable ? null : _malformed;
}

/// Исключение пробы — в объяснение. Формы — те, что приходят на Android на самом
/// деле (сняты на эмуляторе настоящим fetchBrand): package:http оборачивает сокетную
/// ошибку в ClientException, который остаётся и SocketException; сброс соединения
/// не-HTTP-сервисом приезжает голым OSError; чужая веб-страница — FormatException
/// разбора JSON или отказом 404. Номера errno у Android (Linux) и iOS разные — в
/// каждой ветке оба.
ConnectionFailure connectionFailure(Object e) {
  // никто не ответил за отведённое время: чёрная дыра, чужая подсеть, выключенный
  // компьютер за маршрутизатором
  if (e is TimeoutException) return _noAnswer;
  if (e is TlsException) return _tls;
  if (e is ApiException) {
    // 5xx — ответил наш сервер (или прокси перед ним), но не смог; 404 и прочие
    // 4xx — ручки apiBrand по этому адресу нет, значит, и сервера задач там нет
    final status = e.status;
    if (status == null || status < 500) return _notOurServer;
    return (
      what: 'Сервер ответил ошибкой (код $status)',
      hint: 'Адрес верный, но сервер не смог ответить — повторите позже или '
          'сообщите администратору',
    );
  }
  // без сети имя тоже не находится — поэтому подсказка про опечатку и про сеть сразу
  if (e is SocketException && e.message.startsWith('Failed host lookup')) {
    return _unknownHost;
  }
  final errno = switch (e) {
    SocketException(:final osError) => osError?.errorCode,
    OSError(:final errorCode) => errorCode,
    _ => null,
  };
  switch (errno) {
    case 101 || 51: // ENETUNREACH: ни Wi-Fi, ни мобильной сети
      return _noNetwork;
    case 111 || 61: // ECONNREFUSED: компьютер есть, на порту никого
      return _refused;
    case 113 || 65: // EHOSTUNREACH: в подсети по этому адресу никого
      return _noAnswer;
    case 104 || 54: // ECONNRESET: приняли и бросили — говорят не по HTTP
      return _notOurServer;
  }
  if (e is SocketException || e is OSError) return _unknown;
  // ответ был, но не такой, какой даёт сервер задач: страница вместо JSON, обрыв
  // посреди заголовков
  if (e is FormatException || e is http.ClientException) return _notOurServer;
  return _unknown;
}
