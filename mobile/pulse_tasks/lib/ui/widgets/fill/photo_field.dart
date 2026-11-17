import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../../models/fill.dart';
import '../../theme.dart';
import '../shot_gallery.dart';
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

  Widget _photoControl(BuildContext context, FillField f) {
    final shots = galleryShots(f);
    final clear = actions.onRemovePhoto;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (shots.isNotEmpty) ...[
          ShotGallery(
            shots: shots,
            loader: actions.photoLoader,
            onBroken: actions.onPhotoBroken,
            onDelete: actions.onDeleteShot,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text('фото: ${shots.length}',
                  style: TextStyle(fontSize: 12, color: Wms.muted)),
              const Spacer(),
              TextButton.icon(
                  // стирает и на сервере, вернуть нельзя — сперва спросить
                  onPressed: clear == null
                      ? null
                      : () async {
                          if (await confirmClearPhotos(context, shots.length)) {
                            clear();
                          }
                        },
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

}

/// Галерея пункта покадрово: свои файлы и — миниатюрами с сервера — кадры, снятые
/// на другом устройстве. Собранная контроллером [FillField.shots] знает про каждый
/// снимок его серверный индекс, поэтому крестик удаляет ровно этот кадр (#36946).
/// Модель без покадровой сборки (просмотр прошлой проверки, виджет-тесты)
/// разворачивается сюда же из [FillField.photoPaths] и серверного счётчика — один
/// сбор кадров на ввод и на просмотр. Крестика нет у снимка, который нечем
/// адресовать (уехал версией приложения, не знавшей серверных индексов, и сверка его
/// пока не опознала) — для такого остаётся «Удалить все».
List<FillShot> galleryShots(FillField f) {
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

/// Галерея просмотра — из того же сбора кадров, что ввод ([galleryShots]): свои
/// файлы и миниатюры с сервера вместе, а не «свои, если есть хоть один». Тап по
/// миниатюре открывает полный размер; без сети и без файла — «недоступно офлайн».
class PhotoGalleryView extends StatelessWidget {
  final FillField field;
  final FieldActions actions;
  const PhotoGalleryView(
      {super.key, required this.field, required this.actions});

  @override
  Widget build(BuildContext context) {
    final shots = galleryShots(field);
    if (actions.photoLoader == null && shots.every((s) => s.path == null)) {
      return Text('фото приложено: ${shots.length}',
          style: TextStyle(fontSize: 13, color: Wms.muted));
    }
    return ShotGallery(
      shots: shots,
      loader: actions.photoLoader,
      onBroken: actions.onPhotoBroken,
    );
  }
}
