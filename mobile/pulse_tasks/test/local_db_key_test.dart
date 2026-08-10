import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_tasks/data/local_db.dart';

/// Имя файла локальной базы — это и есть вся изоляция: пока ключи разных людей не
/// совпадают, ни один запрос не дотянется до чужих задач, фото и неотправленной очереди.
/// Здесь проверяется только ключ — работа с самими файлами лежит в
/// integration_test/local_db_isolation_test.dart, ей нужно настоящее устройство.
void main() {
  const server = 'http://10.0.2.2:9080';

  test('разные пользователи одного сервера — разные базы', () {
    expect(LocalDb.keyFor(server, 'ivanov'),
        isNot(LocalDb.keyFor(server, 'petrov')));
  });

  test('один и тот же человек на тестовом и на боевом сервере — разные базы', () {
    expect(LocalDb.keyFor('http://test.local:9080', 'ivanov'),
        isNot(LocalDb.keyFor('http://prod.local:9080', 'ivanov')));
  });

  // Логин платформа сличает без учёта регистра, а хвостовой слэш в адресе отрезает и сам
  // ApiClient: иначе один человек получил бы две базы, набрав адрес чуть иначе.
  test('регистр логина и хвостовой слэш адреса на ключ не влияют', () {
    final canonical = LocalDb.keyFor(server, 'ivanov');
    expect(LocalDb.keyFor('$server/', ' IVANOV '), canonical);
    expect(LocalDb.keyFor('$server//', 'Ivanov'), canonical);
  });

  test('ключ годится в имя файла и не выдаёт ни адреса, ни логина', () {
    final key = LocalDb.keyFor(server, 'ivanov');
    expect(key, matches(RegExp(r'^[0-9a-f]{16}$')));
    expect(key.contains('ivanov'), isFalse);
  });

  // Границу между адресом и логином нельзя сдвинуть так, чтобы другая пара дала тот же
  // ключ, — иначе двое работали бы в одном файле.
  test('адрес и логин не склеиваются в общую строку', () {
    expect(LocalDb.keyFor('http://a', 'bc'),
        isNot(LocalDb.keyFor('http://ab', 'c')));
  });
}
