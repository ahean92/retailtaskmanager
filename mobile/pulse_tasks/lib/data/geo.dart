import 'dart:async';

import 'package:geolocator/geolocator.dart';

/// Why the app has no coordinates. Four different causes, one screen: whatever the cause,
/// the person on shift does the same two things — fix it in the settings and try again —
/// so what differs between them is only the sentence they read and which settings page
/// the button opens.
enum GeoFailure {
  /// Location is switched off on the device itself. Nobody gets a fix, permission or not.
  servicesOff,

  /// Access not granted (or dismissed). The system dialog can still be shown, so «Повторить»
  /// alone may be enough.
  denied,

  /// Refused for good — on both platforms the system stops asking after that, and only the
  /// app's own settings page can undo it.
  deniedForever,

  /// Allowed and switched on, and still no position: a freezer, a basement, a stockroom
  /// with no window. The one failure the device is not to blame for.
  noFix,
}

/// The result of trying to find out where the device is: coordinates, or the reason there
/// are none.
sealed class GeoOutcome {
  const GeoOutcome();
}

/// Where the device is, and when it was measured there.
///
/// The timestamp is what makes a remembered position usable at all: a fix from five
/// minutes ago says where the person is now, one from yesterday evening says where the
/// phone spent the night. See [Geo.lastKnownWindow].
class GeoFix extends GeoOutcome {
  final double latitude;
  final double longitude;
  final DateTime at;
  const GeoFix(this.latitude, this.longitude, this.at);
}

class GeoUnavailable extends GeoOutcome {
  final GeoFailure reason;
  const GeoUnavailable(this.reason);
}

/// What the device says about this app's access to the location. Narrower than the
/// platform's own enum: only «ask again» and «settings only» lead anywhere different.
enum GeoPermission { granted, denied, deniedForever }

/// Everything the gate needs from the device, as an interface.
///
/// The geolocator plugin is a set of static methods over a platform channel; behind this
/// seam the order of the questions — services, permission, remembered position, fresh fix
/// — is ordinary Dart and can be exercised on a machine with no GPS in it. [DeviceGeo] is
/// the one implementation that talks to the plugin.
abstract class GeoPlatform {
  Future<bool> servicesEnabled();
  Future<GeoPermission> permission();
  Future<GeoPermission> requestPermission();

  /// The last position the device happens to remember, however old, or null if it
  /// remembers none.
  Future<GeoFix?> lastKnown();

  /// A fresh measurement, or null if none arrived within [timeout] — or if the device
  /// refused to take it at all.
  Future<GeoFix?> fix(Duration timeout);

  /// The page «Открыть настройки» opens: the device's location switch when that is what is
  /// off, the app's own permissions otherwise.
  Future<void> openSettings({required bool locationServices});
}

/// Finding out where the device is, in the order that gets an answer fastest.
class Geo {
  /// How long to wait for a fix. Long enough for a cold start outdoors, short enough that
  /// a phone that will never get one does not hold somebody at the door of their shift.
  static const fixTimeout = Duration(seconds: 15);

  /// How old a remembered position may be and still count as where the person is. This is
  /// the concession decided on 2026-08-05 alongside the server's `geoRequired`: demanding
  /// a fresh fix every time makes a freezer or a basement a place where the app cannot be
  /// used, and nobody walks far enough in five minutes for the answer to change.
  static const lastKnownWindow = Duration(minutes: 5);

  /// On Android this is a *priority*, not a demand for precision: `high` asks the fused
  /// provider for everything it has — satellites, Wi-Fi, cell towers — while `medium`
  /// leaves out the satellites. Measured on the emulator (API 31, position fed with
  /// `adb emu geo fix`): with `medium` nothing arrives at all and the wait runs into the
  /// timeout, with `high` the fix comes back in about four seconds. Extra battery once per
  /// launch is not a price worth the risk of a gate that does not open.
  static const accuracy = LocationAccuracy.high;

  final GeoPlatform platform;

  Geo({GeoPlatform? platform}) : platform = platform ?? const DeviceGeo();

