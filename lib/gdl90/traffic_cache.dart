import 'dart:core';
import 'dart:ui' as ui;
import 'package:avaremp/gdl90/traffic_report_message.dart';
import 'package:avaremp/utils/geo_calculations.dart';
import 'package:avaremp/storage.dart';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:avaremp/gdl90/traffic_alerts.dart';
import 'package:avaremp/constants.dart';

import '../io/gps.dart';

const double _kMinutesPerMillisecond =  1.0 / 60000.0;

enum TrafficAlertLevel { none, advisory, resolution }

// Delay to allow audible alerts to not be constantly called with no updates, wasting CPU (uses async future to wait)
const int _kAudibleAlertCallMinDelayMs = 100;

class Traffic {

  final TrafficReportMessage message;
  double horizontalOwnshipDistanceNmi = 0;
  double verticalOwnshipDistanceFt = 0;
  double closingInSeconds = -1;
  double closestApproachDistanceNmi = 999999;
  TrafficAlertLevel alertLevel = TrafficAlertLevel.none;

  Traffic(this.message) {
    updateOwnshipDistancesAndAlertFields();
  }

  /// Update traffic distinces (horizontal and vertical) to ownship
  void updateOwnshipDistancesAndAlertFields() {
    // Use Haversine distance for speed/battery-efficiency instead of Vicenty, as the margin of error at these 
    // distances (for these purposes) is neglible (0.3% max, within 100 miles)
    // horizontalOwnshipDistance = GeoCalculations().calculateDistance(Gps.toLatLng(Storage().position), message.coordinates);
    horizontalOwnshipDistanceNmi = GeoCalculations().calculateDistance(Gps.toLatLng(Storage().position), message.coordinates);
    // final double vicentyDist = GeoCalculations().calculateDistance(Gps.toLatLng(Storage().position), message.coordinates);
    // if (vicentyDist < 100 || horizontalOwnshipDistanceNmi < 100) {
    //   print("Haversine is $horizontalOwnshipDistanceNmi and Vicenty is $vicentyDist, for a diff of ${horizontalOwnshipDistanceNmi-vicentyDist} or ${(horizontalOwnshipDistanceNmi-vicentyDist)/vicentyDist*100}%");
    // }    
    verticalOwnshipDistanceFt = Storage().units.mToF * Storage().position.altitude - message.altitude;
    TrafficAlerts.setTrafficAlertFields(this, Storage().position, Storage().airborne, Storage().vSpeed);
  }

  bool isOld() {
    return isOldAt(DateTime.now().millisecondsSinceEpoch);
  }

  /// A target we have not heard from recently. Its drawn position is the last
  /// one reported, so it is shown greyed rather than as live traffic.
  static const int staleMs = 5000;
  bool isStaleAt(int nowMs) => (nowMs - message.time.millisecondsSinceEpoch) > staleMs;
  bool get isStale => isStaleAt(DateTime.now().millisecondsSinceEpoch);

  /// [isOld] against a caller-supplied clock reading. The scans below run this
  /// per entry per message, so the DateTime allocation is hoisted to the caller.
  bool isOldAt(int nowMs) {
    // old if more than 1 min
    return (nowMs - message.time.millisecondsSinceEpoch) * _kMinutesPerMillisecond > 1;
  }

  /// Pixel size of the [Marker] used to render this traffic icon.
  /// The [TrafficPainter] circle is centered exactly at the marker's anchor
  /// point so that the on-map projection line appears to emerge from the
  /// center of the circle (and is masked by the circle until it exits the
  /// dot).
  static const double iconWidth = 200;
  static const double iconHeight = 64;
  static const double _kCircleHalf = TrafficPainter._kCanvasSize / 2;
  static const double _kLabelLeft = iconWidth / 2 + _kCircleHalf;
  static const double _kCircleTop = iconHeight / 2 - _kCircleHalf;

