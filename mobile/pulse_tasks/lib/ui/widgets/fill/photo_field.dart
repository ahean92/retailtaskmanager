import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../../models/fill.dart';
import '../../theme.dart';
import '../task_photo.dart';
import 'field_editor.dart';

/// Фото как ответ: значение — сами снимки, поэтому в просмотре редактор молчит, а
/// галерею плитка рисует общим блоком ([PhotoGalleryView]); ввод — [PhotoGallery].
/// Та же галерея служит и доказательством несоответствия у поля любого типа.
class PhotoFieldEditor extends FillFieldEditor {
  const PhotoFieldEditor();

  @override
  Widget value(BuildContext context, FillField f, FieldActions actions) =>
      const SizedBox.shrink();

  @override
  Widget input(BuildContext context, FillField f, FieldActions actions) =>
      PhotoGallery(field: f, actions: actions);
}

/// A field holds 0..N photos, so this is a small gallery rather than a single slot:
/// thumbnails of what was taken here, a tile to add one more, and a clear-all.
class PhotoGallery extends StatelessWidget {
  final FillField field;
  final FieldActions actions;
  const PhotoGallery({super.key, required this.field, required this.actions});

  @override
  Widget build(BuildContext context) => _photoControl(context, field);

  /// Галерея пункта покадрово: свои файлы и — миниатюрами с сервера — кадры, снятые
  /// на другом устройстве. Собранная контроллером [FillField.shots] знает про каждый
  /// снимок его серверный индекс, поэтому крестик удаляет ровно этот кадр (#36946).
  /// Модель без покадровой сборки (виджет-тесты, старый кэш) разворачивается сюда же
  /// из [FillField.photoPaths] и серверного счётчика — галерея одна на все случаи.
  List<FillShot> _galleryShots(FillField f) {
    if (f.shots.isNotEmpty) return f.shots;
    if (f.photoPaths.isNotEmpty) {
      return [
        for (var i = 0; i < f.photoPaths.length; i++)
          FillShot(path: f.photoPaths[i], localIdx: i)
      ];
    }
    return [
      for (final i in f.photoGalleryIndexes)
        FillShot(serverIndex: i, uploaded: true)
    ];
  }

  Widget _photoControl(BuildContext context, FillField f) {
    final shots = _galleryShots(f);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (shots.isNotEmpty) ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [for (final shot in shots) _editableShot(context, f, shot)],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text('фото: ${shots.length}',
                  style: TextStyle(fontSize: 12, color: Wms.muted)),
              const Spacer(),
              TextButton.icon(
                  onPressed: actions.onRemovePhoto,
                  icon: Icon(Icons.delete_outline, size: 18, color: Wms.danger),
                  label: Text('Удалить все',
                      style: TextStyle(color: Wms.danger))),
            ],
          ),
          const SizedBox(height: 4),
        ],
        // свидетельство обязательно, а кадра нет — сказать до, а не после «Далее»
        if (f.needsPhoto && shots.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Icon(Icons.photo_camera_outlined, size: 14, color: Wms.caution),
                const SizedBox(width: 4),
                Text('нужно фото',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Wms.caution)),
              ],
            ),
          ),
        Row(
          children: [
            Expanded(
              child: _SourceTile(
                icon: Icons.photo_camera_outlined,
                label: 'Камера',
                tonal: true,
                onTap: () => _shoot(ImageSource.camera),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _SourceTile(
                icon: Icons.photo_library_outlined,
                label: 'Галерея',
                tonal: false,
                onTap: () => _shoot(ImageSource.gallery),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// Плитки «Камера» и «Галерея» зовут источник напрямую (#37411, п. 6); экран
  /// без прямых колбэков (старая сборка хоста, подмена в тесте) получает прежний
  /// лист выбора — у одной кнопки «снять» нет другого пути в галерею.
  void _shoot(ImageSource source) {
    final direct = actions.onPhotoSource;
    if (direct != null) {
      direct(source);
    } else {
      actions.onPhoto?.call();
    }
  }

  /// Одна плитка галереи: сам кадр и крестик поверх него. Крестика нет у снимка,
  /// который нечем адресовать (уехал версией приложения, не знавшей серверных
  /// индексов, и сверка его пока не опознала) — для такого остаётся «Удалить все».
  Widget _editableShot(BuildContext context, FillField f, FillShot shot) {
    final loader = actions.photoLoader;
    final Widget image = shot.path != null
        ? ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.file(File(shot.path!),
                width: 64,
                height: 64,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => photoPlaceholder()),
          )
        : (loader == null || shot.serverIndex == null
            ? photoPlaceholder()
            : ServerPhotoThumb(index: shot.serverIndex!, loader: loader));
    if (!shot.canDelete || actions.onDeleteShot == null) return image;
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
              onTap: () => actions.onDeleteShot!(shot),
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

/// Плитка источника кадра (#37411, п. 6): «Камера» — тональная (подложка
/// бренда), «Галерея» — контурная. Иконка и подпись в два этажа, высота 64.
class _SourceTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool tonal;
  final VoidCallback onTap;
  const _SourceTile({
    required this.icon,
    required this.label,
    required this.tonal,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        height: 64,
        decoration: BoxDecoration(
          color: tonal ? Wms.brandTint : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          border: tonal ? null : Border.all(color: Wms.line),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 20, color: tonal ? Wms.primary : Wms.text2),
            const SizedBox(width: 8),
            Text(label,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: tonal ? Wms.primary : Wms.text2)),
          ],
        ),
      ),
    );
  }
}

