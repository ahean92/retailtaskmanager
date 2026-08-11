import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/api_client.dart';
import '../data/settings.dart';
import '../data/task_repository.dart';
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
  bool _checking = false;
  String? _checkResult;
  bool _checkOk = false;

  @override
  void initState() {
    super.initState();
    _draft = context.read<TaskRepository>().settings.copy();
    _url = TextEditingController(text: _draft.baseUrl);
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  /// Checks the address alone, and can do so before anybody has signed in: `apiBrand` is
  /// the one endpoint answered without authentication, which is exactly what «правильный
  /// ли адрес» needs — an answer that does not depend on the password.
  Future<void> _check() async {
    _draft.baseUrl = Settings.normalizeUrl(_url.text);
    // show what will actually be dialled: the http:// the address was missing
    if (_url.text != _draft.baseUrl) _url.text = _draft.baseUrl;
    if (_draft.baseUrl.isEmpty) {
      setState(() {
        _checkOk = false;
        _checkResult = 'Укажите адрес сервера';
      });
      return;
    }
    setState(() {
      _checking = true;
      _checkResult = null;
    });
    final probe = ApiClient(_draft, context.read<TaskRepository>().session);
    try {
      final brand = await probe.fetchBrand();
      final name = brand?['name']?.toString() ?? '';
      setState(() {
        _checkOk = true;
        _checkResult =
            name.isEmpty ? 'Сервер отвечает' : 'Сервер отвечает: $name';
      });
    } catch (e) {
      setState(() {
        _checkOk = false;
        _checkResult = 'Ошибка: $e';
      });
    } finally {
      probe.close();
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    _draft.baseUrl = Settings.normalizeUrl(_url.text);
    final repo = context.read<TaskRepository>();
    await _draft.save();
    // the address is half of the local base's name — another server, another cache
    await repo.updateSettings(_draft.copy());
    // the address is what the branding hangs on — ask for it right here, before login
    unawaited(repo.refreshBrand());
    if (!mounted) return;
    // on the first run this screen *is* the app root: saving the address makes the root
    // rebuild into the login form, so there is nothing to navigate to
    if (!widget.firstRun) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Подключение')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _url,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Адрес сервера',
                hintText: '192.168.1.10:9080',
                helperText: 'Задаётся один раз; http:// подставится сам',
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
            ],
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save),
              label: const Text('Сохранить'),
            ),
          ],
        ),
      ),
    );
  }
}
