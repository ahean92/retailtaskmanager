// Общая обвязка модульных тестов.
//
// Настоящий sqlite через ffi (#36716): очереди создания и барьер порядка
// синхронизации живут в схеме, и мокать их — значит не проверить ничего.
// Хранилища секретов и настроек — моки, пустые перед каждым тестом.

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Один раз в начале main(): биндинг + sqlite на ffi вместо платформенного канала.
void initTestEnv() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
}

/// В setUp(): чистые Keystore/Keychain и shared_preferences.
void resetMockStores() {
  FlutterSecureStorage.setMockInitialValues({});
  SharedPreferences.setMockInitialValues({});
}
