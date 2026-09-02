// Сквозная приёмка #36841 на живом стенде — поле-ссылка на справочник хоста
// («Ознакомлен — ФИО» из сотрудников магазина).
//
// Параметры — dart-define: E2E_BASE (адрес стенда), E2E_LOGIN/E2E_PASS (исполнитель),
// E2E_TASK (ST-номер бланочной задачи, в шаблоне которой есть поле-ссылка с каналом
// 'employee' — заводится на стенде перед прогоном).
//
// Сценарий приёмки («Готово когда» тикета):
//  1) НА СВЯЗИ бланк открывается, поле-ссылка приезжает с каналом 'employee', и
//     кандидаты («сотрудники этого магазина») кэшируются вместе с бланком;
//  2) поиск по фамилии работает серверной ручкой (догрузка при связи);
//  3) БЕЗ СЕТИ пикер предлагает кандидатов из кэша, ищется по фамилии, выбор ложится
//     в очередь — «заполняется офлайн»;
//  4) связь вернулась — значение уезжает само; сервер показывает и ссылку (refId), и
//     ФИО-снимок (ref) в apiExecutionFields;
//  5) свободный ввод (если поле его разрешает): текст без ссылки доезжает как снимок
//     без refId — подписать может тот, кого в справочнике нет.
// Печатная форма и карточка заполнения (десктоп) сверяются вне этого теста, на вебе.
//
// Маркеры: boot:, E2E_READY, E2E_CANDIDATES=<n>, NET_OFF, SHOT_picker, SHOT_field,
// E2E_PICKED=<id>, NET_ON, E2E_SYNCED, E2E_FREE_OK | E2E_FREE_SKIPPED, ALL_OK_36841.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pulse_tasks/data/fill_controller.dart';
import 'package:pulse_tasks/data/geo.dart';
import 'package:pulse_tasks/data/task_repository.dart';
import 'package:pulse_tasks/models/fill.dart';
import 'package:pulse_tasks/ui/fill_screen.dart';
import 'package:pulse_tasks/ui/widgets/fill_field_tile.dart';
import 'support/e2e_harness.dart';

