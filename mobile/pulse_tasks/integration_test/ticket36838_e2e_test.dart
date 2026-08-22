// Сквозная приёмка #36838 на живом стенде (192.168.42.28:8888, sosedi.tech1).
// Throwaway-драйвер: сеть и геолокацию переключает внешний шелл по маркерам в логе,
// сервер после прогона сверяется снаружи (/eval EXPORT по UUID из маркеров) — ручки
// чтения этих свойств у мобильного API нет и не нужно.
//
// Сценарии приёмки:
//  1) самолётный режим: задача создана и завершена у витрины в Уручье без сети;
//     перед возвратом сети геолокация выключается ВОВСЕ («устройство нигде» —
//     жёстче, чем «в другом городе»: у дожима нет никакого текущего места, откуда
//     координаты можно было бы подменить) — на сервере обе точки обязаны быть
//     уручскими, а времена — моментов действия, не дожима;
//  2) GPS не берёт: при всё ещё выключенной геолокации задача проходит цикл
//     онлайн, закрывается штатно, на сервере времена есть, координат нет.
//
// Физический «переезд» между городами эмулятором не играется: после NET_OFF
// fused перестаёт принимать `emu geo fix` (нет сетевого подписчика), а суть
// приёмки от него и не зависит — координаты дожима по построению идут из очереди.
//
// Маркеры для шелла: GEO_MOVE=<lon> <lat> → слать `adb emu geo fix` потоком до
// GEO_OK; NET_OFF / NET_ON → svc wifi|data disable/enable; LOC_OFF / LOC_ON →
// settings put secure location_mode 0/3; E2E_TASK=<uuid>, E2E_TASK2=<uuid> — кого
// сверять на сервере; ALL_OK_36838 — клиентская часть приёмки пройдена.
//
// ПЕРЕД запуском: `adb shell pm grant com.mycompany.pulse_tasks
// android.permission.ACCESS_FINE_LOCATION` (и COARSE) — переустановка стирает
// grant, а без него locate() повисает на системном диалоге разрешения.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:pulse_tasks/data/fill_controller.dart';
import 'package:pulse_tasks/data/geo.dart';
import 'package:pulse_tasks/data/task_repository.dart';
import 'package:pulse_tasks/main.dart' as app;

const _uruchie = (id: 'SOS-103', lat: 53.941, lon: 27.672); // «Соседи» в Уручье

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
    if (DateTime.now().isAfter(deadline)) {
      fail('не дождались: $what');
    }
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
    if (DateTime.now().isAfter(deadline)) {
      fail('не дождались: $what');
    }
    await tester.pump(const Duration(milliseconds: 400));
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }
  await _settle(tester);
}

/// Довезти УСТРОЙСТВО до точки — по самому устройству, не по месту в репозитории:
/// в самолётном режиме apiNearbyObjects мёртв и place не сменится, а для тикета
/// важно ровно то, где физически стоит телефон в момент действия.
Future<void> _moveDevice(WidgetTester tester, Geo geo,
    ({String id, double lat, double lon}) target) async {
  debugPrint('GEO_MOVE=${target.lon} ${target.lat}');
  final deadline = DateTime.now().add(const Duration(seconds: 240));
  while (true) {
    final o = await geo.locate(fresh: true);
    // видимый след каждой попытки: «фиксы не доезжают» и «нет разрешения» — разные
    // поломки эмулятора, и без этой строки они неразличимы в логе упавшего прогона
    debugPrint(o is GeoFix
        ? 'geo: ${o.latitude} ${o.longitude}'
        : 'geo: unavailable ($o)');
    if (o is GeoFix &&
        (o.latitude - target.lat).abs() < 0.005 &&
        (o.longitude - target.lon).abs() < 0.005) {
      break;
    }
    if (DateTime.now().isAfter(deadline)) {
      fail('устройство не доехало до ${target.id}');
    }
    await tester.pump(const Duration(milliseconds: 400));
    await Future<void>.delayed(const Duration(seconds: 2));
  }
  debugPrint('GEO_OK ${target.id}');
  await _settle(tester);
}

