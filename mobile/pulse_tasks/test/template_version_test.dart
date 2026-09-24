import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pulse_tasks/app_controllers.dart';
import 'package:pulse_tasks/data/api_client.dart';
import 'package:pulse_tasks/data/fill_controller.dart';
import 'package:pulse_tasks/data/geo.dart';
import 'package:pulse_tasks/data/session.dart';
import 'package:pulse_tasks/data/settings.dart';
import 'package:pulse_tasks/models/ai_draft.dart';
import 'package:pulse_tasks/models/quick_create.dart';
import 'fake_phone.dart';
import 'support/fake_server.dart';
import 'support/test_env.dart';

/// Редакции шаблона (#37175): задача, созданная офлайн, встаёт на ту редакцию, по
/// которой заполнен бланк, а не на ту, что окажется текущей к синхронизации.
///
/// Сценарий тикета: в пятницу телефон забрал «Санитарное состояние» редакции 3; в
/// понедельник в подвале без сети супервайзер создаёт и заполняет внезапную проверку;
/// в 9:00 бэк-офис публикует редакцию 4, где «Холодильник» заменён двумя пунктами; в
/// 11:00 телефон в сети. Сервер создаёт задачу на редакции, номер которой пришёл в
/// apiCreateTask (#37174), — здесь проверяется, что приходит номер бланка.

int _seq = 0;

const _actions = '''
[{"code":"sudden","title":"Внезапная проверка","typeId":"checklist","template":"sanitary","assign":"self"}]
''';

/// apiTemplates с одним шаблоном редакции [version]; null — сервер без редакций,
/// номера в ответе нет вовсе.
String _templates(int? version) {
  // в четвёртой редакции «Холодильник» заменён двумя пунктами
  final codes = version == 4 ? ['fridgeTemp', 'fridgeClean'] : ['fridge'];
  return jsonEncode([
    {
      'code': 'sanitary',
      if (version != null) 'version': version,
      'name': 'Санитарное состояние',
      'fields': [
        for (final c in codes)
          {
            'sectionIndex': 1,
            'section': 'Зал',
            'fieldIndex': codes.indexOf(c) + 1,
            'code': c,
            'name': c,
            'type': 'scale',
          },
      ],
      'options': [
        for (final c in codes) ...[
          {'fieldCode': c, 'code': 'ok', 'name': 'Норма'},
          {
            'fieldCode': c,
            'code': 'bad',
            'name': 'Нарушение',
            'nonconformity': true,
          },
        ],
      ],
    },
  ]);
}

/// Сервер пресетов: отдаёт шаблон текущей редакции, пишет тела мутаций и умеет
/// «пропадать».
class _Server {
  String templates = _templates(3);
  bool down = false;
  final calls = <String>[]; // POST-попытки, включая оборвавшиеся
  final bodies = <(String, String)>[]; // (действие, тело) дошедших

  late final Session session;
  late final ApiClient api;

  _Server(Settings settings) {
    session = Session(
      login: 'sup${_seq++}', // логин уникален: имя базы содержит его
      name: 'Супервайзер',
      token: 'token',
      signedIn: true,
      performerId: 'p1',
    );
    api = ApiClient(settings, session, client: MockClient((request) async {
      final action = actionOf(request);
      if (request.method == 'POST') calls.add(action);
      if (down) throw const SocketException('нет сети');
      if (request.method == 'POST') {
        bodies.add((action, request.body));
        return http.Response('', 200);
      }
      return okJson(switch (action) {
        'apiQuickActions' => _actions,
        'apiTemplates' => templates,
        'apiExecutionInfo' => '{}',
        _ => '[]',
      });
    }));
  }

  List<String> postsOf(String action) =>
      [for (final (a, b) in bodies) if (a == action) b];

  /// Тело apiCreateTask — единственного, дошедшего до сервера.
  Map<String, dynamic> get created =>
      (jsonDecode(postsOf('apiCreateTask').single) as Map)
          .cast<String, dynamic>();
}