  Widget getIcon(double angle) {
    return SizedBox(
      width: iconWidth,
      height: iconHeight,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Vertical-status text label (flight-level diff + vertical-trend arrow)
          Positioned(
            left: _kLabelLeft,
            top: _kCircleTop,
            child: CustomPaint(
              painter: TrafficVerticalStatusPainter(this),
              size: const Size(96, 24),
            ),
          ),
          // Callsign / ID text label, sits below the vertical-status label
          Positioned(
            left: _kLabelLeft,
            top: _kCircleTop + 20,
            child: CustomPaint(
              painter: TrafficIdPainter(this),
              size: const Size(140, 24),
            ),
          ),
          // Centered Avare-style circle dot at the marker's anchor point
          Positioned(
            left: iconWidth / 2 - _kCircleHalf,
            top: iconHeight / 2 - _kCircleHalf,
            child: CustomPaint(
              painter: TrafficPainter(this),
              size: const Size(TrafficPainter._kCanvasSize, TrafficPainter._kCanvasSize),
            ),
          ),
        ],
      ),
    );
  }

  LatLng getCoordinates() {
    return message.coordinates;
  }

  /// Returns the projected position 1 minute in the future at current velocity/heading.
  /// Distance is in user units (nm or mi) per the active unit conversion.
  LatLng getOneMinuteProjection() {
    final double distanceInUserUnits = message.velocity * Storage().units.mpsTo / 60.0;
    return GeoCalculations().calculateOffset(message.coordinates, distanceInUserUnits, message.heading);
  }

  /// Whether this traffic should be highlighted as a threat (advisory or resolution alert).
  bool get isThreat => alertLevel != TrafficAlertLevel.none;

  @override
  String toString() {
    return "${message.callSign}\n${message.altitude.toInt()} ft\n"
    "${(message.velocity * Storage().units.mpsTo).toInt()} ${Storage().settings.getUnits() == "Imperial" ? "mph" : "knots" }\n"
    "${(message.verticalSpeed * Storage().units.mToF).toInt()} fpm";
  }
}


class TrafficCache {

  // Keyed by ICAO. Was a fixed List<Traffic?> scanned linearly on every
  // message, with a full sort on every new aircraft; both were O(n) or worse
  // per report and became a thrash cycle once the array saturated.
  final Map<int, Traffic> _traffic = {};
  /// Vertical separation in feet beyond which traffic is not retained.
  /// [Constants.kMaxIntValue] keeps everything.
  late int _kTrafficAltDiffThresholdFt;

  /// Selectable vertical filters, shown in the map's layer panel. A value of 0
  /// applies no filtering, which is the default.
  static const List<(String, int)> altitudeFilters = [
    ("All", 0),
    ("3,000 ft", 3000),
    ("6,000 ft", 6000),
    ("10,000 ft", 10000),
  ];

  /// Repaint throttle for traffic arrival. Reports can arrive hundreds of times
  /// a second; the map does not need to repaint that often.
  int _lastNotifyMs = 0;
  static const int _notifyIntervalMs = 250;

