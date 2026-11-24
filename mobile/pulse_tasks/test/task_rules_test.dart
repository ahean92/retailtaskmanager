import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pulse_tasks/app_controllers.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/models/ai_draft.dart';
import 'package:pulse_tasks/models/fill.dart';
import 'package:pulse_tasks/models/quick_create.dart';
import 'package:pulse_tasks/ui/widgets/pickers/row_subject_sheet.dart';
import 'support/fake_server.dart';
import 'support/test_env.dart';

/// Правила задачи с телефона: приёмка из пресета и назначение по правилу уезжают в
/// тело apiCreateTask; пометка «нет в остатках» — только у канала, который считает
/// остатки. Сервер проверяет то же в task_rules_check.lsf.

int _seq = 0;

/// apiQuickActions, как его отдаёт сервер: код приёмки — у каждого пресета нового
/// сервера, у «old» его нет (сервер до #37157).
const _actions = '''
[{"code":"call","title":"Позвонить","typeId":"issue","assign":"self","acceptance":"required"},
 {"code":"repair","title":"Поломка","typeId":"issue","assign":"byRule","acceptance":"byType"},
 {"code":"old","title":"Старый сервер","typeId":"issue","assign":"self"}]
''';

class _Server {
  bool down = false;
  final bodies = <(String, String)>[];

  late final Session session;
  late final ApiClient api;

  _Server(Settings settings) {
    session = Session(
      login: 'rules${_seq++}', // логин уникален: имя базы содержит его
      name: 'Супервайзер',
      token: 'token',
      signedIn: true,
      performerId: 'p1',
    );
    api = ApiClient(settings, session, client: MockClient((request) async {
      if (down) throw const SocketException('нет сети');
      final action = actionOf(request);
      if (request.method == 'POST') {
        bodies.add((action, request.body));
        return http.Response('', 200);
      }
      return okJson(switch (action) {
        'apiQuickActions' => _actions,
        'apiExecutionInfo' => '{}',
        _ => '[]',
      });
    }));
  }

  /// Тело последнего дошедшего apiCreateTask.
  Map<String, dynamic> get created {
    final posts = [
      for (final (a, b) in bodies)
        if (a == 'apiCreateTask') b
    ];
    return (jsonDecode(posts.last) as Map).cast<String, dynamic>();
  }
}

