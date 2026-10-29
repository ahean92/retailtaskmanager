import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:pulse_tasks/app_controllers.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/password_hash.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/main.dart';
import 'package:pulse_tasks/ui/brand.dart';
import 'package:pulse_tasks/ui/theme.dart';

import 'support/test_env.dart';

/// Стирание «Выйти и удалить данные» на настоящем корне приложения: вошедший
/// без сети человек, реальная база, реальное удаление файлов — и в конце
/// обязана стоять форма входа, а не пустой экран. Гонку двойного закрытия
/// диалога (чёрный экран 29.10) здесь ловит отдельный тест в
/// profile_exit_test; этот охраняет весь путь стирания целиком.
void main() {
  initTestEnv();

  setUp(() async {
    resetMockStores();
    // удаление фото при выходе идёт в документы телефона — в тесте это tmp-папка
    PathProviderPlatform.instance = _Docs();
    Wms.brand = Brand.pulse;
    await Wms.setMode(ThemeMode.light);
  });

  testWidgets('выход с удалением данных не оставляет пустой экран',
      (tester) async {
    // высокий экран: обе строки выхода стоят внизу длинного профиля.
    // pump, а не pumpAndSettle: живой синк офлайн-приложения ретраится по
    // таймеру бесконечно, settle не наступит никогда
    tester.view.physicalSize = const Size(390, 1700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // вошедший без сети человек на настоящих контроллерах и настоящей базе —
    // как в offline_identity_test; логин уникален, ffi-файл переживает прогон
    final login = 'wipe${DateTime.now().microsecondsSinceEpoch}';
    // хэш — через compute(), а compute в testWidgets живёт только в runAsync
    final passwordHash = await tester
        .runAsync(() => PasswordHash.create('secret')) as String;
    final session = Session(
      login: login,
      password: 'secret',
      passwordHash: passwordHash,
      name: 'Иванов И.И.',
      performerId: 'p1',
      lastContact: DateTime.now(), // окно входа без сети открыто
    );
    final settings = Settings(baseUrl: 'http://test.local:9080');
    final api = ApiClient(settings, session,
        client:
            MockClient((_) async => throw const SocketException('нет сети')));
    final app = AppControllers(api: api, settings: settings, session: session);
    // runAsync: настоящий ffi-sqlite и файловый IO не завершаются под
    // фейковыми часами биндинга — известная ловушка testWidgets
    await tester.runAsync(() async {
      await app.account.signIn(login, 'secret');
    });

    await tester.pumpWidget(PulseApp(app: app));
    await tester.pump(const Duration(milliseconds: 300));
    // вкладка «Профиль» — .last: навигационная подпись стоит ниже заголовка
    // самой вкладки, если обе построены
    await tester.tap(find.text('Профиль').last);
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('Выйти и удалить данные'));
    // unsentChanges перед вопросом — настоящий ffi-запрос, ему нужно окно IO
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(find.text('Удалить и выйти'));
    // чередуем кадры с окнами настоящего IO: стирание закрывает базу и удаляет
    // файлы — это настоящий IO, ему нужны runAsync-окна
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
    }
    await tester.pump(const Duration(milliseconds: 300));

    final exception = tester.takeException();
    expect(exception, isNull,
        reason: 'сборка после стирания бросила (стек выше)');
    expect(find.text('Войти'), findsOneWidget,
        reason: 'после стирания должна быть форма входа, а не пустой экран');
  }, timeout: const Timeout(Duration(seconds: 15)));
}

class _Docs extends PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async =>
      (await Directory.systemTemp.createTemp('wipe_docs')).path;
}
