import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/fill_controller.dart';
import 'package:pulse_tasks/data/local_db.dart';
import 'package:pulse_tasks/data/password_hash.dart';
import 'package:pulse_tasks/data/secure_store.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/data/task_repository.dart';
import 'package:pulse_tasks/models/fill.dart';
import 'package:pulse_tasks/models/task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

/// Два выхода из учётной записи — на настоящих файлах настоящего устройства: обычный,
/// после которого работа дожидается человека, и «выйти и удалить данные», после которого
/// от него на телефоне не остаётся ничего. Что именно удалено, а что уцелело, видно только
/// по файлам, поэтому unit-тестами это не проверить.
///
///     flutter test integration_test -d <device>
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const server = 'http://test.local:9080';
  final ivanov = LocalDb.keyFor(server, 'ivanov');
  final petrov = LocalDb.keyFor(server, 'petrov');

  Future<String> dbPath(String userKey) async =>
      p.join(await getDatabasesPath(), 'pulse_tasks_$userKey.db');

  Future<void> wipeDevice() async {
    final dbDir = Directory(await getDatabasesPath());
    if (dbDir.existsSync()) {
      for (final f in dbDir.listSync().whereType<File>()) {
        if (p.basename(f.path).startsWith('pulse_tasks')) await f.delete();
      }
    }
    final photos = Directory(
        p.join((await getApplicationDocumentsDirectory()).path, 'fill_photos'));
    if (photos.existsSync()) await photos.delete(recursive: true);
    await SecureStore.deleteAll();
    await (await SharedPreferences.getInstance()).clear();
  }

  setUp(wipeDevice);

  String iso() => DateTime.now().toIso8601String();

  /// Приложение с вошедшим пользователем и без сервера. Вход настоящий — тот самый
  /// офлайн-вход, которым человек открывает смену в подвале: пароль сверяется с хэшем,
  /// после чего репозиторий открывает его базу.
  Future<TaskRepository> signedIn(String login) async {
    final session = Session(
      login: login,
      password: 'secret',
      passwordHash: await PasswordHash.create('secret'),
      lastContact: DateTime.now(), // офлайн-окно открыто
    );
    await session.save();
    // адрес на устройстве уже прописан — его задают один раз при выдаче телефона
    final settings = Settings(baseUrl: server);
    await settings.save();
    final api = ApiClient(settings, session,
        client: MockClient((_) async => throw const SocketException('нет сети')));
    final repo = TaskRepository(api: api, settings: settings, session: session);
    await repo.signIn(login, 'secret');
    expect(repo.session.isActive, isTrue, reason: 'офлайн-вход не состоялся');
    return repo;
  }

  /// Снимок, положенный тем же кодом, что и в приложении. Сервера нет, поэтому он
  /// остаётся неотправленным — ровно то состояние, в котором фото и живёт до связи.
  Future<String> addPhoto(LocalDb db, String taskId) async {
    final source =
        File(p.join((await getTemporaryDirectory()).path, 'shot.jpg'));
    await source.writeAsBytes(List<int>.filled(64, 7));
    final api = ApiClient(
      Settings(baseUrl: 'http://127.0.0.1:1'),
      Session(),
      client: MockClient((_) async => throw const SocketException('нет сети')),
    );
    final c = FillController(db: db, api: api, taskId: taskId);
    final field =
        FillField(sectionIndex: 0, fieldIndex: 0, code: 'PHOTO', type: 'photo');
    // addPhoto отправляет очередь в фоне, а тест потом закрывает базу — ждать надо не
    // флага `syncing` (он гаснет раньше последнего запроса), а последнего уведомления:
    // после него контроллер к базе уже не обращается
    await c.addPhoto(field, source.path);
    expect(c.syncing, isTrue, reason: 'отправка стартует ещё внутри addPhoto');
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

  // Человек закончил смену в подвале без связи: его очередь обязана дождаться сети, а не
  // исчезнуть вместе с выходом.
  testWidgets('обычный выход данных не трогает — они ждут возвращения',
      (tester) async {
    final repo = await signedIn('ivanov');
    await repo.db.replaceTasks(
        [const Task(id: 'ST0001', name: 'Проверить витрину', statusId: 's1')]);
    await repo.db.enqueue('ST0001', 's2', 'Выполнена', iso());
    final photo = await addPhoto(repo.db, 'ST0001');
    expect(await repo.unsentChanges(), 2, reason: 'статус и фото ждут отправки');

    await repo.signOut();

    expect(await databaseExists(await dbPath(ivanov)), isTrue);
    expect(File(photo).existsSync(), isTrue);
    // и вернуться можно без сети: устройство помнит эту учётную запись
    expect(await repo.session.matches('ivanov', 'secret'), isTrue);
    expect(repo.session.token, isEmpty, reason: 'токен уходит вместе с сессией');

    await repo.signIn('ivanov', 'secret');
    expect((await repo.db.getTasks()).map((t) => t.id), ['ST0001']);
    expect(await repo.unsentChanges(), 2,
        reason: 'неотправленное дождалось того, кто его сделал');

    // sqflite держит открытые базы в кэше по пути: оставленное соединение достанется
    // следующему тесту, у которого файла под ним уже нет
    await repo.signOut();
  });

  testWidgets('выход с удалением стирает данные ровно этого пользователя',
      (tester) async {
    // сосед по телефону: его база и его фото заведены тем же кодом
    final other = await LocalDb.open(petrov);
    await other.replaceTasks([const Task(id: 'ST0002', name: 'Пересчёт кассы')]);
    await other.enqueue('ST0002', 's2', 'Выполнена', iso());
    final otherPhoto = await addPhoto(other, 'ST0002');
    await other.close();

    final repo = await signedIn('ivanov');
    await repo.db.replaceTasks([const Task(id: 'ST0001', name: 'Витрина')]);
    await repo.db.enqueue('ST0001', 's2', 'Выполнена', iso());
    final myPhoto = await addPhoto(repo.db, 'ST0001');

    await repo.signOutAndWipe();

    expect(await databaseExists(await dbPath(ivanov)), isFalse);
    expect(File(myPhoto).existsSync(), isFalse);
    expect((await FillController.photoDirectory(ivanov)).existsSync(), isFalse);
    expect(repo.tasks, isEmpty, reason: 'экран не должен пережить свои данные');

    // сосед по телефону не пострадал — ни базой, ни своей неотправленной очередью
    expect(await databaseExists(await dbPath(petrov)), isTrue);
    expect(File(otherPhoto).existsSync(), isTrue);
    final again = await LocalDb.open(petrov);
    expect((await again.getTasks()).map((t) => t.id), ['ST0002']);
    expect((await again.getOutbox())['ST0002']?.statusId, 's2');
    await again.close();

    // учётная запись забыта целиком: офлайн-вход по ней больше не проходит
    final forgotten = await Session.load();
    expect(forgotten.login, isEmpty);
    expect(await forgotten.matches('ivanov', 'secret'), isFalse);
    // а адрес принадлежит установке — следующему всё равно есть куда входить
    expect((await Settings.load()).baseUrl, server);
  });

  // «Честное предупреждение» — это число, в которое попало всё несинхронизированное.
  // Бейдж на панели показал бы здесь единицу: он считает только очередь статусов, а
  // заполненные поля и снятые фото дренируются экраном задачи и отсюда не видны.
  testWidgets('предупреждение считает все очереди, а не только статусы',
      (tester) async {
    final repo = await signedIn('ivanov');
    final db = repo.db;
    final now = iso();
    await db.enqueue('ST0001', 's2', 'Выполнена', now);
    await db.enqueueField('ST0001', 'TEMP',
        type: 'number', number: 4, createdAtIso: now);
    await db.enqueueCell('ST0001', 'TABLE', 'row-uuid-1', 'QTY',
        number: 7, createdAtIso: now);
    await db.setResolutionOutbox('ST0001', 'ok', now);
    await db.saveFillPhoto('ST0001', 'PHOTO', 0, '/no/such/shot.jpg', now);

    expect(await repo.unsentChanges(), 5);

    // подтверждённое сервером из счёта уходит: пугать нужно только тем, что пропадёт
    await db.markFillPhotoUploaded('ST0001', 'PHOTO', 0);
    await db.dequeue('ST0001');
    expect(await repo.unsentChanges(), 3);

    await repo.signOut(); // закрыть базу за собой — см. первый тест
  });
}