  /// Tell the map that traffic changed. Driven by traffic *arriving*, not by
  /// the position clock -- ADS-B display must not depend on having a GPS fix.
  void _notifyTrafficChanged() {
    final int nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs - _lastNotifyMs < _notifyIntervalMs) {
      return;
    }
    _lastNotifyMs = nowMs;
    Storage().trafficChange.value++;
  }

  /// Keep traffic within [feet] of ownship altitude; 0 keeps everything.
  void setAltitudeFilter(int feet) {
    _kTrafficAltDiffThresholdFt = feet <= 0 ? Constants.kMaxIntValue : feet;
  }

  /// True when ownship position can serve as a filter reference. With no GPS
  /// fix Storage().position is (0, 0) at zero altitude, which would place every
  /// aircraft thousands of nm away and filter all of it out -- so the range and
  /// altitude gates are skipped entirely and received traffic is shown as-is.
  /// Audible alerting is unaffected: it already returns early without a valid
  /// ownship position, ground speed, or airborne state.
  static bool get _hasOwnshipReference =>
      !Gps.isPositionCloseToZero(Storage().position);

  /// Rank used both for eviction and for ordering audible alerts: 3d distance,
  /// treating 1 nm of horizontal separation as 500 ft of vertical (C182 at
  /// 120 kts, 1000 fpm). Higher is further away.
  static double _score(Traffic t) =>
      t.horizontalOwnshipDistanceNmi * 500 + t.verticalOwnshipDistanceFt.abs();

  TrafficCache(int altitudeFilterFt) {
    setAltitudeFilter(altitudeFilterFt);
  }

  static final bool ac20_172Mode = true;
  bool _audibleAlertsRequested = false;
  bool _audibleAlertsHandling = false;

  void putTraffic(TrafficReportMessage message) {

    // filter own report. Guard against unset defaults (ICAO 0 / empty callsign)
    // so anonymous TIS-B targets (track-file targets often report ICAO 0 and no
    // callsign) are not mistaken for ownship and discarded.
    final int icao = message.icao;
    final int ownshipIcao = Storage().ownshipMessageIcao;
    final int myAircraftIcao = Storage().myAircraftIcao;
    final String myAircraftCallsign = Storage().myAircraftCallsign;
    if((icao != 0 && (icao == ownshipIcao || icao == myAircraftIcao))
      || (myAircraftCallsign.isNotEmpty && message.callSign.isNotEmpty && myAircraftCallsign == message.callSign))
    {
      // do not add ourselves
      message.filter = TrafficFilter.ownship;
      return;
    }

    // Call sign is not always present; keep the last one we saw for this ICAO.
    if(message.callSign.isEmpty) {
      message.callSign = _traffic[icao]?.message.callSign ?? "";
    }

    final Traffic trafficNew = Traffic(message);
    // only display/alert traffic that isn't too far from ownship -- but only
    // when we actually have an ownship position to measure against
    if (_hasOwnshipReference &&
        trafficNew.verticalOwnshipDistanceFt.abs() > _kTrafficAltDiffThresholdFt) {
      _traffic.remove(icao); // drop any report previously held for this aircraft
      message.filter = TrafficFilter.range;
      return;
    }

    _traffic[icao] = trafficNew;

    // No entry cap: stale reports are retired by age in getTraffic() and in the
    // 1 Hz sweep, which bounds the map to aircraft heard in the last minute.

    // Repaint because traffic arrived. Previously the only repaint signal came
    // from the position timer, so with no GPS fix nothing appeared until an
    // unrelated rebuild (a tap) happened to redraw the layer.
    _notifyTrafficChanged();

    // process any audible alerts from traffic (if enabled)
    handleAudibleAlerts();
  }

  /// Traffic ordered nearest-first. [processTrafficForAudibleAlerts] builds the
  /// alert queue in iteration order, so this is what makes simultaneous callouts
  /// speak nearest-first -- previously a side effect of keeping the array sorted.
  List<Traffic?> _trafficByDistance() {
    final List<Traffic> list = _traffic.values.toList();
    list.sort((a, b) => _score(a).compareTo(_score(b)));
    return list;
  }

  void handleAudibleAlerts() {
    // If alerts are running or in the required delay, don't kick off processing again--just note that we want another run later
    if (_audibleAlertsHandling) {
      _audibleAlertsRequested = true;
      return;
    }
    // process when traffic layer is on
    if (Storage().settings.isAudibleAlertsEnabled() && Storage().trafficLayerOn) {
      _audibleAlertsHandling = true;   
      TrafficAlerts.getAndStartTrafficAlerts().then((alerts) {
        // TODO: Set all of the "pref" settings from new Storage params (which in turn have a config UI?)
        alerts?.processTrafficForAudibleAlerts(_trafficByDistance(), Storage().position, Storage().lastMsGpsSignal, Storage().vSpeed,
          Storage().airborne);
        _audibleAlertsRequested = false;
        Future.delayed(const Duration(milliseconds: _kAudibleAlertCallMinDelayMs), () {
          _audibleAlertsHandling = false;
          if (_audibleAlertsRequested) {
            Future(handleAudibleAlerts);
          }
        });
      });
    } else {
      TrafficAlerts.stopAudibleTrafficAlerts();
    }
  }

  /// Recalcs all traffic cache distances (e.g., from an ownship position update), then calls audible alerts
  void updateTrafficDistancesAndAlerts() {
    // Make async event to avoid blocking UI thread for recalcs and alerts
    Future(() {
      final int nowMs = DateTime.now().millisecondsSinceEpoch;
      final bool hasRef = _hasOwnshipReference;
      _traffic.removeWhere((key, t) {
        t.updateOwnshipDistancesAndAlertFields();
        // only display/alert traffic that isn't too far from ownship, and
        // retire stale reports (the per-message scan used to do this)
        return t.isOldAt(nowMs) ||
            (hasRef && t.verticalOwnshipDistanceFt.abs() > _kTrafficAltDiffThresholdFt);
      });
      // Single 1 Hz UI refresh for all traffic (icons + projection lines),
      // including ownship heading changes that rotate icons in track-up.
      Storage().trafficChange.value++;
    }).then((value) => handleAudibleAlerts());
  }

  List<Traffic> getTraffic() {
    final int nowMs = DateTime.now().millisecondsSinceEpoch;
    _traffic.removeWhere((key, t) => t.isOldAt(nowMs));
    return _traffic.values.toList();
  }
}

