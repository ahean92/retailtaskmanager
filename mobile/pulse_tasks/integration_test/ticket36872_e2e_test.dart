// Сквозная приёмка #36872 на живом стенде — выполнение поручения фотоотчётом.
// Throwaway-драйвер: сеть переключает внешний шелл по маркерам в логе, серверные
// сверки — curl из того же шелла.
//
// Параметры — dart-define: E2E_BASE (адрес стенда), E2E_LOGIN/E2E_PASS (исполнитель),
// E2E_PRESET (код пресета «Поручение с фото»), E2E_OBJECT (id объекта; пусто — тот, на
// котором стоит эмулятор), E2E_CORRECTIVE (ST-номер корректирующего действия с
// требованием фото — для проверки отказа сервера).
//
// Сценарий приёмки («Готово когда» тикета):
//  1) БЕЗ СЕТИ поручение создаётся с телефона и сразу открывается своим экраном —
//     вид выполнения приехал с пресетом, а не угадан по типу;
//  2) без фото «Выполнено» недоступно (кнопка и отказ контроллера);
//  3) снимок и комментарий кладутся офлайн, «Выполнено» закрывает задачу локально;
//  4) связь вернулась — цепочка create → start → фото → комментарий → finish уходит
//     сама, и сервер подтверждает: выполнение завершено, снимок в файлах задачи,
//     комментарий в ленте;
//  5) сервер, отвергший завершение (корректирующее действие без фото), доезжает
//     ОТКАЗОМ с текстом констрейнта — это и есть починенный «молчаливый откат».
//
// Маркеры: boot:, E2E_READY, NET_OFF, E2E_CREATED=<uuid>, SHOT_screen, SHOT_photo,
// E2E_DONE_OFFLINE, NET_ON, E2E_SYNCED=<taskId>, E2E_REFUSED, ALL_OK_36872.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:pulse_tasks/data/geo.dart';
import 'package:pulse_tasks/data/simple_controller.dart';
import 'package:pulse_tasks/data/task_repository.dart';
import 'package:pulse_tasks/main.dart' as app;
import 'package:pulse_tasks/models/quick_create.dart';
import 'package:pulse_tasks/ui/simple_execution_screen.dart';
import 'package:pulse_tasks/ui/task_detail_screen.dart';
import 'package:pulse_tasks/ui/widgets/task_card.dart';

const _base = String.fromEnvironment('E2E_BASE',
    defaultValue: 'http://192.168.42.28:8888');
const _login = String.fromEnvironment('E2E_LOGIN', defaultValue: 'sosedi.tech1');
const _pass = String.fromEnvironment('E2E_PASS', defaultValue: 'demo');
const _preset = String.fromEnvironment('E2E_PRESET', defaultValue: 'issue36872');
const _object = String.fromEnvironment('E2E_OBJECT', defaultValue: '');
const _corrective = String.fromEnvironment('E2E_CORRECTIVE', defaultValue: '');

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

