import 'dart:async';
import 'package:avaremp/avidyne/avidyne_ifd.dart';
import 'package:avaremp/instruments/autopilot.dart';
import 'package:avaremp/io/io_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:universal_io/io.dart';
import 'dart:ui' as ui;

// put all singletons here.

import 'package:avaremp/aircraft/aircraft.dart';
import 'package:avaremp/business/models/airport_business.dart';
import 'package:avaremp/utils/app_log.dart';
import 'package:avaremp/place/area.dart';
import 'package:avaremp/data/main_database_helper.dart';
import 'package:avaremp/data/user_database_helper.dart';
import 'package:avaremp/chart/download_screen.dart';
import 'package:avaremp/instruments/flight_status.dart';
import 'package:avaremp/gdl90/adsb_status.dart';
import 'package:avaremp/gdl90/gdl90_buffer.dart';
import 'package:avaremp/io/gps_recorder.dart';
import 'package:avaremp/gdl90/message_factory.dart';
import 'package:avaremp/gdl90/fis_block_cache.dart';
import 'package:avaremp/gdl90/nexrad_cache.dart';
import 'package:avaremp/gdl90/ownship_message.dart';
import 'package:avaremp/gdl90/traffic_cache.dart';
import 'package:avaremp/gdl90/traffic_report_message.dart';
import 'package:avaremp/nmea/nmea_ownship_message.dart';
import 'package:avaremp/utils/path_utils.dart';
import 'package:avaremp/instruments/pfd_painter.dart';
import 'package:avaremp/plan/plan_route.dart';
import 'package:avaremp/utils/stack_with_one.dart';
import 'package:avaremp/utils/unit_conversion.dart';
import 'package:avaremp/weather/airep_cache.dart';
import 'package:avaremp/weather/airsigmet_cache.dart';
import 'package:avaremp/weather/notam_cache.dart';
import 'package:avaremp/weather/taf_cache.dart';
import 'package:avaremp/weather/tfr_cache.dart';
import 'package:avaremp/io/udp_receiver.dart';
import 'package:avaremp/plan/waypoint.dart';
import 'package:avaremp/weather/weather_cache.dart';
import 'package:avaremp/weather/winds_cache.dart';
import 'package:exif/exif.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'data/app_settings.dart';
import 'data/db_general.dart';
import 'package:avaremp/destination/destination.dart';
import 'chart/download_manager.dart';
import 'instruments/flight_timer.dart';
import 'gdl90/message.dart';
import 'utils/geojson_parser.dart';
import 'io/gps.dart';
import 'io/network_traffic.dart';
import 'nmea/nmea_buffer.dart';
import 'nmea/nmea_message.dart';
import 'nmea/nmea_message_factory.dart';
import 'weather/metar_cache.dart';

class Storage {
  static final Storage _instance = Storage._internal();

  factory Storage() {
    return _instance;
  }

  Storage._internal();

  final pfdChange = ValueNotifier<int>(0);
  // on gps update
  final gpsChange = ValueNotifier<Position>(Gps.fromLatLng(LatLng(0, 0)));
  // when plate changes
  final plateChange = ValueNotifier<int>(0);
  /// Ownship map/plate icon image changed ([imagePlane] replaced).
  final planeIconChange = ValueNotifier<int>(0);
  // when destination changes
  final timeChange = ValueNotifier<int>(0);
  final timeRadarChange = ValueNotifier<int>(0);
  // bumped only when the traffic set actually changes (new/updated/removed),
  // so traffic map layers rebuild on real changes instead of every second
  final trafficChange = ValueNotifier<int>(0);
  final rubberBandChange = ValueNotifier<int>(0); // when route is changed via rubber band, for testing with GPS
  final warningChange = ValueNotifier<bool>(false);
  final flightStatus = FlightStatus();
  AirportBusiness? business; // currently selected business on the plate diagram
  late WindsCache winds;
  late MetarCache metar;
  late TafCache taf;
  late TfrCache tfr;
  late AirepCache airep;
  late ValueNotifier<ThemeData> themeNotifier;
  late AirSigmetCache airSigmet;
  late NotamCache notam;
  final NexradCache nexradCache = NexradCache();
  final FisBlockCache fisBlockCache = FisBlockCache();
  final Area area = Area();
  late TrafficCache trafficCache;
  final StackWithOne<Position> _gpsStack = StackWithOne(Gps.fromLatLng(LatLng(0, 0)));
  ImageCache imageCache = ImageCache();
  int myAircraftIcao = 0;
  /// True when the Traffic map layer is enabled. Read from settings rather than
  /// cached out of map_screen.build(), so audible traffic alerting does not
  /// depend on a widget rebuild having happened first.
  bool get trafficLayerOn {
    final List<String> layers = settings.getLayers();
    final List<double> opacity = settings.getLayersOpacity();
    final int index = layers.indexOf("Traffic");
    return index >= 0 && index < opacity.length && opacity[index] > 0;
  }
  String myAircraftCallsign = "";
  int ownshipMessageIcao = 0;
  String ownshipMessageCallsign = ""; // tail number reported by the ADS-B receiver, if any
  final PfdData pfdData = PfdData(); // a place to drive PFD
  GpsRecorder tracks = GpsRecorder();
  late final FlightTimer flightTimer;
  late final FlightTimer flightDownTimer;
  Destination? plateAirportDestination;
  Matrix4 plateTransform = Matrix4.identity();
  late UnitConversion units;
  final DownloadManager downloadManager = DownloadManager();
  final GeoJsonParser geoParser = GeoJsonParser();
  List<bool> activeChecklistSteps = [];
  String activeChecklistName = "";
  static const gpsSwitchoverTimeMs = 30000; // switch GPS in 30 seconds

