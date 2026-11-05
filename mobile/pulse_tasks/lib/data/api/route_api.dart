import 'dart:convert';

import '../api_client.dart';

extension RouteApi on ApiClient {
  Future<String> fetchRouteRaw({String? date}) =>
      getRaw(exec('apiRoute', date == null ? null : {'date': date}));

  Future<String> buildRouteRaw({String? date, double? lat, double? lon}) async {
    final r = await postJson('apiBuildRoute', {
      if (date != null) 'date': date,
      if (lat != null) 'lat': lat,
      if (lon != null) 'lon': lon,
    }, timeout: const Duration(seconds: 60));
    return utf8.decode(r.bodyBytes, allowMalformed: true).trim();
  }

  Future<String> orderRouteRaw(String id, List<String> objects) async {
    final r = await postJson('apiRouteOrder', {'id': id, 'objects': objects});
    return utf8.decode(r.bodyBytes, allowMalformed: true).trim();
  }
}
