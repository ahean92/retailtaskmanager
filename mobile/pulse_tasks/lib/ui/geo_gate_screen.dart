import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/geo.dart';
import '../data/account_controller.dart';
import '../data/location_controller.dart';
import 'theme.dart';
import 'widgets/ds.dart';

/// What went wrong with the location, in a sentence that says what to do about it.
///
/// Public because the gate is not the only place that asks the device where it is:
/// «Обновить местоположение» in the task list header runs into the very same four
/// failures, and there must be one wording of each rather than two that drift apart.
(IconData, String, String) explainGeoFailure(GeoFailure failure) =>
    switch (failure) {
      GeoFailure.servicesOff => (
          Icons.location_disabled,
          'Геолокация выключена',
          'Определение местоположения отключено на устройстве. Включите его в '
              'настройках и повторите.',
        ),
      GeoFailure.denied => (
          Icons.location_off,
          'Нет доступа к местоположению',
          'Приложению нужен доступ к местоположению: без него не подтвердить, что '
              'работа сделана на объекте. Разрешите доступ и повторите.',
        ),
      GeoFailure.deniedForever => (
          Icons.block,
          'Доступ к местоположению запрещён',
          'Доступ отключён насовсем — система больше не спрашивает. Откройте '
              'настройки приложения, разрешите доступ к местоположению и повторите.',
        ),
      GeoFailure.noFix => (
          Icons.satellite_alt,
          'Не удалось определить местоположение',
          'Сигнал не поймался: так бывает в холодильной камере, в подвале и в '
              'глубине склада. Подойдите к окну или выйдите на улицу и повторите.',
        ),
    };

/// The door between the sign-in and the app for everyone who works by location.
///
/// One screen for all four ways of having no coordinates — no permission, permission
/// refused for good, location switched off on the device, no fix arriving — because the
/// person on shift can do the same two things about any of them: put it right in the
/// settings, and try again. What differs is the sentence and which settings page opens.
///
/// It does not let anybody through. There is no «Пропустить» here on purpose: the whole
/// point of the requirement is that work is recorded where it happened. The way out that
/// does exist is the way back — signing out returns to the login form, so a phone whose
/// permission cannot be granted at all is not a phone somebody is locked inside.
///
/// Редизайн #37411 (п. 12): иконка на подложке, заголовок, текст и одна-две кнопки
/// внизу — один шаблон на все причины. Меню аккаунта из шапки ушло на Профиль,
/// но гейт стоит до вкладок, и выход с него остаётся здесь иконкой.
class GeoGateScreen extends StatefulWidget {
  const GeoGateScreen({super.key});

  @override
  State<GeoGateScreen> createState() => _GeoGateScreenState();
}

class _GeoGateScreenState extends State<GeoGateScreen> {
  bool _busy = true;
  GeoFailure? _failure;

  @override
  void initState() {
    super.initState();
    // right after the sign-in, without waiting to be asked: the permission dialog is the
    // first thing the person sees, and in the ordinary case it is also the last
    WidgetsBinding.instance.addPostFrameCallback((_) => _locate());
  }

  Future<void> _locate() async {
    setState(() {
      _busy = true;
      _failure = null;
    });
    // on success the controller notifies and the app root swaps this screen for the home
    // screen — there is no navigation to do here
    final outcome = await context.read<LocationController>().locate();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _failure = outcome is GeoUnavailable ? outcome.reason : null;
    });
  }

  Future<void> _openSettings() async {
    final failure = _failure;
    if (failure == null) return;
    await context.read<LocationController>().geo.openSettings(failure);
  }

  @override
  Widget build(BuildContext context) {
    final failure = _failure;
    final (icon, title, explanation) =
        _busy || failure == null ? (null, null, null) : explainGeoFailure(failure);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Местоположение'),
        // the only way back: this screen is passed or left, not skipped
        actions: [
          IconButton(
            tooltip: 'Выйти из учётной записи',
            icon: const Icon(Icons.logout),
            onPressed: () => _leave(),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
            children: _busy || failure == null
                ? _searching()
                : _blocked(icon!, title!, explanation!),
          ),
        ),
      ),
      bottomNavigationBar: _busy || failure == null
          ? null
          : DsBottomActionBar(
              primaryLabel: 'Повторить',
              onPrimary: _locate,
              secondaryLabel: 'Открыть настройки',
              onSecondary: _openSettings,
            ),
    );
  }

  /// Выход с гейта — тот же вопрос, что и в профиле, без «удалить данные»:
  /// стирать работаещему с чужого телефона нечего, а лишняя кнопка здесь —
  /// лишний способ ошибиться.
  Future<void> _leave() async {
    final account = context.read<AccountController>();
    final unsent = await account.unsentChanges();
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
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
      ),
    );
    if (confirmed != true) return;
    await account.signOut();
  }

  List<Widget> _searching() => [
        const Center(child: CircularProgressIndicator()),
        const SizedBox(height: 24),
        Text(
          'Определяем местоположение…',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 17, color: Wms.text),
        ),
      ];

  List<Widget> _blocked(IconData icon, String title, String explanation) {
    return [
      Center(
        child: Container(
          width: 96,
          height: 96,
          decoration: BoxDecoration(
            color: Wms.chipBg,
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: 44, color: Wms.text2),
        ),
      ),
      const SizedBox(height: 20),
      Text(
        title,
        textAlign: TextAlign.center,
        style: TextStyle(
            fontSize: 20, fontWeight: FontWeight.w700, color: Wms.text),
      ),
      const SizedBox(height: 12),
      Text(
        explanation,
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 15, height: 1.4, color: Wms.muted),
      ),
    ];
  }
}
