// Сквозная приёмка #36844 на живом стенде — сторона исполнителя на эмуляторе.
// Throwaway-драйвер: сеть переключает внешний шелл по маркерам в логе, сторона автора
// (ответ, проверки через ручки) — curl из того же шелла.
//
// Параметры — dart-define: E2E_BASE (адрес стенда), E2E_LOGIN/E2E_PASS (исполнитель),
// E2E_TASK (ST-номер задачи, назначенной на него, с автором-человеком).
//
// Сценарий приёмки («Готово когда»):
//  1) стоя без сети, исполнитель пишет комментарий с фотографией — в ленте сразу, с
//     пометкой; при возврате связи уходит ОДИН раз (шелл сверяет по clientId в
//     apiTaskComments автора и уведомление автора в apiNotifications);
//  2) автор отвечает (шелл, curl) — у исполнителя на карточке непрочитанное, ответ
//     виден в ленте, открытие ленты гасит бейдж (шелл сверяет unreadComments=0 в
//     apiTasks исполнителя).
//
// Маркеры: E2E_READY, NET_OFF, E2E_COMMENT=<clientId>, NET_ON, E2E_SYNCED,
// E2E_WAIT_REPLY (шелл шлёт ответ автора), E2E_REPLY_SEEN, E2E_READ, ALL_OK_36844.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pulse_tasks/data/comment_controller.dart';
import 'package:pulse_tasks/ui/task_detail_screen.dart';
import 'package:pulse_tasks/ui/widgets/task_card.dart';
import 'support/e2e_harness.dart';

const _login = String.fromEnvironment('E2E_LOGIN', defaultValue: 'sosedi.tech1');
const _task = String.fromEnvironment('E2E_TASK');

