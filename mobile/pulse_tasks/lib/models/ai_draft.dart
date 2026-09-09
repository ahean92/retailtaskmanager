import 'json.dart';

/// Черновик задачи, собранный AI по фразе человека, — зеркало ответа `apiAiDraft`.
///
/// Три исхода в одном объекте, потому что экран рисует их тремя состояниями:
///   ok      — задача распознана, показываем карточку и кнопку «Создать»;
///   clarify — данных не хватило, показываем вопрос и поле для ответа;
///   error   — модель недоступна или ответила не тем, показываем фразу и «Повторить».
///
/// Черновик НЕ задача. Он ничего не создаёт: создание идёт обычным путём — той же
/// очередью и той же ручкой `apiCreateTask`, что и у пресетов, с clientId = [dialogId].
/// Поэтому здесь нет ни одного поля, которого не было бы в обычной задаче.
class AiDraft {
  /// Ключ разговора: телефон рождает его, открывая экран AI, повторяет во всех
  /// уточнениях и с ним же создаёт задачу. Один разговор — одна задача.
  final String dialogId;

  /// Номер шага: 1 — исходная фраза, дальше — ответы на уточняющие вопросы.
  final int step;

  /// ok | clarify | error
  final String outcome;

  /// Вопрос человеку — когда [outcome] == 'clarify'.
  final String? question;

  /// Понятная фраза об ошибке и её код — когда [outcome] == 'error'.
  final String? message;
  final String? errorCode;

  /// Замечание к разобранному черновику: «срок в прошлом», «у исполнителя нет роли
  /// на этом объекте». Не мешает создать задачу, но человек должен это увидеть.
  final String? warning;

  final String? name;
  final String? typeId;
  final String? typeName;

  /// Тип выполняется по бланку: такой задаче нужен шаблон, и создавать её «на другого»
  /// бессмысленно — заполнять бланк может только исполнитель.
  final bool usesTemplate;

  final String? objectId;
  final String? objectName;
  final String? objectAddress;

  final String? performerId;
  final String? performerName;

  final String? templateCode;
  final String? templateName;

  /// ISO-дата, как её отдаёт lsFusion.
  final String? deadline;

  final String? priorityId;
  final String? priorityName;

  /// Фото при выполнении обязательно — когда об этом сказано в запросе.
  final bool photoRequired;

  final String? description;

  /// Чем можно заменить тип, выбранный моделью. Список считает сервер и присылает
  /// вместе с черновиком: он уже отфильтрован правилом «бланк только на бланочном
  /// типе», поэтому любой из этих типов можно поставить, ничего больше не меняя.
  /// Пусто или один — менять не на что, и выбор не показывается.
  final List<AiOption> typeOptions;

  /// Что именно уточняется: object | named | performer. По нему экран понимает, куда
  /// класть выбранный вариант.
  final String? optionsFor;

  /// Варианты к уточняющему вопросу — их посчитал сервер тем же поиском, которым задал
  /// вопрос. Выбор пальцем применяется на месте, без повторного обращения к модели:
  /// всё остальное в черновике уже разобрано на этом же шаге.
  final List<AiOption> options;

  /// Насколько модель уверена в разборе, 0..1. Показывается только когда низкая:
  /// «уверенность 0.92» человеку ничего не говорит, а «AI не уверен» — говорит.
  final double? confidence;

  const AiDraft({
    required this.dialogId,
    this.step = 1,
    this.outcome = 'ok',
    this.question,
    this.message,
    this.errorCode,
    this.warning,
    this.name,
    this.typeId,
    this.typeName,
    this.usesTemplate = false,
    this.objectId,
    this.objectName,
    this.objectAddress,
    this.performerId,
    this.performerName,
    this.templateCode,
    this.templateName,
    this.deadline,
    this.priorityId,
    this.priorityName,
    this.photoRequired = false,
    this.description,
    this.confidence,
    this.optionsFor,
    this.options = const [],
    this.typeOptions = const [],
  });

  factory AiDraft.fromJson(Map<String, dynamic> j) => AiDraft(
        dialogId: jsonStr(j['dialogId']) ?? '',
        step: jsonInt(j['step']) ?? 1,
        // Пустой ответ сервера — тоже ответ: разбирать нечего, и это ошибка, а не «ok».
        outcome: jsonStr(j['outcome']) ?? 'error',
        question: jsonStr(j['question']),
        message: jsonStr(j['message']),
        errorCode: jsonStr(j['errorCode']),
        warning: jsonStr(j['warning']),
        name: jsonStr(j['name']),
        typeId: jsonStr(j['typeId']),
        typeName: jsonStr(j['typeName']),
        usesTemplate: _flag(j['usesTemplate']),
        objectId: jsonStr(j['objectId']),
        objectName: jsonStr(j['objectName']),
        objectAddress: jsonStr(j['objectAddress']),
        performerId: jsonStr(j['performerId']),
        performerName: jsonStr(j['performerName']),
        templateCode: jsonStr(j['templateCode']),
        templateName: jsonStr(j['templateName']),
        deadline: jsonStr(j['deadline']),
        priorityId: jsonStr(j['priorityId']),
        priorityName: jsonStr(j['priorityName']),
        photoRequired: _flag(j['photoRequired']),
        description: jsonStr(j['description']),
        confidence: jsonNum(j['confidence']),
        optionsFor: jsonStr(j['optionsFor']),
        // объекты и исполнители приезжают разными списками — непустым будет тот,
        // о котором спросили
        options: [
          ..._options(j['objectOptions']),
          ..._options(j['performerOptions']),
        ],
        typeOptions: _options(j['typeOptions']),
      );

