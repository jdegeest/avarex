import 'dart:async';
import 'dart:convert';

import 'package:avaremp/gdl90/message_factory.dart';
import 'package:avaremp/gdl90/traffic_report_message.dart';
import 'package:avaremp/storage.dart';
import 'package:avaremp/utils/app_log.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

/// Traffic from a community ADS-B aggregator, for bench testing and for use
/// where no receiver is present.
///
/// This is NOT a substitute for ADS-B In. Positions come from ground receivers
/// with seconds of latency and coverage gaps, so every target is timestamped
/// with the feed's own `seen_pos` age and is subject to the same staleness
/// greying as any other traffic.
class NetworkTraffic {
  static final NetworkTraffic _instance = NetworkTraffic._internal();
  factory NetworkTraffic() => _instance;
  NetworkTraffic._internal();

  /// opendata.adsb.fi: no key, no daily cap, asks only for reasonable use.
  static const String _base = "https://opendata.adsb.fi/api/v2";
  static const Duration _interval = Duration(seconds: 3);
  static const int _radiusNm = 100;

  /// Long enough to ride out a slow response, short enough that a hung request
  /// cannot hold the single-flight lock past the point where the data would be
  /// useful anyway.
  static const Duration _requestTimeout = Duration(seconds: 8);

  Timer? _timer;
  bool _polling = false;
  bool get running => _timer != null;

  /// The feed is "live" while the data in hand is still worth showing. Health
  /// is the age of the last *successful* poll and nothing else: keying it off
  /// `lastError` as well made a single dropped request flip the banner to stale
  /// and the next one flip it straight back, which is all the user ever saw.
  ///
  /// At a 3 s cadence this tolerates several consecutive failures before
  /// declaring the feed dead, and still declares it well before the targets
  /// themselves have aged out of the map.
  static const Duration _healthyWithin = Duration(seconds: 30);
  bool get healthy =>
      lastPoll != null &&
      DateTime.now().difference(lastPoll!) < _healthyWithin;

  int lastAircraftCount = 0;
  int lastOwnshipAgeS = -1;
  String? lastError;
  /// Last poll that actually returned aircraft data. Health is measured from
  /// this, never from the last attempt.
  DateTime? lastPoll;
  /// How many attempts in a row have failed. Shown in diagnostics so an
  /// intermittent feed reads differently from a dead one.
  int consecutiveFailures = 0;

  void start() {
    if (_timer != null) {
      return;
    }
    AppLog.logMessage("Network traffic: starting");
    _timer = Timer.periodic(_interval, (_) => _poll());
    _poll();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    lastAircraftCount = 0;
    lastOwnshipAgeS = -1;
    // A stopped feed is not a stale feed; drop the history so a later restart
    // is not reported as healthy on the strength of the previous session.
    lastPoll = null;
    lastError = null;
    consecutiveFailures = 0;
    AppLog.logMessage("Network traffic: stopped");
  }

  /// Centre of the query: our own position when we have one, otherwise the last
  /// map centre, so the very first poll has somewhere to look.
  LatLng _queryCentre() {
    final pos = Storage().position;
    if (pos.latitude != 0 || pos.longitude != 0) {
      return LatLng(pos.latitude, pos.longitude);
    }
    return LatLng(Storage().settings.getCenterLatitude(),
        Storage().settings.getCenterLongitude());
  }

