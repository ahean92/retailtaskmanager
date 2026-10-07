import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/home_controller.dart';
import '../data/notifications_controller.dart';
import '../data/task_repository.dart';
import '../models/quick_create.dart';
import 'ai_task_screen.dart';
import 'home_screen.dart';
import 'notifications_screen.dart';
import 'profile_screen.dart';
import 'quick_create_screen.dart';
import 'task_list_screen.dart';
import 'theme.dart';
import 'widgets/ds.dart';

/// Корень приложения после входа и гео-гейта (#37411, п. 2): нижняя панель
/// «Главная · Задачи · + · Лента · Профиль» вместо чистого стека. Вкладки живут
/// в [IndexedStack] — каждая хранит своё состояние (прокрутку списка, позицию в
/// ленте), и переход по панели ничего не сбрасывает.
///
/// «+» — не вкладка: нажатие открывает нижний лист «Создать» и выбранную вкладку
/// не меняет. Кнопка есть ровно тогда, когда раньше был FAB: пресеты или AI
/// настроены сервером для этого человека.
///
/// Всё, что выше панели — детали задач, заполнение, приёмка — по-прежнему
/// стеком поверх: содержимое вкладки не должно теряться из-за перехода по
/// панели, а пуш из уведомления открывает экран поверх любой вкладки.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _tab = 0; // 0 Главная · 1 Задачи · 2 Лента · 3 Профиль

  @override
  Widget build(BuildContext context) {
    final home = context.watch<HomeController>();
    final feed = context.watch<NotificationsController>();
    final repo = context.watch<TaskRepository>();
    final canCreate =
        !home.quickCreate.isEmpty || home.session.aiEnabled;

    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: const [
          HomeScreen(),
          TaskListScreen(asTab: true),
          NotificationsScreen(asTab: true),
          ProfileScreen(),
        ],
      ),
      bottomNavigationBar: _BottomPanel(
        current: _tab,
        unread: feed.unreadCount,
        pending: repo.pendingCount,
        onCreate: canCreate ? () => _create(context, home) : null,
        onSelect: (i) => setState(() => _tab = i),
      ),
    );
  }

  /// Единственный способ создать — открывается сразу; из нескольких человек
  /// выбирает. Перенесено с прежнего FAB главной: логика та же, лист — в новом
  /// стиле (мокет стр. 4, экран 9).
  Future<void> _create(BuildContext context, HomeController home) async {
    final actions = home.quickCreate.actions;
    final ai = home.session.aiEnabled;

    if (actions.isEmpty && ai) {
      await _openAi(context);
      return;
    }
    if (actions.length == 1 && !ai) {
      await _openPreset(context, actions.first);
      return;
    }

    final chosen = await showDsSheet<Object>(
      context,
      title: 'Создать',
      children: [
        if (ai)
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => Navigator.of(context).pop(_aiChoice),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(
                children: [
                  Icon(Icons.auto_awesome, size: 22, color: Wms.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Описать словами',
                            style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: Wms.text)),
                        Text(
                          '«поставь Иванову проверить ценники до пятницы»',
                          style:
                              TextStyle(fontSize: 13, color: Wms.muted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 4),
          child: Text('Шаблоны',
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                  color: Wms.muted)),
        ),
        for (final a in actions)
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => Navigator.of(context).pop(a),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(
                children: [
                  Text(a.icon ?? '➕',
                      style: const TextStyle(fontSize: 22)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(a.title,
                            style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: Wms.text)),
                        Text(
                          _presetDetails(a),
                          style:
                              TextStyle(fontSize: 13, color: Wms.muted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            children: [
              Icon(Icons.cloud_off_outlined, size: 14, color: Wms.muted),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Без связи задача создаётся и уедет на сервер позже',
                  style: TextStyle(fontSize: 12, color: Wms.muted),
                ),
              ),
            ],
          ),
        ),
      ],
    );
    if (chosen == null || !context.mounted) return;
    if (chosen == _aiChoice) {
      await _openAi(context);
      return;
    }
    await _openPreset(context, chosen as QuickPreset);
  }

  /// Что внутри пресета — одной строкой под названием: кому уйдёт задача и
  /// нужно ли фото. Те же два вопроса, на которые отвечает форма создания.
  static String _presetDetails(QuickPreset p) {
    final whom = switch (p.assign) {
      'self' => 'себе',
      'pick' => 'исполнитель из списка',
      'byRole' => 'по роли на объекте',
      _ => p.assign,
    };
    return [whom, if (p.requirePhoto) 'нужно фото'].join(' · ');
  }

  /// Метка пункта «AI» в списке выбора: пресетом он не является и пресетом
  /// притворяться не должен — у него нет ни типа, ни шаблона, ни политики назначения.
  static const _aiChoice = 'ai';

  Future<void> _openAi(BuildContext context) => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const AiTaskScreen()),
      );

  Future<void> _openPreset(BuildContext context, QuickPreset preset) =>
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => QuickCreateScreen(preset: preset)),
      );
}

