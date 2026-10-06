import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pulse_tasks/app_controllers.dart';
import 'package:pulse_tasks/data/account_controller.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/ui/profile_screen.dart';
import 'package:pulse_tasks/ui/theme.dart';
import 'package:pulse_tasks/ui/brand.dart';

/// Профиль (#37411, п. 12) — сюда переехали оба выхода из прежнего меню аккаунта:
/// проверяется то, что человек видит и на что нажимает, — сколько неотправленного
/// ему назвали и что случилось после «Отмены». Сами файлы удаляет учётная запись,
/// и это проверяется на устройстве (integration_test/sign_out_test.dart).
class _Account extends AccountController {
  _Account({required this.unsent})
      : super(
          api: _app.api,
          session: _app.session,
          settings: _app.settings,
          base: _app.base,
          repo: _app.repo,
        );

  /// Остальные контроллеры — настоящие, но без сети и базы: профиль читает из них
  /// только имя, логин и счётчики.
  static final _app = AppControllers(
    api: ApiClient(Settings(baseUrl: 'http://test.local:9080'),
        Session(login: 'ivanov', name: 'Иванов И.И.', signedIn: true)),
    settings: Settings(baseUrl: 'http://test.local:9080'),
    session: Session(login: 'ivanov', name: 'Иванов И.И.', signedIn: true),
  );

  final int unsent;
  bool signedOut = false;
  bool wiped = false;

  @override
  Future<int> unsentChanges() async => unsent;

  @override
  Future<void> signOut() async => signedOut = true;

  @override
  Future<void> signOutAndWipe() async => wiped = true;
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    Wms.brand = Brand.pulse;
    await Wms.setMode(ThemeMode.light);
  });

  Future<_Account> open(WidgetTester tester, {int unsent = 0}) async {
    // высокий экран: оба выхода стоят внизу длинного профиля, и в тесте до них
    // добираться прокруткой хрупче, чем просто показать всё
    tester.view.physicalSize = const Size(390, 1700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final account = _Account(unsent: unsent);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ..._Account._app.providers,
        ChangeNotifierProvider<AccountController>.value(value: account),
      ],
      child: const MaterialApp(home: ProfileScreen()),
    ));
    await tester.pumpAndSettle();
    return account;
  }

  testWidgets('карточка пользователя и оба выхода на месте', (tester) async {
    await open(tester);
    expect(find.text('Иванов И.И.'), findsOneWidget);
    expect(find.text('ivanov'), findsOneWidget);
    expect(find.text('Выйти'), findsOneWidget);
    expect(find.text('Выйти и удалить данные'), findsOneWidget);
  });

  testWidgets('обычный выход называет неотправленное и обещает его сохранить',
      (tester) async {
    final account = await open(tester, unsent: 3);
    await tester.tap(find.text('Выйти'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Не отправлено изменений: 3'), findsOneWidget);
    expect(find.textContaining('уйдут на сервер'), findsOneWidget);

    await tester.tap(find.text('Выйти').last);
    await tester.pumpAndSettle();
    expect(account.signedOut, isTrue);
    expect(account.wiped, isFalse, reason: 'обычный выход данных не трогает');
  });

  testWidgets('удаление данных предупреждает о потере и слушается «Отмены»',
      (tester) async {
    final account = await open(tester, unsent: 3);
    await tester.tap(find.text('Выйти и удалить данные'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Иванов И.И.'), findsWidgets,
        reason: 'человеку говорят, чьи именно данные будут удалены');
    expect(find.textContaining('Не отправлено изменений: 3'), findsOneWidget);
    expect(find.textContaining('будут потеряны'), findsOneWidget);

    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(account.wiped, isFalse);
    expect(account.signedOut, isFalse, reason: 'отменённый выход — не выход');
  });

  testWidgets('удаление данных происходит только после подтверждения',
      (tester) async {
    final account = await open(tester);
    await tester.tap(find.text('Выйти и удалить данные'));
    await tester.pumpAndSettle();
    // терять нечего — диалог не считает неотправленное (строка «Не отправлено»
    // в самом профиле при этом, конечно, остаётся)
    expect(find.textContaining('Не отправлено изменений'), findsNothing);

    await tester.tap(find.text('Удалить и выйти'));
    await tester.pumpAndSettle();
    expect(account.wiped, isTrue);
    expect(account.signedOut, isFalse);
  });
}