/// Avare-style simple traffic icon: a small filled circle with a black outline.
/// Cyan for normal/proximate traffic, red for threat (advisory or resolution) traffic,
/// brown for ground traffic. The directional/1-minute projection line is rendered
/// separately on the map (in real coordinates) by the traffic layer in `map_screen.dart`.
class TrafficPainter extends AbstractCachedCustomPainter {

  static const double _kCanvasSize = 32;
  static const double _kCenter = _kCanvasSize / 2;
  static const double _kCircleRadius = 7;
  static const double _kOutlineWidth = 2;

  static const double _kMetersToFeetCont = 3.28084;
  static const double _kGroundTrafficOpacity = 0.5;

  // Avare-style fill colors
  // Three tiers, so the colour carries information instead of just "near/not".
  // Previously advisory and resolution were the same red and the painter never
  // branched on resolution at all.
  static const Color kProximateColor = Color(0xFF00C853);  // green: no conflict
  static const Color kAdvisoryColor = Color(0xFFFFC107);   // amber: co-altitude and near
  static const Color kResolutionColor = Color(0xFFFF3535); // red: converging on a conflict
  static const Color _kGroundColor = Color(0xFF836539);   // brown for ground traffic
  static const Color kStaleColor = Color(0xFF9E9E9E);      // grey: not heard recently
  static const Color _kOutlineColor = Color(0xFF000000);  // black outline

  final TrafficAlertLevel _alertLevel;
  final bool _isAirborne;
  final bool _isStale;

  TrafficPainter(Traffic traffic)
    : _alertLevel = traffic.alertLevel,
      _isAirborne = traffic.message.airborne,
      _isStale = traffic.isStale,
      // staleness is part of the icon's appearance, so it must be part of the
      // cache key or a greyed icon would be served for a live target
      super([traffic.alertLevel.index, traffic.message.airborne ? 1 : 0,
             traffic.isStale ? 1 : 0],
        false, const Size(_kCanvasSize, _kCanvasSize));

