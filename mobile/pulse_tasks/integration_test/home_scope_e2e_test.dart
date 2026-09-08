// Сквозная приёмка #37047 на живом стенде (192.168.42.28:8888, sosedi.tech1 у
// «Соседей» в Уручье). Throwaway-драйвер: сеть и координаты крутит внешний шелл по
// маркерам в логе — READY_FOR_AIRPLANE / READY_FOR_NETWORK, а CATALOG_BUMP /
// CATALOG_CLEAN заводят и убирают синтетический объект ZZZ37047 через /eval; тест
// ждёт последствий по состоянию контроллеров.
//
// Сценарий приёмки целиком:
//  1) главная с координатами приносит не весь каталог, а объекты рядом и объекты
//     своих открытых задач — меньше, чем в каталоге, скачанном фоном;
//  2) в авиарежиме лист выбора объекта на главной показывает весь каталог, и объект,
//     которого в ответе главной нет, выбирается;
//  3) со связью следующая главная приносит выбранный объект (objectId), а каталог
//     не перекачивается — версия та же;
//  4) на сервере появился объект — версия сменилась, каталог перекачан; объект
//     убрали — перекачан снова.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pulse_tasks/data/geo.dart';
import 'support/e2e_harness.dart';

const _login = String.fromEnvironment('E2E_LOGIN', defaultValue: 'sosedi.tech1');

/// Объект каталога, которого в ответе главной с координатами быть не должно: далеко
/// от точки прогона и без открытых задач вошедшего.
const _farObject =
    String.fromEnvironment('E2E_FAR_OBJECT', defaultValue: 'SOS-104');

/// Синтетический объект, который шелл заводит по CATALOG_BUMP и убирает по
/// CATALOG_CLEAN.
const _bumpObject = 'ZZZ37047';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('37047: главная по местоположению, каталог фоном', (tester) async {
    final app = await bootApp(tester, login: _login, geoGate: false);

    // прошлый прогон мог оставить выбранным «далёкий» объект — тогда главная
    // честно принесёт его как objectId, и шаг 1 не про то; начинаем с чистого выбора
    if (app.settings.objectId.isNotEmpty) {
      app.settings.objectId = '';
      await app.settings.save();
    }

    // Место — явно, как кнопкой «Обновить местоположение»: учётке без геопривязки
    // гейт не выставляется (на стенде sosedi.tech1 сейчас такая), а сценарию нужны
    // координаты. Разрешение выдаёт оркестратор по маркеру boot: — ждём его, иначе
    // locate() виснет на системном диалоге; поток geo fix мог ещё не доехать до
    // провайдера — пробуем, пока место не определится.
    await untilAsync(
        tester,
        'разрешение геолокации',
        () async => await app.geo.platform.permission() == GeoPermission.granted,
        seconds: 180);
    for (var i = 0; i < 6 && app.location.place.objectId == null; i++) {
      await app.location.locate(fresh: true);
      await settle(tester);
    }
    expect(app.location.place.objectId, isNotNull,
        reason: 'место определено: объект, где стою, известен');
    await app.sync.syncAndRefresh();
    await until(tester, 'каталог скачан фоном',
        () => app.home.catalog.isNotEmpty,
        seconds: 120);
    await until(tester, 'главная с объектами',
        () => app.home.layout.objects.isNotEmpty,
        seconds: 60);

    final homeIds = app.home.layout.objects.map((o) => o.id).toSet();
    final catalogIds = app.home.catalog.map((o) => o.id).toSet();
    final here = app.location.place.objectId;
    debugPrint('E2E_HOME objects=${homeIds.join(',')} '
        'catalog=${catalogIds.length} version=${app.home.catalogVersion} '
        'here=$here');

    // ===== 1. главная — не весь каталог =====
    expect(homeIds.length, lessThan(catalogIds.length),
        reason: 'с координатами apiHome отдаёт меньше объектов, чем в каталоге');
    expect(catalogIds, containsAll(homeIds),
        reason: 'всё, что на главной, есть и в каталоге');
    if (here != null) {
      expect(homeIds, contains(here), reason: 'объект, где стою, — на главной');
    }
    for (final v in app.repo.tasks) {
      final obj = v.task.objectId;
      if (obj != null) {
        expect(homeIds, contains(obj),
            reason: 'объект открытой задачи ${v.id} — на главной');
      }
    }
    expect(homeIds, isNot(contains(_farObject)),
        reason: '$_farObject далеко и без задач — на главной его нет');
    expect(catalogIds, contains(_farObject), reason: 'а в каталоге есть');
    final versionBefore = app.home.catalogVersion;
    await shot(tester, 'SHOT_37047_home');

    // ===== 2. офлайн: выбор из каталога =====
    debugPrint('READY_FOR_AIRPLANE');
    await until(tester, 'авиарежим', () => !app.repo.online, seconds: 240);

    final far = app.home.catalog.firstWhere((o) => o.id == _farObject);
    // полоса объекта над блоками — единственная с этой иконкой на главной
    await tester.tap(find.byIcon(Icons.storefront_outlined).first);
    await settle(tester);
    final tile = find.text(far.name).last;
    await tester.ensureVisible(tile);
    await settle(tester);
    await shot(tester, 'SHOT_37047_picker');
    await tester.tap(tile);
    await settle(tester);
    expect(app.home.objectId, _farObject,
        reason: 'объект вне ответа главной выбран офлайн');
    expect(find.text(far.name), findsWidgets,
        reason: 'полоса показывает выбранный объект');
    await shot(tester, 'SHOT_37047_offline_pick');

    // ===== 3. со связью главная приносит выбранный, каталог не перекачивается =====
    debugPrint('READY_FOR_NETWORK');
    await until(tester, 'сеть', () => app.repo.online, seconds: 240);
    await app.sync.syncAndRefresh();
    await settle(tester);
    expect(app.home.layout.objects.map((o) => o.id), contains(_farObject),
        reason: 'выбранный уходит в apiHome как objectId и возвращается в objects');
    expect(app.home.catalogVersion, versionBefore,
        reason: 'каталог не менялся — версия та же, докачки нет');

    // ===== 4. версия каталога =====
    debugPrint('CATALOG_BUMP'); // шелл заводит ZZZ37047 через /eval
    await untilAsync(tester, 'новый объект в каталоге', () async {
      await app.sync.syncAndRefresh();
      // докачка внутри не awaited — дать ей уехать
      await Future<void>.delayed(const Duration(seconds: 2));
      return app.home.catalog.any((o) => o.id == _bumpObject);
    }, seconds: 120);
    expect(app.home.catalogVersion, isNot(versionBefore));
    debugPrint('E2E_BUMP version=${app.home.catalogVersion}');

    debugPrint('CATALOG_CLEAN'); // шелл убирает ZZZ37047
    await untilAsync(tester, 'объект исчез из каталога', () async {
      await app.sync.syncAndRefresh();
      await Future<void>.delayed(const Duration(seconds: 2));
      return !app.home.catalog.any((o) => o.id == _bumpObject);
    }, seconds: 120);

    // не оставлять телефон на «далёком» объекте
    if (here != null) await app.home.selectObject(here);
    debugPrint('ALL_OK_37047');
  });
}