  static List<AiOption> _options(Object? raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((e) => AiOption.fromJson(e.cast<String, dynamic>()))
        .toList();
  }

  bool get isOk => outcome == 'ok';
  bool get needsClarification => outcome == 'clarify';
  bool get isError => outcome == 'error';

  /// Что мешает создать задачу прямо сейчас. NULL — можно создавать. Проверка та же,
  /// что у экрана создания по пресету: сервер отвергнет такой create теми же словами
  /// («typeId required», «objectId required»), а очередь создания не имеет пути отмены.
  String? get missing {
    if (typeId == null) return 'AI не определил тип задачи';
    if (objectId == null) return 'Не выбран объект';
    if (name == null || name!.trim().isEmpty) return 'Укажите название задачи';
    return null;
  }

  DateTime? get deadlineDate {
    final d = deadline;
    if (d == null) return null;
    final parsed = DateTime.tryParse(d);
    return parsed == null ? null : DateTime(parsed.year, parsed.month, parsed.day);
  }

  /// Показываем предупреждение о слабой уверенности, а не само число: человеку важно
  /// «проверь внимательнее», а не «0.42».
  bool get lowConfidence => confidence != null && confidence! < 0.5;

  AiDraft copyWith({
    String? outcome,
    String? name,
    String? typeId,
    String? typeName,
    String? objectId,
    String? objectName,
    String? objectAddress,
    String? performerId,
    String? performerName,
    Object? deadline = _keep,
    bool? photoRequired,
    Object? description = _keep,
  }) =>
      AiDraft(
        dialogId: dialogId,
        step: step,
        outcome: outcome ?? this.outcome,
        question: question,
        message: message,
        errorCode: errorCode,
        warning: warning,
        name: name ?? this.name,
        typeId: typeId ?? this.typeId,
        typeName: typeName ?? this.typeName,
        // смена типа его не трогает: сервер предлагает на замену только типы той же
        // бланочности, поэтому «по бланку» после подмены остаётся тем же, чем было
        usesTemplate: usesTemplate,
        objectId: objectId ?? this.objectId,
        objectName: objectName ?? this.objectName,
        objectAddress: objectAddress ?? this.objectAddress,
        performerId: performerId ?? this.performerId,
        performerName: performerName ?? this.performerName,
        templateCode: templateCode,
        templateName: templateName,
        // срок и описание можно СНЯТЬ, поэтому у них отдельный часовой: null здесь
        // означает «убрать», а не «оставить как было»
        deadline: deadline == _keep ? this.deadline : deadline as String?,
        priorityId: priorityId,
        priorityName: priorityName,
        photoRequired: photoRequired ?? this.photoRequired,
        description:
            description == _keep ? this.description : description as String?,
        confidence: confidence,
        optionsFor: optionsFor,
        options: options,
        typeOptions: typeOptions,
      );

  static const _keep = Object();

  /// lsFusion не выгружает NULL: флаг либо есть со значением true, либо его нет вовсе.
  static bool _flag(Object? v) {
    if (v is bool) return v;
    if (v is num) return v != 0;
    return '$v'.toLowerCase() == 'true';
  }
}

/// Вариант выбора к уточняющему вопросу: магазин или человек.
class AiOption {
  final String id;
  final String name;

  /// Чем этот вариант отличается от соседнего: адрес магазина, роль человека.
  /// Без него «С - 2 г. Брест» и «С - 3 г. Брест» в списке неразличимы.
  final String? note;

  const AiOption({required this.id, required this.name, this.note});

  factory AiOption.fromJson(Map<String, dynamic> j) => AiOption(
        id: jsonStr(j['id']) ?? '',
        name: jsonStr(j['name']) ?? jsonStr(j['id']) ?? '',
        note: jsonStr(j['note']),
      );
}

/// Что сервер отвечает про сам AI (`apiAiInfo`): включён ли он и какая модель.
/// Кнопки «AI» в приложении нет, пока сервер не сказал «включён», — на стенде без
/// AI-сервиса человек упирался бы в ошибку вместо ответа.
class AiInfo {
  final bool enabled;
  final String? model;

  const AiInfo({this.enabled = false, this.model});

  factory AiInfo.fromJson(Map<String, dynamic> j) => AiInfo(
        enabled: AiDraft._flag(j['enabled']),
        model: jsonStr(j['model']),
      );
}