  final PlanRoute _route = PlanRoute("New Plan");
  PlanRoute get route => _route;
  // Signature of the last active plan persisted to settings. Used to only write
  // to user.db when the plan or its current index actually changes.
  String _lastSavedPlanSignature = "";

  // Build a cheap signature of the current plan state (waypoint ids + current
  // waypoint index + airway sub-index) so we can detect changes without
  // re-serializing the whole plan every second.
  String _planSignature() {
    return "${_route.toString()}|${_route.currentWaypointIndex}|${_route.getCurrentWaypoint()?.currentDestinationIndex ?? 0}";
  }

  // Save the active plan and the waypoint it is on so it can be reloaded after
  // an app shutdown or crash. Only writes when something changed.
  void _persistActivePlanIfChanged() {
    String signature = _planSignature();
    if(signature == _lastSavedPlanSignature) {
      return; // nothing changed, avoid a needless db write
    }
    _lastSavedPlanSignature = signature;
    settings.setActivePlanRoute(_route.toJson(_route.name));
    settings.setActivePlanName(_route.name);
    settings.setActivePlanIndex(_route.currentWaypointIndex);
    settings.setActivePlanDestinationIndex(_route.getCurrentWaypoint()?.currentDestinationIndex ?? 0);
  }

  // Reload the saved active plan into the live route and resume on the waypoint
  // (and airway sub-index) it was on when the app was last running.
  Future<void> _restoreActivePlan() async {
    String json = settings.getActivePlanRoute();
    if(json.isEmpty || json == "[]") {
      return; // no saved plan
    }
    try {
      PlanRoute restored = await PlanRoute.fromJson(json, settings.getActivePlanName(), false);
      _route.copyFrom(restored);
      int index = settings.getActivePlanIndex();
      if(index >= 0 && index < _route.length) {
        _route.setCurrentWaypoint(index);
        _route.setCurrentWaypointDestinationIndex(settings.getActivePlanDestinationIndex());
      }
    }
    catch(e) {
      // saved plan is unusable (e.g. corrupt/missing data), start with empty plan
      _lastSavedPlanSignature = "";
    }
  }
  bool gpsNoLock = false;
  int _lastMsGpsSignal = DateTime.now().millisecondsSinceEpoch;
  int _lastMsExternalSignal = DateTime.now().millisecondsSinceEpoch - gpsSwitchoverTimeMs;
  bool gpsInternal = true;

  // ---------------------------------------------------------------------------
  // Source selection.
  //
  // Position and traffic are chosen independently. They used to share one mode
  // string, which meant you could not run the receiver's traffic while flying a
  // synthesised position, or watch internet traffic while navigating on a real
  // fix. The stored values are unchanged so existing settings still load.
  // ---------------------------------------------------------------------------

  /// Where ownship position comes from: "Auto", "Internal", "External", "Network".
  String gpsSourceMode = "Auto";
  static const List<String> _gpsSourceModes = ["Auto", "Internal", "External", "Network"];

  /// Where map traffic comes from: "Receiver", "Internet", "Both".
  String trafficSourceMode = "Receiver";
  static const List<String> _trafficSourceModes = ["Receiver", "Internet", "Both"];

  void initSourceModes() {
    gpsSourceMode = settings.getGpsSourceMode();
    trafficSourceMode = settings.getTrafficSourceMode(gpsSourceMode);
    applySourceModes();
  }

  /// True while ownship position is synthesised from an internet feed. This is
  /// test data: it carries seconds of latency and coverage gaps, and must be
  /// obvious on screen.
  bool get isNetworkSource => gpsSourceMode == "Network";

  bool get usesReceiverTraffic => trafficSourceMode != "Internet";
  bool get usesNetworkTraffic => trafficSourceMode != "Receiver";

  /// The feed runs if either position or traffic wants it.
  bool get needsNetworkFeed => isNetworkSource || usesNetworkTraffic;

  PositionOrigin _positionOrigin = PositionOrigin.none;
  int _positionOriginMs = 0;
  String _positionOriginDetail = ""; // tail number or callsign, where there is one

  /// Who last wrote [position]. Sticky on purpose: when the selected source
  /// stops supplying one, the position on screen still belongs to whoever put
  /// it there, and saying so is the only way to explain why the aircraft symbol
  /// has stopped moving.
  PositionOrigin get positionOrigin => _positionOrigin;

  /// When [position] was last written, by anyone. Exposed for the audible alert
  /// de-duplication, which needs a clock that actually advances with the fix.
  int get lastPositionUpdateMs => _positionOriginMs;

  /// A position is only worth acting on if it came from the source now selected
  /// and arrived recently enough to still be true.
  bool get positionIsLive =>
      _positionOrigin != PositionOrigin.none &&
      acceptsPositionFrom(_positionOrigin) &&
      (DateTime.now().millisecondsSinceEpoch - _positionOriginMs) <= 2 * gpsSwitchoverTimeMs;

  /// Record an accepted position write. One place, so provenance and its
  /// timestamp can never disagree.
  void _recordPosition(PositionOrigin origin, {String detail = ""}) {
    _positionOrigin = origin;
    _positionOriginMs = DateTime.now().millisecondsSinceEpoch;
    if (detail.isNotEmpty) {
      _positionOriginDetail = detail;
    }
  }

  /// The one place that decides whether a position from [origin] may be used.
  /// All three writers -- this device's GPS, the receiver's ownship reports and
  /// the internet feed -- ask here, so none of them can quietly take over a
  /// source the user did not select.
  bool acceptsPositionFrom(PositionOrigin origin) {
    switch (gpsSourceMode) {
      case "Internal":
        return origin == PositionOrigin.internal;
      case "External":
        return origin == PositionOrigin.external;
      case "Network":
        return origin == PositionOrigin.network;
      default: // Auto: the receiver wins whenever it is talking, this device fills in
        return origin == PositionOrigin.external ||
            (origin == PositionOrigin.internal && gpsInternal);
    }
  }

