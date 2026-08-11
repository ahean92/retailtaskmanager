import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/data/task_repository.dart';
import 'package:pulse_tasks/ui/widgets/account_menu.dart';

/// Меню учётной записи: два выхода и вопрос перед каждым. Проверяется то, что человек
/// видит и на что нажимает, — сколько неотправленного ему назвали и что случилось после
/// «Отмены». Сами файлы удаляет репозиторий, и это проверяется на устройстве
/// (integration_test/sign_out_test.dart).
class _Repo extends TaskRepository {
  _Repo({required this.unsent})
      : super(
          api: ApiClient(Settings(baseUrl: 'http://test.local:9080'),
              Session(login: 'ivanov', name: 'Иванов И.И.', signedIn: true)),
          settings: Settings(baseUrl: 'http://test.local:9080'),
          session:
              Session(login: 'ivanov', name: 'Иванов И.И.', signedIn: true),
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
  Future<_Repo> open(WidgetTester tester, {int unsent = 0}) async {
    final repo = _Repo(unsent: unsent);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(appBar: AppBar(actions: [AccountMenu(repo: repo)])),
    ));
    await tester.tap(find.byIcon(Icons.account_circle_outlined));
    await tester.pumpAndSettle();
    return repo;
  }

  testWidgets('в меню оба выхода и имя того, кто работает', (tester) async {
    await open(tester);
    expect(find.text('Иванов И.И. · ivanov'), findsOneWidget);
    expect(find.text('Выйти'), findsOneWidget);
    expect(find.text('Выйти и удалить данные'), findsOneWidget);
  });

  // Обычный выход ничего не удаляет, поэтому и говорит он не про потерю, а про то, что
  // работа дождётся возвращения.
  testWidgets('обычный выход называет неотправленное и обещает его сохранить',
      (tester) async {
    final repo = await open(tester, unsent: 3);
    await tester.tap(find.text('Выйти'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Не отправлено изменений: 3'), findsOneWidget);
    expect(find.textContaining('уйдут на сервер'), findsOneWidget);

    await tester.tap(find.text('Выйти').last);
    await tester.pumpAndSettle();
    expect(repo.signedOut, isTrue);
    expect(repo.wiped, isFalse, reason: 'обычный выход данных не трогает');
  });

  testWidgets('удаление данных предупреждает о потере и слушается «Отмены»',
      (tester) async {
    final repo = await open(tester, unsent: 3);
    await tester.tap(find.text('Выйти и удалить данные'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Иванов И.И. · ivanov'), findsOneWidget,
        reason: 'человеку говорят, чьи именно данные будут удалены');
    expect(find.textContaining('Не отправлено изменений: 3'), findsOneWidget);
    expect(find.textContaining('будут потеряны'), findsOneWidget);

    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(repo.wiped, isFalse);
    expect(repo.signedOut, isFalse, reason: 'отменённый выход — не выход');
  });

  testWidgets('удаление данных происходит только после подтверждения',
      (tester) async {
    final repo = await open(tester);
    await tester.tap(find.text('Выйти и удалить данные'));
    await tester.pumpAndSettle();
    // терять нечего — про неотправленное не говорится ничего
    expect(find.textContaining('Не отправлено'), findsNothing);

    await tester.tap(find.text('Удалить и выйти'));
    await tester.pumpAndSettle();
    expect(repo.wiped, isTrue);
    expect(repo.signedOut, isFalse);
  });
}
