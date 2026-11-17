import 'dart:io';

import 'package:flutter/material.dart';

import '../../models/fill.dart';
import '../theme.dart';
import 'task_photo.dart';

/// Галерея набора снимков покадрово — одна для пункта бланка и отчёта поручения:
/// свои файлы, миниатюры с сервера и крестик на кадре, который есть чем адресовать
/// (см. [FillShot.canDelete]). У каждой плитки свой ключ по кадру: перерисовка и
/// удаление соседа не отдают плитку чужому снимку и не качают его заново.
class ShotGallery extends StatelessWidget {
  final List<FillShot> shots;
  final double size;
  final double radius;

  /// Снимок с сервера по индексу: миниатюра для плитки, полный размер по тапу.
  /// null — сетевых снимков у экрана нет, такая плитка — заглушка.
  final Future<File?> Function(int index, {required bool thumb})? loader;

  /// Байты снимка с сервера не декодировались — стереть его из кэша.
  final void Function(int index)? onBroken;

  /// Убрать кадр; null — галерея только показывает.
  final void Function(FillShot shot)? onDelete;

  const ShotGallery({
    super.key,
    required this.shots,
    this.size = 64,
    this.radius = 8,
    this.loader,
    this.onBroken,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final shot in shots)
          KeyedSubtree(
              key: ValueKey(_keyOf(shot)), child: _tile(context, shot)),
      ],
    );
  }

  /// Кадр этого телефона узнаётся по строке очереди, чужой — по индексу сервера.
  static String _keyOf(FillShot s) =>
      s.localIdx != null ? 'l${s.localIdx}' : 's${s.serverIndex}';

  Widget _tile(BuildContext context, FillShot shot) {
    final load = loader;
    final index = shot.serverIndex;
    final Widget image = shot.path != null
        ? InkWell(
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) =>
                    TaskPhotoViewer(loader: localPhoto(File(shot.path!))))),
            borderRadius: BorderRadius.circular(radius),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(radius),
              child: Image.file(File(shot.path!),
                  width: size,
                  height: size,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => brokenPhoto(size)),
            ),
          )
        : (load == null || index == null
            ? brokenPhoto(size)
            : TaskPhotoThumb(
                size: size,
                radius: radius,
                loader: ({required thumb}) => load(index, thumb: thumb),
                onBroken: onBroken == null ? null : () => onBroken!(index),
              ));
    if (!shot.canDelete || onDelete == null) return image;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        image,
        Positioned(
          top: -6,
          right: -6,
          child: Tooltip(
            message: 'Удалить снимок',
            child: InkWell(
              onTap: () => onDelete!(shot),
              customBorder: const CircleBorder(),
              child: Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: Wms.warn,
                  shape: BoxShape.circle,
                  border: Border.all(color: Wms.card, width: 2),
                ),
                child: const Icon(Icons.close, size: 13, color: Colors.white),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Спросить перед «Убрать все»: снимки стираются и на сервере, а вернуть их можно
/// только новой съёмкой на месте. true — человек подтвердил.
Future<bool> confirmClearPhotos(BuildContext context, int count) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Убрать все снимки?'),
      content: Text(count == 1
          ? 'Снимок будет удалён — вернуть его можно только новой съёмкой.'
          : 'Все снимки ($count) будут удалены — вернуть их можно только '
              'новой съёмкой.'),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Отмена')),
        TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('Убрать', style: TextStyle(color: Wms.danger))),
      ],
    ),
  );
  return ok == true;
}
