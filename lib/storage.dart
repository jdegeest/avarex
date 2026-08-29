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
  bool cachedTrafficLayerOn = false;
  String myAircraftCallsign = "";
  int ownshipMessageIcao = 0;
  String ownshipMessageCallsign = ""; // tail number reported by the ADS-B receiver, if any
  bool _adsbWasConnected = false; // tracks ADS-B connection edge to reset ownship on disconnect
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
  int get lastMsGpsSignal { return _lastMsExternalSignal; } // read-only timestamp exposed for audible alerts, among any other interested parties
  int _lastMsExternalSignal = DateTime.now().millisecondsSinceEpoch - gpsSwitchoverTimeMs;
  bool gpsInternal = true;
  // GPS source mode: "Auto", "Internal", "External"
  String gpsSourceMode = "Auto";
  static const List<String> _gpsSourceModes = ["Auto", "Internal", "External"];

  void initGpsSourceMode() {
    gpsSourceMode = settings.getGpsSourceMode();
  }

  void cycleGpsSourceMode() {
    int index = (_gpsSourceModes.indexOf(gpsSourceMode) + 1) % _gpsSourceModes.length;
    gpsSourceMode = _gpsSourceModes[index];
    settings.setGpsSourceMode(gpsSourceMode);
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
    if (gpsNoLock) {
      return GpsState.internalSearching;
    }
    return GpsState.internalFix;
  }

  /// Short label for the SRC instrument tile.
  String get gpsStateLabel {
    switch (gpsState) {
      case GpsState.internalFix:        return "Internal";
      case GpsState.internalSearching:  return "No Fix";
      case GpsState.internalPermissionDenied: return "Blocked";
      case GpsState.internalServiceOff: return "Off";
      case GpsState.noProvider:         return "No GPS";
      case GpsState.externalFix:        return "ADS-B";
      case GpsState.externalNoOwnship:  return "No Own";
      case GpsState.externalNoData:     return "No Data";
    }
  }

  /// One-line explanation shared by the warnings drawer and diagnostics.
  String get gpsStateMessage {
    switch (gpsState) {
      case GpsState.internalFix:
        return "Position from this device's own GPS.";
      case GpsState.internalSearching:
        return "This device has a GPS but has not acquired a fix. Move to an open area with a clear view of the sky.";
      case GpsState.internalPermissionDenied:
        return "Location access is denied for AvareX. Grant it in device settings.";
      case GpsState.internalServiceOff:
        return "Location services are turned off on this device. Turn them on in device settings.";
      case GpsState.noProvider:
        return "This computer has no GPS or location provider. That cannot be changed here -- use an external GPS or ADS-B receiver. ADS-B traffic and weather still work without a position.";
      case GpsState.externalFix:
        return "Position from the external ADS-B/GPS receiver.";
      case GpsState.externalNoOwnship:
        return "The ADS-B receiver is connected but is not sending an ownship position, so it likely has no GPS fix of its own. Traffic and weather still work.";
      case GpsState.externalNoData:
        return "No data from an external receiver. Check that you are joined to its Wi-Fi network and that it is powered on.";
    }
  }

  /// True when position acquisition is in a state the pilot should know about.
  bool get gpsNeedsAttention =>
      gpsState != GpsState.internalFix && gpsState != GpsState.externalFix;
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
            // Skip external GPS data when Internal mode is selected
            if (gpsSourceMode == "Internal") {
              continue;
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
            // Skip external GPS data when Internal mode is selected
            if (gpsSourceMode == "Internal") {
              continue;
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
      // Skip internal GPS data when External mode is selected
      if (gpsSourceMode == "External") {
        return;
      }
      if (gpsInternal) {
        if(Gps.isPositionCloseToZero(data)) {
          return; // skip 0, 0 when GPS is not locked
        }
        _lastMsGpsSignal = DateTime.now().millisecondsSinceEpoch; // update time when GPS signal was last received
        _gpsStack.push(data);
        tracks.add(data);
      } // provide internal GPS when external is not available
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
    initGpsSourceMode();
    trafficCache = TrafficCache(settings.getTrafficAltitudeFilter());
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
      final bool adsbConnected = adsbStatus.connected;
      if (_adsbWasConnected && !adsbConnected) {
        ownshipMessageIcao = 0;
        ownshipMessageCallsign = "";
      }
      _adsbWasConnected = adsbConnected;

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
        if(gpsInternal) {
          // check system for any issues
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
        }
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
