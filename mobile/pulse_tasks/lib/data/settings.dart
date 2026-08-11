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
  ///
  /// Unlike the home screen it belongs here rather than to the person: the palette is the
  /// customer's, the same for everyone on this device, and it dresses the login form —
  /// before anybody has signed in there is no user's base to read it from.
  String brandJson;

  /// Object (shop) the home screen shows its per-object numbers for. Kept on the device
  /// rather than on the server: it is where this phone is standing today, not a property
  /// of the account. Geolocation will set it automatically later.
  String objectId;

  Settings({
    this.baseUrl = '',
    this.brandJson = '',
    this.objectId = '',
  });

  bool get isConfigured => baseUrl.trim().isNotEmpty;

  /// The address as typed, turned into something the HTTP client can dial. The person
  /// deploying the phone knows the server as `192.168.1.10:9080` and types exactly that;
  /// a bare host is not a URL, so `Uri.parse` finds no scheme and the request fails
  /// before it leaves the device. On a local network a missing scheme can only mean
  /// http, so that is what it gets. `host:port` is deliberately not read as a scheme —
  /// only an explicit `something://` prefix (https included) is left alone.
  static String normalizeUrl(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return '';
    return RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(s) ? s : 'http://$s';
  }

  Settings copy() => Settings(
        baseUrl: baseUrl,
        brandJson: brandJson,
        objectId: objectId,
      );

  static Future<Settings> load() async {
    final sp = await SharedPreferences.getInstance();
    return Settings(
      baseUrl: sp.getString('baseUrl') ?? '',
      brandJson: sp.getString('brandJson') ?? '',
      objectId: sp.getString('objectId') ?? '',
    );
  }

  Future<void> save() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString('baseUrl', baseUrl.trim());
    await sp.setString('brandJson', brandJson);
    await sp.setString('objectId', objectId);
  }

  /// The home screen an older build cached here, one per device. It was drawn for the only
  /// person that device had, so — exactly like the single local base — it becomes theirs at
  /// the first sign-in after the update, and is removed from here on the way out. Returns
  /// null once there is nothing left to move.
  static Future<String?> takeLegacyHomeJson() async {
    final sp = await SharedPreferences.getInstance();
    final json = sp.getString('homeJson');
    if (json != null) await sp.remove('homeJson');
    return json;
  }
}
