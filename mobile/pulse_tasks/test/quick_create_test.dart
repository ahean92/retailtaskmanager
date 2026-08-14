import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_tasks/models/quick_create.dart';

// Фикстуры — дословные ответы стенда (#36713): apiQuickActions / apiTemplates /
// apiPerformers для demo.user1. Если контракт ручек поедет, эти строки должны
// перестать парситься именно здесь, а не в поле.
const _actions = '''
[{"code":"sudden","title":"Внезапная проверка","icon":"🔍","typeId":"checklist","template":"showcase","assign":"self","deadlineDays":1,"priorityId":"high","requirePhoto":true},
 {"code":"errand","title":"Поручение","icon":"📌","typeId":"issue","assign":"pick","deadlineDays":3,"priorityId":"normal","requireComment":true},
 {"code":"logistCheck","title":"Проверка логистики (демо)","icon":"🚚","typeId":"form","template":"showcase","assign":"byRole","role":"duty","deadlineDays":2,"priorityId":"low"}]
''';

const _templates = '''
[{"code":"showcase","name":"Внезапная проверка витрины (демо)","note":"Демо-набор тикета #36713","passThreshold":80,
  "fields":[
    {"sectionIndex":1,"fieldIndex":1,"code":"clean","requirePhoto":true,"name":"Чистота витрины","weight":2,"section":"Витрина","type":"scale","required":true},
    {"sectionIndex":1,"fieldIndex":2,"unit":"°C","code":"temp","name":"Температура витрины","weight":1,"minNorm":2,"section":"Витрина","type":"number","maxNorm":6,"required":true},
    {"sectionIndex":1,"fieldIndex":3,"code":"note","name":"Замечание","weight":1,"section":"Витрина","type":"text"},
    {"sectionIndex":2,"fieldIndex":1,"code":"prices","name":"Сверка ценников","weight":1,"section":"Ценники","type":"table"}],
  "options":[
    {"score":2,"code":"ok","fieldCode":"clean","name":"Чисто"},
    {"score":0,"code":"dirty","fieldCode":"clean","name":"Грязно","nonconformity":true},
    {"code":"na","fieldCode":"clean","name":"Н/П","notApplicable":true}],
  "columns":[
    {"fieldCode":"prices","name":"Товар","colCode":"product","colIndex":1,"type":"text"},
    {"fieldCode":"prices","name":"Цена на полке","colCode":"shelf","colIndex":2,"compareTo":"system","type":"number"},
    {"readonly":true,"fieldCode":"prices","name":"Цена в системе","colCode":"system","colIndex":3,"type":"number"}]}]
''';

const _performers = '''
[{"id":"demo.user1","name":"Пётр Выездной","roles":[{"role":"manager","object":"910001"},{"role":"duty","object":"910002"}]},
 {"id":"demo.user2","name":"Сергей Наладчиков","roles":[{"role":"duty","object":"910001"}]}]
''';

void main() {
  test('парсит ответы всех трёх ручек как их отдаёт сервер', () {
    final d = QuickCreateData.parse(_actions, _templates, _performers);

    expect(d.isEmpty, isFalse);
    expect(d.actions, hasLength(3));

    final sudden = d.actions.first;
    expect(sudden.code, 'sudden');
    expect(sudden.assign, 'self');
    expect(sudden.templateCode, 'showcase');
    expect(sudden.requirePhoto, isTrue);
    expect(sudden.deadlineDays, 1);

    // у поручения бланка нет — и это не ошибка, а тип без шаблона
    final errand = d.actions[1];
    expect(errand.templateCode, isNull);
    expect(errand.assign, 'pick');

    final byRole = d.actions[2];
    expect(byRole.assign, 'byRole');
    expect(byRole.roleId, 'duty');
    expect(d.templateOf(byRole)?.code, 'showcase');
  });

  test('раскладывает варианты и колонки по полям бланка', () {
    final d = QuickCreateData.parse(_actions, _templates, _performers);
    final t = d.templates['showcase']!;

    expect(t.fields, hasLength(4));
    expect(t.passThreshold, 80);

    final clean = t.fields.firstWhere((f) => f.code == 'clean');
    expect(clean.options.map((o) => o.code), ['ok', 'dirty', 'na']);
    expect(clean.options[1].nonconformity, isTrue);

    final prices = t.fields.firstWhere((f) => f.code == 'prices');
    // колонки отсортированы по colIndex, readonly доехал
    expect(prices.columns.map((c) => c.code), ['product', 'shelf', 'system']);
    expect(prices.columns.last.readonly, isTrue);
    expect(prices.columns[1].compareTo, 'system');

    // у поля без вариантов их и нет — раскладка не размазывает чужое
    final temp = t.fields.firstWhere((f) => f.code == 'temp');
    expect(temp.options, isEmpty);
    expect(temp.minNorm, 2);
    expect(temp.maxNorm, 6);
  });

  test('byRole собирает кандидатов по паре (объект, роль)', () {
    final d = QuickCreateData.parse(_actions, _templates, _performers);

    expect(d.byRole('910001', 'duty').map((p) => p.id), ['demo.user2']);
    expect(d.byRole('910002', 'duty').map((p) => p.id), ['demo.user1']);
    expect(d.byRole('910001', 'manager').map((p) => p.id), ['demo.user1']);
    // на пустом месте — пусто, а не ошибка
    expect(d.byRole('910003', 'duty'), isEmpty);
  });

  test('пустые тела lsFusion — это «пресетов нет», а не ошибка', () {
    final d = QuickCreateData.parse('', '', '');
    expect(d.isEmpty, isTrue);
    expect(d.templates, isEmpty);
    expect(d.performers, isEmpty);
  });
}