const _login = String.fromEnvironment('E2E_LOGIN', defaultValue: 'sosedi.tech1');
const _task = String.fromEnvironment('E2E_TASK', defaultValue: '');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('36841: поле-ссылка — сотрудники магазина, поиск и офлайн',
      (tester) async {
    expect(_task, isNotEmpty,
        reason: 'нужен E2E_TASK — ST-номер задачи с полем-ссылкой');

    final repo = await bootApp(tester, login: _login);
    // База пользователя открывается асинхронно ПОСЛЕ того, как session.isActive стал
    // true, — обращение к repo.db сразу за входом кидает «nobody is signed in»
    // (поймано 6-м прогоном; старые e2e выигрывали эту гонку за счёт лишней работы
    // между входом и первым обращением к базе).
    await untilAsync(tester, 'база пользователя открыта', () async {
      try {
        repo.db;
        return true;
      } catch (_) {
        return false;
      }
    }, seconds: 60);
    // разрешение геолокации выдаёт оркестратор по маркеру boot: — иначе locate()
    // виснет на системном диалоге (грабли #36838)
    if (!repo.geoReady) {
      await untilAsync(
          tester,
          'разрешение геолокации',
          () async =>
              await repo.geo.platform.permission() == GeoPermission.granted,
          seconds: 180);
      await repo.locate(fresh: true);
      await until(tester, 'гео-гейт', () => repo.geoReady, seconds: 120);
    }
    await repo.syncAndRefresh();

    // ===== 1. на связи: бланк с каналом, кандидаты в кэше =====
    final c = FillController(
        db: repo.db, api: repo.api, taskId: _task, geo: repo.geo);
    await c.load();
    expect(c.online, isTrue, reason: 'подготовка идёт на связи');
    expect(c.fields, isNotEmpty, reason: 'бланк приехал');
    final FillField ref = c.fields.firstWhere(
        (f) => f.type == 'objectref' && f.refKind == 'employee',
        orElse: () =>
            fail('в шаблоне задачи $_task нет поля-ссылки с каналом employee'));
    final cached = c.subjectsByField[ref.code] ?? const <RefCandidate>[];
    expect(cached, isNotEmpty,
        reason: 'кандидаты канала кэшируются вместе с бланком');
    debugPrint('E2E_CANDIDATES=${cached.length}');

    // ===== 2. поиск по фамилии — серверной ручкой =====
    // фамилия — первое слово ФИО первого кандидата: тест не привязан к данным стенда
    final target = cached.first;
    final surname = target.name.split(' ').first;
    final found = await c.searchSubjects(ref, surname);
    expect(found.map((x) => x.id), contains(target.id),
        reason: 'серверный поиск по «$surname» обязан найти $target');
    debugPrint('E2E_READY field=${ref.code} target=${target.id} q=$surname');

    // ===== 3. без сети: пикер из кэша, выбор ложится в очередь =====
    debugPrint('NET_OFF');
    await untilAsync(tester, 'авиарежим',
        () async => !(await _probe(repo)), seconds: 240);

    // экран бланка — настоящий, поверх кэша, записанного шагом 1. Навигатором, а не
    // Navigator.of(контекст MaterialApp): Navigator живёт ВНУТРИ MaterialApp, и поиск
    // вверх от него самого никого не находит (первый прогон, дубль 2)
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    nav.push(
        MaterialPageRoute(builder: (_) => const FillScreen(taskId: _task)));
    await until(tester, 'экран бланка',
        () => find.byType(FillScreen).evaluate().isNotEmpty, seconds: 90);
    await settle(tester, frames: 20);

    // заголовок плитки — «№. Название», поэтому по вхождению, а не точному тексту
    await pageTo(tester, find.textContaining(ref.name ?? ref.code));
    // пустое поле зовёт выбирать; заполненное показывает ФИО — оба открывают пикер
    final opener = find.text('Выбрать…').evaluate().isNotEmpty
        ? find.text('Выбрать…')
        : find.text(ref.refName ?? 'Выбрать…');
    await tester.ensureVisible(opener.first);
    await settle(tester, frames: 3);
    await tester.tap(opener.first);
    await until(tester, 'пикер предметов',
        () => find.byType(RefPickerSheet).evaluate().isNotEmpty, seconds: 60);
    await settle(tester, frames: 10);

    // ищется по фамилии — офлайн, по кэшу бланка
    await tester.enterText(
        find.descendant(
            of: find.byType(RefPickerSheet), matching: find.byType(TextField)),
        surname);
    await settle(tester, frames: 12); // дебаунс пикера — 300 мс
    await until(
        tester,
        'кандидат «${target.name}» в пикере офлайн',
        () => find
            .descendant(
                of: find.byType(RefPickerSheet),
                matching: find.text(target.name))
            .evaluate()
            .isNotEmpty,
        seconds: 30);
    await shot(tester, 'SHOT_picker'); // пикер: поиск по фамилии, кандидаты
    await tester.tap(find
        .descendant(
            of: find.byType(RefPickerSheet), matching: find.text(target.name))
        .first);
    await until(tester, 'пикер закрыт',
        () => find.byType(RefPickerSheet).evaluate().isEmpty, seconds: 30);
    await settle(tester, frames: 10);

    // значение на плитке и в очереди
    expect(find.text(target.name), findsWidgets,
        reason: 'выбранное ФИО видно на бланке');
    await shot(tester, 'SHOT_field'); // поле заполнено офлайн
    final queued = await repo.db.getFieldOutbox(_task);
    final row = queued.firstWhere((e) => e['fieldCode'] == ref.code,
        orElse: () => fail('выбор не лёг в очередь поля'));
    expect(row['refId'], target.id);
    expect(row['refName'], target.name);
    debugPrint('E2E_PICKED=${target.id}');

    // ===== 4. связь вернулась: значение уезжает, сервер держит ссылку и снимок =====
    debugPrint('NET_ON');
    await untilAsync(tester, 'очередь поля пуста', () async {
      await repo.syncAndRefresh();
      final ob = await repo.db.getFieldOutbox(_task);
      return ob.every((e) => e['fieldCode'] != ref.code);
    }, seconds: 420);

    var server = await _serverField(repo, ref.code);
    expect(server['refId'], target.id, reason: 'ссылка доехала');
    expect('${server['ref']}', target.name, reason: 'ФИО-снимок доехал');
    debugPrint('E2E_SYNCED');

    // ===== 5. свободный ввод — тот, кого в справочнике нет =====
    if (ref.allowFreeSubject) {
      final stamp = DateTime.now().millisecondsSinceEpoch % 100000;
      final freeName = 'Стажёр Смирнова (E2E $stamp)';
      await c.setRef(ref, name: freeName);
      await untilAsync(tester, 'свободный ввод дожат', () async {
        await c.syncAll();
        final ob = await repo.db.getFieldOutbox(_task);
        return ob.every((e) => e['fieldCode'] != ref.code);
      }, seconds: 120);
      server = await _serverField(repo, ref.code);
      expect(server['refId'], isNull,
          reason: 'свободный текст — снимок без ссылки');
      expect('${server['ref']}', contains('$stamp'));
      debugPrint('E2E_FREE_OK');
    } else {
      debugPrint('E2E_FREE_SKIPPED (allowFreeSubject выключен у поля)');
    }

    c.dispose();
    debugPrint('ALL_OK_36841');
  });
}

/// Жив ли сервер — лёгкий запрос вместо чтения repo.online: тот обновляется только
/// проходом синка, а тесту нужен факт «сеть уже отрезана» сам по себе.
Future<bool> _probe(TaskRepository repo) async {
  try {
    await repo.api.fetchStatuses();
    return true;
  } catch (_) {
    return false;
  }
}

/// Поле бланка глазами сервера (apiExecutionFields) — по коду.
Future<Map<String, dynamic>> _serverField(
    TaskRepository repo, String code) async {
  final raw = await repo.api.fetchExecutionFields(_task);
  return raw.firstWhere((m) => m['code'] == code,
      orElse: () => fail('сервер не отдал поле $code'));
}
