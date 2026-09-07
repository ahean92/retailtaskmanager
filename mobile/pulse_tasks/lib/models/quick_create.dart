// Создание задачи в поле: пресеты и предзагруженные справочники, зеркало
// apiQuickActions / apiTemplates / apiPerformers (#36713).
//
// Всё это приезжает при синхронизации и живёт в кэше: проверяющий стоит в магазине
// без связи, и к моменту «создать» бланк и список людей уже должны быть на телефоне.
// Задачи на сервере ещё нет, поэтому здесь нет ни одного taskId — данные адресуются
// кодами справочников, как их отдаёт сервер.

import 'dart:convert';

import 'fill.dart';
import 'json.dart';

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
        icon: jsonStr(j['icon']),
        typeId: jsonStr(j['typeId']),
        templateCode: jsonStr(j['template']),
        assign: jsonStr(j['assign']) ?? 'self',
        roleId: jsonStr(j['role']),
        deadlineDays: jsonInt(j['deadlineDays']),
        priorityId: jsonStr(j['priorityId']),
        executionKind: jsonStr(j['executionKind']),
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
    final fieldsRaw = jsonMaps(j['fields']);
    final optionsRaw = jsonMaps(j['options']);
    final columnsRaw = jsonMaps(j['columns']);
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
      name: jsonStr(j['name']),
      note: jsonStr(j['note']),
      passThreshold: jsonNum(j['passThreshold']),
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
        roles: jsonList(j['roles'], PerformerRole.fromJson),
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

/// Объект, на который ставится задача, — как его знают экраны создания: из соседей по
/// координатам или из объектов главной, поэтому не привязан ни к одному из их типов.
typedef CreateObject = ({String id, String name, String? address});

/// Черновик задачи по пресету — то, что человек заполнил на экране создания, и правила
/// над этим: кому уйдёт задача и чего ещё не хватает. Без экрана и без базы: экран
/// рисует поля, решает — этот класс, а HomeController по нему создаёт задачу.
class PresetDraft {
  final QuickPreset preset;

  /// Шаблон бланочного пресета из кэша; null — пресет без бланка или бланк ещё не приехал.
  final PresetTemplate? template;

  /// Куда; null — объект не выбран, и создавать нельзя.
  final CreateObject? object;
  final String name;
  final String description;
  final DateTime? deadline;

  /// Кадры автора («вот бардак на витрине») — пути к снимкам из камеры/галереи.
  final List<String> photoPaths;

  /// Выбранный вручную исполнитель (для политик pick/byRole со списком).
  final Performer? picked;

  const PresetDraft({
    required this.preset,
    this.template,
    this.object,
    this.name = '',
    this.description = '',
    this.deadline,
    this.photoPaths = const [],
    this.picked,
  });

  /// Кому уйдёт задача. NULL при политике self — сервер сам назначит на создателя,
  /// и это надёжнее, чем пересылать ему его же идентификатор.
  Performer? assignee(QuickCreateData data) {
    switch (preset.assign) {
      case 'pick':
        final all = data.performers;
        return picked != null && all.any((c) => c.id == picked!.id)
            ? picked
            : null;
      case 'byRole':
        final objectId = object?.id;
        if (objectId == null || preset.roleId == null) return null;
        final candidates = data.byRole(objectId, preset.roleId!);
        if (candidates.length == 1) return candidates.first;
        return picked != null && candidates.any((c) => c.id == picked!.id)
            ? picked
            : null;
      default:
        return null;
    }
  }

  /// Первая недостающая вещь — подпись под выключенной кнопкой. NULL — можно создавать.
  String? missing(QuickCreateData data) {
    if (preset.typeId == null) {
      // сервер отвергнет такой create ('typeId required'), а очередь создания не
      // имеет пути отмены — лучше не дать создать вовсе; чинится в бэк-офисе
      return 'Пресет настроен без типа задачи — сообщите администратору';
    }
    if (object == null) return 'Не выбран объект';
    if (preset.templateCode != null && template == null) {
      return 'Бланк ещё не приехал с сервера';
    }
    if (name.trim().isEmpty) return 'Укажите название';
    switch (preset.assign) {
      case 'self':
        break;
      case 'pick':
        if (assignee(data) == null) return 'Выберите исполнителя';
      case 'byRole':
        if (assignee(data) == null) {
          return 'На этом объекте нет исполнителя с нужной ролью';
        }
      default:
        // политика из будущей версии сервера: рисовать нечего, создавать — тем более
        return 'Неизвестный способ назначения «${preset.assign}»';
    }
    if (preset.requireComment && description.trim().isEmpty) {
      return 'Опишите, что нужно сделать';
    }
    return null;
  }
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

