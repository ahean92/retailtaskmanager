import 'dart:io';

import 'package:flutter/material.dart';

import '../../../models/fill.dart';
import '../../theme.dart';

/// Что бланк умеет делать с полем — колбэки экрана заполнения одним значением, чтобы
/// редактор типа получал их разом, а не полутора десятками параметров. В просмотре
/// ([readOnly], #36778) их нет: экран просмотра отдаёт плитке только поле, и редактор
/// рисует значение, а не контрол. Собирает их FillFieldTile из своих параметров.
class FieldActions {
  final void Function(String optionCode)? onOption;
  final void Function(double? value)? onNumber;
  final void Function(String? text)? onText;
  final void Function(bool? value)? onBool;
  final VoidCallback? onDatePick;
  final VoidCallback? onScan;
  final VoidCallback? onPhoto;
  final VoidCallback? onRemovePhoto;
  final void Function(FillShot shot)? onDeleteShot;
  final void Function(FillRowData row, FillColumn col, double? value)? onCell;
  final Future<void> Function(String? subjectId, String? subjectName)? onAddRow;
  final void Function(FillRowData row)? onDeleteRow;
  final Future<List<RefCandidate>> Function(String query, {bool allItems})?
      onRowSubjectSearch;
  final void Function(String? id, String? name)? onRef;
  final Future<List<RefCandidate>> Function(String query)? onRefSearch;

  /// Снимок поля с сервера (просмотр прошлой проверки): миниатюра для галереи,
  /// полный размер по тапу. null — сетевых фото у этого экрана нет.
  final Future<File?> Function(int index, {required bool thumb})? photoLoader;
  final bool readOnly;

  const FieldActions({
    this.onOption,
    this.onNumber,
    this.onText,
    this.onBool,
    this.onDatePick,
    this.onScan,
    this.onPhoto,
    this.onRemovePhoto,
    this.onDeleteShot,
    this.onCell,
    this.onAddRow,
    this.onDeleteRow,
    this.onRowSubjectSearch,
    this.onRef,
    this.onRefSearch,
    this.photoLoader,
    this.readOnly = false,
  });
}

/// Редактор одного типа поля: как показать уже данный ответ в просмотре (#36778) и
/// каким контролом его вводить. Тип поля — [FillField.kind]; какой редактор какому
/// типу положен, записано в одном месте — `fieldEditors` (editors.dart). Новый тип
/// поля = новый файл с редактором и строка в той карте, плитка не меняется.
abstract class FillFieldEditor {
  const FillFieldEditor();

  /// Значение отвеченного поля — «— не отвечено» плитка показывает сама.
  Widget value(BuildContext context, FillField f, FieldActions actions);

  /// Контрол ввода.
  Widget input(BuildContext context, FillField f, FieldActions actions);
}

/// Число без хвоста «.0»: «6», но «6.5».
String trimNum(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toString();

/// Значение в просмотре — крупно; [warn] — замечание, красным.
Widget fieldValue(String text, {bool warn = false}) => Text(
      text,
      style: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: warn ? Wms.warn : Wms.text,
      ),
    );

/// Пометка на плитке: «обязательное», «критичное», «в норме», «вне системы».
class FieldBadge extends StatelessWidget {
  final String text;
  final Color color;
  const FieldBadge(this.text, this.color, {super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(text, style: TextStyle(fontSize: 11, color: color)),
    );
  }
}
