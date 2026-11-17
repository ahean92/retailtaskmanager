import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:pulse_tasks/models/home.dart';
import 'package:pulse_tasks/ui/widgets/home/text.dart';

/// Текст главной: свёрнутый длинный — без ошибки переполнения и с «Читать
/// полностью», короткому разворачивать нечего; ссылка обрабатывается приложением, и
/// не-http(s) никуда не открывается.

Widget _host(String body) => MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: HomeTextBlock(
              block: HomeBlock(code: 't', type: 'text', title: 'Т', body: body)),
        ),
      ),
    );

void main() {
  const long = '<p>Первый</p><p>Второй</p><p>Третий</p><p>Четвёртый</p>'
      '<p>Пятый</p><p>Шестой</p><p>Седьмой</p>'
      '<p><a href="https://example.org/doc">Регламент</a></p>';

  testWidgets('длинный текст свёрнут без ошибки и разворачивается; у короткого '
      '«Читать полностью» нет', (t) async {
    await t.pumpWidget(_host(long));
    await t.pump();
    expect(t.takeException(), isNull, reason: 'свёрнутый текст не «переполнен»');
    expect(find.text('Читать полностью'), findsOneWidget);
    await t.tap(find.text('Читать полностью'));
    await t.pump();
    expect(find.text('Свернуть'), findsOneWidget);
    await t.tap(find.text('Свернуть'));
    await t.pump();

    await t.pumpWidget(_host('<p>Одна строка</p>'));
    await t.pump();
    expect(find.text('Читать полностью'), findsNothing);
    expect(find.text('Свернуть'), findsNothing);
  });

  testWidgets('ссылку обрабатывает приложение; не-http(s) не открывается',
      (t) async {
    await t.pumpWidget(_host(long));
    final onTap = t.widget<HtmlWidget>(find.byType(HtmlWidget)).onTapUrl;
    expect(onTap, isNotNull, reason: 'без обработчика ссылка молчала');
    // обработана (true) — и отвергнута: пакет не пробует открыть её сам
    expect(await onTap!('file:///sdcard/secret.txt'), isTrue);
    expect(await onTap('intent://scan#Intent;end'), isTrue);
  });
}
