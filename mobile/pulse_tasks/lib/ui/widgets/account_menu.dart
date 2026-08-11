import 'package:flutter/material.dart';

import '../../data/task_repository.dart';
import '../theme.dart';

/// Who is signed in, and the two ways out of the account.
///
/// It sits on every screen the app can be left from — the start page and the task list —
/// because the way out must not depend on how deep into the app somebody happened to walk.
/// The two exits are deliberately not one with a checkbox: the ordinary one is what
/// happens at the end of a shift and touches nothing, and the one that erases the work is
/// a separate line with its own question.
class AccountMenu extends StatelessWidget {
  final TaskRepository repo;
  const AccountMenu({super.key, required this.repo});

  /// Whose account this is, as it is shown to the person themselves. The name is what they
  /// recognise, the login is what makes two people with one name different.
  String get _who => [repo.session.name, repo.session.login]
      .where((s) => s.isNotEmpty)
      .join(' · ');

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<_Exit>(
      tooltip: 'Учётная запись',
      icon: const Icon(Icons.account_circle_outlined),
      onSelected: (choice) => _leave(context, wipe: choice == _Exit.wipe),
      itemBuilder: (context) => [
        // the start page has nowhere else to say under whom the phone is working
        PopupMenuItem<_Exit>(
          enabled: false,
          child: Text(
            _who,
            style: TextStyle(
                fontSize: 13, fontWeight: FontWeight.w600, color: Wms.text),
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem<_Exit>(
          value: _Exit.plain,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.logout),
            title: Text('Выйти'),
          ),
        ),
        PopupMenuItem<_Exit>(
          value: _Exit.wipe,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.delete_forever_outlined, color: Wms.warn),
            title: Text('Выйти и удалить данные',
                style: TextStyle(color: Wms.warn)),
          ),
        ),
      ],
    );
  }

  /// Ask, then leave. The count comes out of the base before the question is put, because
  /// «сколько изменений останутся неотправленными» is the whole of what the person is being
  /// asked to weigh — for the ordinary exit it is a reason to sync first, for the wipe it
  /// is what they are about to destroy.
  Future<void> _leave(BuildContext context, {required bool wipe}) async {
    final navigator = Navigator.of(context);
    final unsent = await repo.unsentChanges();
    if (!context.mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) =>
          wipe ? _wipeDialog(context, unsent) : _plainDialog(context, unsent),
    );
    if (confirmed != true) return;

    // The screens of the person who is leaving go first, while their base is still open:
    // a task or a half-filled form left standing on the stack would keep its controller
    // alive over a closed base — and would be the first thing the next person sees.
    navigator.popUntil((r) => r.isFirst);
    // and the root swaps itself for the login screen as soon as the repository notifies
    await (wipe ? repo.signOutAndWipe() : repo.signOut());
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

  /// Everything this dialog promises is irreversible, so it names what goes, says whose it
  /// is, and puts the unsent count in plain words rather than behind «возможна потеря
  /// данных». The confirming button says what it does — «Удалить и выйти», not «ОК».
  AlertDialog _wipeDialog(BuildContext context, int unsent) => AlertDialog(
        title: const Text('Выйти и удалить данные?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('С устройства будут удалены задачи, заполненные формы, '
                'фотографии и сохранённый пароль — всё, что хранится '
                'для «$_who». Данные других пользователей этого телефона '
                'останутся на месте.'),
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

enum _Exit { plain, wipe }