/// Снимок «с места» — 64×64 PNG, собранный на устройстве без ассетов и камеры:
/// приёмке важен факт вложения и его дорога, а не содержимое кадра.
Future<String> _makePhoto() async {
  const w = 64, h = 64;
  final raw = BytesBuilder();
  for (var y = 0; y < h; y++) {
    raw.addByte(0); // filter: none
    for (var x = 0; x < w; x++) {
      raw.add([x * 4, y * 4, 128]);
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
  final f = File('${dir.path}/e2e36844.png');
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

/// Вертикальный список экрана: `find.byType(Scrollable).first` на списке задач — это
/// горизонтальная лента чипов-фильтров (грабли #36836), поэтому — по направлению.
Finder _verticalList() => find.byWidgetPredicate(
    (w) => w is Scrollable && w.axisDirection == AxisDirection.down);

/// Прокрутить вертикальный список до виджета (finder'ы внизу ленивого ListView не
/// существуют, пока не докрутишь).
Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 30 && finder.evaluate().isEmpty; i++) {
    await tester.drag(_verticalList().first, const Offset(0, -300));
    await settle(tester, frames: 3);
  }
  expect(finder, findsWidgets);
  await tester.ensureVisible(finder.first);
  await settle(tester, frames: 3);
}

/// Карточка нашей задачи в списке — по подписи (тип · название), объект у соседних
/// задач тот же.
Finder _ourCard() => find.ancestor(
    of: find.textContaining('36844: дверь подсобки'),
    matching: find.byType(TaskCard));

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('36844: переписка по задаче — офлайн, один раз, непрочитанное',
      (tester) async {
    expect(_task, isNotEmpty, reason: 'нужен --dart-define=E2E_TASK=ST...');
    final repo = await bootApp(tester, login: _login);

    await repo.syncAndRefresh();
    await until(tester, 'задача $_task в списке',
        () => repo.viewOf(_task) != null, seconds: 120);
    final key = repo.viewOf(_task)!.task.clientId ?? _task;
    final before = repo.viewOf(_task)!.commentCount;
    debugPrint('E2E_READY count=$before');

    // ===== 1. без сети: комментарий с фото =====
    debugPrint('NET_OFF');
    await until(tester, 'авиарежим', () => !repo.online, seconds: 240);

    // лента — настоящим контроллером секции (экран передаёт то же самое)
    final c = TaskCommentsController(db: repo.db, api: repo.api, taskId: key);
    await c.load();
    expect(c.online, isFalse);
    final text = '36844 дверь подсобки закрыта, ключа нет '
        '${DateTime.now().millisecondsSinceEpoch % 100000}';
    await c.send(text, photoPath: await _makePhoto());
    await c.syncAll(); // присоединиться к отправке, упёршейся в «нет сети»
    final mine = c.items.where((x) => x.pending).toList();
    expect(mine, hasLength(1), reason: 'в ленте сразу, с пометкой');
    expect(mine.single.photoPath, isNotNull);
    final clientId = mine.single.clientId!;
    debugPrint('E2E_COMMENT=$clientId');
    await repo.reloadLocal();
    expect(repo.viewOf(_task)!.commentCount, before + 1,
        reason: 'счётчик карточки учитывает неотправленное');
    expect(await repo.db.pendingChanges(), greaterThanOrEqualTo(1));

    // и на экране: открыть карточку нашей задачи из списка, докрутить до ленты
    await tester.tap(find.textContaining('Все').first);
    await settle(tester);
    await _scrollTo(tester, _ourCard());
    await tester.tap(_ourCard().first);
    await until(tester, 'деталка',
        () => find.byType(TaskDetailScreen).evaluate().isNotEmpty);
    await _scrollTo(tester, find.text('Комментарии'));
    await _scrollTo(tester, find.textContaining('не отправлено'));
    debugPrint('UI_PENDING_SEEN');
    await shot(tester, 'SHOT_pending'); // лента с неотправленным сообщением
    await tester.pageBack();
    await settle(tester);
    await tester.pageBack(); // и со списка — на главную
    await settle(tester);

    // ===== 2. связь вернулась: уходит один раз =====
    debugPrint('NET_ON');
    await untilAsync(tester, 'очередь сообщений пуста', () async {
      await repo.syncAndRefresh();
      return (await repo.db.getAllCommentOutbox()).isEmpty;
    }, seconds: 300);
    await c.load();
    expect(c.items.where((x) => x.clientId == clientId), hasLength(1),
        reason: 'ровно одно сообщение с нашим ключом — не задвоилось');
    expect(c.items.where((x) => x.clientId == clientId).single.pending, isFalse);
    expect(c.items.where((x) => x.clientId == clientId).single.files,
        isNotEmpty,
        reason: 'вложение доехало и вернулось файлом');
    debugPrint('E2E_SYNCED');

    // ===== 3. автор отвечает (шелл) — непрочитанное на карточке =====
    debugPrint('E2E_WAIT_REPLY');
    await untilAsync(tester, 'ответ автора в apiTasks', () async {
      await repo.syncAndRefresh();
      return repo.viewOf(_task)!.unreadComments >= 1;
    }, seconds: 300);
    debugPrint('E2E_REPLY_SEEN unread=${repo.viewOf(_task)!.unreadComments}');

    // бейдж на карточке в списке
    await tester.tap(find.textContaining('Все').first);
    await settle(tester);
    await _scrollTo(tester, _ourCard());
    expect(
        find.descendant(
            of: _ourCard(), matching: find.textContaining('ново')),
        findsWidgets,
        reason: 'карточка помечена «N новое/новых»');
    await shot(tester, 'SHOT_badge'); // карточка с «1 новое»
    // открыть ленту — прочитано, бейдж гаснет
    await tester.tap(_ourCard().first);
    await until(tester, 'деталка',
        () => find.byType(TaskDetailScreen).evaluate().isNotEmpty);
    await _scrollTo(tester, find.text('Комментарии'));
    await _scrollTo(tester, find.textContaining('возьми на вахте'));
    await until(tester, 'лента прочитана (бейдж 0)',
        () => repo.viewOf(_task)!.unreadComments == 0, seconds: 120);
    await shot(tester, 'SHOT_thread'); // лента с ответом автора
    await untilAsync(tester, 'отметка ушла на сервер',
        () async => (await repo.db.getPendingCommentReads()).isEmpty,
        seconds: 120);
    debugPrint('E2E_READ');
    c.dispose();
    debugPrint('ALL_OK_36844');
  });
}
