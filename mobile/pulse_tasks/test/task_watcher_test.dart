import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:pulse_tasks/app_controllers.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/models/task_view.dart';
import 'package:pulse_tasks/models/task.dart';
import 'package:pulse_tasks/ui/task_detail_screen.dart';
import 'support/fake_server.dart';
import 'support/test_env.dart';

/// Наблюдатель за задачей (#37135) на телефоне: задача приезжает, читается и
/// переписывается — но своей группой, а не «Моими».
///
/// Главное здесь — то, ради чего признак `watched` вообще заводился. Строка без
/// assigned и authored читается клиентом как назначенная (совместимость со старым
/// сервером, #36844): без отдельного признака наблюдаемая задача молча уехала бы в
/// «Мои», и плитка главной, считающая mine() на сервере, разошлась бы с длиной
/// списка — дефект доверия #36751.
///
/// Настоящий sqlite (ffi): признак живёт в строке задачи и переживает самолётный
/// режим вместе с ней, а мок не проверил бы ни хранение, ни ALTER TABLE.

int _seq = 0;

/// Своя база на каждый сценарий: файл базы ключуется парой (адрес, логин), и общий
/// логин оставил бы задачи предыдущего сценария в следующем. Отметка времени в логине —
/// по прецеденту соседних тестов: файлы баз переживают прогон, а 'ivanov0' занят чужим
/// набором задач из другого файла тестов.
Future<AppControllers> _repo(List<Map<String, Object?>> fetched) async {
  final settings = Settings(baseUrl: 'http://test.local:9080');
  final session = Session(
    login: 'ivanov${DateTime.now().microsecondsSinceEpoch}_${_seq++}',
    name: 'Иванов И.И.',
    token: 'token',
    signedIn: true,
    performerId: 'p1',
  );
  final app = AppControllers(
    api: ApiClient(settings, session,
        client: MockClient((r) async => okJson('[]'))),
    settings: settings,
    session: session,
  );
  await app.account.updateSettings(settings); // открывает базу этого логина
  for (final j in fetched) {
    await app.repo.db.tasks
        .insertLocalTask(Task.fromJson(j.cast<String, dynamic>()));
  }
  await app.repo.reloadLocal();
  return app;
}

TaskView _view(AppControllers app, String id) =>
    app.repo.tasks.firstWhere((v) => v.id == id);

void main() {
  initTestEnv();

  late Directory docs;

  setUp(() {
    resetMockStores();
    // карточка задачи читает кэш снимков из каталога приложения — на настольной
    // машине его никто не подставляет
    docs = Directory.systemTemp.createTempSync('pulse_docs');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => docs.path);
  });

  tearDown(() {
    if (docs.existsSync()) docs.deleteSync(recursive: true);
  });

  test('наблюдаемая — своя группа, а не «мои»', () async {
    final app = await _repo([
      {'id': 'ST1', 'name': 'Моя', 'assigned': true, 'mine': true},
      {
        'id': 'ST2',
        'name': 'Чужая проверка',
        'watched': true,
        'assignedTo': 'Петров П.П.',
      },
      {
        'id': 'ST3',
        'name': 'И моя, и слежу',
        'assigned': true,
        'watched': true,
        'mine': true,
      },
      {'id': 'ST4', 'name': 'Поручение', 'authored': true, 'watched': true},
      {'id': 'ST5', 'name': 'Старый сервер'},
    ]);

    final w = _view(app, 'ST2');
    expect(w.group, TaskGroup.watched);
    expect(w.watchedOnly, isTrue);
    expect(w.readOnly, isTrue, reason: 'смотрю и переписываюсь, но не работаю');
    expect(w.canTake, isFalse, reason: 'взятие идёт по назначению, не по подписке');
    expect(w.releasable, isFalse);

    expect(_view(app, 'ST1').group, TaskGroup.mine);
    expect(_view(app, 'ST3').group, TaskGroup.mine,
        reason: 'назначенная не перестаёт быть моей от того, что я слежу');
    expect(_view(app, 'ST3').readOnly, isFalse);
    expect(_view(app, 'ST4').group, TaskGroup.authored,
        reason: 'автор — более сильная роль: там видно исполнителя');
    expect(_view(app, 'ST5').group, TaskGroup.mine,
        reason: 'выдача старого сервера вся назначена лично');
    app.dispose();
  });

  // Ровно то, из-за чего признак и понадобился: плитка «Мои задачи» считает mine()
  // на сервере, а фильтры-двойники — group == mine на телефоне.
  test('плитка сходится со списком: наблюдаемых в «моих» фильтрах нет', () async {
    final app = await _repo([
      {'id': 'ST1', 'name': 'Моя', 'assigned': true, 'mine': true, 'overdue': 1},
      {'id': 'ST2', 'name': 'Слежу', 'watched': true, 'overdue': 1},
    ]);
    final all = app.repo.tasks;
    expect(all, hasLength(2), reason: 'обе приехали и обе видны в «Всех задачах»');
    expect(all.where(TaskFilter.open.matches).map((v) => v.id), ['ST1']);
    expect(all.where(TaskFilter.overdue.matches).map((v) => v.id), ['ST1'],
        reason: 'просроченная наблюдаемая — не моя просроченная');
    expect(all.where(TaskFilter.all.matches), hasLength(2));
    app.dispose();
  });

  test('признак переживает кэш и обновление базы', () async {
    final app = await _repo([
      {'id': 'ST1', 'name': 'Слежу', 'watched': true},
    ]);
    // перечитывание из sqlite — то же, что открытие приложения в самолётном режиме
    await app.repo.reloadLocal();
    expect(_view(app, 'ST1').watchedOnly, isTrue);
    expect(_view(app, 'ST1').task.watched, isTrue);
    app.dispose();
  });

  testWidgets('карточка наблюдателя: баннер вместо кнопок работы',
      (tester) async {
    await tester.runAsync(() async {
      final app = await _repo([
        {
          'id': 'ST1',
          'name': 'Чужая проверка',
          'watched': true,
          'assignedTo': 'Петров П.П.',
          'executionKind': 'simple',
          'statusId': 'new',
          'status': 'Новый',
        },
      ]);
      await tester.pumpWidget(MultiProvider(
        providers: app.providers,
        child: const MaterialApp(home: TaskDetailScreen(taskId: 'ST1')),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.textContaining('Вы наблюдаете за этой задачей'), findsOneWidget);
      expect(find.textContaining('Вы автор этой задачи'), findsNothing);
      expect(find.text('Выполнить'), findsNothing,
          reason: 'работа по задаче — у исполнителя');
      app.dispose();
    });
  });
}