  /// Whether a traffic report from this source may be shown.
  bool acceptsTrafficFrom(TrafficSource source) =>
      source == TrafficSource.receiver ? usesReceiverTraffic : usesNetworkTraffic;

  /// Start or stop the network feed to match the selection, and drop traffic the
  /// previous selection left behind -- those targets stop updating the moment
  /// the source changes, so they would otherwise sit on the map as ghosts until
  /// they aged out.
  ///
  /// [_positionOrigin] deliberately survives: the position on screen is still
  /// whoever's it was, and [positionIsLive] already reports it as no longer
  /// current because the new selection does not accept that origin.
  void applySourceModes() {
    trafficCache.clear();
    if (!isNetworkSource) {
      ownshipMessageIcao = 0;
      ownshipMessageCallsign = "";
    }
    // The signal clocks were last touched by the source we just left; leaving
    // them fresh made the new source look like it already had a lock.
    final int stale = DateTime.now().millisecondsSinceEpoch - 2 * gpsSwitchoverTimeMs - 1;
    _lastMsGpsSignal = stale;
    _lastMsExternalSignal = stale;
    if (needsNetworkFeed) {
      NetworkTraffic().start();
    }
    else {
      NetworkTraffic().stop();
    }
  }

  /// Stop pretending to be whatever aircraft was adopted from the feed. The
  /// position on screen belongs to that aircraft, so it must not keep flying
  /// under a tail number the user has since changed. The origin stays, so the
  /// stale position can still be attributed to the aircraft it came from.
  void clearNetworkOwnship() {
    ownshipMessageIcao = 0;
    ownshipMessageCallsign = "";
    if (_positionOrigin == PositionOrigin.network) {
      _positionOriginMs = 0; // no longer current, whatever its age said
    }
    NetworkTraffic().lastOwnshipAgeS = -1;
  }

  static List<String> get gpsSourceModes => _gpsSourceModes;
  static List<String> get trafficSourceModes => _trafficSourceModes;

  void selectGpsSourceMode(String mode) {
    if (!_gpsSourceModes.contains(mode) || mode == gpsSourceMode) {
      return;
    }
    gpsSourceMode = mode;
    settings.setGpsSourceMode(mode);
    applySourceModes();
  }

  void selectTrafficSourceMode(String mode) {
    if (!_trafficSourceModes.contains(mode) || mode == trafficSourceMode) {
      return;
    }
    trafficSourceMode = mode;
    settings.setTrafficSourceMode(mode);
    applySourceModes();
  }

  /// One or two words naming a mode, for a selector where all the options are
  /// on screen together and the words have to line up in a row.
  static String gpsSourceModeName(String mode) {
    switch (mode) {
      case "Internal": return "Device";
      case "External": return "Receiver";
      case "Network":  return "Feed";
      default:         return "Auto";
    }
  }

  static String trafficSourceModeName(String mode) {
    switch (mode) {
      case "Internet": return "Web";
      case "Both":     return "Both";
      default:         return "Receiver";
    }
  }

  bool isRollReversed = false;

  // ADS-B receiver status (heartbeat + ground uplinks post to this directly)
  final AdsbStatus adsbStatus = AdsbStatus();

  // gps
  final _gps = Gps();
  final _udpReceiver = UdpReceiver();
  // where all data is place. This is set on init in main
  late String dataDir;
  late String cacheDir;
  late Position position;
  double vSpeed = 0;
  bool airborne = true;  
  final AppSettings settings = AppSettings();

  final Gdl90Buffer gdl90Buffer = Gdl90Buffer();
  final NmeaBuffer nmeaBuffer = NmeaBuffer();

  int _key = 1111;

  String getKey() {
    return (_key++).toString();
  }

  // make it double buffer to get rid of plate load flicker
  ui.Image? imagePlate;
  ui.Image? imagePlane;
  LatLng? topLeftPlate;
  LatLng? bottomRightPlate;


  // to move the plate
  String lastPlateAirport = "";
  String currentPlate = "";
  List<double>? matrixPlate;
  bool dataExpired = false;
  bool chartsMissing = false;
  bool gpsNotPermitted = false;
  bool gpsDisabled = false;
  /// No location provider exists on this system at all (typical on desktop).
  /// Distinct from permission denied or service disabled -- neither of which
  /// the user can act on when there is simply no provider.
  bool gpsNoProvider = false;

  /// The single source of truth for how position acquisition is doing, used by
  /// both the warnings drawer and the instrument tile so they cannot disagree.
  GpsState get gpsState {
    if (isNetworkSource) {
      if (!NetworkTraffic().healthy) {
        return GpsState.networkNoData;
      }
      return (_positionOrigin == PositionOrigin.network && positionIsLive)
          ? GpsState.networkFix
          : GpsState.networkNoOwnship;
    }
    if (gpsSourceMode == "External" || !gpsInternal) {
      if (!adsbStatus.connected) {
        return GpsState.externalNoData;
      }
      if (adsbStatus.typeCount(0x0A) == 0 || adsbStatus.secondsSinceOwnship > 30) {
        return GpsState.externalNoOwnship;
      }
      return GpsState.externalFix;
    }
    if (gpsNoProvider) {
      return GpsState.noProvider;
    }
    if (gpsNotPermitted) {
      return GpsState.internalPermissionDenied;
    }
    if (gpsDisabled) {
      return GpsState.internalServiceOff;
    }
    // Not just "no signal recently" -- a position left behind by a source the
    // user has switched away from is not a fix from this device.
    if (gpsNoLock || _positionOrigin != PositionOrigin.internal) {
      return GpsState.internalSearching;
    }
    return GpsState.internalFix;
  }

