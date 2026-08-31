// Сквозная приёмка #36946 на живом стенде — удаление ОДНОГО снимка пункта.
//
// Проверяется ровно то, что записано в приёмке тикета:
//  1) из трёх снимков пункта удаляется средний — крестиком на настоящем экране бланка;
//     два оставшихся на месте и на телефоне, и на сервере, переснимать ничего не надо,
//     а photoCount после синхронизации равен двум;
//  2) удаление, сделанное в самолётном режиме, доезжает после включения сети, и
//     повторная отправка очереди не роняет ошибку на уже удалённом снимке;
//  3) кадр, снятый офлайн и удалённый до отправки, на сервере не появляется вовсе и
//     места на устройстве не занимает.
//
// Сервер проверяется его же ручкой (apiExecutionFields: photoCount и photoIndexes), а
// не состоянием контроллера: вопрос тикета именно в том, тот ли снимок исчез ТАМ.
//
// Throwaway-драйвер: сеть переключает внешний шелл по маркерам в логе.
//
// Параметры — dart-define: E2E_BASE, E2E_LOGIN/E2E_PASS, E2E_TASK (задача с бланком),
// E2E_FIELD (код пункта; пусто — первый пункт типа photo).
//
// Маркеры: boot:, E2E_READY, E2E_UPLOADED, SHOT_gallery, E2E_MIDDLE_OK, SHOT_after,
// NET_OFF, E2E_OFFLINE_READY, NET_ON, E2E_OFFLINE_OK, E2E_RETRY_OK, ALL_OK_36946.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:pulse_tasks/data/fill_controller.dart';
import 'package:pulse_tasks/data/geo.dart';
import 'package:pulse_tasks/data/task_repository.dart';
import 'package:pulse_tasks/main.dart' as app;
import 'package:pulse_tasks/models/fill.dart';
import 'package:pulse_tasks/ui/fill_screen.dart';

const _base = String.fromEnvironment('E2E_BASE',
    defaultValue: 'http://192.168.42.28:8888');
const _login = String.fromEnvironment('E2E_LOGIN', defaultValue: 'demo.user1');
const _pass = String.fromEnvironment('E2E_PASS', defaultValue: 'demo');
const _task = String.fromEnvironment('E2E_TASK', defaultValue: 'DEMO36751-1');
const _field = String.fromEnvironment('E2E_FIELD', defaultValue: '');

Future<void> _settle(WidgetTester tester, {int frames = 12}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 120));
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }
}

Future<void> _until(WidgetTester tester, String what, bool Function() done,
    {int seconds = 180}) async {
  final deadline = DateTime.now().add(Duration(seconds: seconds));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('не дождались: $what');
    await tester.pump(const Duration(milliseconds: 400));
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }
  await _settle(tester);
}

Future<void> _untilAsync(
    WidgetTester tester, String what, Future<bool> Function() done,
    {int seconds = 180}) async {
  final deadline = DateTime.now().add(Duration(seconds: seconds));
  while (!await done()) {
    if (DateTime.now().isAfter(deadline)) fail('не дождались: $what');
    await tester.pump(const Duration(milliseconds: 400));
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }
  await _settle(tester);
}

/// Снимок экрана делает шелл (`adb exec-out screencap`) по маркеру — здесь только
/// пауза, чтобы кадр был дорисован и шелл успел.
Future<void> _shot(WidgetTester tester, String marker) async {
  await _settle(tester, frames: 6);
  debugPrint(marker);
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
}

/// Долистать бланк до нужного места: КАЖДЫЙ раздел прокручивается сверху донизу и
/// только потом листается следующий. Наоборот нельзя: список раздела ленивый, плитки
/// ниже сгиба ещё не построены, и «не нашли на этой странице» означало бы всего лишь
/// «не долистали» — драйвер пробегал все четыре раздела, ничего не увидев.
Future<void> _pageTo(WidgetTester tester, Finder finder) async {
  final vertical = find.byWidgetPredicate(
      (w) => w is Scrollable && w.axisDirection == AxisDirection.down);
  for (var page = 0; page < 12 && finder.evaluate().isEmpty; page++) {
    for (var i = 0; i < 20 && finder.evaluate().isEmpty; i++) {
      if (vertical.evaluate().isEmpty) break;
      await tester.drag(vertical.first, const Offset(0, -300));
      await _settle(tester, frames: 3);
    }
    if (finder.evaluate().isNotEmpty) break;
    final next = find.widgetWithText(FilledButton, 'Далее');
    if (next.evaluate().isEmpty) break;
    await tester.tap(next.first);
    await _settle(tester, frames: 8);
  }
  if (finder.evaluate().isEmpty) {
    // что вообще на экране — иначе «не нашли» ничего не говорит о причине
    final texts = [
      for (final e in find.byType(Text).evaluate())
        (e.widget as Text).data ?? ''
    ];
    debugPrint('E2E_SCREEN ${jsonEncode(texts)}');
  }
  expect(finder, findsWidgets);
  await tester.ensureVisible(finder.first);
  await _settle(tester, frames: 3);
}

