import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_tasks/ui/fill_screen.dart';
import 'package:pulse_tasks/ui/task_detail_screen.dart';

import 'support/app_host.dart';
import 'support/fake_pulse_server.dart';
import 'support/test_env.dart';

/// Бланк против правил сервера, на общем сервере из записанных ответов 6.2: агрегат
/// задачи без заполнения отвечает одной шапкой, балл выше максимума поля сервер не
/// принимает, а запись без ключа comment стирает примечание. Клиент обязан жить с
/// каждым из них: карточка, открытая раньше бланка, не мешает ему завести
/// выполнение; «Полный балл» при шаге, который не делит максимум, отправляет сам
/// максимум; примечание едет с каждой записью значения.

const _task = 'ZZZ-E2E-TYPES';

void main() {
  initTestEnv();
  late FakePulseServer srv;

  setUp(() {
    resetMockStores();
    srv = FakePulseServer();
  });

  testWidgets('карточка до бланка: бланк всё равно стартует и показывает поля',
      (t) async {
    await t.runAsync(() async {
      srv.fills[_task] = FakeFill.recorded('apiExecutionBundle_filled',
          blank: true, started: false);
      final app = await appOf(srv.api, srv.settings, srv.session);
      app.location.place = atObject('ZZZE2E');

      // первое открытие — карточка: она спрашивает бланк и получает одну шапку
      await t.pumpWidget(host(app, const TaskDetailScreen(taskId: _task)));
      await until(t, () => srv.calls.contains('apiExecutionBundle'),
          reason: 'карточка спросила бланк');
      await settle(t, 6);
      await closeScreen(t);

      await t.pumpWidget(host(app, const FillScreen(taskId: _task)));
      await until(t, () => find.text('1. ZZZ текст').evaluate().isNotEmpty,
          reason: 'бланк открылся с полями, а не «Полей нет»');
      expect(srv.calls, contains('apiStartExecution'),
          reason: 'ответ карточки без полей не выдаёт себя за заведённое выполнение');

      await closeScreen(t);
      app.dispose();
    });
  });

  testWidgets('«Полный балл» при шаге 2 и максимуме 5 отправляет 5, примечание '
      'остаётся', (t) async {
    await t.runAsync(() async {
      final fill = FakeFill.recorded('apiExecutionBundle_filled');
      // записанное поле: максимум 5, балл 4 и примечание; шаг — настройка шаблона
      fill.field('s1')['step'] = 2;
      srv.fills[_task] = fill;
      final app = await appOf(srv.api, srv.settings, srv.session);
      app.location.place = atObject('ZZZE2E');

      await t.pumpWidget(host(app, const FillScreen(taskId: _task)));
      await until(t, () => find.text('1. ZZZ текст').evaluate().isNotEmpty,
          reason: 'бланк открылся');
      await scrollTo(t, find.text('Полный балл'));
      await settle(t, 2);
      await t.tap(find.text('Полный балл'));
      await until(t, () => srv.postsOf('apiSetField').isNotEmpty,
          reason: 'сервер принял балл — выше максимума он отказал бы');
      expect(srv.postsOf('apiSetField').last['number'], 5);
      expect(fill.field('s1')['number'], 5);
      expect(fill.field('s1')['comment'], 'примечание',
          reason: 'без ключа comment сервер стёр бы примечание');
      await until(t, () => find.text('5 из 5').evaluate().isNotEmpty,
          reason: 'на экране максимум, а не «6 из 5»');

      await closeScreen(t);
      app.dispose();
    });
  });
}
