import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_tasks/ui/fill_screen.dart';

import 'support/app_host.dart';
import 'support/fake_pulse_server.dart';
import 'support/test_env.dart';

/// Поле-ссылка на экране бланка, общий сервер: строка «Выбрать…» открывает пикер с
/// кандидатами канала поля, выбор уходит на сервер ссылкой и снимком имени и виден в
/// поле; «Очистить» снимает выбор — на сервере не остаётся ни ссылки, ни снимка.

const _task = 'ZZZ-E2E-REF';

void main() {
  initTestEnv();
  late FakePulseServer srv;

  setUp(() {
    resetMockStores();
    srv = FakePulseServer();
  });

  testWidgets('выбор из справочника уходит ссылкой и снимком; «Очистить» снимает',
      (t) async {
    await t.runAsync(() async {
      srv.fills[_task] =
          FakeFill.recorded('apiExecutionBundle_ref', blank: true);
      final app = await appOf(srv.api, srv.settings, srv.session);
      app.location.place = atObject('ZZZE2E');

      await t.pumpWidget(host(app, const FillScreen(taskId: _task)));
      await until(t, () => find.text('Выбрать…').evaluate().isNotEmpty,
          reason: 'поле-ссылка без ответа ждёт выбора');

      await t.tap(find.text('Выбрать…'));
      await until(t, () => find.byType(ListTile).evaluate().isNotEmpty,
          reason: 'пикер показал кандидатов канала');
      await t.tap(find.widgetWithText(ListTile, 'ZZZ E2E объект'));
      await until(t, () => srv.postsOf('apiSetField').isNotEmpty,
          reason: 'выбор отправлен');
      final sent = srv.postsOf('apiSetField').last;
      expect(sent['field'], 'r1');
      expect(sent['refId'], 'ZZZE2E', reason: 'ссылка — id кандидата');
      expect(sent['refName'], 'ZZZ E2E объект', reason: 'и снимок имени');
      expect(srv.fills[_task]!.field('r1')['ref'], 'ZZZ E2E объект');
      expect(find.text('ZZZ E2E объект'), findsWidgets,
          reason: 'выбранное видно в поле');

      await t.tap(find.byTooltip('Очистить'));
      await until(t, () => srv.postsOf('apiSetField').length == 2,
          reason: 'очистка отправлена');
      final cleared = srv.postsOf('apiSetField').last;
      expect(cleared['refId'], '', reason: 'пустые id и имя — явная очистка');
      expect(cleared['refName'], '');
      expect(srv.fills[_task]!.field('r1')['refId'], '');
      await until(t, () => find.text('Выбрать…').evaluate().isNotEmpty,
          reason: 'поле снова ждёт выбора');

      await closeScreen(t);
      app.dispose();
    });
  });
}
