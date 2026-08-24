import 'dart:io';

import 'package:flutter/material.dart';

import '../theme.dart';

/// Откуда виджет берёт снимок: миниатюру или полный размер. Кэш и сеть — забота
/// вызывающего (`TaskFileCache.loaderFor`), локальный файл отдаётся тем же способом,
/// поэтому ещё не отправленное фото из очереди рисуется тем же виджетом, что и
/// приехавшее с сервера.
typedef PhotoLoader = Future<File?> Function({required bool thumb});

/// Загрузчик для файла, который уже лежит на устройстве (снимок в очереди отправки).
PhotoLoader localPhoto(File file) => ({required bool thumb}) async => file;

/// Миниатюра снимка с открытием в полный экран по тапу.
///
/// Общий виджет ленты переписки (#36844) и карточки задачи (#36842): и там, и там
/// показывается один и тот же `TaskFile` с сервера, качается он одной ручкой, и
/// «недоступно офлайн» должно выглядеть одинаково — иначе два места разойдутся в
/// поведении на первой же правке.
class TaskPhotoThumb extends StatelessWidget {
  final PhotoLoader loader;
  final double size;

  /// Подпись под снимком в полный экран — «Фото проблемы», «Результат: Пётр, 12.07».
  final String? caption;

  const TaskPhotoThumb({
    super.key,
    required this.loader,
    this.size = 112,
    this.caption,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<File?>(
      future: loader(thumb: true),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return _box(const Center(
              child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))));
        }
        final file = snap.data;
        if (file == null) {
          return Tooltip(
            message: 'Фото недоступно офлайн',
            child: _box(Icon(Icons.cloud_off, size: 20, color: Wms.muted)),
          );
        }
        return InkWell(
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => TaskPhotoViewer(loader: loader, caption: caption))),
          borderRadius: BorderRadius.circular(8),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.file(file,
                width: size,
                height: size,
                fit: BoxFit.cover,
                // файл на диске испорчен (обрыв записи) — плитка-заглушка вместо
                // красного экрана исключения
                errorBuilder: (_, __, ___) => brokenPhoto(size)),
          ),
        );
      },
    );
  }

  Widget _box(Widget child) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: Wms.line,
          borderRadius: BorderRadius.circular(8),
        ),
        child: child,
      );
}

/// Плитка на месте снимка, который не удалось прочитать с диска.
Widget brokenPhoto(double size) => Container(
      width: size,
      height: size,
      color: Wms.line,
      child: Icon(Icons.broken_image_outlined, size: 20, color: Wms.muted),
    );

/// Полный размер по явному тапу — только тогда он и качается (галерея в поле не должна
/// тянуть мегабайты фоном). Пока полный едет, показана миниатюра.
class TaskPhotoViewer extends StatelessWidget {
  final PhotoLoader loader;
  final String? caption;

  const TaskPhotoViewer({super.key, required this.loader, this.caption});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: caption == null
            ? null
            : Text(caption!, style: const TextStyle(fontSize: 15)),
      ),
      body: Center(
        child: FutureBuilder<File?>(
          future: loader(thumb: false),
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return FutureBuilder<File?>(
                future: loader(thumb: true),
                builder: (context, thumbSnap) => thumbSnap.data == null
                    ? const CircularProgressIndicator(color: Colors.white)
                    : Image.file(thumbSnap.data!,
                        errorBuilder: (_, __, ___) =>
                            const CircularProgressIndicator(
                                color: Colors.white)),
              );
            }
            final file = snap.data;
            if (file == null) {
              return const Text('Фото недоступно офлайн',
                  style: TextStyle(color: Colors.white70));
            }
            return InteractiveViewer(
              maxScale: 5,
              child: Image.file(file,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const Text(
                      'Фото недоступно офлайн',
                      style: TextStyle(color: Colors.white70))),
            );
          },
        ),
      ),
    );
  }
}
