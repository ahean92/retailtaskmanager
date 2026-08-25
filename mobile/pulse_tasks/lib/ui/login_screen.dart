import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/task_repository.dart';
import 'settings_screen.dart';
import 'theme.dart';

/// The first thing the app shows: login, password, «Войти».
///
/// The server address is not here on purpose — it is set once when the device is deployed
/// and lives behind the gear. The person who comes on shift is not the one who knows the
/// address of anything.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _login;
  final _pass = TextEditingController();
  bool _busy = false;
  bool _obscure = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    // the login of whoever was signed in last: the same person usually comes back to the
    // same phone, and the password is the only thing worth typing twice
    _login = TextEditingController(
        text: context.read<TaskRepository>().session.login);
  }

  @override
  void dispose() {
    _login.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // on success the app root swaps this screen for the home screen — the repository
      // notifies, and there is no navigation to do here
      await context.read<TaskRepository>().signIn(_login.text.trim(), _pass.text);
    } on LoginException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final brand = Wms.brand;
    return Scaffold(
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: IconButton(
                  tooltip: 'Настройки',
                  icon: Icon(Icons.settings, color: Wms.muted),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const SettingsScreen()),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              if (brand.logoBytes != null) ...[
                Center(
                  // Логотип заказчика рисуют под светлый фон, и в тёмной теме он
                  // получает свою подложку: тёмный знак на тёмном экране просто
                  // исчезнет, а вход — единственный экран, где логотип и есть
                  // брендирование. В светлой подложка не нужна и не рисуется.
                  child: Container(
                    padding:
                        Wms.isDark ? const EdgeInsets.all(8) : EdgeInsets.zero,
                    decoration: Wms.isDark
                        ? BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(8))
                        : null,
                    child: Image.memory(
                      brand.logoBytes!,
                      height: 56,
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],
              Center(
                child: Text(
                  brand.name,
                  style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w700,
                      color: Wms.primary),
                ),
              ),
              if (brand.tagline.isNotEmpty)
                Center(
                  child: Text(brand.tagline,
                      style: TextStyle(fontSize: 15, color: Wms.muted)),
                ),
              const SizedBox(height: 32),
              TextFormField(
                controller: _login,
                autocorrect: false,
                enableSuggestions: false,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Логин',
                  prefixIcon: Icon(Icons.person_outline),
                  border: OutlineInputBorder(),
                ),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Введите логин' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _pass,
                obscureText: _obscure,
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) => _busy ? null : _submit(),
                decoration: InputDecoration(
                  labelText: 'Пароль',
                  prefixIcon: const Icon(Icons.lock_outline),
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    tooltip: _obscure ? 'Показать' : 'Скрыть',
                    icon: Icon(
                        _obscure ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.error_outline, size: 18, color: Wms.warn),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(_error!, style: TextStyle(color: Wms.warn)),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _busy ? null : _submit,
                child: _busy
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Wms.onChrome))
                    : const Text('Войти'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
