import 'package:flutter/widgets.dart';

/// Экран задачи, которой больше нет в списке (завершена или принята здесь же,
/// закрыта и подтверждена сервером), — тупик, и он уходит назад сам. Один раз:
/// перерисовка, пока уход ещё впереди, не должна снять второй маршрут и унести с
/// собой список задач.
mixin LeaveWhenGone<T extends StatefulWidget> on State<T> {
  bool _leaving = false;

  void leave() {
    if (_leaving) return;
    _leaving = true;
    final navigator = Navigator.of(context);
    // во время build маршрут не снимают — сначала дорисуется кадр, в котором это
    // решили
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (navigator.mounted && navigator.canPop()) navigator.pop();
    });
  }
}
