import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/geo.dart';
import '../data/task_repository.dart';
import 'theme.dart';
import 'widgets/account_menu.dart';

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
    // on success the repository notifies and the app root swaps this screen for the home
    // screen — there is no navigation to do here
    final outcome = await context.read<TaskRepository>().locate();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _failure = outcome is GeoUnavailable ? outcome.reason : null;
    });
  }

  Future<void> _openSettings() async {
    final failure = _failure;
    if (failure == null) return;
    await context.read<TaskRepository>().geo.openSettings(failure);
  }

  /// What went wrong, in a sentence that says what to do about it.
  static (IconData, String, String) _explain(GeoFailure failure) =>
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

  @override
  Widget build(BuildContext context) {
    final failure = _failure;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Местоположение'),
        // the only way back: this screen is passed or left, not skipped
        actions: [AccountMenu(repo: context.read<TaskRepository>())],
      ),
      body: SafeArea(
        child: Center(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
            children: _busy || failure == null
                ? _searching()
                : _blocked(_explain(failure)),
          ),
        ),
      ),
    );
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

  List<Widget> _blocked((IconData, String, String) reason) {
    final (icon, title, explanation) = reason;
    return [
      Icon(icon, size: 64, color: Wms.warn),
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
      const SizedBox(height: 28),
      FilledButton(onPressed: _locate, child: const Text('Повторить')),
      const SizedBox(height: 12),
      OutlinedButton(
          onPressed: _openSettings, child: const Text('Открыть настройки')),
    ];
  }
}
