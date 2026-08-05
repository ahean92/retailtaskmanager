import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/api_client.dart';
import '../data/settings.dart';
import '../data/task_repository.dart';
import 'home_screen.dart';

class SettingsScreen extends StatefulWidget {
  final bool firstRun;
  const SettingsScreen({super.key, this.firstRun = false});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _formKey = GlobalKey<FormState>();
  late Settings _draft;
  late TextEditingController _url, _user, _pass, _assignee;
  bool _checking = false;
  String? _checkResult;
  bool _checkOk = false;

  @override
  void initState() {
    super.initState();
    _draft = context.read<TaskRepository>().settings.copy();
    _url = TextEditingController(text: _draft.baseUrl);
    _user = TextEditingController(text: _draft.username);
    _pass = TextEditingController(text: _draft.password);
    _assignee = TextEditingController(text: _draft.assignee);
  }

  @override
  void dispose() {
    _url.dispose();
    _user.dispose();
    _pass.dispose();
    _assignee.dispose();
    super.dispose();
  }

  void _collect() {
    _draft
      ..baseUrl = _url.text.trim()
      ..username = _user.text.trim()
      ..password = _pass.text
      ..assignee = _assignee.text.trim();
  }

  Future<void> _check() async {
    _collect();
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
    final probe = ApiClient(_draft);
    try {
      final statuses = await probe.fetchStatuses();
      setState(() {
        _checkOk = true;
        _checkResult = 'Успешно. Статусов получено: ${statuses.length}';
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
    _collect();
    final repo = context.read<TaskRepository>();
    await _draft.save();
    repo.updateSettings(_draft.copy());
    // the address is what the branding hangs on — ask for it right here, before login
    unawaited(repo.refreshBrand());
    unawaited(repo.syncAndRefresh());
    if (!mounted) return;
    if (widget.firstRun) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const HomeScreen()),
      );
    } else {
      Navigator.of(context).pop();
    }
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
                hintText: 'http://192.168.1.10:9080',
                border: OutlineInputBorder(),
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Обязательное поле' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _user,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Пользователь (необязательно)',
                hintText: 'admin',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _pass,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Пароль (необязательно)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _assignee,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'ID исполнителя (необязательно)',
                helperText: 'Показывать только задачи этого исполнителя. Пусто — все.',
                border: OutlineInputBorder(),
              ),
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
                style: TextStyle(
                  color: _checkOk ? Colors.green.shade700 : Colors.red.shade700,
                ),
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
