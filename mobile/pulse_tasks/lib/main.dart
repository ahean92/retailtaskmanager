import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'data/api_client.dart';
import 'data/local_db.dart';
import 'data/settings.dart';
import 'data/task_repository.dart';
import 'ui/brand.dart';
import 'ui/home_screen.dart';
import 'ui/settings_screen.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final settings = await Settings.load();

  // Apply the brand kept from the last run BEFORE the first frame — otherwise the app
  // opens in its own colours and repaints into the customer's a moment later, which
  // reads as a glitch rather than as branding.
  if (settings.brandJson.isNotEmpty) {
    try {
      Wms.brand = Brand.fromJson(
          (jsonDecode(settings.brandJson) as Map).cast<String, dynamic>());
    } catch (_) {
      // stored brand unreadable — the default palette is a perfectly good fallback
    }
  }

  final db = await LocalDb.open();
  final api = ApiClient(settings);
  final repo = TaskRepository(db: db, api: api, settings: settings);
  await repo.init();

  runApp(PulseApp(repo: repo));
}

class PulseApp extends StatelessWidget {
  final TaskRepository repo;
  const PulseApp({super.key, required this.repo});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<TaskRepository>.value(
      value: repo,
      // One binary for every customer: the name and the palette come from the brand the
      // server supplies once the address is known, so the whole app is rebuilt when it
      // arrives rather than being decided at build time.
      child: ValueListenableBuilder<Brand>(
        valueListenable: Wms.notifier,
        builder: (context, brand, _) => MaterialApp(
          title: brand.tagline.isEmpty
              ? brand.name
              : '${brand.name} — ${brand.tagline}',
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(brand),
          home: repo.settings.isConfigured
              ? const HomeScreen()
              : const SettingsScreen(firstRun: true),
        ),
      ),
    );
  }
}
