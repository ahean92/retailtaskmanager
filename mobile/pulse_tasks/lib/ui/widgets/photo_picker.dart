import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../data/task_file_controller.dart';
import '../camera_screen.dart';

/// Откуда берутся кадры задачи (#36914) — одним жестом и в одном виде везде, где к
/// задаче прикладывают фото: экран создания и карточка готовой задачи.
///
/// Два пути и оба множественные: своя камера снимает серией, не закрываясь между
/// кадрами (см. [CameraScreen]), галерея отдаёт несколько снимков разом
/// (`pickMultiImage`). Предел «сколько ещё можно» приходит снаружи — он считается по
/// задаче целиком (уже уехавшие кадры плюс те, что ждут отправки).
///
/// Возвращает пути к файлам во временном каталоге; пустой список — человек передумал.
/// Отсекает то, что не влезает: лишние кадры сверх предела и слишком тяжёлые снимки
/// не молча пропадают, а объясняются строкой внизу экрана.
Future<List<String>> pickTaskPhotos(BuildContext context,
    {required int limit}) async {
  final messenger = ScaffoldMessenger.of(context);
  if (limit <= 0) {
    messenger.showSnackBar(
        SnackBar(content: Text(TaskFilesController.limitMessage(0))));
    return const [];
  }
  final source = await showModalBottomSheet<_PhotoSource>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Wrap(children: [
        ListTile(
          leading: const Icon(Icons.photo_camera),
          title: const Text('Снять'),
          subtitle: const Text('Несколько кадров подряд'),
          onTap: () => Navigator.pop(ctx, _PhotoSource.camera),
        ),
        ListTile(
          leading: const Icon(Icons.photo_library),
          title: const Text('Галерея'),
          subtitle: const Text('Можно выбрать несколько'),
          onTap: () => Navigator.pop(ctx, _PhotoSource.gallery),
        ),
      ]),
    ),
  );
  if (source == null || !context.mounted) return const [];

  if (source == _PhotoSource.camera) {
    final shots = await Navigator.of(context).push<List<String>>(
      MaterialPageRoute(builder: (_) => CameraScreen(limit: limit)),
    );
    return shots ?? const [];
  }

  final List<XFile> picked;
  try {
    picked = await ImagePicker()
        .pickMultiImage(maxWidth: 1280, maxHeight: 1280, imageQuality: 70);
  } catch (e) {
    messenger.showSnackBar(
        SnackBar(content: Text('Не удалось получить фото: $e')));
    return const [];
  }
  if (picked.isEmpty) return const [];

  final taken = <String>[];
  var dropped = 0;
  var tooLarge = 0;
  var unreadable = 0;
  for (final f in picked) {
    if (taken.length >= limit) {
      dropped++;
      continue;
    }
    final int size;
    try {
      size = await File(f.path).length();
    } on FileSystemException {
      // файл галереи пропал или не читается (облачный, ещё не скачан) — снимка нет
      unreadable++;
      continue;
    }
    if (size > TaskFilesController.maxPhotoBytes) {
      tooLarge++;
      continue;
    }
    taken.add(f.path);
  }
  // все причины пропуска — одним сообщением: следующее заменило бы предыдущее
  final skipped = [
    if (dropped > 0)
      '${TaskFilesController.limitMessage(0)} '
          'Взяты первые $limit, остальные ($dropped) пропущены.',
    if (tooLarge > 0)
      'Пропущено слишком больших снимков: $tooLarge '
          '(предел ${TaskFilesController.maxPhotoBytes ~/ (1024 * 1024)} МБ).',
    if (unreadable > 0) 'Не удалось прочитать снимков: $unreadable.',
  ];
  if (skipped.isNotEmpty) {
    messenger.showSnackBar(SnackBar(content: Text(skipped.join('\n'))));
  }
  return taken;
}

enum _PhotoSource { camera, gallery }

/// Камера или галерея — лист выбора ленты задачи и чата: снимок «с места» делают
/// камерой, а «вот что было утром» берут из галереи. null — человек передумал.
Future<ImageSource?> askPhotoSource(BuildContext context) =>
    showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(children: [
          ListTile(
            leading: const Icon(Icons.photo_camera),
            title: const Text('Камера'),
            onTap: () => Navigator.pop(ctx, ImageSource.camera),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library),
            title: const Text('Галерея'),
            onTap: () => Navigator.pop(ctx, ImageSource.gallery),
          ),
        ]),
      ),
    );

/// Один кадр из названного источника — сразу в системный пикер: пункт бланка,
/// поручение, сообщение. Кадр уходит в [use]; человек передумал — [use] не зовётся.
/// Отказ пикера или [use] — строкой внизу экрана, а не молчанием.
Future<void> pickOnePhoto(BuildContext context, ImageSource source,
    Future<void> Function(String path) use) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final file = await ImagePicker().pickImage(
        source: source, maxWidth: 1280, maxHeight: 1280, imageQuality: 70);
    if (file == null) return;
    await use(file.path);
  } catch (e) {
    messenger.showSnackBar(
        SnackBar(content: Text('Не удалось получить фото: $e')));
  }
}
