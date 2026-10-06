import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/account_controller.dart';
import '../data/location_controller.dart';
import '../data/session.dart';
import '../data/task_repository.dart';
import 'theme.dart';
import 'unsent_screen.dart';
import 'widgets/ds.dart';

/// Профиль — вкладка нижней панели (#37411, п. 12): учётная запись, «Не
/// отправлено», текущий объект, оформление, подключение и выход. Прежнее меню
/// аккаунта в шапке главной уходит: выход со смены теперь отсюда, а не из
/// иконки, у которой перед этим стояло ещё три таких же.
///
/// Должности на клиенте нет — карточка пользователя рисует только имя и логин;
/// заведённая сервером должность появится здесь же, без отдельной правки.
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final account = context.watch<AccountController>();
    final repo = context.watch<TaskRepository>();
    final session = account.session;

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.only(top: 8),
          children: [
            const DsScreenTitle('Профиль'),
            _UserCard(session: session),
            DsCard(children: [
              _Row(
                icon: Icons.cloud_upload_outlined,
                title: 'Не отправлено',
                trailing: repo.pendingCount > 0
                    ? DsChip('${repo.pendingCount}', tone: DsTone.danger, compact: true)
                    : DsChip('0', compact: true),
                onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const UnsentScreen())),
              ),
              if (session.geoRequired)
                _Row(
                  icon: Icons.storefront_outlined,
                  title: 'Текущий объект',
                  trailing: Flexible(
                    child: Text(
                      context.watch<LocationController>().place.object?.name ??
                          'не определён',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: Wms.text2),
                    ),
                  ),
                ),
            ]),
            _ThemeSection(),
            DsCard(children: [
              _Row(
                icon: repo.online
                    ? Icons.cloud_done_outlined
                    : Icons.cloud_off,
                title: 'Подключение',
                iconColor: repo.online ? Wms.done : Wms.danger,
                trailing: Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        repo.online ? 'Сервер отвечает' : 'Нет связи с сервером',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: repo.online ? Wms.done : Wms.danger),
                      ),
                      Text(
                        account.settings.baseUrl,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: Wms.muted),
                      ),
                    ],
                  ),
                ),
              ),
            ]),
            _ExitSection(account: account),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

/// Карточка «кто работает»: аватар-инициалы, имя, под ним логин — по нему
/// отличают двух полных тёзок, и поддержка просит именно его.
class _UserCard extends StatelessWidget {
  final Session session;
  const _UserCard({required this.session});

  @override
  Widget build(BuildContext context) {
    final name =
        session.name.isNotEmpty ? session.name : session.login;
    return DsCard(children: [
      Row(
        children: [
          DsAvatar(name, size: 56),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: Wms.text)),
                if (session.login.isNotEmpty && session.login != name)
                  Text(session.login,
                      style: TextStyle(fontSize: 13, color: Wms.muted)),
              ],
            ),
          ),
        ],
      ),
    ]);
  }
}

/// Оформление: сегмент «Система / Светлая / Тёмная» с пояснением. Применяется
/// сразу, без «Сохранить»: тему выбирают глазами, глядя на результат.
class _ThemeSection extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return DsCard(children: [
      ValueListenableBuilder<ThemeMode>(
        valueListenable: Wms.mode,
        builder: (context, mode, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Оформление',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: Wms.text2)),
            const SizedBox(height: 10),
            SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(
                    value: ThemeMode.system, label: Text('Система')),
                ButtonSegment(value: ThemeMode.light, label: Text('Светлая')),
                ButtonSegment(value: ThemeMode.dark, label: Text('Тёмная')),
              ],
              selected: {mode},
              showSelectedIcon: false,
              onSelectionChanged: (s) => unawaited(Wms.setMode(s.first)),
            ),
            const SizedBox(height: 10),
            Text(
              '«Система» — как настроен телефон. Тёмная бережёт глаза в '
              'полутёмном зале и на складе; цвета заказчика работают в обеих.',
              style: TextStyle(fontSize: 12, color: Wms.muted),
            ),
          ],
        ),
      ),
    ]);
  }
}

