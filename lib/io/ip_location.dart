import 'dart:async';
import 'dart:convert';

import 'package:avaremp/utils/app_log.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

/// A rough position from this device's network address, for when nothing
/// better exists: a desktop with no location provider, or a phone that has sat
/// indoors without a fix. City-level at best, often the ISP's exchange rather
/// than the user, so it is only ever a place to open the map -- never a fix.
class IpLocation {
  static const Duration _timeout = Duration(seconds: 8);

  /// Keyless services, tried in turn. Each has its own field names, so each
  /// carries its own reader; the first one that answers with coordinates wins.
  static final List<(Uri, (LatLng, String)? Function(Map<String, dynamic>))>
      _services = [
    (Uri.parse("https://ipapi.co/json/"), (j) => _read(j, "latitude", "longitude",
        j["error"] != true, j["city"], j["region"])),
    (Uri.parse("https://ipwho.is/"), (j) => _read(j, "latitude", "longitude",
        j["success"] != false, j["city"], j["region"])),
    (Uri.parse("http://ip-api.com/json/"), (j) => _read(j, "lat", "lon",
        j["status"] == "success", j["city"], j["regionName"])),
  ];

  static (LatLng, String)? _read(Map<String, dynamic> j, String latKey,
      String lonKey, bool ok, dynamic city, dynamic region) {
    final double? lat = (j[latKey] as num?)?.toDouble();
    final double? lon = (j[lonKey] as num?)?.toDouble();
    if (!ok || lat == null || lon == null || (lat == 0 && lon == 0)) {
      return null;
    }
    final String place = [city, region]
        .whereType<String>()
        .where((s) => s.isNotEmpty)
        .join(", ");
    return (LatLng(lat, lon), place);
  }

  /// Plain "what is my address" services, unmetered, so they can be asked
  /// often. The address changing is the cue to look the place up again.
  static final List<Uri> _addressServices = [
    Uri.parse("https://api.ipify.org?format=text"),
    Uri.parse("https://checkip.amazonaws.com"),
  ];

  /// This device's public address as the internet sees it, or null when no
  /// service could be reached.
  Future<String?> publicAddress() async {
    for (final Uri url in _addressServices) {
      try {
        final http.Response r = await http
            .get(url, headers: {"User-Agent": "AvareX"})
            .timeout(_timeout);
        final String ip = r.body.trim();
        if (r.statusCode == 200 && ip.isNotEmpty && ip.length < 64) {
          return ip;
        }
      }
      catch (e) {
        AppLog.logMessage("Public address via ${url.host} failed: $e");
      }
    }
    return null;
  }

  /// Coordinates and a place name ("Salt Lake City, Utah"), or null when no
  /// service could be reached. Never throws: the callers run on a timer and a
  /// lookup that fails is simply tried again later.
  Future<(LatLng, String)?> lookup() async {
    for (final (Uri url, reader) in _services) {
      try {
        final http.Response r = await http
            .get(url, headers: {"User-Agent": "AvareX"})
            .timeout(_timeout);
        if (r.statusCode != 200) {
          continue;
        }
        final (LatLng, String)? found =
            reader(jsonDecode(r.body) as Map<String, dynamic>);
        if (found != null) {
          return found;
        }
      }
      catch (e) {
        AppLog.logMessage("IP location lookup via ${url.host} failed: $e");
      }
    }
    return null;
  }
}