/// Нижняя панель: пять позиций, средняя — «+». Высота 80, карточка с верхней
/// рамкой. Активная вкладка — подложка-«пилюля» из фирменных 10 %, иконка и
/// подпись фирменным (стр. 2–6 макета); остальные — приглушённые, подписи
/// 11/600. Бейджи: непрочитанные на «Ленте», ожидающие отправки — на
/// «Профиле».
///
/// «+» — квадрат 56 с радиусом 14, залит фирменным, стоит в ряд с остальными
/// позициями, без тени: как на всех экранах макета.
class _BottomPanel extends StatelessWidget {
  final int current;
  final int unread;
  final int pending;
  final VoidCallback? onCreate;
  final ValueChanged<int> onSelect;

  const _BottomPanel({
    required this.current,
    required this.unread,
    required this.pending,
    this.onCreate,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Wms.card,
        border: Border(top: BorderSide(color: Wms.line)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 72,
          child: Row(
            children: [
              _item(0, Icons.home_outlined, Icons.home, 'Главная'),
              _item(1, Icons.checklist_outlined, Icons.checklist, 'Задачи'),
              Expanded(
                child: Center(
                  child: onCreate == null
                      ? const SizedBox.shrink()
                      : _PlusButton(onTap: onCreate!),
                ),
              ),
              _item(2, Icons.notifications_outlined, Icons.notifications,
                  'Лента',
                  badge: unread),
              _item(3, Icons.person_outline_outlined, Icons.person, 'Профиль',
                  badge: pending),
            ],
          ),
        ),
      ),
    );
  }

  Widget _item(int index, IconData icon, IconData activeIcon, String label,
      {int badge = 0}) {
    final active = index == current;
    final color = active ? Wms.primary : Wms.muted;
    return Expanded(
      child: InkWell(
        onTap: () => onSelect(index),
        borderRadius: BorderRadius.circular(12),
        child: Center(
          child: Container(
            // подложка-«пилюля» активной вкладки (макет, стр. 2–6): выделяет
            // место в панели, а не только цвет иконки
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
            decoration: BoxDecoration(
              color: active ? Wms.brandTint : null,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Badge(
                  isLabelVisible: badge > 0,
                  label: Text('$badge'),
                  backgroundColor: Wms.danger,
                  textColor: Wms.isDark ? const Color(0xFF3B2220) : Colors.white,
                  child:
                      Icon(active ? activeIcon : icon, size: 22, color: color),
                ),
                const SizedBox(height: 4),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: color),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PlusButton extends StatelessWidget {
  final VoidCallback onTap;
  const _PlusButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Создать',
      child: InkWell(
        onTap: onTap,
        customBorder:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        child: Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: Wms.primary,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(Icons.add, size: 28, color: Wms.on(Wms.primary)),
        ),
      ),
    );
  }
}