/// Два выхода из учётной записи — как в прежнем меню аккаунта: обычный ничего
/// не трогает, второй стирает работу, и потому это отдельная строка со своим
/// вопросом, а не галочка в первом.
class _ExitSection extends StatelessWidget {
  final AccountController account;
  const _ExitSection({required this.account});

  @override
  Widget build(BuildContext context) {
    return DsCard(children: [
      _Row(
        icon: Icons.logout,
        title: 'Выйти',
        onTap: () => _leave(context, wipe: false),
      ),
      const Divider(height: 1, thickness: 1),
      _Row(
        icon: Icons.delete_forever_outlined,
        title: 'Выйти и удалить данные',
        iconColor: Wms.danger,
        titleColor: Wms.danger,
        onTap: () => _leave(context, wipe: true),
      ),
    ]);
  }

  /// Спросить, затем выйти. Сколько изменений не отправлено — узнать до вопроса:
  /// ради них человек и решает, синхронизироваться ли сначала.
  Future<void> _leave(BuildContext context, {required bool wipe}) async {
    final navigator = Navigator.of(context);
    final unsent = await account.unsentChanges();
    if (!context.mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) =>
          wipe ? _wipeDialog(context, unsent) : _plainDialog(context, unsent),
    );
    if (confirmed != true) return;

    // Экраны уходящего закрываются, пока его база ещё открыта: карточка или
    // недозаполненный бланк над закрытой базой — контроллер без данных.
    navigator.popUntil((r) => r.isFirst);
    await (wipe ? account.signOutAndWipe() : account.signOut());
  }

  AlertDialog _plainDialog(BuildContext context, int unsent) => AlertDialog(
        title: const Text('Выйти из учётной записи?'),
        content: Text(unsent == 0
            ? 'Данные останутся на устройстве. Чтобы продолжить работу, '
                'понадобится снова ввести пароль.'
            : 'Не отправлено изменений: $unsent. Они останутся на этом устройстве '
                'и уйдут на сервер, когда вы снова войдёте.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Выйти'),
          ),
        ],
      );

  AlertDialog _wipeDialog(BuildContext context, int unsent) => AlertDialog(
        title: const Text('Выйти и удалить данные?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('С устройства будут удалены задачи, заполненные формы, '
                'фотографии и сохранённый пароль — всё, что хранится '
                'для «${account.session.name}». Данные других пользователей '
                'этого телефона останутся на месте.'),
            if (unsent > 0) ...[
              const SizedBox(height: 12),
              Text(
                'Не отправлено изменений: $unsent. Они будут потеряны — '
                'сервер их не получит.',
                style:
                    TextStyle(color: Wms.warn, fontWeight: FontWeight.w600),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: Wms.warn),
            child: const Text('Удалить и выйти'),
          ),
        ],
      );
}

/// Строка профиля: иконка, название, справа значение или счётчик. Касание —
/// не меньше 44.
class _Row extends StatelessWidget {
  final IconData icon;
  final String title;
  final Color? iconColor;
  final Color? titleColor;
  final Widget? trailing;
  final VoidCallback? onTap;

  const _Row({
    required this.icon,
    required this.title,
    this.iconColor,
    this.titleColor,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Icon(icon, size: 20, color: iconColor ?? Wms.text2),
          const SizedBox(width: 12),
          Expanded(
            child: Text(title,
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: onTap != null ? FontWeight.w600 : FontWeight.w400,
                    color: titleColor ?? Wms.text)),
          ),
          if (trailing != null) trailing!,
          if (onTap != null)
            Icon(Icons.chevron_right, size: 18, color: Wms.muted),
        ],
      ),
    );
    if (onTap == null) return row;
    return InkWell(onTap: onTap, borderRadius: BorderRadius.circular(8), child: row);
  }
}
