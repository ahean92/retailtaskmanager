// Сквозная приёмка #36914 на живом стенде — несколько фото при создании задачи и
// дозагрузка кадра к уже существующей задаче.
//
// Throwaway-драйвер: сеть переключает внешний шелл по маркерам в логе, серверные
// сверки — ручками самого приложения (apiTasks, apiTaskComments).
//
// Параметры — dart-define: E2E_BASE (адрес стенда), E2E_LOGIN/E2E_PASS, E2E_PRESET
// (код пресета создания), E2E_OBJECT (id объекта; пусто — тот, на котором стоит
// эмулятор).
//
// Сценарий приёмки («Готово когда» тикета):
//  1) БЕЗ СЕТИ задача создаётся с ТРЕМЯ кадрами — все три ложатся в очередь снимков,
//     а тело создания уезжает без фото внутри;
//  2) кадр, убранный до отправки, не уезжает и не остаётся на диске;
//  3) связь вернулась — задача и кадры уходят сами, и сервер отдаёт их файлами
//     ЗАДАЧИ (apiTasks.files), а не вложениями переписки;
//  4) фото, приложенное к уже существующей задаче, доезжает тем же путём и видно на
//     карточке — без единого написанного комментария.
//
// Маркеры: boot:, E2E_READY, NET_OFF, E2E_CREATED=<uuid>, SHOT_create, E2E_DISCARDED,
// NET_ON, E2E_SYNCED=<taskId>, SHOT_card, E2E_ATTACHED, ALL_OK_36914.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:pulse_tasks/data/geo.dart';
import 'package:pulse_tasks/data/task_file_controller.dart';
import 'package:pulse_tasks/data/task_repository.dart';
import 'package:pulse_tasks/main.dart' as app;
import 'package:pulse_tasks/models/quick_create.dart';
import 'package:pulse_tasks/ui/task_detail_screen.dart';
import 'package:pulse_tasks/ui/widgets/task_card.dart';

const _base = String.fromEnvironment('E2E_BASE',
    defaultValue: 'http://192.168.42.28:8888');
const _login = String.fromEnvironment('E2E_LOGIN', defaultValue: 'sosedi.tech1');
const _pass = String.fromEnvironment('E2E_PASS', defaultValue: 'demo');
const _preset = String.fromEnvironment('E2E_PRESET', defaultValue: 'issue36872');
const _object = String.fromEnvironment('E2E_OBJECT', defaultValue: '');

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

