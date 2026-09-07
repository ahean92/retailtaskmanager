import 'dart:convert';

import '../data/api_client.dart';
import '../data/settings.dart';
import 'brand.dart';
import 'theme.dart';

/// Оформление с сервера: бренд заказчика — имя, палитра, логотип — тянется, как только
/// известен адрес, и применяется к живому приложению через [Wms]. Единственный, кто
/// знает и сеть, и тему: слой данных темы не касается, а экраны — сети.
class AppearanceController {
  final ApiClient api;
  final Settings settings;

  AppearanceController({required this.api, required this.settings});

  /// Pulls the customer's branding and applies it. Called as soon as the server address
  /// is known — a failure is silent by design: a wrong palette must never stand between
  /// the inspector and their tasks, the app simply keeps the look it already had.
  Future<void> refreshBrand() async {
    if (!settings.isConfigured) return;
    try {
      final j = await api.fetchBrand();
      if (j == null || j.isEmpty) return;
      settings.brandJson = jsonEncode(j);
      await settings.save();
      Wms.brand = Brand.fromJson(j);
    } catch (_) {
      // offline, older server without the endpoint, malformed palette — keep the current
    }
  }
}