  /// There is a position on the map, but it is not current and nothing selected
  /// is refreshing it. This is the state that used to be invisible: the aircraft
  /// symbol sat at the last fix looking exactly like a live one.
  bool get positionIsFrozen =>
      _positionOrigin != PositionOrigin.none &&
      !positionIsLive &&
      !Gps.isPositionCloseToZero(position);

  /// Name of the source that put the current position on screen, in a form that
  /// reads inside a sentence.
  String get positionOriginLabel {
    switch (_positionOrigin) {
      case PositionOrigin.none:
        return "nothing yet";
      case PositionOrigin.internal:
        return "this device's GPS";
      case PositionOrigin.external:
        return _positionOriginDetail.isEmpty
            ? "the ADS-B receiver"
            : "the ADS-B receiver ($_positionOriginDetail)";
      case PositionOrigin.network:
        return _positionOriginDetail.isEmpty
            ? "the internet feed"
            : "the internet feed, as $_positionOriginDetail";
    }
  }

  /// What the user asked for, as opposed to what they are getting.
  String get positionSourceLabel {
    switch (gpsSourceMode) {
      case "Internal": return "This device's GPS";
      case "External": return "ADS-B receiver";
      case "Network":  return "Internet feed";
      default:         return "Automatic";
    }
  }

  String get trafficSourceLabel {
    switch (trafficSourceMode) {
      case "Internet": return "Internet feed";
      case "Both":     return "Receiver + internet";
      default:         return "ADS-B receiver";
    }
  }

  /// How long ago, in words. Used wherever an age is reported so they all read
  /// the same way.
  /// The same age with the trailing "ago" dropped, for a status column where
  /// the heading already supplies the context.
  static String describeAgeShort(int ms) {
    final int s = ms ~/ 1000;
    if (s < 2)    return "now";
    if (s < 90)   return "$s s";
    if (s < 5400) return "${(s / 60).round()} min";
    return "${(s / 3600).round()} h";
  }

  static String describeAge(int ms) {
    final int s = ms ~/ 1000;
    if (s < 2)    return "just now";
    if (s < 90)   return "$s s ago";
    if (s < 5400) return "${(s / 60).round()} min ago";
    return "${(s / 3600).round()} h ago";
  }

  /// The one line about position provenance, quoted everywhere rather than
  /// reworded, so no two surfaces can describe it differently. Kept to a single
  /// short clause: the aircraft symbol already shows staleness by going grey,
  /// so this only has to name the source and its age.
  String get positionProvenanceMessage {
    final String age =
        describeAge(DateTime.now().millisecondsSinceEpoch - _positionOriginMs);
    if (positionIsLive) {
      return "From $positionOriginLabel, $age.";
    }
    if (_positionOrigin == PositionOrigin.none ||
        Gps.isPositionCloseToZero(position)) {
      return "Nothing from $positionSourceLabel yet.";
    }
    return "Frozen -- last from $positionOriginLabel, $age.";
  }

  /// Short word for the instrument tile: what is driving the aircraft symbol.
  String get positionTileLabel {
    if (positionIsFrozen) {
      return "Frozen";
    }
    switch (gpsState) {
      case GpsState.internalFix:              return "Device";
      case GpsState.externalFix:              return "ADS-B";
      case GpsState.internalSearching:        return "Searching";
      case GpsState.externalNoOwnship:        return "No Fix";
      case GpsState.externalNoData:           return "No Link";
      case GpsState.noProvider:               return "No GPS";
      case GpsState.networkFix:
        // Name the aircraft we are pretending to be, so a spoofed position can
        // never be mistaken for our own.
        final String tail = settings.getNetworkOwnshipTail().trim();
        return tail.isEmpty ? "Feed" : tail.toUpperCase();
      case GpsState.networkNoOwnship:         return "No A/C";
      case GpsState.networkNoData:            return "No Feed";
      case GpsState.internalPermissionDenied:
      case GpsState.internalServiceOff:       return "Off";
    }
  }

  /// Short word for the ADS-B tile: where the targets on the map came from.
  String get trafficTileLabel {
    final bool receiver = usesReceiverTraffic && adsbStatus.trafficFresh;
    final bool feed = usesNetworkTraffic && NetworkTraffic().healthy;
    if (receiver && feed) return "Both";
    if (receiver)         return "ADS-B";
    if (feed)             return "Web";
    return usesReceiverTraffic && adsbStatus.connected ? "Quiet" : "None";
  }

  /// Which source put the current position on screen, in one word.
  String get positionOriginShort {
    switch (_positionOrigin) {
      case PositionOrigin.none:     return "none";
      case PositionOrigin.internal: return "device";
      case PositionOrigin.external: return "receiver";
      case PositionOrigin.network:
        return _positionOriginDetail.isEmpty ? "feed" : _positionOriginDetail;
    }
  }

  /// Provenance for a status column: which source, how old, and whether it has
  /// stopped. Three words at most -- the colour carries the severity.
  String get positionProvenanceShort {
    if (_positionOrigin == PositionOrigin.none ||
        Gps.isPositionCloseToZero(position)) {
      return "none";
    }
    final String age =
        describeAgeShort(DateTime.now().millisecondsSinceEpoch - _positionOriginMs);
    return positionIsLive
        ? "$positionOriginShort $age"
        : "frozen $positionOriginShort $age";
  }

  // ---------------------------------------------------------------------------
  // Per-candidate health. Each source describes itself once, in the fewest
  // words that are still unambiguous; the diagnostics screen lists them all and
  // marks the selected one, so no two rows can give conflicting accounts of the
  // same hardware. The colour says how bad it is, so the words never have to.
  // ---------------------------------------------------------------------------

