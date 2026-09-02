// Сквозная приёмка #36840 на живом стенде — запуск внешних приложений с главной.
//
// Что проверяется здесь: секция «Приложения» приехала с сервера и видна на главной;
// тап по отсутствующему приложению даёт внятное «не установлено»; тап по записи с
// шаблоном URI открывает внешний обработчик (Chrome эмулятора) с подставленным
// контекстом; тап по записи с пакетом открывает само приложение. Первая половина
// видна изнутри приложения, вторая — только снаружи: после запуска чужого activity
// наше приложение уходит в фон, и снимает её шелл по маркерам в логе
// (`adb exec-out screencap`), как в прошлых приёмках.
//
// Android 10+ запрещает запуск activity из фонового приложения, поэтому внешний
// запуск в прогоне ровно один — ПОСЛЕДНИМ шагом, и сценарий разбит на два прогона
// параметром E2E_LAUNCH:
//   =portal (по умолчанию) — секция, диалог «не установлено» по ТСД (эмулятор без
//     него), затем тап «Портал»: url_launcher открывает браузер с URI, в котором
//     виден подставленный objectId/login (запись кладёт scripts/demo/testdata.lsf);
//   =tsd — после `adb install` ТСД: тап по нему открывает терминал сбора данных.
//
// Параметры — dart-define: E2E_BASE, E2E_LOGIN/E2E_PASS, E2E_LAUNCH.
// Маркеры: boot:, E2E_READY, SHOT_apps_section, SHOT_not_installed,
// PORTAL_LAUNCHED / TSD_LAUNCHED, ALL_OK_36840.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'support/e2e_harness.dart';

const _login = String.fromEnvironment('E2E_LOGIN', defaultValue: 'demo.user1');
const _launch = String.fromEnvironment('E2E_LAUNCH', defaultValue: 'portal');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('36840: секция приложений на главной и запуск', (tester) async {
    final repo = await bootApp(tester, login: _login);
    await repo.syncAndRefresh();

    // список приложений — данные модуля ExternalApp на стенде: демо-ТСД из
    // loadDefaultData и «Портал» из scripts/demo/testdata.lsf
    await until(tester, 'внешние приложения приехали',
        () => repo.externalApps.isNotEmpty,
        seconds: 60);
    debugPrint('E2E_READY apps=${repo.externalApps.map((a) => a.code).toList()} '
        'objectId=${repo.objectId}');

    // --- секция на главной: она в конце ленты, ListView строит её лениво —
    // прокручиваем, пока заголовок не окажется в кадре
    final list = find.byType(Scrollable).first;
    await tester.dragUntilVisible(
        find.text('Приложения'), list, const Offset(0, -200));
    await settle(tester);
    expect(find.text('Терминал сбора данных'), findsOneWidget);
    await shot(tester, 'SHOT_apps_section');

    if (_launch == 'tsd') {
      // --- прогон 2 (после adb install ТСД): тап открывает сам терминал.
      // Маркер — СРАЗУ после тапа, до первого же pump: наше приложение уже в фоне,
      // его activity на паузе, и pump не вернётся, пока шелл-наблюдатель по этому
      // маркеру не снимет внешний экран и не поднимет приложение обратно
      // (am start). Печатать маркер после ожидания — взаимный тупик: тест ждёт
      // кадров, наблюдатель ждёт маркера (первый прогон так провисел 12 часов).
      await tester.tap(find.text('Терминал сбора данных'),
          warnIfMissed: false);
      debugPrint('TSD_LAUNCHED');
      await settle(tester, frames: 15);
      // мы снова на переднем плане; установленное приложение обязано было
      // открыться: диалог здесь — регресс запуска по пакету (историю про
      // MATCH_DEFAULT_ONLY см. в комментарии _defaultLaunchPackage)
      expect(find.text('Приложение не установлено на этом устройстве.'),
          findsNothing);
      debugPrint('ALL_OK_36840');
      return;
    }

    // --- прогон 1: ТСД на чистом эмуляторе не установлен — тап обязан ответить
    // внятным диалогом, а не молчанием
    await tester.tap(find.text('Терминал сбора данных'), warnIfMissed: false);
    await settle(tester, frames: 15);
    expect(find.text('Приложение не установлено на этом устройстве.'),
        findsOneWidget);
    await shot(tester, 'SHOT_not_installed');
    await tester.tap(find.text('Закрыть'));
    await settle(tester);

    // --- запись с шаблоном URI: тап уводит в браузер, в адресе — подставленный
    // объект и логин. Маркер до первого pump — по той же причине, что в ветке
    // ТСД: приложение уходит в фон, и без возврата (am start наблюдателем по
    // маркеру) пампы не вернутся.
    await tester.tap(find.text('Портал'), warnIfMissed: false);
    debugPrint('PORTAL_LAUNCHED');
    await settle(tester, frames: 15);
    debugPrint('ALL_OK_36840');
  });
}