  @override
  void freshPaint(Canvas canvas) {
    final double opacity = _isAirborne ? 1.0 : _kGroundTrafficOpacity;

    final Color fillColor;
    if (_isStale) {
      // Position is from more than TrafficPainter staleness ago; do not paint it
      // as though it were a current report.
      fillColor = kStaleColor;
    } else if (!_isAirborne) {
      fillColor = _kGroundColor;
    } else if (_alertLevel == TrafficAlertLevel.resolution) {
      fillColor = kResolutionColor;
    } else if (_alertLevel == TrafficAlertLevel.advisory) {
      fillColor = kAdvisoryColor;
    } else {
      fillColor = kProximateColor;
    }

    const Offset center = Offset(_kCenter, _kCenter);
    canvas.drawCircle(center, _kCircleRadius,
      Paint()..color = fillColor.withValues(alpha: opacity));
    canvas.drawCircle(center, _kCircleRadius,
      Paint()
        ..color = _kOutlineColor.withValues(alpha: opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = _kOutlineWidth);
  }

  @pragma("vm:prefer-inline")
  static int getVerticalSpeedDirection(double verticalSpeedMps) {
    if (verticalSpeedMps * _kMetersToFeetCont < -100) {
      return -1;
    } else if (verticalSpeedMps * _kMetersToFeetCont > 100) {
      return 1;
    } else {
      return 0;
    }
  }
}

/// Painter for traffic vertical status text box (+/- flight level, and vertical speed direction arrows)
class TrafficVerticalStatusPainter extends AbstractCachedCustomPainter {
  static const double _vertLocationFontSize = 16, _vertSpeedArrowFontSize = 24;
  static const _vertLocationTextStyle = TextStyle(shadows: [Shadow(offset: Offset(2, 2))], color: Colors.white, fontWeight: FontWeight.w600, fontSize: _vertLocationFontSize);
  static const _vertSpeedArrowStyle = TextStyle(shadows: [Shadow(offset: Offset(2, 2))], color: Colors.white, fontWeight: FontWeight.w900, fontSize: _vertSpeedArrowFontSize);
  static final _boundingBoxPaint = Paint()..color = const Color.fromRGBO(0, 0, 0, .2);
  static const double _offsetX = 0, _offsetY = 0;
  static const double _charPixeslWidth = 10;

  /// Bumped whenever the rendered text format changes so that the static
  /// in-memory image cache (in [AbstractCachedCustomPainter]) does not return a
  /// stale rasterization across hot reloads. Increment when the format string,
  /// fonts, sizes, or layout offsets are changed.
  static const int _formatVersion = 3;

  final int _flightLevelDiff;
  final int _vspeedDirection;
  final bool _isAirborne;

  TrafficVerticalStatusPainter(Traffic t):
    _flightLevelDiff = getFlightLevelDiff(t),
    _vspeedDirection = TrafficPainter.getVerticalSpeedDirection(t.message.verticalSpeed),
    _isAirborne = t.message.airborne,
    super([_formatVersion, getFlightLevelDiff(t), TrafficPainter.getVerticalSpeedDirection(t.message.verticalSpeed), t.message.airborne ? 1 : 0], false,
      const Size(96, 32));

  /// Format a flight-level diff as a signed, zero-padded 3-digit string.
  /// Examples: 60 -> "+060", -60 -> "-060", 6 -> "+006", 0 -> "000", 100 -> "+100", -1234 -> "-1234".
  static String formatFlightLevelDiff(int flightLevelDiff) {
    final int absVal = flightLevelDiff.abs();
    final String absStr = absVal < 100 ? absVal.toString().padLeft(3, '0') : absVal.toString();
    if (flightLevelDiff > 0) {
      return '+$absStr';
    } else if (flightLevelDiff < 0) {
      return '-$absStr';
    }
    return absStr;
  }

