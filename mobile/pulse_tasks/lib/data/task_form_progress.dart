import 'dart:convert';

import '../models/fill.dart';
import '../models/json.dart';
import 'task_repository.dart';

/// Бланк задачи для её карточки (#37411, п. 5): «Заполнение N из M», разделы с
/// готовностью и есть ли у объекта прошлая проверка — из кэша бланка на телефоне.
/// Только чтение: выполнения не заводит (в отличие от FillController.load), строку
/// кэша при связи освежает [TaskRepository.fillCacheForCard].
///
/// Поверх кэша накладывается то, что ещё не уехало (то же наложение, что в бланке —
/// overlayOutbox): заполненное офлайн видно в прогрессе сразу, а не после появления
/// связи.
class TaskFormProgress {
  final List<FillField> fields;

  /// Есть ли у объекта прошлая проверка — по prevDate шапки бланка.
  final bool hasPast;

  const TaskFormProgress(this.fields, {required this.hasPast});

  int get answered => fields.where((f) => f.answered).length;

  /// Готовность разделов в порядке бланка. Имя — первое непустое имя раздела у его
  /// пунктов, без него — «Раздел N».
  List<SectionProgress> get sections => [
        for (final i in fields.sectionIndexes)
          () {
            final list = fields.where((f) => f.sectionIndex == i).toList();
            return SectionProgress(
              list
                      .firstWhere((f) => (f.section ?? '').isNotEmpty,
                          orElse: () => list.first)
                      .section ??
                  'Раздел ${i + 1}',
              answered: list.where((f) => f.answered).length,
              total: list.length,
            );
          }(),
      ];

  /// Раздел, куда продолжать: первый с незаполненными пунктами. null — всё
  /// заполнено, осталось проверить и завершить.
  String? get nextSection {
    for (final s in sections) {
      if (!s.complete) return s.name;
    }
    return null;
  }

  /// Бланк задачи [taskId] для карточки; null — бланка у задачи нет или его не
  /// прочесть. Архивная закрытая — без бланка: карточка про «что было», и заведение
  /// выполнения по закрытой задаче сервер всё равно не примет. Наблюдателю бланк
  /// сервер не отдаёт — запрос на каждом открытии карточки уходил бы в отказ.
  /// [force] — возврат из бланка: там всё может измениться быстрее, чем за 30
  /// секунд, и возраст кэша ничего не говорит.
  static Future<TaskFormProgress?> load(TaskRepository repo, String taskId,
      {bool force = false}) async {
    final view = repo.viewOf(taskId);
    if (view == null ||
        view.archived ||
        view.watchedOnly ||
        !view.task.opensFill) {
      return null;
    }
    final db = repo.localDb;
    if (db == null) return null;
    final id = view.task.clientId ?? taskId;
    final c = await repo.fillCacheForCard(id, force: force);
    if (c == null) return null;
    final List<FillField> fields;
    final String? prevDate;
    try {
      final fieldsRaw =
          (jsonDecode(c['fieldsJson'] as String) as List).cast<dynamic>();
      final optionsRaw =
          (jsonDecode(c['optionsJson'] as String) as List).cast<dynamic>();
      final columnsRaw =
          jsonDecode((c['columnsJson'] as String?) ?? '[]') as List;
      final rowsRaw = jsonDecode((c['rowsJson'] as String?) ?? '[]') as List;
      fields = assembleFillFields(fieldsRaw, optionsRaw, columnsRaw, rowsRaw);
      prevDate = jsonStr((jsonDecode((c['infoJson'] as String?) ?? '{}')
          as Map)['prevDate']);
    } catch (_) {
      // нечитаемый кэш — блока прогресса просто не будет
      return null;
    }
    // кадры, ждущие отправки: у поля-фото снимок и есть ответ (path null — это
    // команда «стереть весь набор», а не кадр)
    final pendingShots = <String, List<String>>{};
    for (final e in await db.fill.getPendingFillPhotos(id)) {
      final path = e['path'] as String?;
      if (path == null) continue;
      pendingShots.putIfAbsent(e['fieldCode'] as String, () => []).add(path);
    }
    overlayOutbox(
      fields,
      fieldOutbox: await db.fill.getFieldOutbox(id),
      rowOutbox: await db.fill.getRowOutbox(id),
      cellOutbox: await db.fill.getCellOutbox(id),
      pendingPhotoPaths: pendingShots,
    );
    return TaskFormProgress(fields, hasPast: prevDate != null);
  }
}

/// Раздел бланка на карточке задачи: имя и сколько пунктов из скольких отвечено.
class SectionProgress {
  final String name;
  final int answered;
  final int total;
  const SectionProgress(this.name,
      {required this.answered, required this.total});

  bool get complete => answered >= total;
}
