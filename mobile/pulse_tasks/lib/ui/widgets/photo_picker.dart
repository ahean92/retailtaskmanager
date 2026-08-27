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
  for (final f in picked) {
    if (taken.length >= limit) {
      dropped++;
      continue;
    }
    final size = await File(f.path).length();
    if (size > TaskFilesController.maxPhotoBytes) {
      tooLarge++;
      continue;
    }
    taken.add(f.path);
  }
  if (dropped > 0) {
    messenger.showSnackBar(SnackBar(
        content: Text('${TaskFilesController.limitMessage(0)} '
            'Взяты первые $limit, остальные ($dropped) пропущены.')));
  } else if (tooLarge > 0) {
    messenger.showSnackBar(SnackBar(
        content: Text('Пропущено слишком больших снимков: $tooLarge '
            '(предел ${TaskFilesController.maxPhotoBytes ~/ (1024 * 1024)} МБ).')));
  }
  return taken;
}

enum _PhotoSource { camera, gallery }
