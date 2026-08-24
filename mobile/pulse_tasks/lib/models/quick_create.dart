// Создание задачи в поле: пресеты и предзагруженные справочники, зеркало
// apiQuickActions / apiTemplates / apiPerformers (#36713).
//
// Всё это приезжает при синхронизации и живёт в кэше: проверяющий стоит в магазине
// без связи, и к моменту «создать» бланк и список людей уже должны быть на телефоне.
// Задачи на сервере ещё нет, поэтому здесь нет ни одного taskId — данные адресуются
// кодами справочников, как их отдаёт сервер.

import 'dart:convert';

import 'fill.dart';

/// Кнопка «создать» как её настроили в бэк-офисе. Сервер уже отфильтровал пресеты по
/// ролям текущего пользователя — клиент рисует всё, что пришло, в порядке прихода.
class QuickPreset {
  final String code;
  final String title;

  /// Эмодзи из настройки — как у блока главной: новая кнопка получает картинку из
  /// формы настройки, а не из релиза клиента.
  final String? icon;

  final String? typeId;

  /// Код шаблона для бланочных типов; у поручения его нет.
  final String? templateCode;

  /// self | pick | byRole — кому назначается создаваемая задача.
  final String assign;

  /// Роль на объекте для byRole.
  final String? roleId;

  final int? deadlineDays;
  final String? priorityId;

  /// Чем задача этого пресета будет выполняться (#36872): `fill` — бланк, `simple` —
  /// фотоотчёт, null — старый сервер признака не шлёт. Кладётся в локальную строку
  /// задачи при создании, поэтому поручение, созданное без связи, открывается своим
  /// экраном сразу — не дожидаясь, пока сервер подтвердит создание и вернёт задачу.
  final String? executionKind;
  final bool requirePhoto;
  final bool requireComment;

  const QuickPreset({
    required this.code,
    required this.title,
    this.icon,
    this.typeId,
    this.templateCode,
    this.assign = 'self',
    this.roleId,
    this.deadlineDays,
    this.priorityId,
    this.executionKind,
    this.requirePhoto = false,
    this.requireComment = false,
  });

  factory QuickPreset.fromJson(Map<String, dynamic> j) => QuickPreset(
        code: j['code']?.toString() ?? '',
        title: j['title']?.toString() ?? '',
        icon: _str(j['icon']),
        typeId: _str(j['typeId']),
        templateCode: _str(j['template']),
        assign: _str(j['assign']) ?? 'self',
        roleId: _str(j['role']),
        deadlineDays: _int(j['deadlineDays']),
        priorityId: _str(j['priorityId']),
        executionKind: _str(j['executionKind']),
        requirePhoto: j['requirePhoto'] == true,
        requireComment: j['requireComment'] == true,
      );
}

/// Шаблон целиком, как его отдаёт apiTemplates: поля с уже разложенными по ним
/// вариантами и колонками. Состав полей — тот же, что в apiExecutionFields, поэтому
/// модели бланка (FillField и компания) переиспользованы как есть.
class PresetTemplate {
  final String code;
  final String? name;
  final String? note;
  final double? passThreshold;
  final bool resolutionRequired;
  final List<FillField> fields;

  /// Сырые куски ответа apiTemplates — ими сеется fill_cache проверки, создаваемой на
  /// месте (#36716). Состав ключей у apiTemplates и apiExecutionFields/Options/Columns
  /// совпадает намеренно, поэтому FillController читает посеянный кэш тем же парсером,
  /// что и обычный, — «взять шаблон не от задачи» сводится к другому источнику JSON.
  final List<Map<String, dynamic>> fieldsRaw;
  final List<Map<String, dynamic>> optionsRaw;
  final List<Map<String, dynamic>> columnsRaw;

  const PresetTemplate({
    required this.code,
    this.name,
    this.note,
    this.passThreshold,
    this.resolutionRequired = false,
    this.fields = const [],
    this.fieldsRaw = const [],
    this.optionsRaw = const [],
    this.columnsRaw = const [],
  });