void main() {
  initTestEnv();

  late Settings settings;
  late _Server server;
  // немедленные отправки после создания (в createTask они без await): тест их
  // дожидается, иначе попытка «из подвала» могла бы доехать уже после появления связи
  late List<Future<void>> pushes;

  setUp(() {
    resetMockStores();
    settings = Settings(baseUrl: 'http://test.local:9080');
    server = _Server(settings);
  });

  /// Телефон с базой этого логина и пресетами, забранными с сервера.
  Future<AppControllers> phone() async {
    final app = AppControllers(
        api: server.api,
        settings: settings,
        session: server.session,
        geo: Geo(platform: FakePhone()));
    await app.account.updateSettings(settings); // открывает базу этого логина
    pushes = [];
    final push = app.repo.pushLocalTasks!;
    app.repo.pushLocalTasks = () {
      final f = push();
      pushes.add(f);
      return f;
    };
    await app.home.refreshQuickCreate();
    return app;
  }

  /// Внезапная проверка, как её собирает экран создания: шаблон — из кэша.
  PresetDraft sudden(AppControllers app) {
    final data = app.home.quickCreate;
    final preset = data.actions.single;
    return PresetDraft(
      preset: preset,
      template: data.templateOf(preset),
      object: (id: 'b24', name: 'Магазин №1', address: null),
      name: 'Санитарное состояние',
    );
  }

  test('проверка, заполненная офлайн по редакции 3, уходит на ней, хотя к '
      'отправке кэш уже переписан редакцией 4', () async {
    final app = await phone();
    expect(app.home.quickCreate.templates['sanitary']?.version, 3);

    // понедельник, подвал: проверку создают и заполняют по кэшу
    server.down = true;
    final uuid = await app.home.createFromPreset(sudden(app));
    await Future.wait(pushes);
    final fill =
        FillController(db: app.repo.db, api: server.api, taskId: uuid);
    await fill.load();
    expect(fill.fields.map((f) => f.code), ['fridge']);
    await fill.setOption(fill.fields.single, 'bad');
    await fill.syncAll(refreshSummary: false); // дождаться попытки из _commit
    fill.dispose();
    expect(server.bodies, isEmpty, reason: 'из подвала не ушло ничего');

    // 9:00 — опубликована редакция 4; 11:00 — телефон в сети, и первой приезжает
    // она: кэш шаблона переписан раньше, чем ушла задача
    server.templates = _templates(4);
    server.down = false;
    await app.home.refreshQuickCreate();
    expect(app.home.quickCreate.templates['sanitary']?.version, 4);
    await app.sync.drainLocalTasks();

    expect(server.created['templateId'], 'sanitary');
    expect(server.created['templateVersion'], 3,
        reason: 'редакция бланка, а не текущая к отправке');
    // ответ ушёл следом — по пункту третьей редакции, на ней сервер его и примет
    final answer = jsonDecode(server.postsOf('apiSetField').single) as Map;
    expect(answer['field'], 'fridge');
    expect(answer['optCode'], 'bad');
    app.dispose();
  });

  test('поручение из AI-черновика несёт код шаблона, но не номер', () async {
    final app = await phone();
    final draft = AiDraft.fromJson({
      'dialogId': '11111111-2222-3333-4444-555555555555',
      'outcome': 'ok',
      'name': 'Проверить холодильники',
      'typeId': 'checklist',
      'usesTemplate': true,
      'templateCode': 'sanitary', // шаблон в кэше есть — и редакция у него есть
      'objectId': 'b24',
      'performerId': 'ivanov',
    });
    await app.home.createFromAiDraft(draft);
    await Future.wait(pushes);

    // заполнять будет исполнитель, потом — по той редакции, что будет текущей
    expect(server.created['templateId'], 'sanitary');
    expect(server.created.containsKey('templateVersion'), isFalse);
    app.dispose();
  });

  test('задача, чей бланк ещё не приехал, уходит без номера', () async {
    final app = await phone();
    await app.repo.createTask(
      typeId: 'checklist',
      objectId: 'b24',
      name: 'Санитарное состояние',
      templateCode: 'sanitary', // бланк у задачи есть, а шаблона под рукой нет
    );
    await Future.wait(pushes);

    expect(server.created['templateId'], 'sanitary');
    expect(server.created.containsKey('templateVersion'), isFalse);
    app.dispose();
  });

  test('сервер без редакций: номера нет ни в кэше, ни в создании', () async {
    server.templates = _templates(null);
    final app = await phone();
    final template = app.home.quickCreate.templates['sanitary'];
    expect(template, isNotNull);
    expect(template!.version, isNull);

    await app.home.createFromPreset(sudden(app));
    await Future.wait(pushes);

    // тело — как до #37175: код шаблона и ничего сверх него
    expect(server.created['templateId'], 'sanitary');
    expect(server.created.containsKey('templateVersion'), isFalse);
    app.dispose();
  });
}
