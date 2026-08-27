import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/data/task_repository.dart';
import 'package:pulse_tasks/models/external_app.dart';
import 'package:pulse_tasks/ui/widgets/external_apps_section.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Запуск внешних приложений с главной (#36840). Несущие стены тикета:
///  - список — данные необязательного серверного модуля: 404 означает «модуля нет»
///    и стирает кэш, отказ сети кэш бережёт, а пустой 200 — такая же настройка,
///    как непустой;
///  - URI собирается с экранированием подстановок — «Санта №5» не имеет права
///    сломать запуск;
///  - секция рисует только своё (Android) и молчит на пустом.
///
/// Фикстура — дословный ответ apiExternalApps стенда: если контракт ручки поедет,
/// эти строки должны перестать парситься именно здесь, а не в поле.

int _seq = 0;

const _apps = '''
[{"code":"tsd","title":"Терминал сбора данных","icon":"📟","platform":"android","package":"by.luxsoft.tsd"},
 {"code":"portal","title":"Портал","icon":"🌐","platform":"android","uri":"https://portal.local/o/{objectId}?user={login}","market":"https://play.google.com/store/apps/details?id=portal"},
 {"code":"iosOnly","title":"Сканер iOS","icon":"📷","platform":"ios","uri":"scanner://open"}]
''';

/// Сервер с настраиваемым ответом единственной интересной здесь ручки.
class _Server {
  String body = _apps;
  int status = 200;
  bool down = false;

  late final Session session;
  late final ApiClient api;

