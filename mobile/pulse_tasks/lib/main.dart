import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'data/api_client.dart';
import 'data/local_db.dart';
import 'data/settings.dart';
import 'data/task_repository.dart';
import 'ui/settings_screen.dart';
import 'ui/task_list_screen.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final settings = await Settings.load();
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
      child: MaterialApp(
        title: 'Пульс — Задачи',
        debugShowCheckedModeBanner: false,
        theme: buildWmsTheme(),
        home: repo.settings.isConfigured
            ? const TaskListScreen()
            : const SettingsScreen(firstRun: true),
      ),
    );
  }
}
