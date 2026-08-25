import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/data/task_repository.dart';
import 'package:pulse_tasks/main.dart';
import 'package:pulse_tasks/ui/brand.dart';
import 'package:pulse_tasks/ui/settings_screen.dart';
import 'package:pulse_tasks/ui/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Тёмная тема (#36917). Проверяется не «есть ли тёмный вариант», а то, ради чего он
/// заводился: что на нём всё читается, что выбор человека переживает перезапуск, что
/// системная настройка телефона доходит до приложения на месте — и что цвета
/// заказчика при этом остаются его цветами.
///
/// Контраст считается по WCAG ([Brand.contrast]) — это единственный способ проверить
/// «текст не сливается с фоном» не глазами. Глазами — на устройстве,
/// integration_test/ticket36917_e2e_test.dart.

/// Экран-щуп: красится из [Wms] и открывается ровно так же, как настоящие, —
/// константой. Именно константа и делает случай интересным (см. проверку ниже).
class _Probe extends StatelessWidget {
  const _Probe();

  static const probeKey = Key('probe');

  @override
  Widget build(BuildContext context) =>
      Scaffold(body: Container(key: probeKey, color: Wms.card));
}

/// Репозиторий без адреса сервера: приложение открывается на экране настроек, где и
/// живёт переключатель темы. Ни сети, ни базы для этого не нужно.
class _Repo extends TaskRepository {
  _Repo()
      : super(
          api: ApiClient(Settings(), Session()),
          settings: Settings(),
          session: Session(),
        );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    Wms.brand = Brand.pulse;
    await Wms.setMode(ThemeMode.light);
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher
        .clearPlatformBrightnessTestValue();
  });

  group('тёмная палитра', () {
    final dark = Brand.pulse.darkVariant;

    test('на карточке читается всё, чем на ней пишут', () {
      final ink = {
        'текст': dark.text,
        'приглушённый': dark.muted,
        'фирменный': dark.primary,
        'акцент': dark.accent,
        'ok': dark.ok,
        'warn': dark.warn,
      };
      ink.forEach((what, color) {
        expect(Brand.contrast(color, dark.card), greaterThanOrEqualTo(4.5),
            reason: '$what на тёмной карточке');
      });
      // «моё» в переписке и выбранный вариант в бланке — отдельным, более светлым
      expect(Brand.contrast(dark.primaryDark, dark.card),
          greaterThan(Brand.contrast(dark.primary, dark.card)));
    });

    test('подложки остаются тёмными — белым плашкам взяться неоткуда', () {
      for (final surface in [dark.bg, dark.card, dark.line, dark.active]) {
        expect(surface.computeLuminance(), lessThan(0.2));
      }
      // карточка приподнята над фоном, как и в светлой теме
      expect(dark.card.computeLuminance(),
          greaterThan(dark.bg.computeLuminance()));
    });

    test('текст читается и на фоне, и на подложке выделения', () {
      expect(Brand.contrast(dark.text, dark.bg), greaterThanOrEqualTo(4.5));
      expect(Brand.contrast(dark.text, dark.active), greaterThanOrEqualTo(4.5));
      expect(Brand.contrast(dark.muted, dark.bg), greaterThanOrEqualTo(4.5));
    });

    test('красная подложка несоответствия не светит на тёмном', () {
      Wms.brand = Brand.pulse;
      final light = Wms.warnTint;
      Wms.setMode(ThemeMode.dark);
      expect(Wms.warnTint.a, light.a, reason: 'та же прозрачность');
      expect(Color.alphaBlend(Wms.warnTint, Wms.card).computeLuminance(),
          lessThan(0.2));
    });
  });

  group('бренд заказчика', () {
    // палитра, какой её может прислать сервер: свой тёмно-вишнёвый вместо синего
    final santa =
        Brand.fromJson(const {'name': 'Санта', 'primary': '#8B1E3F'});

    test('в тёмной теме остаётся его цветом, а не общим голубым', () {
      final dark = santa.darkVariant;
      final was = HSLColor.fromColor(santa.primary);
      final now = HSLColor.fromColor(dark.primary);
      expect((now.hue - was.hue).abs(), lessThan(1.0), reason: 'тот же оттенок');
      expect(now.lightness, greaterThan(was.lightness), reason: 'но светлее');
      expect(Brand.contrast(dark.primary, dark.card),
          greaterThanOrEqualTo(4.5));
      expect(dark.name, 'Санта');
    });

    test('шапка в обеих темах одна — фирменная', () {
      Wms.brand = santa;
      expect(Wms.chrome, santa.primary);
      Wms.setMode(ThemeMode.dark);
      expect(Wms.chrome, santa.primary,
          reason: 'тёмная тема гасит лист, а не бренд');
      final theme = buildAppTheme(Wms.darkPalette, dark: true);
      expect(theme.appBarTheme.backgroundColor, santa.primary);
    });

    test('цвет, который и так читается, не трогают', () {
      const white = Color(0xFFFFFFFF);
      expect(Brand.readableOn(white, const Color(0xFF12161B)), white);
    });
  });

  group('выбор темы', () {
    test('сохраняется и читается на следующем запуске', () async {
      await Wms.setMode(ThemeMode.dark);
      final sp = await SharedPreferences.getInstance();
      expect(sp.getString('themeMode'), 'dark');

      Wms.mode.value = ThemeMode.system; // как будто приложение запустили заново
      await Wms.loadMode();
      expect(Wms.mode.value, ThemeMode.dark);
      expect(Wms.isDark, isTrue);
    });

    test('«как в системе» идёт за настройкой телефона', () async {
      TestWidgetsFlutterBinding.instance.platformDispatcher
          .platformBrightnessTestValue = Brightness.dark;
      await Wms.setMode(ThemeMode.system);
      expect(Wms.isDark, isTrue);

      TestWidgetsFlutterBinding.instance.platformDispatcher
          .platformBrightnessTestValue = Brightness.light;
      Wms.resolve();
      expect(Wms.isDark, isFalse);
    });

    test('явный выбор системную настройку перебивает', () async {
      TestWidgetsFlutterBinding.instance.platformDispatcher
          .platformBrightnessTestValue = Brightness.dark;
      await Wms.setMode(ThemeMode.light);
      expect(Wms.isDark, isFalse);
    });
  });

  group('переключение на живом приложении', () {
    Future<void> open(WidgetTester tester) async {
      await tester.pumpWidget(PulseApp(repo: _Repo()));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);
    }

    ThemeData themeOf(WidgetTester tester) =>
        Theme.of(tester.element(find.byType(SettingsScreen)));

    testWidgets('«Тёмная» применяется без перезапуска', (tester) async {
      await open(tester);
      expect(themeOf(tester).brightness, Brightness.light);

      await tester.tap(find.text('Тёмная'));
      await tester.pumpAndSettle();

      final theme = themeOf(tester);
      expect(theme.brightness, Brightness.dark);
      expect(theme.scaffoldBackgroundColor, Brand.pulse.darkVariant.bg);
      expect(Wms.card, Brand.pulse.darkVariant.card,
          reason: 'палитра под виджетами тоже стала тёмной');
      // шапка осталась фирменной
      expect(theme.appBarTheme.backgroundColor, Brand.pulse.primary);

      await tester.tap(find.text('Светлая'));
      await tester.pumpAndSettle();
      expect(themeOf(tester).brightness, Brightness.light);
      expect(Wms.card, Brand.pulse.card);
    });

    testWidgets('при «Система» ночной режим телефона доходит сам',
        (tester) async {
      await open(tester);
      await tester.tap(find.text('Система'));
      await tester.pumpAndSettle();
      expect(themeOf(tester).brightness, Brightness.light);

      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pumpAndSettle();

      expect(themeOf(tester).brightness, Brightness.dark);
      expect(Wms.isDark, isTrue);
    });

    /// Экран, открытый ПОВЕРХ, — отдельный случай, и он же был настоящей ошибкой:
    /// палитра читается статикой, а не через InheritedWidget, и экран о смене темы
    /// сам не узнаёт. Открывают его всюду одинаково — `builder: (_) => const
    /// Экран()`, а константа в Dart канонизируется: на перестройке маршрут отдаёт ТОТ
    /// ЖЕ экземпляр, Flutter видит идентичный виджет и обрывает обход. Экран остаётся
    /// в старых цветах, пока не перестроится сам по себе. На устройстве это выглядело
    /// белыми карточками списка на тёмном фоне.
    Future<void> pushProbe(WidgetTester tester) async {
      unawaited(PulseApp.navigatorKey.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const _Probe()),
      ));
      await tester.pumpAndSettle();
    }

    Color probeColor(WidgetTester tester) =>
        tester.widget<Container>(find.byKey(_Probe.probeKey)).color!;

    testWidgets('экран, открытый поверх, не остаётся в старой палитре',
        (tester) async {
      await open(tester);
      await pushProbe(tester);
      expect(probeColor(tester), Brand.pulse.card);

      await Wms.setMode(ThemeMode.dark);
      await tester.pumpAndSettle();
      expect(probeColor(tester), Brand.pulse.darkVariant.card);
    });

    /// Та же беда была и у брендирования на ходу: сервер присылает палитру заказчика,
    /// когда экраны уже открыты.
    testWidgets('бренд с сервера доходит до уже открытого экрана',
        (tester) async {
      await open(tester);
      await pushProbe(tester);

      final santa = Brand.fromJson(const {'card': '#FFF3E0'});
      Wms.brand = santa;
      await tester.pumpAndSettle();
      expect(probeColor(tester), santa.card);
    });
  });
}