  _Server(Settings settings) {
    session = Session(
      login: 'sidorov${_seq++}', // логин уникален: имя базы содержит его
      name: 'Сидоров С.С.',
      token: 'token',
      signedIn: true,
      performerId: 'p1',
    );
    api = ApiClient(settings, session, client: MockClient((request) async {
      if (down) throw const SocketException('нет сети');
      final action = request.url.path.split('.').last;
      if (action == 'apiExternalApps') {
        return http.Response.bytes(utf8.encode(body), status,
            headers: {'content-type': 'application/json; charset=utf-8'});
      }
      return http.Response.bytes(utf8.encode('[]'), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    }));
  }
}

Future<TaskRepository> _repo(Settings settings, _Server server) async {
  final repo = TaskRepository(
      api: server.api, settings: settings, session: server.session);
  await repo.updateSettings(settings); // открывает базу этого логина
  return repo;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Settings settings;
  late _Server server;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    settings = Settings(baseUrl: 'http://test.local:9080');
    server = _Server(settings);
  });

  group('модель', () {
    test('парсит ответ ручки как его отдаёт сервер', () {
      final apps = ExternalApp.parseList(_apps);
      expect(apps, hasLength(3));

      final tsd = apps.first;
      expect(tsd.code, 'tsd');
      expect(tsd.platform, 'android');
      expect(tsd.package, 'by.luxsoft.tsd');
      // у ТСД нет ни своей схемы, ни маркета — и это не ошибка, а его манифест
      expect(tsd.uriTemplate, isNull);
      expect(tsd.marketUrl, isNull);

      final portal = apps[1];
      expect(portal.uriTemplate, isNotNull);
      expect(portal.marketUrl, isNotNull);
      expect(apps.last.platform, 'ios');
    });

    test('пустое тело lsFusion — «приложений нет», а не ошибка', () {
      expect(ExternalApp.parseList(''), isEmpty);
      expect(ExternalApp.parseList('[]'), isEmpty);
    });
  });

  group('сборка URI', () {
    const portal = ExternalApp(
      code: 'portal',
      title: 'Портал',
      uriTemplate: 'https://portal.local/o/{objectId}?user={login}',
    );

    test('подставляет и экранирует значения', () {
      final uri = portal.launchUri(objectId: 'Санта №5', login: 'иванов и');
      // пробел и кириллица обязаны уехать процентами — сырыми они ломают запуск
      expect(uri,
          'https://portal.local/o/%D0%A1%D0%B0%D0%BD%D1%82%D0%B0%20%E2%84%965'
          '?user=%D0%B8%D0%B2%D0%B0%D0%BD%D0%BE%D0%B2%20%D0%B8');
      expect(Uri.parse(uri!).queryParameters['user'], 'иванов и');
    });

    test('плейсхолдер без значения — пустая строка, а не литерал', () {
      const t = ExternalApp(
          code: 't', title: 'Т', uriTemplate: 'app://open?task={taskId}&x={unknown}');
      expect(t.launchUri(objectId: 'b24'), 'app://open?task=&x=');
    });

    test('без шаблона URI нет — запуск пойдёт по пакету', () {
      const tsd = ExternalApp(code: 'tsd', title: 'ТСД', package: 'by.luxsoft.tsd');
      expect(tsd.launchUri(objectId: 'b24', login: 'admin'), isNull);
    });
  });

  group('репозиторий', () {
    test('200 с телом наполняет список и кэш; новый репозиторий читает кэш',
        () async {
      final repo = await _repo(settings, server);
      await repo.refreshExternalApps();
      expect(repo.externalApps.map((a) => a.code), ['tsd', 'portal', 'iosOnly']);

      // тот же логин, новый процесс: секция живёт из кэша, офлайн
      final again = await _repo(settings, server);
      expect(again.externalApps.map((a) => a.code),
          ['tsd', 'portal', 'iosOnly']);
    });

    test('пустой 200 записывается: приложения выключили — секция пропадает',
        () async {
      final repo = await _repo(settings, server);
      await repo.refreshExternalApps();
      expect(repo.externalApps, isNotEmpty);

      server.body = '[]';
      await repo.refreshExternalApps();
      expect(repo.externalApps, isEmpty);
      expect(await repo.db.getApps(), anyOf(isEmpty, '[]'));
    });

    test('404 стирает кэш: модуль убрали из сборки — секция не живёт вечно',
        () async {
      final repo = await _repo(settings, server);
      await repo.refreshExternalApps();
      expect(repo.externalApps, isNotEmpty);

      server.status = 404;
      server.body = 'not found';
      await repo.refreshExternalApps();
      expect(repo.externalApps, isEmpty);
    });

    test('отказ сервера и офлайн кэш берегут', () async {
      final repo = await _repo(settings, server);
      await repo.refreshExternalApps();
      expect(repo.externalApps, hasLength(3));

      server.status = 500;
      server.body = 'boom';
      await repo.refreshExternalApps();
      expect(repo.externalApps, hasLength(3));

      server.down = true;
      await repo.refreshExternalApps();
      expect(repo.externalApps, hasLength(3));
    });
  });

  group('секция главной', () {
    // Швы вместо плагинов: каналов url_launcher/android_intent в widget-тестах нет.
    // Заодно они записывают, ЧТО секция попросила открыть, — сюда доезжает и
    // подстановка контекста.
    final uris = <Uri>[];
    final packages = <String>[];
    var launchOk = false;

    setUp(() {
      uris.clear();
      packages.clear();
      launchOk = false;
    });

    Widget host(List<ExternalApp> apps) => MaterialApp(
          home: Scaffold(
            body: ListView(children: [
              ExternalAppsSection(
                apps: apps,
                objectId: 'b24',
                login: 'admin',
                launchUriFn: (u) async {
                  uris.add(u);
                  return launchOk;
                },
                launchPackageFn: (p) async {
                  packages.add(p);
                  return launchOk;
                },
              ),
            ]),
          ),
        );

    // Секция сама глядит на defaultTargetPlatform — вариант подменяет его на время
    // теста и честно возвращает, не спотыкаясь о проверку инвариантов биндинга.
    const android = TargetPlatformVariant(<TargetPlatform>{TargetPlatform.android});

    testWidgets('рисует только Android-записи', (tester) async {
      await tester.pumpWidget(host(ExternalApp.parseList(_apps)));

      expect(find.text('Приложения'), findsOneWidget);
      expect(find.text('Терминал сбора данных'), findsOneWidget);
      expect(find.text('Портал'), findsOneWidget);
      // запись чужой платформы пропущена, как незнакомый тип блока главной
      expect(find.text('Сканер iOS'), findsNothing);
    }, variant: android);

    testWidgets('пустой список — секции нет вовсе', (tester) async {
      await tester.pumpWidget(host(const []));
      expect(find.text('Приложения'), findsNothing);
    }, variant: android);

    testWidgets('одни iOS-записи — секции тоже нет', (tester) async {
      await tester.pumpWidget(host(const [
        ExternalApp(code: 'x', title: 'Сканер', platform: 'ios'),
      ]));
      expect(find.text('Приложения'), findsNothing);
    }, variant: android);

    testWidgets('тап по записи с пакетом зовёт пакет, успех — без диалога',
        (tester) async {
      launchOk = true;
      await tester.pumpWidget(host(ExternalApp.parseList(_apps)));

      await tester.tap(find.text('Терминал сбора данных'));
      await tester.pumpAndSettle();
      expect(packages, ['by.luxsoft.tsd']);
      expect(uris, isEmpty);
      expect(find.byType(AlertDialog), findsNothing);
    }, variant: android);

    testWidgets('тап по записи с шаблоном открывает URI с текущим контекстом',
        (tester) async {
      launchOk = true;
      await tester.pumpWidget(host(ExternalApp.parseList(_apps)));

      await tester.tap(find.text('Портал'));
      await tester.pumpAndSettle();
      // подстановки доехали до запуска: объект главной и логин вошедшего
      expect(uris.single.toString(), 'https://portal.local/o/b24?user=admin');
      expect(packages, isEmpty);
    }, variant: android);

    testWidgets(
        'недоступное приложение — внятное «не установлено», с маркетом если он '
        'задан', (tester) async {
      await tester.pumpWidget(host(ExternalApp.parseList(_apps)));

      await tester.tap(find.text('Терминал сбора данных'));
      await tester.pumpAndSettle();
      expect(find.text('Приложение не установлено на этом устройстве.'),
          findsOneWidget);
      expect(find.text('Установить'), findsNothing); // маркета у ТСД нет
      await tester.tap(find.text('Закрыть'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);

      await tester.tap(find.text('Портал'));
      await tester.pumpAndSettle();
      expect(find.text('Приложение не установлено на этом устройстве.'),
          findsOneWidget);
      expect(find.text('Установить'), findsOneWidget);
      await tester.tap(find.text('Установить'));
      await tester.pumpAndSettle();
      // кнопка ведёт в маркет из справочника — и закрывает диалог за собой
      expect(uris.last.toString(),
          'https://play.google.com/store/apps/details?id=portal');
      expect(find.byType(AlertDialog), findsNothing);
    }, variant: android);
  });
}
