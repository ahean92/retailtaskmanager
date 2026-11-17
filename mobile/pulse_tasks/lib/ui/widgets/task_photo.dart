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
///
/// «Нет фото» — два разных ответа, и смешивать их нельзя (15.10): файл НЕ
/// СКАЧАЛСЯ (нет сети, отказ) — облако «недоступно офлайн»; скачался, но байтами
/// не картинка — «файл повреждён», и такой файл стирается из кэша
/// ([onBroken]), чтобы следующий заход перекачал. Кто положил тот же самый
/// битый JPEG на сервер, увидит честное «повреждён», а не вечную ловлю сети.
///
/// Миниатюра запрашивается один раз на жизнь плитки: перерисовка экрана (буква в
/// соседнем поле, ход синхронизации) не идёт в сеть заново и не мигает индикатором.
/// Неудача повторяется по тапу на плитку «недоступно офлайн» или новой плиткой
/// (экран открыли снова). Поэтому в списке плитке нужен ключ по снимку: без него
/// другой снимок на том же месте получил бы прежнюю картинку.
class TaskPhotoThumb extends StatefulWidget {
  final PhotoLoader loader;
  final double size;

  /// Скругление углов: 8 — у плиток ленты и бланка, 12 — у крупных плиток отчёта.
  final double radius;

  /// Подпись под снимком в полный экран — «Фото проблемы», «Результат: Пётр, 12.07».
  final String? caption;

  /// Байты не декодировались — стереть их из кэша (например,
  /// `() => unawaited(cache.evict(id))`). null — загрузчик без кэша: снимок из
  /// очереди этого телефона, стирать нечего.
  final void Function()? onBroken;

  const TaskPhotoThumb({
    super.key,
    required this.loader,
    this.size = 112,
    this.radius = 8,
    this.caption,
    this.onBroken,
  });

  @override
  State<TaskPhotoThumb> createState() => _TaskPhotoThumbState();
}

class _TaskPhotoThumbState extends State<TaskPhotoThumb> {
  late Future<File?> _thumb = widget.loader(thumb: true);

  void _retry() => setState(() {
        _thumb = widget.loader(thumb: true);
      });

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(widget.radius);
    return FutureBuilder<File?>(
      future: _thumb,
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
            child: InkWell(
              onTap: _retry,
              borderRadius: radius,
              child: _box(Icon(Icons.cloud_off, size: 20, color: Wms.muted)),
            ),
          );
        }
        return InkWell(
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => TaskPhotoViewer(
                  loader: widget.loader,
                  caption: widget.caption,
                  onBroken: widget.onBroken))),
          borderRadius: radius,
          child: ClipRRect(
            borderRadius: radius,
            child: Image.file(file,
                width: widget.size,
                height: widget.size,
                fit: BoxFit.cover,
                // файл на диске испорчен (обрыв записи, битые байты на сервере) —
                // плитка «повреждён» вместо красного экрана исключения, и кэш
                // чистится: держать такое значило бы навсегда запереть снимок
                errorBuilder: (_, __, ___) {
                  widget.onBroken?.call();
                  return Tooltip(
                      message: 'Файл повреждён',
                      child: brokenPhoto(widget.size));
                }),
          ),
        );
      },
    );
  }

  Widget _box(Widget child) => Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          color: Wms.line,
          borderRadius: BorderRadius.circular(widget.radius),
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

  /// Байты полного размера не декодировались — стереть из кэша (см. TaskPhotoThumb).
  final void Function()? onBroken;

  const TaskPhotoViewer(
      {super.key, required this.loader, this.caption, this.onBroken});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Снимок смотрят на чёрном в любой теме — так его видно, и так это
      // делают все просмотрщики (аудит цветов #36917).
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
                  // не «офлайн»: файл доехал, но картинкой не стал — человек
                  // искал бы проблему в сети (так и случилось, 15.10)
                  errorBuilder: (_, __, ___) {
                    onBroken?.call();
                    return const Text('Файл повреждён — показать не удалось',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white70));
                  }),
            );
          },
        ),
      ),
    );
  }
}
