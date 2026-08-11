import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/fill_controller.dart';
import 'package:pulse_tasks/data/local_db.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/models/fill.dart';
import 'package:pulse_tasks/models/task.dart';
import 'package:pulse_tasks/models/task_status.dart';
import 'package:sqflite/sqflite.dart';

/// Изоляция локальной базы по пользователю — на настоящих файлах настоящего устройства:
/// unit-тест проверяет только ключ, а «не видно чужого» — это про sqlite и файловую
/// систему, которых в unit-тестах нет.
///
///     flutter test integration_test -d <device>
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const serverA = 'http://test.local:9080';
  const serverB = 'http://prod.local:9080';

  final ivanov = LocalDb.keyFor(serverA, 'ivanov');
  final petrov = LocalDb.keyFor(serverA, 'petrov');

  Future<void> wipe() async {
    final dbDir = Directory(await getDatabasesPath());
    if (dbDir.existsSync()) {
      for (final f in dbDir.listSync().whereType<File>()) {
        if (p.basename(f.path).startsWith('pulse_tasks')) await f.delete();
      }
    }
    final photos = Directory(
        p.join((await getApplicationDocumentsDirectory()).path, 'fill_photos'));
    if (photos.existsSync()) await photos.delete(recursive: true);
  }

  setUp(wipe);

  String iso() => DateTime.now().toIso8601String();

  testWidgets('вход другим пользователем не показывает ни одной чужой задачи',
      (tester) async {
    final a = await LocalDb.open(ivanov);
    await a.replaceTasks(
        [const Task(id: 'ST0001', name: 'Проверить витрину', statusId: 's1')]);
    await a.replaceStatuses(
        [const TaskStatus(id: 's1', name: 'В работе', closed: false)]);
    await a.enqueue('ST0001', 's2', 'Выполнена', iso());
    await a.close();

    // выход и вход вторым: его база пуста, как на новом устройстве
    final b = await LocalDb.open(petrov);
    expect(await b.getTasks(), isEmpty);
    expect(await b.getOutbox(), isEmpty);
    await b.replaceTasks([const Task(id: 'ST0002', name: 'Пересчитать кассу')]);
    await b.close();

    // возврат в первого: его задача и его неотправленная очередь на месте
    final again = await LocalDb.open(ivanov);
    final tasks = await again.getTasks();
    expect(tasks.map((t) => t.id), ['ST0001']);
    final outbox = await again.getOutbox();
    expect(outbox['ST0001']?.statusId, 's2');
    await again.close();
  });

  // Цифры главного экрана считаны для конкретного исполнителя — это такие же его данные,
  // как и список задач, и жить они должны там же.
  testWidgets('главный экран одного не показывается другому', (tester) async {
    const layout = '{"blocks":[{"code":"k","type":"text","title":"Сводка А"}]}';
    final a = await LocalDb.open(ivanov);
    await a.saveHome(layout, iso());
    await a.close();

    final b = await LocalDb.open(petrov);
    expect(await b.getHome(), isNull,
        reason: 'чужой дашборд не должен встречать вошедшего');
    await b.close();

    final again = await LocalDb.open(ivanov);
    expect(await again.getHome(), layout);
    await again.close();
  });

  testWidgets('один логин на двух серверах — две разные базы', (tester) async {
    final test = await LocalDb.open(LocalDb.keyFor(serverA, 'ivanov'));
    await test.replaceTasks([const Task(id: 'ST-TEST')]);
    await test.close();

    final prod = await LocalDb.open(LocalDb.keyFor(serverB, 'ivanov'));
    expect(await prod.getTasks(), isEmpty,
        reason: 'боевой сервер не должен показывать задачи тестового');
    await prod.close();
  });

  // Обновление поверх сборки, у которой база была одна на устройство. Терять её нельзя:
  // в ней может лежать неотправленная очередь, а для снятого офлайн фото — единственная
  // копия. Заводится она здесь так же, как её оставила бы старая сборка: файлом с той же
  // схемой по старому пути.
  testWidgets('старая база достаётся первому вошедшему вместе с очередью',
      (tester) async {
    final dbDir = await getDatabasesPath();
    final legacyPath = p.join(dbDir, 'pulse_tasks.db');

    final old = await LocalDb.open('legacy-stand-in');
    await old.replaceTasks([const Task(id: 'ST0777', name: 'Снять показания')]);
    await old.enqueue('ST0777', 's2', 'Выполнена', iso());
    await old.close();
    await File(p.join(dbDir, 'pulse_tasks_legacy-stand-in.db'))
        .rename(legacyPath);

    final mine = await LocalDb.open(ivanov);
    expect((await mine.getTasks()).map((t) => t.id), ['ST0777']);
    expect((await mine.getOutbox())['ST0777']?.statusId, 's2',
        reason: 'неотправленные изменения переживают обновление');
    await mine.close();

    expect(await databaseExists(legacyPath), isFalse,
        reason: 'старая база переехала, а не скопировалась — второй раз её '
            'никто не унаследует');

    final other = await LocalDb.open(petrov);
    expect(await other.getTasks(), isEmpty);
    await other.close();
  });

  testWidgets('фото двух пользователей не перезаписывают друг друга',
      (tester) async {
    final source =
        File(p.join((await getTemporaryDirectory()).path, 'shot.jpg'));
    await source.writeAsBytes(List<int>.filled(64, 7));

    final a = await LocalDb.open(ivanov);
    final pathA = await _addPhoto(a, source.path);
    final b = await LocalDb.open(petrov);
    final pathB = await _addPhoto(b, source.path);

    // одна и та же задача, одно и то же поле — но два файла в двух каталогах
    expect(pathA, isNot(pathB));
    expect(p.basename(p.dirname(pathA)), a.userKey);
    expect(p.basename(p.dirname(pathB)), b.userKey);
    expect(File(pathA).existsSync(), isTrue);
    expect(File(pathB).existsSync(), isTrue);

    // и в базе каждого — только его собственный снимок
    expect((await a.getFillPhotos('ST0001')).single['path'], pathA);
    expect((await b.getFillPhotos('ST0001')).single['path'], pathB);
    await a.close();
    await b.close();
  });
}

/// Кладёт снимок через тот же код, что и приложение, и возвращает путь, по которому он
/// сохранён. Сервера нет: очередь после этого остаётся неотправленной — именно то
/// состояние, в котором фото и живёт на устройстве до связи.
Future<String> _addPhoto(LocalDb db, String sourcePath) async {
  final api = ApiClient(
    Settings(baseUrl: 'http://127.0.0.1:1'),
    Session(),
    client: MockClient((_) async => http.Response('', 503)),
  );
  final c = FillController(db: db, api: api, taskId: 'ST0001');
  final field =
      FillField(sectionIndex: 0, fieldIndex: 0, code: 'PHOTO', type: 'photo');
  await c.addPhoto(field, sourcePath);
  // addPhoto отправляет очередь в фоне, а тест потом закрывает базу. Ждать по флагу
  // `syncing` нельзя: он гаснет раньше последнего запроса контроллера к базе, и тот
  // упадёт уже на закрытой — причём не здесь, а в брошенном future, из-за которого
  // flutter_test пойдёт дальше и уронит соседний тест. Ждём последнего уведомления:
  // после него контроллер к базе не обращается.
  final drained = Completer<void>();
  void watch() {
    if (!c.syncing && !drained.isCompleted) drained.complete();
  }

  c.addListener(watch);
  await drained.future;
  c.removeListener(watch);
  api.close();
  return field.photoPaths.single;
}