  @override
  void freshPaint(ui.Canvas canvas) {
    if (!_isAirborne) {
      return;
    }

    final String vertLocationMsg = formatFlightLevelDiff(_flightLevelDiff);
    final String directionText = (_vspeedDirection > 0 ? "↑" : (_vspeedDirection < 0 ? "↓": ""));
    // Draw transluscent bounding box for greater visibility (especially sectionals)
    final ui.Path statusBoundingBox = ui.Path()
      ..addRRect(RRect.fromRectAndRadius(
        Rect.fromLTRB(_offsetX, _offsetY, _offsetX+(vertLocationMsg.length+directionText.length)*_charPixeslWidth+_charPixeslWidth, _offsetY+24),
        const Radius.circular(6)));
    canvas.drawPath(statusBoundingBox, _boundingBoxPaint);
    // Paint vertical position. Use unbounded maxWidth so text never wraps and
    // hides a leading-zero digit (e.g. "+060" being collapsed to "+06" / "+0").
    final vertLocationTextPainter = TextPainter(text: TextSpan(text: vertLocationMsg, style: _vertLocationTextStyle), textDirection: TextDirection.ltr);
    vertLocationTextPainter.layout(
      minWidth: 0,
      maxWidth: double.infinity,
    );
    vertLocationTextPainter.paint(canvas, const Offset(_offsetX, _offsetY));
    // Paint ascending/descending direction arrows (if not flying level)
    if (directionText.isNotEmpty) {
      final verticalSpeedTextPainter = TextPainter(text: TextSpan(text: directionText, style: _vertSpeedArrowStyle), textDirection: TextDirection.ltr);
      verticalSpeedTextPainter.layout(
        minWidth: 0,
        maxWidth: double.infinity,
      );
      verticalSpeedTextPainter.paint(canvas, Offset(_offsetX + vertLocationTextPainter.width + 2, _offsetY-(_vertSpeedArrowFontSize-_vertLocationFontSize)));
    }
  }

  /// get flight level
  @pragma("vm:prefer-inline")
  static int getFlightLevelDiff(final Traffic traffic) {
    return -(traffic.verticalOwnshipDistanceFt / 100).round();
  }
}

/// Painter for traffic identifier (N-number if in ADSB message, ICAO number if not)
class TrafficIdPainter extends AbstractCachedCustomPainter {
  static const double _trafficIdFontSize = 16;
  static final _boundingBoxPaint = Paint()..color = const Color.fromRGBO(0, 0, 0, .2);
  static const _trafficIdTextStyle = TextStyle(shadows: [Shadow(offset: Offset(2, 2))], color: Colors.white, fontWeight: FontWeight.w600, fontSize: _trafficIdFontSize);
  static const double _offsetX = 0, _offsetY = 0;
  static const double _charPixeslWidth = 12;

  final String _trafficId;
  final bool _isAirborne;

  TrafficIdPainter(final Traffic t): 
    _trafficId = t.message.callSign.isNotEmpty ? t.message.callSign : t.message.icao.toString(),
    _isAirborne = t.message.airborne,
    super([ (t.message.callSign.isNotEmpty ? t.message.callSign : t.message.icao.toString()).hashCode, t.message.airborne ? 1 : 0 ], 
      false, Size((t.message.callSign.isNotEmpty ? t.message.callSign : t.message.icao.toString()).length*_charPixeslWidth+24, 42));
    
  @override
  void freshPaint(ui.Canvas canvas) {
    if (!_isAirborne) { // Don't clutter UI with ID's of aircraft on the ground--airports would be a mess
      return;
    }
    // paint transluscent bounding box
    final ui.Path statusBoundingBox = ui.Path()
      ..addRRect(RRect.fromRectAndRadius(
        Rect.fromLTRB(_offsetX, _offsetY, _offsetX+(_trafficId.length)*_charPixeslWidth+_charPixeslWidth, _offsetY+32),
        const Radius.circular(6)));
    canvas.drawPath(statusBoundingBox, _boundingBoxPaint);
    // paint traffic ID
    final trafficIdTextPainter = TextPainter(text: TextSpan(text: _trafficId, style: _trafficIdTextStyle), textDirection: TextDirection.ltr);
    trafficIdTextPainter.layout(
      minWidth: 0,
      maxWidth: _trafficId.length*_charPixeslWidth,
    );    
    trafficIdTextPainter.paint(canvas, const Offset(_offsetX, _offsetY));    
  }
}

/// Abstract custom painter helper that maintains a picture (graphical ops) or raster (image pixels) cache, as configured
abstract class AbstractCachedCustomPainter extends CustomPainter {

