import 'package:shared_preferences/shared_preferences.dart';

/// Connection settings, persisted via shared_preferences.
///
/// NOTE: for the MVP the password is stored in plain shared_preferences. For a
/// real deployment switch to flutter_secure_storage (see README).
class Settings {
  String baseUrl; // e.g. http://192.168.1.10:9080
  String username; // lsFusion login (HTTP Basic); empty => anonymous
  String password;
  String assignee; // optional: show only tasks for this assignee id; empty => all

  Settings({
    this.baseUrl = '',
    this.username = '',
    this.password = '',
    this.assignee = '',
  });

  bool get isConfigured => baseUrl.trim().isNotEmpty;

  Settings copy() => Settings(
        baseUrl: baseUrl,
        username: username,
        password: password,
        assignee: assignee,
      );

  static Future<Settings> load() async {
    final sp = await SharedPreferences.getInstance();
    return Settings(
      baseUrl: sp.getString('baseUrl') ?? '',
      username: sp.getString('username') ?? '',
      password: sp.getString('password') ?? '',
      assignee: sp.getString('assignee') ?? '',
    );
  }

  Future<void> save() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString('baseUrl', baseUrl.trim());
    await sp.setString('username', username.trim());
    await sp.setString('password', password);
    await sp.setString('assignee', assignee.trim());
  }
}
