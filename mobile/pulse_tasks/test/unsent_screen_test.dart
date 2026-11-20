import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_tasks/ui/unsent_screen.dart';
import 'package:pulse_tasks/ui/widgets/ds.dart';

import 'support/app_host.dart';
import 'support/fake_pulse_server.dart';
import 'support/test_env.dart';

/// Экран «Не отправлено» на общем сервере: человек в поле отвечает себе на вопрос
/// «я заполнил — оно ушло или нет?». Ответ бланка, набранный без связи, виден
/// операцией с именем задачи и уходит по «Отправить сейчас» с видимым итогом; отказ
/// сервера стоит у своей операции его словами, и такую операцию можно убрать из
/// очереди — сама она не уедет никогда.

const _task = 'ZZZ-E2E-TYPES';

void main() {
  initTestEnv();
  late FakePulseServer srv;

  setUp(() {
    resetMockStores();
    srv = FakePulseServer();
  });

  testWidgets('ответ без связи — операцией с именем задачи; «Отправить сейчас» '
      'отправляет и говорит итог', (t) async {
    await t.runAsync(() async {
      srv.fills[_task] =
          FakeFill.recorded('apiExecutionBundle_filled', blank: true);
      final app = await appOf(srv.api, srv.settings, srv.session);
      await app.repo.db.fill.enqueueField(_task, 't1',
          type: 'text',
          text: 'витрина в порядке',
          createdAtIso: '2026-11-20T09:00:00');
      await app.repo.reloadLocal();

      await t.pumpWidget(host(app, const UnsentScreen()));
      await settle(t);
      expect(find.text('Бланк: 1 ответ'), findsOneWidget);
      expect(find.text('ZZZ E2E типы'), findsOneWidget,
          reason: 'операция зовётся именем задачи из списка сервера');
      expect(find.text('1 действие ждёт связи с сервером'), findsOneWidget);

      await t.tap(find.text('Отправить сейчас'));
      await until(t, () => find.byType(DsBanner).evaluate().isNotEmpty,
          reason: 'итог отправки показан плашкой');
      expect(find.text('Бланк: 1 ответ'), findsNothing,
          reason: 'уехавшая операция уходит из списка');
      expect(find.text('Всё отправлено'), findsWidgets);
      expect(srv.fills[_task]!.field('t1')['text'], 'витрина в порядке',
          reason: 'ответ дошёл до сервера');

      await closeScreen(t);
      app.dispose();
    });
  });

  testWidgets('отказ сервера — причиной у операции; «Убрать из очереди» убирает её '
      'после подтверждения', (t) async {
    await t.runAsync(() async {
      // бланк завершили на другом устройстве: запись в него сервер отклоняет
      srv.fills[_task] = FakeFill.recorded('apiExecutionBundle_filled')
        ..finished = true;
      final app = await appOf(srv.api, srv.settings, srv.session);
      final db = app.repo.db;
      await db.fill.enqueueField(_task, 't1',
          type: 'text', text: 'поздно', createdAtIso: '2026-11-20T09:00:00');
      await app.repo.reloadLocal();

      await t.pumpWidget(host(app, const UnsentScreen()));
      await settle(t);
      await t.tap(find.text('Отправить сейчас'));
      await until(
          t,
          () => find
              .text('Отправить не удалось — причины в списке')
              .evaluate()
              .isNotEmpty,
          reason: 'неудача отправки показана плашкой');
      expect(find.textContaining('Execution already finished'), findsOneWidget,
          reason: 'причина — словами сервера, у своей операции');
      expect(srv.postsOf('apiSetField'), isEmpty);

      await t.tap(find.byTooltip('Убрать из очереди'));
      await settle(t, 4);
      expect(find.text('Убрать из очереди?'), findsOneWidget);
      await t.tap(find.text('Убрать'));
      await until(t, () => find.text('Бланк: 1 ответ').evaluate().isEmpty,
          reason: 'убранная операция ушла с экрана');
      expect(await db.fill.getFieldOutbox(_task), isEmpty,
          reason: 'и из очереди телефона');

      await closeScreen(t);
      app.dispose();
    });
  });
}
