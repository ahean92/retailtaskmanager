import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'data/api_client.dart';
import 'data/session.dart';
import 'data/settings.dart';
import 'data/task_repository.dart';
import 'ui/brand.dart';
import 'ui/geo_gate_screen.dart';
import 'ui/home_screen.dart';
import 'ui/login_screen.dart';
import 'ui/settings_screen.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final settings = await Settings.load();
  final session = await Session.load();

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

  // the local base is not opened here: it is named after whoever is signed in, so it is
  // the repository that opens it — at startup if the session survived, at the sign-in
  // otherwise — and closes it again when they leave
  final api = ApiClient(settings, session);
  final repo = TaskRepository(api: api, settings: settings, session: session);
  await repo.init();

  runApp(PulseApp(repo: repo));
}

class PulseApp extends StatelessWidget {
  final TaskRepository repo;
  const PulseApp({super.key, required this.repo});

  /// Kept at the app level so a session that dies mid-work can take the screens above it
  /// down: swapping the root alone would leave the task somebody was in the middle of
  /// sitting on top of the login form.
  static final navigatorKey = GlobalKey<NavigatorState>();

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
          navigatorKey: navigatorKey,
          title: brand.tagline.isEmpty
              ? brand.name
              : '${brand.name} — ${brand.tagline}',
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(brand),
          home: Consumer<TaskRepository>(
            builder: (context, repo, _) => _start(repo),
          ),
        ),
      ),
    );
  }

  /// Four states, in the order a device goes through them: an address has to be set up
  /// once, then somebody signs in, then — for everyone the server says works by location —
  /// the app finds out where that is, and from the next launch on the saved session takes
  /// them straight to the tasks.
  ///
  /// The gate is here rather than inside the sign-in so that it stands on every way in,
  /// including the one that skips the login form: a session restored at startup passes it
  /// too, and a permission withdrawn overnight therefore stops the app at the door.
  Widget _start(TaskRepository repo) {
    if (!repo.settings.isConfigured) return const SettingsScreen(firstRun: true);
    if (!repo.session.isActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        navigatorKey.currentState?.popUntil((r) => r.isFirst);
      });
      return const LoginScreen();
    }
    if (!repo.geoReady) return const GeoGateScreen();
    return const HomeScreen();
  }
}