  /// Ask the device where it is. Never throws: a gate that fails with a stack trace is a
  /// gate that cannot be got past.
  ///
  /// [fresh] — не довольствоваться запомненной позицией, а мерить заново. Так спрашивает
  /// «Обновить местоположение»: эту кнопку жмут ровно потому, что переехали, и ответ
  /// «вы там же, где четыре минуты назад» — единственный, который здесь бесполезен.
  /// С #36837 цена ошибки выросла: от места зависит уже не «какие задачи видны», а
  /// можно ли работать, и человек, доехавший до магазина, упирался бы в «только для
  /// чтения» на задаче, у которой стоит ногами. На старте (гейт) кэш остаётся: там
  /// вопрос другой — «где я вообще», и мгновенный ответ лучше похода к окну.
  Future<GeoOutcome> locate({bool fresh = false}) async {
    try {
      if (!await platform.servicesEnabled()) {
        return const GeoUnavailable(GeoFailure.servicesOff);
      }

      var granted = await platform.permission();
      if (granted == GeoPermission.denied) {
        // never asked, or asked and dismissed — either way the system dialog is still
        // available, and this is the moment it is shown: right after the sign-in
        granted = await platform.requestPermission();
      }
      switch (granted) {
        case GeoPermission.denied:
          return const GeoUnavailable(GeoFailure.denied);
        case GeoPermission.deniedForever:
          return const GeoUnavailable(GeoFailure.deniedForever);
        case GeoPermission.granted:
          break;
      }

      // the cheap answer first: a position from a few minutes ago is as true as one
      // measured now, and it arrives instantly instead of after a walk to the window
      if (!fresh) {
        final remembered = await platform.lastKnown();
        if (remembered != null && _fresh(remembered)) return remembered;
      }

      return await platform.fix(fixTimeout) ??
          const GeoUnavailable(GeoFailure.noFix);
    } catch (_) {
      // the plugin itself gave way — no location hardware, a channel that is not there.
      // No coordinates is no coordinates; the screen says so and offers to try again.
      return const GeoUnavailable(GeoFailure.noFix);
    }
  }

  bool _fresh(GeoFix fix) =>
      DateTime.now().difference(fix.at) < lastKnownWindow;

  Future<void> openSettings(GeoFailure reason) =>
      platform.openSettings(locationServices: reason == GeoFailure.servicesOff);
}

/// The real device. The only place in the app that talks to the geolocator plugin.
class DeviceGeo implements GeoPlatform {
  const DeviceGeo();

  @override
  Future<bool> servicesEnabled() => Geolocator.isLocationServiceEnabled();

  @override
  Future<GeoPermission> permission() async =>
      _permission(await Geolocator.checkPermission());

  @override
  Future<GeoPermission> requestPermission() async =>
      _permission(await Geolocator.requestPermission());

  @override
  Future<GeoFix?> lastKnown() async =>
      _fix(await Geolocator.getLastKnownPosition());

  @override
  Future<GeoFix?> fix(Duration timeout) async {
    try {
      return _fix(await Geolocator.getCurrentPosition(
          locationSettings:
              LocationSettings(accuracy: Geo.accuracy, timeLimit: timeout)));
    } on TimeoutException {
      return null; // the ordinary case: allowed, switched on, and still nothing indoors
    } on LocationServiceDisabledException {
      return null; // switched off in the moment between the check and the measurement
    } on PermissionDeniedException {
      return null; // withdrawn in that same moment
    }
  }

  @override
  Future<void> openSettings({required bool locationServices}) async =>
      locationServices
          ? await Geolocator.openLocationSettings()
          : await Geolocator.openAppSettings();

  static GeoPermission _permission(LocationPermission p) => switch (p) {
        LocationPermission.always ||
        LocationPermission.whileInUse =>
          GeoPermission.granted,
        LocationPermission.deniedForever => GeoPermission.deniedForever,
        // `unableToDetermine` is not a yes, and there is nothing to do with it but ask
        _ => GeoPermission.denied,
      };

  static GeoFix? _fix(Position? p) =>
      p == null ? null : GeoFix(p.latitude, p.longitude, p.timestamp);
}