  /// This device's own location provider, whether or not it is selected.
  (String, SourceHealth) get deviceGpsHealth {
    if (gpsNoProvider)   return ("none fitted", SourceHealth.absent);
    if (gpsNotPermitted) return ("denied", SourceHealth.failed);
    if (gpsDisabled)     return ("switched off", SourceHealth.failed);
    if (!acceptsPositionFrom(PositionOrigin.internal)) {
      return ("standby", SourceHealth.idle);
    }
    if (_positionOrigin == PositionOrigin.internal && positionIsLive) {
      return ("fix", SourceHealth.ok);
    }
    return ("no fix", SourceHealth.degraded);
  }

  /// The receiver's own GPS, as a position candidate. Its link health is a
  /// separate question, reported under the receiver section.
  (String, SourceHealth) get receiverPositionHealth {
    if (!adsbStatus.connected) return ("no link", SourceHealth.absent);
    if (adsbStatus.typeCount(0x0A) == 0) {
      return ("no ownship", SourceHealth.degraded);
    }
    if (!adsbStatus.ownshipFresh) {
      return ("stale ${describeAgeShort(adsbStatus.secondsSinceOwnship * 1000)}",
          SourceHealth.degraded);
    }
    final String tail = ownshipMessageCallsign.trim();
    return ("${tail.isEmpty ? "fix" : tail} ${adsbStatus.secondsSinceOwnship} s",
        SourceHealth.ok);
  }

  /// The internet feed, as a position candidate.
  (String, SourceHealth) get feedPositionHealth {
    if (!NetworkTraffic().running) return ("off", SourceHealth.idle);
    if (!NetworkTraffic().healthy) return ("unreachable", SourceHealth.failed);
    final String tail = settings.getNetworkOwnshipTail().trim().toUpperCase();
    if (tail.isEmpty) return ("no tail set", SourceHealth.degraded);
    if (_positionOrigin == PositionOrigin.network && positionIsLive) {
      return ("as $tail", SourceHealth.ok);
    }
    return ("$tail not seen", SourceHealth.degraded);
  }

  /// The receiver, as a traffic candidate.
  (String, SourceHealth) get receiverTrafficHealth {
    if (!usesReceiverTraffic)  return ("standby", SourceHealth.idle);
    if (!adsbStatus.connected) return ("no link", SourceHealth.absent);
    if (adsbStatus.trafficMessageCount == 0) {
      return ("no targets", SourceHealth.degraded);
    }
    return ("${adsbStatus.trafficMessageCount} msgs ${adsbStatus.secondsSinceTraffic} s",
        adsbStatus.trafficFresh ? SourceHealth.ok : SourceHealth.degraded);
  }

  /// The internet feed, as a traffic candidate.
  (String, SourceHealth) get feedTrafficHealth {
    if (!usesNetworkTraffic)       return ("standby", SourceHealth.idle);
    if (!NetworkTraffic().running) return ("off", SourceHealth.idle);
    if (!NetworkTraffic().healthy) return ("unreachable", SourceHealth.failed);
    return ("${NetworkTraffic().lastAircraftCount} aircraft", SourceHealth.ok);
  }

  /// True when position acquisition is in a state the pilot should know about.
  bool get gpsNeedsAttention => !positionIsLive;
  final List<String> _exceptions = [];

  // for navigation on tabs
  final GlobalKey globalKeyBottomNavigationBar = GlobalKey();

  void setDestination(Destination? destination) {
    if(destination != null) {
      route.addDirectTo(Waypoint(destination));
    }
  }

  /*
   * Ability to show warning messages to user when exceptions occur
   */
  List<String> getExceptions() {
    return _exceptions;
  }



  void setException(String value) {
    if(_exceptions.contains(value)) {
      return;
    }
    _exceptions.add(value.split('\n').first); // only first line
  }

  StreamSubscription<Position>? _gpsStream;

  // for transition from plan to find for waypoint insert at a specific index
  bool planSearch = false;