/// Галерея просмотра: локальные файлы, если они на этом устройстве есть (свой
/// завершённый бланк), иначе — миниатюры с сервера через [FieldActions.photoLoader];
/// тап по миниатюре открывает полный размер. Без сети и без файла — плейсхолдер.
class PhotoGalleryView extends StatelessWidget {
  final FillField field;
  final FieldActions actions;
  const PhotoGalleryView(
      {super.key, required this.field, required this.actions});

  @override
  Widget build(BuildContext context) => _readOnlyPhotos(context, field);

  Widget _readOnlyPhotos(BuildContext context, FillField f) {
    if (f.photoPaths.isNotEmpty) {
      return Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final path in f.photoPaths)
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.file(File(path),
                  width: 64,
                  height: 64,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => photoPlaceholder()),
            ),
        ],
      );
    }
    final loader = actions.photoLoader;
    if (loader == null) {
      return Text('фото приложено: ${f.serverPhotoCount}',
          style: TextStyle(fontSize: 13, color: Wms.muted));
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        // фактические серверные индексы: после удаления они не уплотняются, и
        // «от 1 до count» промахнулся бы мимо снимков за дырой
        for (final i in f.photoGalleryIndexes)
          ServerPhotoThumb(index: i, loader: loader),
      ],
    );
  }
}

/// Кадр, который нечем показать: файл стёрт или ещё не приехал.
Widget photoPlaceholder() => Container(
      width: 64,
      height: 64,
      color: Wms.line,
      child: Icon(Icons.broken_image, color: Wms.muted),
    );

/// Миниатюра серверного снимка в просмотре: качается лениво и однажды (контроллер
/// держит дисковый кэш), тап открывает полный размер. Файла нет и сети нет —
/// честный плейсхолдер «фото недоступно офлайн».
class ServerPhotoThumb extends StatelessWidget {
  final int index;
  final Future<File?> Function(int index, {required bool thumb}) loader;
  const ServerPhotoThumb(
      {super.key, required this.index, required this.loader});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<File?>(
      future: loader(index, thumb: true),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: Wms.line,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Center(
              child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          );
        }
        final file = snap.data;
        if (file == null) {
          return Tooltip(
            message: 'Фото недоступно офлайн',
            child: Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: Wms.line,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(Icons.cloud_off, size: 20, color: Wms.muted),
            ),
          );
        }
        return InkWell(
          // полный размер — тем же просмотрщиком, что у снимка задачи (#36778: качается
          // только по явному тапу, пока едет — миниатюра)
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => TaskPhotoViewer(
                  loader: ({required thumb}) => loader(index, thumb: thumb)))),
          borderRadius: BorderRadius.circular(8),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            // файл могла удалить фоновая инвалидация кэша (прошлая проверка
            // сменилась под открытым экраном) — плейсхолдер, а не error-виджет
            child: Image.file(file,
                width: 64,
                height: 64,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                      width: 64,
                      height: 64,
                      color: Wms.line,
                      child: Icon(Icons.broken_image, color: Wms.muted),
                    )),
          ),
        );
      },
    );
  }
}
