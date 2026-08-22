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
  });

  factory AiDraft.fromJson(Map<String, dynamic> j) => AiDraft(
        dialogId: _str(j['dialogId']) ?? '',
        step: _int(j['step']) ?? 1,
        // Пустой ответ сервера — тоже ответ: разбирать нечего, и это ошибка, а не «ok».
        outcome: _str(j['outcome']) ?? 'error',
        question: _str(j['question']),
        message: _str(j['message']),
        errorCode: _str(j['errorCode']),
        warning: _str(j['warning']),
        name: _str(j['name']),
        typeId: _str(j['typeId']),
        typeName: _str(j['typeName']),
        usesTemplate: _flag(j['usesTemplate']),
        objectId: _str(j['objectId']),
        objectName: _str(j['objectName']),
        objectAddress: _str(j['objectAddress']),
        performerId: _str(j['performerId']),
        performerName: _str(j['performerName']),
        templateCode: _str(j['templateCode']),
        templateName: _str(j['templateName']),
        deadline: _str(j['deadline']),
        priorityId: _str(j['priorityId']),
        priorityName: _str(j['priorityName']),
        photoRequired: _flag(j['photoRequired']),
        description: _str(j['description']),
        confidence: _num(j['confidence']),
        optionsFor: _str(j['optionsFor']),
        // объекты и исполнители приезжают разными списками — непустым будет тот,
        // о котором спросили
        options: [
          ..._options(j['objectOptions']),
          ..._options(j['performerOptions']),
        ],
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
        typeId: typeId,
        typeName: typeName,
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
      );

  static const _keep = Object();

  static String? _str(Object? v) {
    if (v == null) return null;
    final s = '$v'.trim();
    return s.isEmpty ? null : s;
  }

  static int? _int(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse('${v ?? ''}');
  }

  static double? _num(Object? v) {
    if (v is num) return v.toDouble();
    return double.tryParse('${v ?? ''}'.replaceAll(',', '.'));
  }

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
        id: AiDraft._str(j['id']) ?? '',
        name: AiDraft._str(j['name']) ?? AiDraft._str(j['id']) ?? '',
        note: AiDraft._str(j['note']),
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
        model: AiDraft._str(j['model']),
      );
}
