import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/fill.dart';
import 'api_client.dart';
import 'client_id.dart';
import 'fill_cache_store.dart';
import 'local_db.dart';
import 'photo_disk_cache.dart';
import 'photo_shots.dart';

/// Галерея снимков бланка одной задачи (0..N на пункт): очередь кадров этого телефона,
/// серверные индексы и сверка между ними, кэш скачанных с сервера кадров. Отдельно от
/// [FillController]: снимки — треть бланка по объёму и своя логика (сверка индексов,
/// призраки в кэше, файлы на диске), а правка ответов и дренаж о ней ничего не знают.
///
/// Что пересчитать, перерисовать и отправить после правки, решает контроллер: здесь
/// только кадры и строки их очереди.
class FillShots {
  final LocalDb db;
  final ApiClient api;
  final String taskId;

  /// Пункты загруженного бланка — у контроллера они меняются целиком при загрузке,
  /// поэтому берутся каждый раз заново, а не запоминаются.
  final List<FillField> Function() fields;

  /// Где лежат свои кадры и скачанные на время экрана — каталоги задаёт контроллер
  /// (FillController.photoDirectory / serverPhotoDirectory).
  final Future<Directory> Function() photoDirectory;
  final Future<Directory> Function() serverPhotoDirectory;

  FillShots(
      {required this.db,
      required this.api,
      required this.taskId,
      required this.fields,
      required this.photoDirectory,
      required this.serverPhotoDirectory});

  /// Appends a shot. Each one gets its own local index and its own queue entry, so a
  /// second photo never overwrites the first — on the device or on the server — and
  /// its own client key, by which the server recognizes a retried send (#37348).
  Future<void> add(FillField f, String sourcePath) async {
    final idx = await db.fill.nextPhotoIndex(taskId, f.code);
    final clientId = newClientId();
    final saved = await _persist(sourcePath, f, clientId);
    await db.fill.saveFillPhoto(taskId, f.code, idx, saved,
        DateTime.now().toIso8601String(),
        clientId: clientId);
    await rebuild();
  }

  /// Убрать ОДИН кадр пункта (#36946).
  ///
  /// Снятый и ещё не отправленный уходит из очереди и с устройства — на сервере он не
  /// появляется вовсе. Уехавший удаляется на сервере по своему индексу, обычной
  /// офлайн-очередью: индексы там не уплотняются, так что соседние кадры остаются на
  /// своих местах и переснимать их не нужно. Файл стирается сразу — он свой, а не
  /// серверный, и держать его после удаления значило бы занимать место снимком,
  /// которого в проверке уже нет.
  Future<void> delete(FillField f, FillShot shot) async {
    if (shot.serverIndex != null && (shot.uploaded || shot.path == null)) {
      await db.fill.enqueuePhotoDelete(
          taskId, f.code, shot.serverIndex!, DateTime.now().toIso8601String());
      // скачанная миниатюра этого кадра больше ничего не показывает
      await evictServer(f, shot.serverIndex!);
    }
    if (shot.localIdx != null) {
      await db.fill.deleteFillPhoto(taskId, f.code, shot.localIdx!);
      if (shot.path != null) {
        try {
          await File(shot.path!).delete();
        } catch (_) {}
      }
    }
    if (shot.serverIndex != null) {
      await _forgetInCache(f.code, shot.serverIndex!);
    }
    await rebuild();
  }

