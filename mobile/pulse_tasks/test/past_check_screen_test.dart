import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_tasks/ui/past_check_screen.dart';

import 'support/app_host.dart';
import 'support/fake_pulse_server.dart';
import 'support/test_env.dart';

/// Просмотр прошлой проверки на общем сервере, с карточки объекта: шапка с итогом,
/// ответы и примечания на чтение, разделы листаются; без связи — та же проверка из
/// кэша с предупреждением; объект, который ещё не проверяли, говорит об этом, а не
/// показывает пустой экран.

const _object = 'ZZZE2E';

void main() {
  initTestEnv();
  late FakePulseServer srv;

  setUp(() {
    resetMockStores();
    srv = FakePulseServer();
  });

  testWidgets('проверка объекта: шапка, ответы, разделы; без связи — из кэша',
      (t) async {
    await t.runAsync(() async {
      srv.pastByObject[_object] = FakeFill.recorded('apiExecutionBundle_filled')
        ..finished = true;
      final app = await appOf(srv.api, srv.settings, srv.session);

      await t.pumpWidget(host(app, const PastCheckScreen.forObject(_object)));
      await until(t, () => find.text('ZZZ E2E объект').evaluate().isNotEmpty,
          reason: 'шапка проверки загрузилась');
      expect(find.text('ZZZ E2E типы'), findsOneWidget, reason: 'шаблон');
      expect(find.textContaining('Проверено 15.01'), findsOneWidget,
          reason: 'дата проверки обязательна');
      expect(find.text('Раздел 1 из 2'), findsOneWidget);
      expect(find.text('текст'), findsOneWidget, reason: 'ответ на чтение');
      await scrollTo(t, find.text('примечание'));
      expect(find.text('примечание'), findsOneWidget,
          reason: 'примечание к баллу видно');

      await t.tap(find.text('Далее'));
      await until(t, () => find.text('Раздел 2 из 2').evaluate().isNotEmpty,
          reason: 'второй раздел открылся');
      expect(find.text('ZZZ таблица'), findsWidgets);
      await closeScreen(t);

      // связь пропала — просмотр открывается из того, что успел забрать
      srv.offline = true;
      await t.pumpWidget(host(app, const PastCheckScreen.forObject(_object)));
      await until(t, () => find.text('ZZZ E2E объект').evaluate().isNotEmpty,
          reason: 'проверка из кэша');
      expect(find.textContaining('Офлайн — показана сохранённая проверка'),
          findsOneWidget);
      await closeScreen(t);
      app.dispose();
    });
  });

  testWidgets('объект без проверок — «ещё не было», а не пустота', (t) async {
    await t.runAsync(() async {
      final app = await appOf(srv.api, srv.settings, srv.session);
      await t.pumpWidget(host(app, const PastCheckScreen.forObject(_object)));
      await until(
          t,
          () => find
              .text('Прошлых проверок здесь ещё не было')
              .evaluate()
              .isNotEmpty,
          reason: 'ответ «выполнения нет» прочитан как «проверок не было»');
      await closeScreen(t);
      app.dispose();
    });
  });
}
