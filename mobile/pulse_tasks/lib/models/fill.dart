// Generic fillable-execution models, mirroring the server's unified engine
// (apiExecution*). A field is rendered by its type; the answer lives in the
// type-appropriate value slot. Field codes are stable and used for addressing.
//
// Модели разложены по файлам fill/, импорт остаётся один: поле, таблица, итог,
// кандидаты справочника и сборка из ответов сервера — стороны одного бланка, и экрану
// обычно нужны все.

export 'fill/assemble.dart';
export 'fill/field.dart';
export 'fill/ref_candidate.dart';
export 'fill/score.dart';
export 'fill/table.dart';