  void _processData() {
    // gdl90
    while(true) {
      Uint8List? message;
      try {
        message = gdl90Buffer.get();
      } catch (e, st) {
        setException("ADS-B data error");
        AppLog.logMessage("GDL90 data error: $e\n$st");
        break;
      }
      if (null != message) {
        try {
          Message? m = MessageFactory.buildMessage(message);
          if(m != null && m is OwnShipMessage) {
            if (!acceptsPositionFrom(PositionOrigin.external)) {
              continue; // the user is navigating on some other source
            }
            Position p = Position(longitude: m.coordinates.longitude, latitude: m.coordinates.latitude, timestamp: DateTime.timestamp(), accuracy: 0, altitude: m.altitude, altitudeAccuracy: 0, heading: m.heading, headingAccuracy: 0, speed: m.velocity, speedAccuracy: 0);
            if(Gps.isPositionCloseToZero(p)) {
              continue; // skip 0, 0 when GPS is not locked
            }
            ownshipMessageIcao = m.icao;
            // keep the last reported tail number (some frames omit it)
            if (m.callSign.isNotEmpty) {
              ownshipMessageCallsign = m.callSign;
            }
            _lastMsGpsSignal = DateTime.now().millisecondsSinceEpoch; // update time when GPS signal was last received
            _lastMsExternalSignal = _lastMsGpsSignal; // start ignoring internal GPS
            _recordPosition(PositionOrigin.external, detail: m.callSign);
            _gpsStack.push(p);
            // Record additional ownship settings for audible alerts (among other interested parties)--or perhaps these can just reside here in Storage?
            vSpeed = m.verticalSpeed;
            airborne = m.airborne;
            // record waypoints for tracks.
            tracks.add(p);
          }
        } catch (e, st) {
          setException("ADS-B parse error");
          adsbStatus.recordParseError();
          AppLog.logMessage("GDL90 parse error: $e\n$st");
        }
      }
      else {
        break;
      }
    }
    // nmea
    while(true) {
      Uint8List? message;
      try {
        message = nmeaBuffer.get();
      } catch (e, st) {
        setException("NMEA data error");
        AppLog.logMessage("NMEA data error: $e\n$st");
        break;
      }
      if (null != message) {
        try {
          NmeaMessage? m = NmeaMessageFactory.buildMessage(message);
          if(m != null && m is NmeaOwnShipMessage) {
            if (!acceptsPositionFrom(PositionOrigin.external)) {
              continue; // the user is navigating on some other source
            }
            NmeaOwnShipMessage m0 = m;
            Position p = Position(longitude: m0.coordinates.longitude, latitude: m0.coordinates.latitude, timestamp: DateTime.timestamp(), accuracy: 0, altitude: m0.altitude, altitudeAccuracy: 0, heading: m0.heading, headingAccuracy: 0, speed: m0.velocity, speedAccuracy: 0);
            if(Gps.isPositionCloseToZero(p)) {
              continue; // skip 0, 0 when GPS is not locked
            }
            ownshipMessageIcao = m0.icao;
            _lastMsGpsSignal = DateTime.now().millisecondsSinceEpoch; // update time when GPS signal was last received
            _lastMsExternalSignal = _lastMsGpsSignal; // start ignoring internal GPS
            vSpeed = m0.verticalSpeed;
            airborne = m0.altitude > 100;
            _recordPosition(PositionOrigin.external);
            _gpsStack.push(p);
            tracks.add(p);
          }
        } catch (e, st) {
          setException("NMEA parse error");
          AppLog.logMessage("NMEA parse error: $e\n$st");
        }
      }
      else {
        break;
      }
    }
  }

  /// Guards against stacking a second set of sockets/subscriptions on top of a
  /// live one. startIO() is called on every resume, so it must be a no-op when
  /// IO is already running.
  bool _ioStarted = false;

  /// Accept a position derived from the network feed. Routed through the same
  /// stack the GDL90 ownship path uses, so everything downstream treats it
  /// identically -- including the staleness and source reporting.
  void setNetworkOwnship(Position p, double vspeedFpm, bool isAirborne,
      int icao, String callSign) {
    if (!acceptsPositionFrom(PositionOrigin.network) ||
        Gps.isPositionCloseToZero(p)) {
      return;
    }
    // Adopting this aircraft's identity keeps the traffic cache from also
    // drawing it as a target, by the same rule that hides a receiver's ownship.
    ownshipMessageIcao = icao;
    if (callSign.isNotEmpty) {
      ownshipMessageCallsign = callSign;
    }
    _lastMsGpsSignal = DateTime.now().millisecondsSinceEpoch;
    _lastMsExternalSignal = _lastMsGpsSignal;
    _recordPosition(PositionOrigin.network, detail: callSign.isEmpty
        ? settings.getNetworkOwnshipTail().trim().toUpperCase() : callSign);
    _gpsStack.push(p);
    vSpeed = vspeedFpm;
    airborne = isAirborne;
    tracks.add(p);
  }

  /// Subscribes to the internal GPS. Separate from [startIO] so a GPS-only event
  /// (permission granted) can restart just this, without closing the ADS-B
  /// sockets -- doing that took traffic down for an unrelated reason.
  void _startGpsStream() {
    if(gpsDisabled) {
      return;
    }
    _gpsStream?.cancel(); // never overwrite a live subscription
    _gpsStream = _gps.getStream();
    _gpsStream?.onDone(() {});
    _gpsStream?.onError((obj) {});
    _gpsStream?.onData((data) {
      if (!acceptsPositionFrom(PositionOrigin.internal)) {
        return; // another source is selected, or is currently winning in Auto
      }
      if(Gps.isPositionCloseToZero(data)) {
        return; // skip 0, 0 when GPS is not locked
      }
      _lastMsGpsSignal = DateTime.now().millisecondsSinceEpoch; // update time when GPS signal was last received
      _recordPosition(PositionOrigin.internal);
      _gpsStack.push(data);
      tracks.add(data);
    });
  }

  void startIO() {
    if (_ioStarted) {
      return;
    }
    _ioStarted = true;
    // GPS data receive
    // start both external and internal
    _startGpsStream();

    // GPS data receive
    _udpReceiver.start([4000, 43211, 49002], [false, false, false]);

    // Broadcast the Avidyne "AVISDK" trigger so any Avidyne IFD on the network
    // starts streaming its Capstone (GDL90) ADS-B data. That data arrives on
    // UDP 4000 above and flows through the normal GDL90 decoder.
    AvidyneIfd().start();
  }

  void stopIO() {
    if (!_ioStarted) {
      return;
    }
    _ioStarted = false;
    try {
      _udpReceiver.finish();
    }
    catch(e) {
      AppLog.logMessage("Error stopping UDP: $e");
    }
    try {
      AvidyneIfd().stop();
    }
    catch(e) {
      AppLog.logMessage("Error stopping Avidyne discovery: $e");
    }
    try {
      _gpsStream?.cancel();
      _gpsStream = null;
    }
    catch(e) {
      AppLog.logMessage("Error stopping GPS: $e");
    }
  }