Future<bool> _probe(TaskRepository repo) async {
  try {
    await repo.api.fetchStatuses();
    return true;
  } catch (_) {
    return false;
  }
}

/// Что о снимках пункта говорит САМ сервер: сколько их и под какими индексами.
Future<({int count, List<int> indexes})> _onServer(
    TaskRepository repo, String fieldCode) async {
  final raw = await repo.api.fetchExecutionFields(_task);
  final j = raw.firstWhere((e) => e['code'] == fieldCode,
      orElse: () => fail('пункт $fieldCode пропал из бланка'));
  final idx = [
    for (final s in '${j['photoIndexes'] ?? ''}'.split(','))
      if (int.tryParse(s.trim()) != null) int.parse(s.trim())
  ];
  return (count: (j['photoCount'] as num?)?.toInt() ?? 0, indexes: idx);
}

/// Кадр, какой его кладёт на диск камера, — одноцветный PNG.
Future<String> _shotFile(String name, int tint) async {
  final dir = await getTemporaryDirectory();
  final f = File(p.join(dir.path, '$name.png'));
  await f.writeAsBytes(_png(tint));
  return f.path;
}

/// 1×1 PNG заданного оттенка: собирается руками, чтобы у каждого кадра были свои
/// байты — «остались ИМЕННО те два снимка» иначе не проверить.
List<int> _png(int tint) {
  final b = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');
  return [...b, ...utf8.encode('# tint $tint')]; // хвост PNG-декодеру не мешает
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('36946: удаляется один кадр, а не вся галерея', (tester) async {
    app.main();
    await _until(tester, 'первый кадр приложения',
        () => find.byType(MaterialApp).evaluate().isNotEmpty,
        seconds: 90);

    final ctx = tester.element(find.byType(MaterialApp).first);
    final repo = Provider.of<TaskRepository>(ctx, listen: false);

    // --- вход, если переустановка снесла настройки/сессию ---
    debugPrint('boot: configured=${repo.settings.isConfigured} '
        'active=${repo.session.isActive} login="${repo.session.login}"');
    if (repo.session.isActive && repo.session.login != _login) {
      await repo.signOut();
      await _settle(tester);
    }
    if (!repo.settings.isConfigured) {
      await tester.enterText(find.byType(TextField).first, _base);
      await _settle(tester);
      await tester.tap(find.text('Сохранить'));
      await _settle(tester);
    }
    if (!repo.session.isActive) {
      final fields = find.byType(TextField);
      expect(fields, findsWidgets, reason: 'ни сессии, ни формы входа');
      await tester.enterText(fields.at(0), _login);
      await tester.enterText(fields.at(1), _pass);
      await _settle(tester);
      await tester.tap(find.text('Войти'));
      await _until(tester, 'вход', () => repo.session.isActive, seconds: 90);
    }
    if (repo.session.geoRequired && !repo.geoReady) {
      await _untilAsync(
          tester,
          'разрешение геолокации',
          () async =>
              await repo.geo.platform.permission() == GeoPermission.granted,
          seconds: 180);
      await repo.locate(fresh: true);
      await _until(tester, 'гео-гейт', () => repo.geoReady, seconds: 120);
    }
    await repo.syncAndRefresh();
    await _settle(tester);

    // ===== подготовка: чистый пункт с фотографиями =====
    var c = FillController(
        db: repo.db, api: repo.api, taskId: _task, geo: repo.geo);
    await c.load();
    expect(c.online, isTrue, reason: 'подготовка идёт на связи');
    expect(c.fields, isNotEmpty, reason: 'бланк приехал');
    final FillField f = _field.isEmpty
        ? c.fields.firstWhere((x) => x.type == 'photo',
            orElse: () => fail('в шаблоне задачи $_task нет пункта-фото'))
        : c.fields.firstWhere((x) => x.code == _field,
            orElse: () => fail('в бланке нет пункта $_field'));
    if (f.photoCount > 0) {
      // прогон начинается с чистого пункта — иначе «средний» неопределён
      await c.clearPhotos(f);
      await c.syncAll();
    }
    expect((await _onServer(repo, f.code)).count, 0,
        reason: 'пункт очищен перед прогоном');

    // ===== 1. три кадра уезжают, каждый со своим индексом =====
    final sources = [
      await _shotFile('e2e36946_a', 10),
      await _shotFile('e2e36946_b', 120),
      await _shotFile('e2e36946_c', 240),
    ];
    for (final s in sources) {
      await c.addPhoto(f, s);
    }
    await c.syncAll();
    var server = await _onServer(repo, f.code);
    expect(server.count, 3, reason: 'три кадра доехали');
    expect(server.indexes, [1, 2, 3]);
    expect([for (final s in f.shots) s.serverIndex], [1, 2, 3],
        reason: 'телефон знает индекс каждого своего кадра');
    debugPrint('E2E_UPLOADED indexes=${server.indexes}');

    // ===== 2. средний кадр удаляется КРЕСТИКОМ на настоящем экране =====
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    nav.push(
        MaterialPageRoute(builder: (_) => const FillScreen(taskId: _task)));
    await _until(tester, 'экран бланка',
        () => find.byType(FillScreen).evaluate().isNotEmpty, seconds: 90);
    await _settle(tester, frames: 20);
    // ищется сама галерея: крестики живут в плитке нужного пункта, и ждать их —
    // то же самое, что ждать плитку, но без догадок о её заголовке
    await _pageTo(tester, find.byTooltip('Удалить снимок'));
    await _until(tester, 'галерея из трёх кадров',
        () => find.byTooltip('Удалить снимок').evaluate().length == 3,
        seconds: 60);
    await _shot(tester, 'SHOT_gallery'); // три кадра, у каждого свой крестик

    final keptFiles = [f.shots[0].path!, f.shots[2].path!];
    final middleFile = f.shots[1].path!;
    await tester.tap(find.byTooltip('Удалить снимок').at(1));
    await _settle(tester, frames: 10);
    await _until(tester, 'в галерее осталось два кадра',
        () => find.byTooltip('Удалить снимок').evaluate().length == 2,
        seconds: 60);
    await _shot(tester, 'SHOT_after'); // остались первый и третий

    await _untilAsync(tester, 'удаление уехало', () async {
      final s = await _onServer(repo, f.code);
      return s.count == 2;
    }, seconds: 120);
    server = await _onServer(repo, f.code);
    expect(server.indexes, [1, 3], reason: 'удалён ровно средний снимок');
    expect(File(middleFile).existsSync(), isFalse,
        reason: 'место на устройстве освободилось');
    for (final path in keptFiles) {
      expect(File(path).existsSync(), isTrue,
          reason: 'соседние кадры переснимать не нужно');
    }
    debugPrint('E2E_MIDDLE_OK indexes=${server.indexes}');

    // ===== 3. самолётный режим: удаление ждёт сети, а кадр до отправки не уезжает ==
    debugPrint('NET_OFF');
    await _untilAsync(tester, 'авиарежим',
        () async => !(await _probe(repo)), seconds: 240);

    // экран бланка тот же — но контроллер под ним свой у экрана; работаем его же
    // очередями через репозиторий, как это делает приложение
    final offline = FillController(
        db: repo.db, api: repo.api, taskId: _task, geo: repo.geo);
    await offline.load();
    final of = offline.fields.firstWhere((x) => x.code == f.code);
    expect(of.shots, hasLength(2), reason: 'офлайн бланк берётся из кэша');

    // 3a) удаление уехавшего кадра — ложится в очередь
    final doomed = of.shots.first;
    await offline.deleteShot(of, doomed);
    var queued = await repo.db.getPhotoDeletes(_task);
    expect(queued, hasLength(1), reason: 'удаление ждёт сети в очереди');
    expect(queued.single['serverIdx'], doomed.serverIndex);

    // 3b) кадр, снятый офлайн и удалённый до отправки
    final orphanSource = await _shotFile('e2e36946_d', 60);
    await offline.addPhoto(of, orphanSource);
    final orphan = offline.fields
        .firstWhere((x) => x.code == f.code)
        .shots
        .lastWhere((s) => !s.uploaded);
    final orphanPath = orphan.path!;
    await offline.deleteShot(
        offline.fields.firstWhere((x) => x.code == f.code), orphan);
    expect(File(orphanPath).existsSync(), isFalse,
        reason: 'снятый и убранный кадр не занимает место');
    expect(await repo.db.getPendingFillPhotos(_task), isEmpty,
        reason: 'из очереди отправки он тоже ушёл');
    debugPrint('E2E_OFFLINE_READY queued=${queued.length}');

    debugPrint('NET_ON');
    await _untilAsync(tester, 'сеть вернулась', () async => await _probe(repo),
        seconds: 240);
    await _untilAsync(tester, 'очередь удалений ушла', () async {
      await offline.syncAll();
      return (await repo.db.getPhotoDeletes(_task)).isEmpty;
    }, seconds: 180);

    server = await _onServer(repo, f.code);
    expect(server.count, 1,
        reason: 'удаление доехало, а снятый офлайн кадр не уезжал вовсе');
    expect(server.indexes, [3], reason: 'остался ровно не удалённый кадр');
    debugPrint('E2E_OFFLINE_OK indexes=${server.indexes}');

    // ===== 4. повторная отправка по уже удалённому индексу очередь не роняет =====
    await repo.db.enqueuePhotoDelete(
        _task, f.code, doomed.serverIndex!, DateTime.now().toIso8601String());
    await offline.syncAll();
    expect(await repo.db.getPhotoDeletes(_task), isEmpty,
        reason: 'повтор ушёл, а не застрял с ошибкой');
    expect(offline.lastSyncError, isNull);
    expect((await _onServer(repo, f.code)).indexes, [3]);
    debugPrint('E2E_RETRY_OK');

    // ===== уборка: стенд остаётся таким же, каким был до прогона =====
    final cleanup = offline.fields.firstWhere((x) => x.code == f.code);
    await offline.clearPhotos(cleanup);
    await offline.syncAll();
    expect((await _onServer(repo, f.code)).count, 0);
    debugPrint('ALL_OK_36946');
  });
}
