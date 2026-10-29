import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Диалог подтверждения выхода: после подтверждения он не закрывается, а
/// гасит кнопки и показывает «Выходим…», пока выход не закончится.
///
/// Выход — не мгновенный: снять регистрацию пуша (запрос к серверу), закрыть и
/// заново открыть базу. Диалог прежнего образца закрывался по кнопке сразу, и
/// всё это время строки «Выйти» под ним оставались живыми: человек успевал
/// нажать выход ещё раз, и новые подтверждения стекались поверх идущего. Этот
/// диалог остаётся модальным до конца — кнопки гаснут, системная «назад»
/// заперта, и повторные нажатия не достают ни до него, ни до экрана под ним.
class ExitConfirmDialog extends StatefulWidget {
  final String title;
  final Widget content;
  final String confirmLabel;

  /// Цвет подтверждающей кнопки — тревожный для выхода со стиранием.
  final Color? confirmColor;

  /// Сам выход. Завершился — диалог закрылся сам, но только если его ещё никто
  /// не закрыл раньше: подменяющий экраны корень сносит диалог своим popUntil
  /// в тот же момент (сессия уже неактивна), и поп по уже уходящему маршруту
  /// хватает ДОМАШНИЙ — навигатор пустеет, и экран чернеет (ловили 29.10 на
  /// «выйти и удалить данные»: локальное стирание успевало раньше анимации
  /// ухода). Ошибся выход — кнопки оживают: молча погасший навсегда диалог был
  /// бы «вечным выходом» без дороги назад.
  final Future<void> Function() onConfirm;

  const ExitConfirmDialog({
    super.key,
    required this.title,
    required this.content,
    required this.confirmLabel,
    this.confirmColor,
    required this.onConfirm,
  });

  @override
  State<ExitConfirmDialog> createState() => _ExitConfirmDialogState();
}

class _ExitConfirmDialogState extends State<ExitConfirmDialog> {
  bool _leaving = false;

  Future<void> _leave() async {
    setState(() => _leaving = true);
    try {
      await widget.onConfirm();
      // закрыть можно только свой ещё-текущий маршрут: корень в этот же момент
      // сносит диалог своим popUntil, и поп по уже уходящему диалогу хватает
      // последний «живой» — домашний — маршрут (так ловили чёрный экран).
      // Сначала mounted: у размонтированного State нет и контекста
      final route = mounted ? ModalRoute.of(context) : null;
      if (route?.isCurrent == true) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (kDebugMode) debugPrint('выход не удался: $e');
      if (mounted) setState(() => _leaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Системная «назад» по идущему выходу закрывала бы диалог, а экран под
      // ним ещё жив — это тот же второй выход, от которого диалог защищает
      canPop: !_leaving,
      child: AlertDialog(
        title: Text(widget.title),
        content: widget.content,
        actions: [
          TextButton(
            onPressed: _leaving ? null : () => Navigator.of(context).pop(),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: _leaving ? null : _leave,
            style: widget.confirmColor == null
                ? null
                : TextButton.styleFrom(foregroundColor: widget.confirmColor),
            child: _leaving
                ? const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      SizedBox(width: 10),
                      Text('Выходим…'),
                    ],
                  )
                : Text(widget.confirmLabel),
          ),
        ],
      ),
    );
  }
}

/// Предупреждение обычного выхода: что останется на устройстве и что с ним
/// будет. Один текст на профиль и гео-гейт — гейт задаёт «тот же вопрос, что
/// и в профиле», и жить ему полагается в одной копии.
Widget plainExitWarning(int unsent) => Text(unsent == 0
    ? 'Данные останутся на устройстве. Чтобы продолжить работу, '
        'понадобится снова ввести пароль.'
    : 'Не отправлено изменений: $unsent. Они останутся на этом устройстве '
        'и уйдут на сервер, когда вы снова войдёте.');
