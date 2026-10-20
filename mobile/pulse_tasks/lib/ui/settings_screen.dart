import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/api_client.dart';
import '../data/account_controller.dart';
import '../data/connection_failure.dart';
import '../data/session.dart';
import '../data/settings.dart' show Settings;
import 'appearance_controller.dart';
import 'theme.dart';

/// Where this device talks to. Filled in once, when the phone is handed out, and reached
/// afterwards only through the gear on the login screen — the person who comes on shift
/// signs in, they do not configure anything.
class SettingsScreen extends StatefulWidget {
  final bool firstRun;
  const SettingsScreen({super.key, this.firstRun = false});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _formKey = GlobalKey<FormState>();
  late Settings _draft;
  late TextEditingController _url;

  /// Протокол — выбор сегмента над полем, а не догадка по адресу: у сервера
  /// заказчика он бывает и https, и узнать его по виду `host:port` нельзя.
  bool _https = false;
  bool _checking = false;
  String? _checkResult;
  bool _checkOk = false;

  /// Что проверить, если проверка не прошла, — строкой под её итогом.
  String? _checkHint;

  @override
  void initState() {
    super.initState();
    _draft = context.read<AccountController>().settings.copy();
    // сохранённый адрес разбирается на протокол и host:port: протокол уезжает в
    // сегмент, в поле остаётся только хост
    final parsed = Settings.splitUrl(_draft.baseUrl);
    _https = parsed.scheme == 'https';
    _url = TextEditingController(text: parsed.host);
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  /// Кнопки «Проверить» и «Сохранить» работают с одним адресом, и собирается он
  /// отсюда: явные http/https, напечатанные в поле по привычке старой версии,
  /// уезжают в сегмент; голый `host:port` схемы в поле не имеет, и остаётся
  /// сегмент, выбранный руками, — протокол не угадывается. Опечатанная схема
  /// (`htp://`) не разбирается — её поймает валидация адреса.
  void _reconcile() {
    final parsed = Settings.splitUrl(_url.text);
    final known = parsed.scheme == 'http' || parsed.scheme == 'https';
    if (!known) {
      final trimmed = _url.text.trim();
      if (trimmed != _url.text) setState(() => _url.text = trimmed);
      return;
    }
    if (parsed.scheme == (_https ? 'https' : 'http') &&
        _url.text == parsed.host) {
      return;
    }
    setState(() {
      _https = parsed.scheme == 'https';
      _url.text = parsed.host;
    });
  }

  /// Checks the address alone, and can do so before anybody has signed in: `apiBrand` is
  /// the one endpoint answered without authentication, which is exactly what «правильный
  /// ли адрес» needs — an answer that does not depend on the password.
  Future<void> _check() async {
    _reconcile();
    _draft.baseUrl = Settings.composeUrl(https: _https, host: _url.text);
    if (_draft.baseUrl.isEmpty) {
      setState(() {
        _checkOk = false;
        _checkResult = 'Укажите адрес сервера';
        _checkHint = null;
      });
      return;
    }
    final malformed = addressFailure(_draft.baseUrl);
    if (malformed != null) {
      _fail(malformed);
      return;
    }
    setState(() {
      _checking = true;
      _checkResult = null;
      _checkHint = null;
    });
    // Своя, пустая сессия, а не сессия вошедшего: проверяется адрес, который ещё не
    // сохранён и может вести к чужому серверу (#37178).
    final probe = ApiClient(_draft, Session());
    try {
      final brand = await probe.fetchBrand();
      final name = brand?['name']?.toString() ?? '';
      setState(() {
        _checkOk = true;
        _checkResult =
            name.isEmpty ? 'Сервер отвечает' : 'Сервер отвечает: $name';
      });
    } catch (e) {
      _fail(connectionFailure(e));
    } finally {
      probe.close();
      if (mounted) setState(() => _checking = false);
    }
  }

  void _fail(ConnectionFailure f) => setState(() {
        _checkOk = false;
        _checkResult = f.what;
        _checkHint = f.hint;
      });

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    _reconcile();
    _draft.baseUrl = Settings.composeUrl(https: _https, host: _url.text);
    final account = context.read<AccountController>();
    final appearance = context.read<AppearanceController>();
    await _draft.save();
    // the address is half of the local base's name — another server, another cache
    await account.updateSettings(_draft.copy());
    // the address is what the branding hangs on — ask for it right here, before login
    unawaited(appearance.refreshBrand());
    if (!mounted) return;
    // on the first run this screen *is* the app root: saving the address makes the root
    // rebuild into the login form, so there is nothing to navigate to
    if (!widget.firstRun) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _label('Подключение'),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('http')),
                ButtonSegment(value: true, label: Text('https')),
              ],
              selected: {_https},
              showSelectedIcon: false,
              onSelectionChanged: (s) => setState(() => _https = s.first),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _url,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Адрес сервера',
                hintText: '192.168.1.10:9080',
                helperText: 'Задаётся один раз: протокол — переключателем, '
                    'в поле — только адрес',
                border: OutlineInputBorder(),
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Обязательное поле' : null,
            ),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: _checking ? null : _check,
              icon: _checking
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.wifi_tethering),
              label: const Text('Проверить подключение'),
            ),
            if (_checkResult != null) ...[
              const SizedBox(height: 10),
              Text(
                _checkResult!,
                style: TextStyle(color: _checkOk ? Wms.ok : Wms.warn),
              ),
              if (_checkHint != null) ...[
                const SizedBox(height: 4),
                Text(_checkHint!,
                    style: TextStyle(fontSize: 13, color: Wms.muted)),
              ],
            ],
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save),
              label: const Text('Сохранить'),
            ),
            const Divider(height: 40),
            _label('Оформление'),
            _themePicker(),
          ],
        ),
      ),
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(
          text.toUpperCase(),
          style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
              color: Wms.muted),
        ),
      );

  /// Тема — единственная настройка этого экрана, которая применяется сразу, без
  /// «Сохранить»: её выбирают глазами, глядя на результат, и кнопка между выбором и
  /// результатом здесь только мешала бы. Адрес сервера так нельзя — его сначала
  /// проверяют.
  Widget _themePicker() => ValueListenableBuilder<ThemeMode>(
        valueListenable: Wms.mode,
        builder: (context, mode, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(
                    value: ThemeMode.system,
                    icon: Icon(Icons.brightness_auto_outlined),
                    label: Text('Система')),
                ButtonSegment(
                    value: ThemeMode.light,
                    icon: Icon(Icons.light_mode_outlined),
                    label: Text('Светлая')),
                ButtonSegment(
                    value: ThemeMode.dark,
                    icon: Icon(Icons.dark_mode_outlined),
                    label: Text('Тёмная')),
              ],
              selected: {mode},
              showSelectedIcon: false,
              onSelectionChanged: (s) => unawaited(Wms.setMode(s.first)),
            ),
            const SizedBox(height: 10),
            Text(
              '«Система» — как настроен телефон. Тёмная бережёт глаза в полутёмном '
              'зале и на складе; цвета заказчика работают в обеих.',
              style: TextStyle(fontSize: 12, color: Wms.muted),
            ),
          ],
        ),
      );
}