/// Заполнить бланк showcase до годного к завершению состояния (clean=ok — без
/// несоответствия, чтобы не требовалось фото; temp — обязательное число).
Future<void> _fillShowcase(FillController c) async {
  final clean = c.fields.firstWhere((f) => f.code == 'clean');
  await c.setOption(clean, 'ok');
  await c.setNumber(c.fields.firstWhere((f) => f.code == 'temp'), 5);
  if (c.resolutionRequired) await c.setResolution('done');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('36838: координаты начала и завершения — в саму задачу',
      (tester) async {
    app.main();
    await _until(tester, 'первый кадр приложения',
        () => find.byType(MaterialApp).evaluate().isNotEmpty,
        seconds: 90);

    final ctx = tester.element(find.byType(MaterialApp).first);
    final repo = Provider.of<TaskRepository>(ctx, listen: false);

    // --- вход, если переустановка снесла настройки/сессию (Keystore-грабли) ---
    debugPrint('boot: configured=${repo.settings.isConfigured} '
        'active=${repo.session.isActive} login="${repo.session.login}"');
    if (repo.session.isActive && repo.session.login != 'sosedi.tech1') {
      await repo.signOut();
      await _settle(tester);
    }
    if (!repo.settings.isConfigured) {
      await tester.enterText(
          find.byType(TextField).first, 'http://192.168.42.28:8888');
      await _settle(tester);
      await tester.tap(find.text('Сохранить'));
      await _settle(tester);
    }
    if (!repo.session.isActive) {
      final fields = find.byType(TextField);
      expect(fields, findsWidgets, reason: 'ни сессии, ни формы входа');
      await tester.enterText(fields.at(0), 'sosedi.tech1');
      await tester.enterText(fields.at(1), 'demo');
      await _settle(tester);
      await tester.tap(find.text('Войти'));
      await _until(tester, 'вход', () => repo.session.isActive, seconds: 90);
    }

    // ===== подготовка на связи: встать в Уручье, пресеты — в кэш =====
    await _moveDevice(tester, repo.geo, _uruchie);
    await repo.locate(fresh: true);
    await _until(tester, 'место = Уручье',
        () => repo.place.objectId == _uruchie.id, seconds: 120);
    await repo.syncAndRefresh();
    await _until(tester, 'пресеты в кэше',
        () => repo.quickCreate.actions.isNotEmpty, seconds: 90);
    final sudden = repo.quickCreate.actions
        .firstWhere((a) => a.templateCode != null && a.assign == 'self');

    // ===== сценарий 1: самолётный режим у витрины =====
    debugPrint('NET_OFF');
    await _until(tester, 'авиарежим', () => !repo.online, seconds: 240);

    final name1 =
        '36838 самолётный ${DateTime.now().millisecondsSinceEpoch % 100000}';
    final uuid1 = await repo.createTask(
      typeId: sudden.typeId!,
      templateCode: sudden.templateCode,
      priorityId: sudden.priorityId,
      requirePhoto: sudden.requirePhoto,
      objectId: _uruchie.id,
      objectName: '«Соседи» в Уручье',
      name: name1,
    );
    debugPrint('E2E_TASK=$uuid1');

    // бланк — headless-контроллером, ровно как экран (fill_screen передаёт то же)
    final c1 = FillController(
        db: repo.db, api: repo.api, taskId: uuid1, geo: repo.geo);
    await c1.load();
    expect(c1.fields, isNotEmpty, reason: 'бланк посеян из шаблона');
    await _fillShowcase(c1);
    expect(await c1.finish(), isTrue,
        reason: 'офлайн-завершение обязано стать в очередь');
    c1.dispose();

    // ===== «через час», устройство «нигде»: сеть возвращается =====
    // геолокация гаснет ДО сети: у дожима нет текущего места — точки в задаче
    // могли приехать только из очереди
    debugPrint('LOC_OFF');
    await _untilAsync(tester, 'геолокация выключена',
        () async => await repo.geo.locate(fresh: true) is GeoUnavailable,
        seconds: 120);
    debugPrint('NET_ON');
    await _untilAsync(tester, 'очереди опустели',
        () async => await repo.db.pendingChanges() == 0,
        seconds: 300);
    debugPrint('SCENARIO1_SYNCED');

    // ===== сценарий 2: GPS не берёт (онлайн, геолокация всё ещё выключена) =====

    final name2 =
        '36838 без GPS ${DateTime.now().millisecondsSinceEpoch % 100000}';
    final uuid2 = await repo.createTask(
      typeId: sudden.typeId!,
      templateCode: sudden.templateCode,
      priorityId: sudden.priorityId,
      requirePhoto: sudden.requirePhoto,
      objectId: _uruchie.id,
      objectName: '«Соседи» в Уручье',
      name: name2,
    );
    debugPrint('E2E_TASK2=$uuid2');

    final c2 = FillController(
        db: repo.db, api: repo.api, taskId: uuid2, geo: repo.geo);
    await c2.load();
    expect(c2.fields, isNotEmpty);
    await _fillShowcase(c2);
    expect(await c2.finish(), isTrue,
        reason: 'отсутствие координат не блокирует завершение');
    c2.dispose();

    await _untilAsync(tester, 'вторая задача дожата',
        () async => await repo.db.pendingChanges() == 0,
        seconds: 300);

    debugPrint('LOC_ON');
    debugPrint('ALL_OK_36838');
  });
}