  // Cap the global image cache so that map chart tiles, plate/NEXRAD overlays,
  // and network (Topo/USGS) tiles cannot balloon memory on older devices.
  // Flutter's default is 1000 images / 100 MB, which is far too generous for a
  // map-heavy app running on low-RAM hardware.
  void _configureImageCache() {
    if (kIsWeb || Platform.isAndroid || Platform.isIOS) {
      // Mobile / web: assume limited RAM (older phones and tablets).
      imageCache.maximumSize = 100;
      imageCache.maximumSizeBytes = 32 << 20; // 32 MB
    } else {
      // Desktop: more headroom available.
      imageCache.maximumSize = 200;
      imageCache.maximumSizeBytes = 64 << 20; // 64 MB
    }
  }

  Future<void> init() async {
    WidgetsFlutterBinding.ensureInitialized();
    _configureImageCache();
    if (kIsWeb) {
      // No filesystem on web; use inert paths
      dataDir = "/";
      cacheDir = "/";
    } else {
      Directory dir = await getApplicationDocumentsDirectory();
      dataDir =
          PathUtils.getFilePath(dir.path, "avarex"); // put files in a folder
      dir = await getApplicationSupportDirectory();
      cacheDir = dir.path; // for tiles cache
      dir = Directory(dataDir);
      if (!dir.existsSync()) {
        dir.createSync();
      }
    }
    DbGeneral.set(); // set database platform

    await settings.initSettings();
    // trafficCache must exist first: initSourceModes() applies the selection,
    // source, which clears traffic, and this is a late field.
    trafficCache = TrafficCache(settings.getTrafficAltitudeFilter());
    initSourceModes();
    themeNotifier = ValueNotifier<ThemeData>(Storage().settings.isLightMode() ? ThemeData.light() : ThemeData.dark());
    units = UnitConversion(settings.getUnits());
    flightTimer = FlightTimer(true, 0, timeChange);
    flightDownTimer = FlightTimer(false, 30 * 60, timeChange); // 30 minute down timer
    WakelockPlus.enable().onError(
      (error, stackTrace) => {
        // wakelock is optional
      }
    ); // keep screen on
    // ask for GPS permission

    gpsNoProvider = await Gps().isProviderUnavailable().onError((error, stackTrace) => true);
    gpsNotPermitted = !gpsNoProvider && await Gps().isPermissionDenied().onError((error, stackTrace) => false);
    if(gpsNotPermitted) {
      Gps().requestPermissions().onError((error, stackTrace) => {});
    }
    gpsDisabled = !gpsNoProvider && await Gps().isDisabled().onError((error, stackTrace) => false);

    LatLng last = LatLng(settings.getCenterLatitude(), settings.getCenterLongitude());
    position = Gps.fromLatLng(last);
    _gpsStack.push(position);

    // don't await on this, but set when available, as DB access could take a few ms
    loadAircraftIds();
    Aircraft.reloadAircraftIcon();

    // this is a long login process, do not await here

    await checkChartsExist();
    await checkDataExpiry();

    winds = WeatherCache.make(WindsCache) as WindsCache;
    metar = WeatherCache.make(MetarCache) as MetarCache;
    taf = WeatherCache.make(TafCache) as TafCache;
    tfr = WeatherCache.make(TfrCache) as TfrCache;
    airep = WeatherCache.make(AirepCache) as AirepCache;
    airSigmet = WeatherCache.make(AirSigmetCache) as AirSigmetCache;
    notam = WeatherCache.make(NotamCache) as NotamCache;

    // set area
    await area.update(position);

    // reload the active plan (and the waypoint it was on) if the app was
    // previously closed or crashed while a plan was active
    await _restoreActivePlan();

    Timer.periodic(const Duration(seconds: 1), (tim) async {
      // send AP data
      String data = AutoPilot.apCreateSentences();
      IoScreenState.sendData(data);
    });

    Timer.periodic(const Duration(milliseconds: 100), (tim) async {
      _processData();
    });


    Timer.periodic(const Duration(milliseconds: 250), (tim) async {
      // this provides time to apps
      timeRadarChange.value++;
    });

    Timer.periodic(const Duration(seconds: 1), (tim) async {
      // this provides time to apps
      timeChange.value++;

      // clear the ADS-B-derived ownship identity when the receiver disconnects
      // A receiver whose own GPS has no fix keeps sending heartbeats while
      // sending no ownship reports, so the connected->disconnected edge never
      // fires and the tail number used to sit on screen indefinitely. Key the
      // identity off the ownship stream's own freshness instead.
      // In Network mode the identity is the tail number we adopted, which the
      // feed maintains; the receiver has no say in it.
      final bool adsbConnected = adsbStatus.connected;
      if (!isNetworkSource && (!adsbConnected || !adsbStatus.ownshipFresh)) {
        ownshipMessageIcao = 0;
        ownshipMessageCallsign = "";
      }

      Position positionIn = _gpsStack.pop(); // used for testing and injecting GPS location
      position = Gps.clone(positionIn, area.geoAltitude);
      gpsChange.value = position; // tell everyone

      // Refresh traffic on the clock, not on GPS movement. gpsChange holds a
      // Position, which has value equality including its timestamp, and
      // Gps.clone copies that timestamp -- so with no GPS fix the same position
      // is assigned every second, compares equal, and the notifier never fires.
      // Traffic then reached the cache but the map layer was never told to
      // repaint, so ADS-B targets never appeared without a fix.
      trafficCache.updateTrafficDistancesAndAlerts();

      // update flight status
      flightStatus.update(position.speed);

      route.update(); // change to route
      _persistActivePlanIfChanged(); // keep plan + current index saved for crash/restart recovery
      int now = DateTime.now().millisecondsSinceEpoch;

      // Handle GPS source based on mode
      if (gpsSourceMode == "Auto") {
        gpsInternal = ((_lastMsExternalSignal + gpsSwitchoverTimeMs) < now);
      } else {
        gpsInternal = (gpsSourceMode == "Internal");
      }

      int diff = now - _lastMsGpsSignal;
      if (diff > 2 * gpsSwitchoverTimeMs) { // no GPS signal from both sources, send warning
        gpsNoLock = true;
      }
      else {
        gpsNoLock = false;
      }

      // runway crossings are too brief for the 10 second area cadence
      area.updateRunwayAwareness();

      if((timeChange.value % 10) == 0) {
        // update area every 10 seconds
        area.update(position);
      }

      if((timeChange.value % 5) == 0) {
        // Poll this device's location health in every mode. The diagnostics
        // screen reports it on its own line, and it used to freeze at whatever
        // it happened to be when the user selected another source.
        gpsNoProvider = await Gps().isProviderUnavailable().onError((error, stackTrace) => true);
        bool permissionDenied = !gpsNoProvider &&
            await Gps().isPermissionDenied().onError((error, stackTrace) => false);
        if(permissionDenied == false && gpsNotPermitted == true) {
          // restart GPS since permission was denied, and now its allowed.
          // Only the GPS subscription -- the ADS-B sockets stay up.
          _startGpsStream();
        }
        gpsNotPermitted = permissionDenied;
        gpsDisabled = !gpsNoProvider && await Gps().isDisabled().onError((error, stackTrace) => false);
        warningChange.value =
            gpsNeedsAttention || dataExpired || chartsMissing || _exceptions.isNotEmpty;
      }

      if((timeChange.value % (10 * 60)) == 0) {
        // clear system image cache
        imageCache.clear();
        downloadWeather();
      }

    });

    downloadWeather();

  }