  /// Removes every photo of a field — одним пустым `photo`, а не N удалениями по
  /// индексам: сервер стирает набор целиком, и поштучные удаления после него уже не о
  /// чем (очередь их и снимает).
  Future<void> clear(FillField f) async {
    final old = [for (final s in f.shots) if (s.path != null) s.path!];
    // на сервере есть что стирать, если туда уехал хоть один кадр — в том числе
    // только что, ответом, в котором сервер своих индексов назвать ещё не успел
    final wasOnServer =
        f.serverPhotoCount > 0 || f.shots.any((s) => s.uploaded);
    // скачанные миниатюры набора больше ничего не показывают: нумерация на сервере
    // начнётся заново, и прежний файл по индексу 1 выдал бы себя за новый кадр
    for (final s in f.shots) {
      if (s.serverIndex != null) await evictServer(f, s.serverIndex!);
    }
    f.photoPaths = [];
    f.serverPhotoCount = 0;
    f.serverPhotoIndexes = [];
    f.shots = [];

    final rows = await db.fill.getFillPhotos(taskId);
    for (final e in rows) {
      if (e['fieldCode'] == f.code) {
        await db.fill.deleteFillPhoto(taskId, f.code, e['idx'] as int);
      }
    }
    await db.fill.clearPhotoDeletes(taskId, f.code);
    if (wasOnServer) {
      // an empty photo tells the server to drop the whole set for this field
      await db.fill.saveFillPhoto(
          taskId, f.code, 0, null, DateTime.now().toIso8601String());
      // и кэш бланка больше не называет этих снимков — иначе офлайн они вернутся
      // плитками «фото недоступно офлайн» (см. [_forgetInCache])
      await _forgetInCache(f.code, null);
    }
    for (final path in old) {
      try {
        await File(path).delete();
      } catch (_) {}
    }
  }

  /// Снимки прежнего выполнения, уже уехавшие с этого телефона (#37158): на сервере они
  /// остаются при сданном бланке, а строки и файлы здесь больше ничего не держат.
  /// Неотправленные не трогаются — стереть их значило бы потерять работу.
  Future<void> dropSent() async {
    for (final r in await db.fill.getFillPhotos(taskId)) {
      if ((r['uploaded'] as int? ?? 0) == 0) continue;
      await db.fill
          .deleteFillPhoto(taskId, r['fieldCode'] as String, r['idx'] as int);
      final path = r['path'] as String?;
      if (path == null) continue;
      try {
        await File(path).delete();
      } catch (_) {}
    }
  }

  /// Вычеркнуть удалённый кадр из кэша бланка — см. [FillCacheStore.forgetShot].
  Future<void> _forgetInCache(String fieldCode, int? index) =>
      FillCacheStore(db).forgetShot(taskId, fieldCode, index);

  /// Собрать покадровую галерею каждого пункта из очереди снимков и серверных
  /// индексов — и заодно сверить, под каким индексом на сервере лежит локальный файл
  /// (общая для бланка и поручения сверка — [assembleShots]).
  Future<void> rebuild() async {
    final rows = await db.fill.getFillPhotos(taskId);
    final deletes = await db.fill.getPhotoDeletes(taskId);
    final rowsByField = <String, List<Map<String, Object?>>>{};
    for (final r in rows) {
      rowsByField.putIfAbsent(r['fieldCode'] as String, () => []).add(r);
    }
    final deletedByField = <String, Set<int>>{};
    for (final d in deletes) {
      deletedByField
          .putIfAbsent(d['fieldCode'] as String, () => {})
          .add(d['serverIdx'] as int);
    }

    for (final f in fields()) {
      final g = assembleShots(
          rowsByField[f.code] ?? const <Map<String, Object?>>[],
          f.photoGalleryIndexes,
          deletedByField[f.code] ?? const <int>{});
      for (final e in g.assigned.entries) {
        await db.fill.setFillPhotoServerIdx(taskId, f.code, e.key, e.value);
      }
      f.shots = g.shots;
      f.photoPaths = [for (final s in g.shots) if (s.path != null) s.path!];
      // Список и счёт — то, что называет сервер, без очереди удалений. Счёт не
      // подмешивает только что отправленные кадры: при пустом списке модель
      // достраивает индексы «от 1 до счёта» (старый сервер), и следующая сборка
      // приняла бы выдуманный индекс за серверный — лишняя плитка удалённого кадра.
      // Что отправленное есть на сервере, «Удалить все» узнаёт по самим кадрам.
      f.serverPhotoIndexes = g.server;
      f.serverPhotoCount = g.server.length;
    }
  }

