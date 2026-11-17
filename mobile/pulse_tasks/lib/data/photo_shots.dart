import '../models/fill.dart';

/// Покадровая галерея одного набора снимков — пункта бланка или отчёта поручения:
/// очередь этого телефона поверх индексов, которые называет сервер. Одна на оба
/// набора: сервер нумерует их одинаково («максимум + 1», после удаления индексы не
/// уплотняются), и две копии сверки разошлись бы на первой же правке.
///
/// [rows] — строки очереди набора (`idx`, `path`, `uploaded`, `serverIdx`); строка
/// без пути — намерение «стереть набор», в галерею не входит. [server] — индексы,
/// которые сервер называет сейчас; [deleted] — уже поставленные в очередь удаления,
/// их в галерее нет.
///
/// Сверка (а не догадка) — то, чем серверный список тут ценен: снимки, уехавшие
/// прошлой версией приложения, своего индекса не знают, и раздать им свободные
/// серверные индексы по порядку отправки — единственный способ научиться удалять их
/// поштучно. Назначенные индексы не отбираются, даже если сервер их сейчас не
/// называет: список мог быть прочитан ДО того, как этот кадр уехал, а лишнее
/// удаление по несуществующему индексу сервер и так проглотит.
///
/// Возвращает кадры в порядке показа, серверные индексы без очереди удалений и
/// индексы, назначенные сверкой (локальный idx → серверный): их вызывающий
/// записывает в свою очередь.
({List<FillShot> shots, List<int> server, Map<int, int> assigned})
    assembleShots(List<Map<String, Object?>> rows, Iterable<int> server,
        Set<int> deleted) {
  // кадры с файлом; строки sqflite только для чтения, поэтому назначенные индексы
  // копятся рядом
  final files = [for (final r in rows) if (r['path'] != null) r];
  // Один индекс у двух строк — след прежнего дренажа без экрана, который давал всем
  // кадрам прохода индекс 1. Такой индекс адресует не тот кадр, поэтому он забыт, и
  // строки получают индексы сверкой заново.
  final seen = <int>{}, twice = <int>{};
  for (final r in files) {
    final s = r['serverIdx'] as int?;
    if (s != null && !seen.add(s)) twice.add(s);
  }
  final serverIdxOf = <int, int>{
    for (final r in files)
      if (r['serverIdx'] != null && !twice.contains(r['serverIdx']))
        r['idx'] as int: r['serverIdx'] as int
  };
  final claimed = <int, Map<String, Object?>>{
    for (final r in files)
      if (serverIdxOf[r['idx'] as int] != null) serverIdxOf[r['idx'] as int]!: r
  };
  final named = [for (final i in server) if (!deleted.contains(i)) i];
  // свободные серверные индексы достаются отправленным кадрам без индекса — в
  // порядке отправки, ведь сервер дописывает снимки в конец
  final unclaimed = [for (final i in named) if (!claimed.containsKey(i)) i];
  final assigned = <int, int>{};
  var next = 0;
  for (final r in files) {
    final local = r['idx'] as int;
    if (serverIdxOf[local] != null || (r['uploaded'] as int? ?? 0) == 0) {
      continue;
    }
    if (next >= unclaimed.length) break;
    final idx = unclaimed[next++];
    serverIdxOf[local] = idx;
    claimed[idx] = r;
    assigned[local] = idx;
  }

  final shots = <FillShot>[];
  final used = <int>{};
  for (final i in named) {
    final r = claimed[i];
    if (r == null) {
      shots.add(FillShot(serverIndex: i, uploaded: true));
    } else {
      used.add(r['idx'] as int);
      shots.add(FillShot(
          path: r['path'] as String,
          localIdx: r['idx'] as int,
          serverIndex: i,
          uploaded: true));
    }
  }
  // кадры очереди, которых сервер ещё не называет: снятые офлайн и только что
  // отправленные (список старше отправки)
  for (final r in files) {
    final local = r['idx'] as int;
    if (used.contains(local)) continue;
    shots.add(FillShot(
      path: r['path'] as String,
      localIdx: local,
      serverIndex: serverIdxOf[local],
      uploaded: (r['uploaded'] as int? ?? 0) != 0,
    ));
  }
  return (shots: shots, server: named, assigned: assigned);
}

/// Индекс, который сервер даст только что отправленному кадру набора: он нумерует их
/// как «максимум существующего + 1» (`lastPhotoIndex`), а максимум отправитель знает —
/// из того, что сервер называл в последний раз ([server]), из индексов, уже
/// назначенных своим кадрам ([rows]), и из стоящих в очереди удаления ([deleted]: на
/// сервере они ещё живы, удаления уходят ПОСЛЕ загрузок).
///
/// Догадка нужна, чтобы снятый кадр можно было удалить сразу, не переоткрывая экран.
/// Знание набора тут не только у экрана: дренаж без экрана читает тот же список из
/// кэша — иначе каждый кадр его прохода получал бы индекс 1, каким бы ни был
/// настоящий, и удаление второго стирало бы на сервере первый.
int nextServerIndex(Iterable<int> server, List<Map<String, Object?>> rows,
    Iterable<int> deleted) {
  var max = 0;
  for (final i in [
    ...server,
    for (final r in rows)
      if (r['serverIdx'] != null) r['serverIdx'] as int,
    ...deleted,
  ]) {
    if (i > max) max = i;
  }
  return max + 1;
}
