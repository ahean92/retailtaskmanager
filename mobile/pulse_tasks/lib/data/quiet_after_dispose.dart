import 'package:flutter/foundation.dart';

/// Контроллер приложения, которого будит фоновая работа, пережившая его:
/// синхронизация идёт без ожидания, а приложение уже закрыто (в тестах — конец
/// теста, см. AppControllers.dispose). Будить снятых слушателей некому, а
/// ChangeNotifier после dispose падает — одна проверка здесь вместо проверки
/// после каждого await, как у контроллеров экранов (SyncCoalescer).
mixin QuietAfterDispose on ChangeNotifier {
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }
}
