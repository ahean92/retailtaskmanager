// Общая обвязка модульных тестов.
//
// Настоящий sqlite через ffi (#36716): очереди создания и барьер порядка
// синхронизации живут в схеме, и мокать их — значит не проверить ничего.
// Хранилища секретов и настроек — моки, пустые перед каждым тестом.

import 'dart:async';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Каталоги баз тестов: по одному на файл тестов. Внутри пакета, а не в системной
/// временной папке: там антивирус проверяет каждый файл, и база с её журналом
/// работает на порядок медленнее.
final _root = Directory('.dart_tool/pulse_test_db');

/// Замок в каталоге файла тестов: заперт, пока идут его тесты, и отпускается
/// вместе с процессом. По нему уборка отличает живой каталог от брошенного.
const _ownerLock = '.owner';

/// Один раз в начале main(): биндинг + sqlite на ffi вместо платформенного канала.
///
/// Базы — в своём каталоге этого файла тестов, который удаляется после всех его
/// тестов. По умолчанию ffi кладёт их в .dart_tool/sqflite_common_ffi/databases, и
/// файл базы, названный по логину, переживал прогон: кэш прошлого прогона ломал
/// проверки, а каталог рос гигабайтами.
void initTestEnv() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  _sweepStale();
  _root.createSync(recursive: true);
  final dir = _root.createTempSync();
  final owner = File('${dir.path}/$_ownerLock').openSync(mode: FileMode.write)
    ..lockSync();
  // ffi запоминает каталог сразу, ждать нечего
  unawaited(databaseFactory.setDatabasesPath(dir.path));
  Future<void> cleanup() {
    // открытый файл Windows не удалит
    owner.closeSync();
    return _deleteDatabases(dir);
  }
  try {
    tearDownAll(cleanup);
  } on StateError {
    // сквозной набор зовёт отсюда из setUpAll, где «после всех тестов» — это
    // addTearDown
    addTearDown(cleanup);
  }
}

/// Windows не удаляет открытый файл. Базу последнего теста AppControllers.dispose
/// закрывает без ожидания — её хватает подождать. Тест, не освободивший свои
/// контроллеры, держит базу до конца процесса, и закрывать её здесь нельзя: под
/// ней может ещё идти его синхронизация. Такой каталог уберёт следующий файл
/// тестов, когда этот процесс кончится.
Future<void> _deleteDatabases(Directory dir) async {
  for (var attempt = 0; attempt < 5; attempt++) {
    try {
      dir.deleteSync(recursive: true);
      return;
    } on FileSystemException {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
}

/// Каталоги, которые их файлы тестов не смогли удалить: база осталась открытой до
/// конца процесса. Убираем их, как только процесс кончился, а не по возрасту: за
/// час прогонов подряд таких каталогов с базами копились сотни. Каталог моложе
/// минуты не трогаем: сосед мог только что его создать и ещё не успел запереть.
void _sweepStale() {
  if (!_root.existsSync()) return;
  final now = DateTime.now();
  for (final d in _root.listSync().whereType<Directory>()) {
    try {
      if (now.difference(d.statSync().modified) < const Duration(minutes: 1) ||
          _ownerAlive(d)) {
        continue;
      }
      d.deleteSync(recursive: true);
    } on FileSystemException {
      // его удаляет соседний процесс или база ещё открыта — уберёт следующий
    }
  }
}

/// Заперт ли каталог живым файлом тестов. Замка нет — cleanup уже отпустил
/// каталог, хозяина нет.
bool _ownerAlive(Directory d) {
  final lock = File('${d.path}/$_ownerLock');
  if (!lock.existsSync()) return false;
  final probe = lock.openSync(mode: FileMode.append);
  try {
    probe.lockSync();
    return false;
  } on FileSystemException {
    return true;
  } finally {
    probe.closeSync();
  }
}

/// В setUp(): чистые Keystore/Keychain и shared_preferences.
void resetMockStores() {
  FlutterSecureStorage.setMockInitialValues({});
  SharedPreferences.setMockInitialValues({});
}