  Future<void> loadAircraftIds() async {
    final String acName = settings.getAircraft();
    if (acName.isEmpty) {
      // Reset, if there is no longer any aircraft selected (say all were deleted)
      myAircraftCallsign = "";
      myAircraftIcao = 0;
      return;
    }
    try {
      final Aircraft ac = await UserDatabaseHelper.db.getAircraft(acName);
      if (ac.icao.isNotEmpty) {
        try {
          myAircraftIcao = ac.icao.trim().length > 6 ? int.parse(ac.icao) : int.parse(ac.icao, radix: 16);
        } catch (e) {
          AppLog.logMessage("Invalid ICAO in database: ${ac.icao}");
          // ignore
        }
      }
      if (ac.tail.isNotEmpty) {
        myAircraftCallsign = ac.tail.trim().toUpperCase();
      }
    } catch (e) {
      myAircraftCallsign = "";
      myAircraftIcao = 0;
    }
  }

  Future<void> downloadWeather() async {
    winds.download();
    metar.download();
    taf.download();
    tfr.download();
    airep.download();
    airSigmet.download();
  }

  Future<void> checkDataExpiry() async {
    dataExpired = await DownloadScreenState.isAnyChartExpired();
  }

  Future<void> checkChartsExist() async {
    chartsMissing = !(await DownloadScreenState.doesAnyChartExists());
  }

  Future<void> loadPlate() async {
    String plateAirport = settings.getCurrentPlateAirport();
    plateAirportDestination = await MainDatabaseHelper.db.findAirport(plateAirport);
    String path = await PathUtils.getPlatePath(dataDir, plateAirport, currentPlate);
    File file = File(path);
    Completer<ui.Image> completerPlate = Completer();
    Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    }
    catch(e) {
      ByteData bd = await rootBundle.load('assets/images/black.png');
      // file bad or not found
      bytes = bd.buffer.asUint8List();
    }
    topLeftPlate = null;
    bottomRightPlate = null;

    ui.decodeImageFromList(bytes, (ui.Image img) {
      return completerPlate.complete(img);
    });
    ui.Image? image = await completerPlate.future; // double buffering
    if(imagePlate != null) {
      imagePlate!.dispose();
      imagePlate = null;
    }
    imagePlate = image;

    Map<String, IfdTag> exif = await readExifFromBytes(bytes);
    matrixPlate = null;
    IfdTag? tag = exif["EXIF UserComment"];
    if(null != tag) {
      List<String> tokens = tag.toString().split("|");
      if(tokens.length == 4) {
        matrixPlate = [];
        matrixPlate!.add(double.parse(tokens[0]));
        matrixPlate!.add(double.parse(tokens[1]));
        matrixPlate!.add(double.parse(tokens[2]));
        matrixPlate!.add(double.parse(tokens[3]));

        double dx = matrixPlate![0];
        double dy = matrixPlate![1];
        double lonTopLeft = matrixPlate![2];
        double latTopLeft = matrixPlate![3];
        double latBottomRight = latTopLeft + image.height / dy;
        double lonBottomRight = lonTopLeft + image.width / dx;
        topLeftPlate = LatLng(latTopLeft, lonTopLeft);
        bottomRightPlate = LatLng(latBottomRight, lonBottomRight);
      }
      else if(tokens.length == 6) { //could be made same as for other plates
        matrixPlate = [];
        matrixPlate!.add(double.parse(tokens[0]));
        matrixPlate!.add(double.parse(tokens[1]));
        matrixPlate!.add(double.parse(tokens[2]));
        matrixPlate!.add(double.parse(tokens[3]));
        matrixPlate!.add(double.parse(tokens[4]));
        matrixPlate!.add(double.parse(tokens[5]));
      }
    }

    plateChange.value++; // change in storage
  }
}


class FileCacheManager {

  static final FileCacheManager _instance = FileCacheManager._internal();

  factory FileCacheManager() {
    return _instance;
  }

  FileCacheManager._internal();

  // this must be in a singleton class.
  final CacheManager documentsCacheManager = CacheManager(Config("customDocumentsCache", stalePeriod: const Duration(minutes: 1)));
  final CacheManager mapCacheManager = CacheManager(Config("customMapCache", stalePeriod: const Duration(days: 60)));
}
