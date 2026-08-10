import 'package:shared_preferences/shared_preferences.dart';

/// Connection settings, persisted via shared_preferences.
///
/// Deliberately not the account: who is signed in lives in [Session]. This screen is
/// filled in once, when the device is deployed, and the person who comes on shift never
/// sees it — they see the login form.
class Settings {
  String baseUrl; // e.g. http://192.168.1.10:9080

  /// Last brand received from this server, as raw JSON. Kept so the app opens already
  /// wearing the customer's colours instead of flashing the default palette first.
  String brandJson;

  /// Last home screen received from this server, as raw JSON. The home page is the first
  /// thing the app shows, and an inspector who opens it in the aisle without a signal
  /// should see yesterday's dashboard rather than a spinner.
  String homeJson;

  /// Object (shop) the home screen shows its per-object numbers for. Kept on the device
  /// rather than on the server: it is where this phone is standing today, not a property
  /// of the account. Geolocation will set it automatically later.
  String objectId;

  Settings({
    this.baseUrl = '',
    this.brandJson = '',
    this.homeJson = '',
    this.objectId = '',
  });

  bool get isConfigured => baseUrl.trim().isNotEmpty;

  Settings copy() => Settings(
        baseUrl: baseUrl,
        brandJson: brandJson,
        homeJson: homeJson,
        objectId: objectId,
      );

  static Future<Settings> load() async {
    final sp = await SharedPreferences.getInstance();
    return Settings(
      baseUrl: sp.getString('baseUrl') ?? '',
      brandJson: sp.getString('brandJson') ?? '',
      homeJson: sp.getString('homeJson') ?? '',
      objectId: sp.getString('objectId') ?? '',
    );
  }

  Future<void> save() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString('baseUrl', baseUrl.trim());
    await sp.setString('brandJson', brandJson);
    await sp.setString('homeJson', homeJson);
    await sp.setString('objectId', objectId);
  }
}