/// Снимок «с места» — 64×64 PNG, собранный на устройстве без ассетов и камеры:
/// приёмке важен факт снимка и его дорога, а не содержимое кадра.
Future<String> _makePhoto(String name) async {
  const w = 64, h = 64;
  final raw = BytesBuilder();
  for (var y = 0; y < h; y++) {
    raw.addByte(0); // filter: none
    for (var x = 0; x < w; x++) {
      raw.add([x * 4, 200, y * 4]);
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

/// Вертикальный список экрана: `find.byType(Scrollable).first` на списке задач — это
/// горизонтальная лента чипов-фильтров (грабли #36836), поэтому — по направлению.
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

  testWidgets('36872: поручение с фото — создание и выполнение офлайн',
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
    // пресеты и справочники — заранее, пока связь есть: в подвале их не догрузить
    await _untilAsync(tester, 'пресет «$_preset» предзагружен', () async {
      await repo.refreshQuickCreate();
      return repo.quickCreate.actions.any((a) => a.code == _preset);
    }, seconds: 180);
    final QuickPreset preset =
        repo.quickCreate.actions.firstWhere((a) => a.code == _preset);
    // вид выполнения приехал С СЕРВЕРА, вместе с пресетом (#36872)
    expect(preset.executionKind, 'simple',
        reason: 'сервер обязан сказать, чем выполняется задача этого пресета');
    expect(preset.requirePhoto, isTrue, reason: 'пресет с требованием фото');
    final objectId = _object.isNotEmpty ? _object : repo.objectId;
    expect(objectId, isNotNull, reason: 'нужен объект: E2E_OBJECT или место');
    debugPrint('E2E_READY object=$objectId kind=${preset.executionKind}');

    // ===== 1. без сети: создать поручение и открыть его экраном выполнения =====
    debugPrint('NET_OFF');
    await _until(tester, 'авиарежим', () => !repo.online, seconds: 240);

    final stamp = DateTime.now().millisecondsSinceEpoch % 100000;
    final title = '36872 поддоны в зале $stamp';
    final uuid = await repo.createTask(
      preset: preset,
      objectId: objectId!,
      objectName: repo.currentObject?.name,
      name: title,
    );
    await repo.reloadLocal();
    debugPrint('E2E_CREATED=$uuid');
    final created = repo.viewOf(uuid);
    expect(created, isNotNull, reason: 'задача в списке сразу');
    // ключевое: экран выбирается по слову сервера, приехавшему с пресетом, — задача
    // ещё не существует на сервере, а открыть её уже есть чем
    expect(created!.task.opensSimple, isTrue);
    expect(created.task.requirePhoto, isTrue);

    // ===== 2. без фото «Выполнено» недоступно =====
    final c = SimpleExecutionController(
        db: repo.db,
        api: repo.api,
        taskId: uuid,
        geo: repo.geo,
        requirePhotoHint: created.task.requirePhoto == true);
    await c.load();
    expect(c.online, isFalse, reason: 'мы в самолётном режиме');
    expect(c.requirePhoto, isTrue,
        reason: 'требование фото известно заранее, а не из отказа сервера');
    expect(c.canFinish, isFalse);
    expect(await c.finish(), isFalse);
    expect(c.error, 'Приложите фото выполненной работы');

    // и на экране: карточка задачи с кнопкой выполнения. Ищется по пометке
    // «ожидает синхронизации» — в заголовке карточки стоит ОБЪЕКТ, а названия
    // задачи там нет вовсе (подпись берётся с сервера, а он этой задачи не знает)
    await tester.tap(find.textContaining('Все').first);
    await _settle(tester);
    Finder ourCard() => find.ancestor(
        of: find.textContaining('ожидает синхронизации'),
        matching: find.byType(TaskCard));
    await _scrollTo(tester, ourCard());
    await tester.tap(ourCard().first);
    await _until(tester, 'карточка задачи',
        () => find.byType(TaskDetailScreen).evaluate().isNotEmpty);
    await _scrollTo(tester, find.textContaining('Выполнить'));
    await _shot(tester, 'SHOT_card'); // карточка поручения с кнопкой «Выполнить»
    await tester.tap(find.textContaining('Выполнить').first);
    await _until(tester, 'экран выполнения',
        () => find.byType(SimpleExecutionScreen).evaluate().isNotEmpty,
        seconds: 90);
    await _settle(tester, frames: 20);
    await _shot(tester, 'SHOT_screen'); // экран без фото: «Выполнено» погашено

    // ===== 3. снимок и комментарий — офлайн =====
    // Снимок кладётся контроллером: камеру на эмуляторе не нажать, а очередь у
    // экранного и этого контроллера одна — экран увидит его, когда откроется заново.
    await c.addPhoto(await _makePhoto('e2e36872'));
    expect(c.hasPhoto, isTrue);
    expect(c.canFinish, isTrue);
    await tester.pageBack(); // назад на карточку
    await _settle(tester);
    await tester.tap(find.textContaining('Выполнить').first);
    await _until(tester, 'экран выполнения со снимком',
        () => find.byType(SimpleExecutionScreen).evaluate().isNotEmpty,
        seconds: 90);
    await _settle(tester, frames: 20);
    // комментарий — руками в поле, как человек
    await tester.enterText(find.byType(TextField).first,
        'Поддоны убраны, проход свободен (E2E $stamp)');
    await _settle(tester);
    await _shot(tester, 'SHOT_photo'); // тот же экран со снимком и комментарием

    // Убрать клавиатуру: пока она поднята, нижняя панель экрана скрыта нарочно —
    // навигация и «Выполнено» под клавиатурой ловят промахи. Кнопка появляется, когда
    // поле теряет фокус, — как и у человека.
    FocusManager.instance.primaryFocus?.unfocus();
    await _until(
        tester,
        'кнопка «Выполнено» после сворачивания клавиатуры',
        () => find.widgetWithText(FilledButton, 'Выполнено').evaluate().isNotEmpty,
        seconds: 60);

    // «Выполнено» — настоящей кнопкой экрана
    await tester.tap(find.widgetWithText(FilledButton, 'Выполнено').first);
    await _untilAsync(tester, 'завершение легло в очередь',
        () async => await repo.db.hasSimpleFinish(uuid),
        seconds: 120);
    await c.load();
    expect(c.finished, isTrue, reason: 'офлайн: закрыто на телефоне');
    expect(await repo.db.getSimpleComment(uuid), isNotNull,
        reason: 'комментарий ждёт отправки вместе с отчётом');
    expect(await repo.db.pendingChanges(), greaterThanOrEqualTo(3),
        reason: 'создание, старт, снимок, комментарий и завершение в очередях');
    debugPrint('E2E_DONE_OFFLINE');

    // ===== 4. связь вернулась: цепочка уходит сама =====
    debugPrint('NET_ON');
    await _untilAsync(tester, 'очереди задачи пусты', () async {
      await repo.syncAndRefresh();
      return !await repo.db.hasSimpleFinish(uuid) &&
          (await repo.db.getPendingSimplePhotos(uuid)).isEmpty &&
          await repo.db.getCreateEntry(uuid) == null;
    }, seconds: 420);

    final info = await repo.api.fetchSimpleInfo(uuid);
    expect(info, isNotNull);
    expect(info!['finished'], isTrue, reason: 'сервер видит выполнение закрытым');
    expect(info['photoCount'], isNotNull, reason: 'снимок доехал');
    expect('${info['comment']}', contains('E2E $stamp'),
        reason: 'комментарий доехал');

    // Сверяем ручками по UUID, а не по списку: успешное выполнение ЗАКРЫВАЕТ задачу
    // (allDone → done), а закрытые apiTasks на телефон не отдаёт вовсе — та же
    // особенность, что описана в демо-наборе #36842. UUID адресует задачу и после
    // закрытия (taskByAnyId).
    debugPrint('E2E_SYNCED=$uuid');
    // комментарий выполнения зеркалится в ленту задачи (onFinish); фото — в её файлы,
    // и вложением того же системного сообщения
    await _untilAsync(tester, 'комментарий и снимок в ленте задачи', () async {
      final comments = await repo.api.fetchTaskComments(uuid);
      return comments.any((x) => (x.text ?? '').contains('E2E $stamp')) &&
          comments.any((x) => x.files.isNotEmpty);
    }, seconds: 300);

    // ===== 5. сервер отвергает завершение без фото — с причиной, а не «успехом» =====
    // корректирующее действие того же вида: экран у него общий с поручением
    if (_corrective.isNotEmpty) {
      final cc = SimpleExecutionController(
          db: repo.db,
          api: repo.api,
          taskId: _corrective,
          geo: repo.geo,
          requirePhotoHint:
              repo.viewOf(_corrective)?.task.requirePhoto == true);
      await cc.load();
      expect(cc.requirePhoto, isTrue);
      // обходим клиентский гвард нарочно: проверяется СЕРВЕРНЫЙ отказ — тот самый,
      // что раньше доезжал до телефона как «выполнено» (молчаливый откат)
      cc.requirePhoto = false;
      expect(await cc.finish(), isFalse, reason: 'сервер обязан отказать');
      expect(cc.finished, isFalse);
      expect(cc.error, contains('фото'),
          reason: 'до человека доезжает причина отказа');
      expect(await repo.db.hasSimpleFinish(_corrective), isFalse);
      cc.dispose();
      debugPrint('E2E_REFUSED ${cc.error}');
    }

    c.dispose();
    debugPrint('ALL_OK_36872');
  });
}