  /// Static caches, for faster rendering of the same icons, based on UI state
  static final Map<int,ui.Picture> _pictureCache = {};  // Graphical operations cache (for realtime rasterization config, e.g., shadow on)
  static final Map<int,ui.Image> _imageCache = {};      // Rasterized pixel image cache (for non-realtime config, e.g., no shadow off)

  /// These caches were unbounded. TrafficIdPainter keys on callsign and
  /// TrafficVerticalStatusPainter on flight-level difference, so both grow with
  /// every distinct aircraft/altitude seen and never shrink -- tens of MB of
  /// retained ui.Image over a long flight. Bounded FIFO (Dart maps preserve
  /// insertion order); native handles are released on eviction.
  static const int _maxCacheEntries = 256;

  static void _cachePicture(int key, ui.Picture picture) {
    while (_pictureCache.length >= _maxCacheEntries) {
      final int oldest = _pictureCache.keys.first;
      _pictureCache.remove(oldest)?.dispose();
    }
    _pictureCache[key] = picture;
  }

  static void _cacheImage(int key, ui.Image image) {
    while (_imageCache.length >= _maxCacheEntries) {
      final int oldest = _imageCache.keys.first;
      _imageCache.remove(oldest)?.dispose();
    }
    _imageCache[key] = image;
  }

  /// Unique key of icon state based on flight properties above that define the icon appearance, per the current
  /// configuration of enabled features.  This is used to determine UI-relevant state changes for repainting,
  /// as well as the key to the picture cache  
  int _uiStateKey = 0;
  /// Can we use a raster/image cache, or does each image need to re-rasterize (i.e., we can only cache the picture, which is the graphical ops)
  final bool _isRealtimeRasterizationRequired;
  final ui.Size _maxSize;

  AbstractCachedCustomPainter(final List<int> stateKeyComponents, bool isRealtimeRasterizationRequired,
    ui.Size maxSize):
    _isRealtimeRasterizationRequired = isRealtimeRasterizationRequired,
    _maxSize = maxSize
  {
    _uiStateKey = Constants.hashInts([ runtimeType.hashCode ] + stateKeyComponents);
  }

  @override
  void paint(ui.Canvas canvas, ui.Size size) {
    // Used cached rasterized (pixel) image if possible
    if (!_isRealtimeRasterizationRequired) {
      final ui.Image? cachedImage = _imageCache[_uiStateKey];  
      if (cachedImage != null) {
        paintImage(canvas: canvas, rect: Rect.fromLTWH(0, 0, cachedImage.width*1.0, cachedImage.height*1.0), image: cachedImage);
        return;
      }
    }

    // ...otherwise, use cached picture (pre-rasterization graphical operations) if possible
    final ui.Picture? cachedPicture = _pictureCache[_uiStateKey];
    final ui.Picture picture;
    if (cachedPicture != null) {
      picture = cachedPicture;        
    } else {
      // ...otherwise, create a new picture, and save it to the raster/image caches as appropriate
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final ui.Canvas drawingCanvas = Canvas(recorder);   

      freshPaint(drawingCanvas); 

      // store this fresh image to the cache(s) for quick and efficient rendering next time
      final ui.Picture newPicture = recorder.endRecording();
      _cachePicture(_uiStateKey, newPicture);
      picture = newPicture;
    } 
    
    // Cache pixels of image to image cache, to save rasterization next time, if possible, and paint image
    if (!_isRealtimeRasterizationRequired) {
      picture.toImage(_maxSize.width.ceil(), _maxSize.height.ceil()).then((newImage) {
        _cacheImage(_uiStateKey, newImage);
      });
    }
    canvas.drawPicture(picture);
  }

  /// Abstract hook for implementing painter to paint the custom UI
  void freshPaint(ui.Canvas canvas);

  @override
  bool shouldRepaint(covariant AbstractCachedCustomPainter oldDelegate) {
    return oldDelegate._uiStateKey != _uiStateKey;
  }
}