  Future<void> _poll() async {
    if (_polling) {
      return; // never stack requests if one is slow
    }
    _polling = true;
    try {
      final LatLng c = _queryCentre();
      final Uri url = Uri.parse(
          "$_base/lat/${c.latitude.toStringAsFixed(4)}"
          "/lon/${c.longitude.toStringAsFixed(4)}/dist/$_radiusNm");
      final http.Response r = await http
          .get(url, headers: {"User-Agent": "AvareX"})
          .timeout(_requestTimeout);
      if (r.statusCode != 200) {
        lastError = "HTTP ${r.statusCode}";
        consecutiveFailures++;
        return;
      }
      final Map<String, dynamic> body = jsonDecode(r.body) as Map<String, dynamic>;
      final List<dynamic> list = (body["aircraft"] ?? body["ac"] ?? []) as List<dynamic>;
      // The fetch succeeded, so the poll succeeded. Mark it before ingesting:
      // one aircraft with an unexpected field used to throw out of here and
      // leave the whole poll recorded as a failure.
      lastError = null;
      lastPoll = DateTime.now();
      consecutiveFailures = 0;
      _ingest(list);
    }
    catch (e) {
      lastError = e.toString();
      consecutiveFailures++;
      AppLog.logMessage("Network traffic poll failed: $e");
    }
    finally {
      _polling = false;
    }
  }

  /// Aggregator feeds are loosely typed and vary between sources: a field that
  /// is a number for one aircraft can be absent or a string for the next.
  static double? _num(Map<String, dynamic> a, String key) {
    final dynamic v = a[key];
    return v is num ? v.toDouble() : null;
  }

  void _ingest(List<dynamic> list) {
    final String wantTail =
        Storage().settings.getNetworkOwnshipTail().trim().toUpperCase();
    int count = 0;
    for (final dynamic raw in list) {
      if (raw is! Map<String, dynamic>) {
        continue;
      }
      final Map<String, dynamic> a = raw;
      final double? lat = _num(a, "lat");
      final double? lon = _num(a, "lon");
      final double? track = _num(a, "track");
      if (lat == null || lon == null || track == null) {
        continue; // nothing to place or project
      }
      final dynamic altRaw = a["alt_baro"];
      final bool onGround = altRaw is String && altRaw == "ground";
      final double altFt = altRaw is num ? altRaw.toDouble() : 0;
      final double gs = _num(a, "gs") ?? 0;
      final double vs = _num(a, "baro_rate") ?? _num(a, "geom_rate") ?? 0;
      final double seen = _num(a, "seen_pos") ?? 0;
      final String hex = (a["hex"] is String ? a["hex"] as String : "").trim();
      final String flight =
          (a["flight"] is String ? a["flight"] as String : "").trim();
      final int icao = int.tryParse(hex.replaceAll("~", ""), radix: 16) ?? 0;

      // Be that aircraft, if a tail number was given.
      if (wantTail.isNotEmpty && flight.toUpperCase() == wantTail) {
        lastOwnshipAgeS = seen.round();
        // We are this aircraft now, so clear whatever position it was last
        // shown at as traffic -- otherwise a ghost of it stays where it was
        // standing when the tail number was entered.
        Storage().trafficCache.removeTraffic(icao);
        Storage().setNetworkOwnship(
            Position(
              latitude: lat, longitude: lon,
              altitude: altFt / Storage().units.mToF,
              speed: gs / Storage().units.mpsTo,
              heading: track,
              timestamp: DateTime.now(),
              accuracy: 0, altitudeAccuracy: 0, headingAccuracy: 0, speedAccuracy: 0),
            vs, !onGround, icao, flight);
        continue; // never show ourselves as traffic
      }

      final TrafficReportMessage m = TrafficReportMessage(MessageType.trafficReport);
      m.icao = icao;
      m.coordinates = LatLng(lat, lon);
      m.altitude = altFt;
      m.velocity = gs;
      m.heading = track;
      m.trackType = TrackType.trueTrack; // the feed reports ground track
      m.verticalSpeed = vs;
      m.callSign = flight;
      m.airborne = !onGround;
      // Timestamp with the feed's own age so the existing staleness rules grey
      // these out exactly as they would a weak receiver.
      m.time = DateTime.now().toUtc().subtract(Duration(milliseconds: (seen * 1000).round()));
      Storage().trafficCache.putTraffic(m, fromNetwork: true);
      count++;
    }
    lastAircraftCount = count;
  }
}