void main() {
  initTestEnv();

  group('пресет', () {
    test('приёмка и «по правилу» читаются из apiQuickActions', () {
      final list = (jsonDecode(_actions) as List)
          .map((j) => QuickPreset.fromJson(j as Map<String, dynamic>))
          .toList();
      expect(list[0].acceptance, 'required');
      expect(list[1].assign, 'byRule');
      expect(list[1].details, 'по правилу назначения');
      expect(list[2].acceptance, isNull, reason: 'переопределения нет — ключа нет');
    });

    test('«по правилу» не ждёт исполнителя и не называет его', () {
      const preset = QuickPreset(
          code: 'repair', title: 'Поломка', typeId: 'issue', assign: 'byRule');
      const draft = PresetDraft(
          preset: preset,
          object: (id: 'b24', name: 'Магазин №1', address: null),
          name: 'Касса не печатает');
      const data = QuickCreateData();
      expect(draft.missing(data), isNull);
      expect(draft.assignee(data), isNull);
    });
  });

  group('тело apiCreateTask', () {
    late Settings settings;
    late _Server server;

    setUp(() {
      resetMockStores();
      settings = Settings(baseUrl: 'http://test.local:9080');
      server = _Server(settings);
    });

    Future<AppControllers> phone() async {
      final app = AppControllers(
          api: server.api, settings: settings, session: server.session);
      await app.account.updateSettings(settings);
      await app.home.refreshQuickCreate();
      return app;
    }

    PresetDraft draft(AppControllers app, String code) => PresetDraft(
          preset:
              app.home.quickCreate.actions.firstWhere((a) => a.code == code),
          object: (id: 'b24', name: 'Магазин №1', address: null),
          name: 'Задача по пресету $code',
        );

    test('приёмка из пресета уезжает кодом, «себе» — без правила', () async {
      final app = await phone();
      await app.home.createFromPreset(draft(app, 'call'));
      await app.sync.drainLocalTasks();
      final body = server.created;
      expect(body['acceptance'], 'required');
      expect(body['quickActionCode'], 'call');
      expect(body.containsKey('assignByRule'), isFalse);
      expect(body.containsKey('assigneeId'), isFalse);
      await app.repo.db.close();
    });

    test('пресет без приёмки — ключа нет, задача «как у типа»',
        () async {
      final app = await phone();
      await app.home.createFromPreset(draft(app, 'old'));
      await app.sync.drainLocalTasks();
      expect(server.created.containsKey('acceptance'), isFalse);
      await app.repo.db.close();
    });

    test('«по правилу»: признак вместо исполнителя, до ответа задача не «моя»',
        () async {
      final app = await phone();
      server.down = true; // подвал: строку видно до отправки
      final uuid = await app.home.createFromPreset(draft(app, 'repair'));
      final local = app.repo.tasks.firstWhere((t) => t.task.id == uuid).task;
      expect(local.assigneeId, isNull);
      expect(local.assigned, isFalse,
          reason: 'исполнителя назовёт сервер — до того она в «Поставленных мной»');
      expect(local.assignedTo, 'по правилу назначения');

      server.down = false;
      await app.sync.drainLocalTasks();
      final body = server.created;
      expect(body['assignByRule'], isTrue);
      expect(body.containsKey('assigneeId'), isFalse);
      expect(body['acceptance'], 'byType');
      await app.repo.db.close();
    });

    test('AI-черновик без исполнителя — по правилу, с исполнителем — ему', () async {
      final app = await phone();
      Map<String, dynamic> draftJson(String dialog, [String? performer]) => {
            'dialogId': dialog,
            'outcome': 'ok',
            'name': 'Проверить выкладку',
            'typeId': 'issue',
            'objectId': 'b24',
            if (performer != null) 'performerId': performer,
          };

      await app.home.createFromAiDraft(
          AiDraft.fromJson(draftJson('11111111-2222-3333-4444-555555555555')));
      await app.sync.drainLocalTasks();
      expect(server.created['assignByRule'], isTrue);
      expect(server.created.containsKey('assigneeId'), isFalse);

      await app.home.createFromAiDraft(AiDraft.fromJson(
          draftJson('11111111-2222-3333-4444-666666666666', 'ivanov')));
      await app.sync.drainLocalTasks();
      expect(server.created['assigneeId'], 'ivanov');
      expect(server.created.containsKey('assignByRule'), isFalse);
      await app.repo.db.close();
    });
  });

  group('пометка «нет в остатках»', () {
    // Ответ apiRowSubjects, как его отдаёт сервер: канал товаров считает остатки и
    // шлёт available true/false, у сотрудников ключа нет вовсе.
    final answer = [
      {
        'subjectId': 'ITM-1',
        'name': 'Молоко',
        'kind': 'item',
        'available': true
      },
      {
        'subjectId': 'ITM-9',
        'name': 'Кефир',
        'kind': 'item',
        'available': false
      },
      {'subjectId': 'E-1', 'name': 'Иванов', 'kind': 'employee'},
    ];

    testWidgets('помечена позиция вне остатков, сотрудник — нет', (tester) async {
      final candidates = answer.map(RefCandidate.fromJson).toList();
      expect(candidates.map((c) => c.available), [true, false, null]);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: RowSubjectSheet(
            title: 'Добавить позицию',
            allowFree: false,
            search: (q, {bool allItems = false}) async => candidates,
          ),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('нет в остатках объекта'), findsOneWidget);
      final kefir = find.ancestor(
          of: find.text('Кефир'), matching: find.byType(ListTile));
      expect(
          find.descendant(
              of: kefir, matching: find.text('нет в остатках объекта')),
          findsOneWidget);
    });
  });
}