  /// Миниатюра или полный размер кадра, которого на этом устройстве нет, — снят на
  /// другом телефоне или в веб-АРМ. С диска прошлого раза файл не берётся: индекс
  /// освобождается вместе с последним снимком и может достаться следующему, так что
  /// файл нужен ровно столько, сколько открыт экран, и не переживает ни удаления, ни
  /// новой съёмки — поэтому он во временном каталоге ([serverPhotoDirectory]), а не
  /// рядом со своими снимками. Офлайн — null, галерея показывает «фото недоступно
  /// офлайн».
  late final PhotoDiskCache _serverPhotos = PhotoDiskCache(serverPhotoDirectory);

  Future<File?> serverFile(FillField f, int index, {required bool thumb}) =>
      _serverPhotos.file(_serverName(f.code, index, thumb),
          () => api.fetchFieldPhoto(taskId, f.code, index, thumb: thumb),
          reuseDisk: false);

  /// Кадр удалён или его байты не декодировались — оба размера с диска долой;
  /// следующий показ скачает заново.
  Future<void> evictServer(FillField f, int index) => _serverPhotos.evict([
        _serverName(f.code, index, true),
        _serverName(f.code, index, false),
      ]);

  String _serverName(String code, int index, bool thumb) =>
      'srv_${fileSafe(taskId)}_${fileSafe(code)}_$index${thumb ? '_t' : ''}.jpg';

  /// Имя файла — по ключу кадра, а не по индексу очереди: индекс после удаления
  /// последнего кадра достаётся следующему, и картинка, закэшированная по тому же
  /// пути, показала бы удалённый снимок вместо нового.
  Future<String> _persist(
      String sourcePath, FillField f, String clientId) async {
    final photoDir = await photoDirectory();
    if (!await photoDir.exists()) await photoDir.create(recursive: true);
    final dest = p.join(photoDir.path,
        '${fileSafe(taskId)}_${fileSafe(f.code)}_$clientId.jpg');
    await File(sourcePath).copy(dest);
    return dest;
  }

  FillField? _fieldByCode(String code) {
    for (final f in fields()) {
      if (f.code == code) return f;
    }
    return null;
  }

  /// Индекс, который сервер даст только что отправленному кадру пункта, — см.
  /// [nextServerIndex] в photo_shots. Что сервер называл в последний раз, знает
  /// загруженный бланк, а у контроллера без экрана (дренаж переподключения бланк не
  /// загружает) — кэш бланка.
  Future<int> nextIndexOnServer(String code) async {
    final f = _fieldByCode(code);
    return nextServerIndex(
      f != null ? f.photoGalleryIndexes : await _cachedIndexes(code),
      [
        for (final r in await db.fill.getFillPhotos(taskId))
          if (r['fieldCode'] == code) r
      ],
      [
        for (final d in await db.fill.getPhotoDeletes(taskId))
          if (d['fieldCode'] == code) d['serverIdx'] as int
      ],
    );
  }

  /// Серверные индексы снимков пункта по кэшу бланка — последнее, что сервер о них
  /// говорил этому телефону. Кэша нет или он нечитаем — пусто.
  Future<List<int>> _cachedIndexes(String code) async {
    final c = await db.fill.getFillCache(taskId);
    if (c == null) return const [];
    try {
      for (final j in jsonDecode(c['fieldsJson'] as String) as List) {
        if (j is Map && j['code'] == code) {
          return FillField.fromJson(j.cast<String, dynamic>())
              .photoGalleryIndexes;
        }
      }
    } catch (_) {}
    return const [];
  }

  /// Пустое фото доехало — на сервере у пункта не осталось ни одного снимка, и
  /// нумерация начнётся заново с единицы.
  void clearedOnServer(String code) {
    final f = _fieldByCode(code);
    if (f == null) return;
    f.serverPhotoIndexes = [];
    f.serverPhotoCount = 0;
    f.shots = [];
    f.photoPaths = [];
  }
}