  factory PresetTemplate.fromJson(Map<String, dynamic> j) {
    final fieldsRaw = _rawList(j['fields']);
    final optionsRaw = _rawList(j['options']);
    final columnsRaw = _rawList(j['columns']);
    final fields = fieldsRaw.map(FillField.fromJson).toList();
    final options = optionsRaw.map(FillOption.fromJson).toList();
    final columns = columnsRaw.map(FillColumn.fromJson).toList();
    // та же раскладка, что в FillController.load: варианты и колонки — по коду поля
    final byOpt = <String, List<FillOption>>{};
    for (final o in options) {
      (byOpt[o.fieldCode] ??= []).add(o);
    }
    final byCol = <String, List<FillColumn>>{};
    for (final c in columns) {
      (byCol[c.fieldCode] ??= []).add(c);
    }
    for (final f in fields) {
      f.options = byOpt[f.code] ?? const [];
      final cols = byCol[f.code] ?? const <FillColumn>[];
      f.columns = [...cols]..sort((a, b) => a.colIndex.compareTo(b.colIndex));
    }
    return PresetTemplate(
      code: j['code']?.toString() ?? '',
      name: _str(j['name']),
      note: _str(j['note']),
      passThreshold: _num(j['passThreshold']),
      resolutionRequired: j['resolutionRequired'] == true,
      fields: fields,
      fieldsRaw: fieldsRaw,
      optionsRaw: optionsRaw,
      columnsRaw: columnsRaw,
    );
  }
}

/// Кому можно поручать: человек и его роли на объектах. Сервер отдаёт только тех,
/// у кого роль есть хотя бы где-то — полный список сотрудников сети в поле бесполезен.
class Performer {
  final String id;
  final String name;
  final List<PerformerRole> roles;

  const Performer({required this.id, required this.name, this.roles = const []});

  factory Performer.fromJson(Map<String, dynamic> j) => Performer(
        id: j['id']?.toString() ?? '',
        name: j['name']?.toString() ?? '',
        roles: _list(j['roles'], PerformerRole.fromJson),
      );

  bool hasRoleAt(String objectId, String roleId) =>
      roles.any((r) => r.objectId == objectId && r.roleId == roleId);
}

class PerformerRole {
  final String objectId;
  final String roleId;

  const PerformerRole({required this.objectId, required this.roleId});

  factory PerformerRole.fromJson(Map<String, dynamic> j) => PerformerRole(
        objectId: j['object']?.toString() ?? '',
        roleId: j['role']?.toString() ?? '',
      );
}

/// Всё, что нужно для кнопки «+» и заготовки, одним значением. Собирается из трёх
/// сырых ответов сервера — тех же строк, что лежат в кэше, поэтому парсинг один и
/// тот же и для свежего ответа, и для кэша, поднятого без сети.
class QuickCreateData {
  final List<QuickPreset> actions;
  final Map<String, PresetTemplate> templates; // по коду шаблона
  final List<Performer> performers;

  const QuickCreateData({
    this.actions = const [],
    this.templates = const {},
    this.performers = const [],
  });

  bool get isEmpty => actions.isEmpty;

  /// Пустое тело lsFusion шлёт вместо пустого массива — это «пресетов нет», а не ошибка.
  factory QuickCreateData.parse(
      String actionsJson, String templatesJson, String performersJson) {
    final templates = <String, PresetTemplate>{};
    for (final t in _decode(templatesJson).map(PresetTemplate.fromJson)) {
      if (t.code.isNotEmpty) templates[t.code] = t;
    }
    return QuickCreateData(
      actions: _decode(actionsJson).map(QuickPreset.fromJson).toList(),
      templates: templates,
      performers: _decode(performersJson).map(Performer.fromJson).toList(),
    );
  }

  PresetTemplate? templateOf(QuickPreset p) =>
      p.templateCode == null ? null : templates[p.templateCode];

  /// Исполнители с ролью [roleId] на объекте [objectId] — из них собирается вариант
  /// «назначить по роли».
  List<Performer> byRole(String objectId, String roleId) =>
      performers.where((p) => p.hasRoleAt(objectId, roleId)).toList();

  static List<Map<String, dynamic>> _decode(String body) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) return const [];
    final decoded = jsonDecode(trimmed);
    if (decoded is! List) return const [];
    return decoded
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
  }
}

String? _str(Object? v) {
  final s = v?.toString().trim();
  return (s == null || s.isEmpty) ? null : s;
}

int? _int(Object? v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse('$v');
}

double? _num(Object? v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse('$v');
}

List<T> _list<T>(Object? raw, T Function(Map<String, dynamic>) parse) {
  if (raw is! List) return const [];
  return raw
      .whereType<Map>()
      .map((e) => parse(e.cast<String, dynamic>()))
      .toList();
}

List<Map<String, dynamic>> _rawList(Object? raw) {
  if (raw is! List) return const [];
  return raw.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
}