/// Кадр «с места» — PNG, собранный на устройстве без ассетов: камеру эмулятора в
/// integration_test не нажать, а приёмке важна дорога снимка, а не его содержимое.
/// Цвет разный у каждого кадра — чтобы на скриншоте было видно, что их три.
Future<String> _makePhoto(String name, int tint) async {
  const w = 64, h = 64;
  final raw = BytesBuilder();
  for (var y = 0; y < h; y++) {
    raw.addByte(0); // filter: none
    for (var x = 0; x < w; x++) {
      raw.add([tint, (x * 4) & 0xff, (y * 4) & 0xff]);
    }
  }
  final idat = ZLibCodec(level: 6).encode(raw.toBytes());
  Uint8List chunk(String type, List<int> data) {
    final b = BytesBuilder();
    b.add(_be32(data.length));
    final td = [...type.codeUnits, ...data];
    b.add(td);
    b.add(_be32(_crc32(td)));
    return b.toBytes();
  }

  final png = BytesBuilder()
    ..add([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    ..add(chunk('IHDR', [..._be32(w), ..._be32(h), 8, 2, 0, 0, 0]))
    ..add(chunk('IDAT', idat))
    ..add(chunk('IEND', []));
  final dir = await getTemporaryDirectory();
  final f = File('${dir.path}/$name.png');
  await f.writeAsBytes(png.toBytes());
  return f.path;
}

List<int> _be32(int v) =>
    [(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff];

int _crc32(List<int> data) {
  var crc = 0xFFFFFFFF;
  for (final b in data) {
    crc ^= b;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
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

Finder _verticalList() => find.byWidgetPredicate(
    (w) => w is Scrollable && w.axisDirection == AxisDirection.down);

Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 30 && finder.evaluate().isEmpty; i++) {
    await tester.drag(_verticalList().first, const Offset(0, -300));
    await _settle(tester, frames: 3);
  }
  expect(finder, findsWidgets);
  await tester.ensureVisible(finder.first);
  await _settle(tester, frames: 3);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('36914: три кадра при создании и дозагрузка к задаче',
      (tester) async {
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
    // разрешение геолокации выдаёт оркестратор по маркеру boot: — иначе locate()
    // виснет на системном диалоге (грабли #36838)
    if (!repo.geoReady) {
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
    await _untilAsync(tester, 'пресет «$_preset» предзагружен', () async {
      await repo.refreshQuickCreate();
      return repo.quickCreate.actions.any((a) => a.code == _preset);
    }, seconds: 180);
    final QuickPreset preset =
        repo.quickCreate.actions.firstWhere((a) => a.code == _preset);
    final objectId = _object.isNotEmpty ? _object : repo.objectId;
    expect(objectId, isNotNull, reason: 'нужен объект: E2E_OBJECT или место');
    debugPrint('E2E_READY object=$objectId');

    // ===== 1. без сети: задача с тремя кадрами =====
    debugPrint('NET_OFF');
    await _until(tester, 'авиарежим', () => !repo.online, seconds: 240);

    final stamp = DateTime.now().millisecondsSinceEpoch % 100000;
    final title = '36914 витрина и ценник $stamp';
    final shots = [
      await _makePhoto('e2e36914_a', 220),
      await _makePhoto('e2e36914_b', 120),
      await _makePhoto('e2e36914_c', 40),
    ];
    final uuid = await repo.createTask(
      typeId: preset.typeId!,
      templateCode: preset.templateCode,
      priorityId: preset.priorityId,
      requirePhoto: preset.requirePhoto,
      executionKind: preset.executionKind,
      objectId: objectId!,
      objectName: repo.currentObject?.name,
      name: title,
      photoPaths: shots,
    );
    await repo.reloadLocal();
    debugPrint('E2E_CREATED=$uuid');
    expect(repo.viewOf(uuid), isNotNull, reason: 'задача в списке сразу');

    var pending = await repo.pendingTaskPhotos(uuid);
    expect(pending, hasLength(3),
        reason: 'все три кадра ждут отправки своей очередью');
    for (final q in pending) {
      expect(File(q.path).existsSync(), isTrue,
          reason: 'копия в телефоне — единственная, пока кадр не доехал');
    }

    // карточка: снимки видно ещё до отправки
    await tester.tap(find.textContaining('Все').first);
    await _settle(tester);
    Finder ourCard() => find.ancestor(
        of: find.textContaining('ожидает синхронизации'),
        matching: find.byType(TaskCard));
    await _scrollTo(tester, ourCard());
    await tester.tap(ourCard().first);
    await _until(tester, 'карточка задачи',
        () => find.byType(TaskDetailScreen).evaluate().isNotEmpty);
    await _settle(tester, frames: 20);
    await _shot(tester, 'SHOT_create'); // карточка с тремя кадрами в очереди

    // ===== 2. кадр, убранный до отправки =====
    final extraSource = await _makePhoto('e2e36914_d', 255);
    await repo.attachTaskPhoto(uuid, extraSource);
    pending = await repo.pendingTaskPhotos(uuid);
    expect(pending, hasLength(4));
    final discarded = pending.last;
    await repo.discardTaskPhoto(discarded.clientId);
    expect(File(discarded.path).existsSync(), isFalse,
        reason: 'убранный кадр не занимает место на телефоне');
    expect(await repo.pendingTaskPhotos(uuid), hasLength(3));
    debugPrint('E2E_DISCARDED');

    // ===== 3. связь вернулась: задача и кадры уходят сами =====
    debugPrint('NET_ON');
    await _untilAsync(tester, 'очереди задачи пусты', () async {
      await repo.syncAndRefresh();
      return await repo.db.getCreateEntry(uuid) == null &&
          (await repo.pendingTaskPhotos(uuid)).isEmpty;
    }, seconds: 420);

    // сервер отдаёт кадры файлами ЗАДАЧИ, а не вложениями переписки
    await _untilAsync(tester, 'три снимка в файлах задачи', () async {
      await repo.refresh();
      final view = repo.viewOf(uuid);
      return view != null && view.task.files.where((f) => f.image).length >= 3;
    }, seconds: 240);
    final synced = repo.viewOf(uuid)!;
    expect(synced.task.files.where((f) => f.image), hasLength(3),
        reason: 'ровно три: убранный кадр на сервер не поехал');
    debugPrint('E2E_SYNCED=${synced.id}');

    // ни одного НАПИСАННОГО комментария при этом не появилось
    final comments = await repo.api.fetchTaskComments(uuid);
    expect(comments.where((c) => (c.text ?? '').trim().isNotEmpty), isEmpty,
        reason: 'фото цепляется к задаче, а не пишет за человека сообщение');

    // ===== 4. дозагрузка к существующей задаче =====
    await repo.attachTaskPhoto(synced.id, await _makePhoto('e2e36914_e', 90));
    await _untilAsync(tester, 'досланный кадр уехал', () async {
      await repo.syncAndRefresh();
      return (await repo.pendingTaskPhotos(synced.id)).isEmpty;
    }, seconds: 240);
    await _untilAsync(tester, 'четвёртый снимок на задаче', () async {
      await repo.refresh();
      final view = repo.viewOf(synced.id);
      return view != null && view.task.files.where((f) => f.image).length >= 4;
    }, seconds: 240);
    debugPrint('E2E_ATTACHED');

    // и он виден на карточке — там же, где остальные
    await tester.pageBack();
    await _settle(tester);
    Finder syncedCard() => find.ancestor(
        of: find.textContaining(title), matching: find.byType(TaskCard));
    if (syncedCard().evaluate().isEmpty) {
      // подпись карточки берётся с сервера и может отличаться от названия — тогда
      // открываем первую карточку своего объекта, задача одна на этот прогон
      await _scrollTo(tester, find.byType(TaskCard));
      await tester.tap(find.byType(TaskCard).first);
    } else {
      await _scrollTo(tester, syncedCard());
      await tester.tap(syncedCard().first);
    }
    await _until(tester, 'карточка синхронизированной задачи',
        () => find.byType(TaskDetailScreen).evaluate().isNotEmpty);
    await _settle(tester, frames: 20);
    await _scrollTo(tester, find.textContaining('Было'));
    await _shot(tester, 'SHOT_card'); // галерея из четырёх снимков

    expect(TaskFilesController.maxPerTask, 10,
        reason: 'предел на задачу — тот, что обещан в приёмке');
    debugPrint('ALL_OK_36914');
  });
}
