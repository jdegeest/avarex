import 'dart:math';
import 'dart:ui' as ui;

import 'package:avaremp/destination/destination_calculations.dart';
import 'package:avaremp/gdl90/adsb_status_screen.dart';
import 'package:avaremp/utils/geo_calculations.dart';
import 'package:avaremp/instruments/pfd_painter.dart';
import 'package:avaremp/plan/plan_route.dart';
import 'package:avaremp/storage.dart';
import 'package:avaremp/plan/waypoint.dart';
import 'package:avaremp/utils/toast.dart';
import 'package:dropdown_button2/dropdown_button2.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';

import '../constants.dart';
import 'package:avaremp/destination/destination.dart';
import '../io/gps.dart';


/// Where the instrument panel sits. The edge it is docked to decides how it
/// lays out: a top or bottom strip flows wide with many columns, a side strip
/// runs tall with one or two.
enum PanelDock { free, top, bottom, left, right }

class InstrumentList extends StatefulWidget {
  const InstrumentList({super.key});

  @override
  State<InstrumentList> createState() => InstrumentListState();

  static double angularDifference(double hdg, double brg) {
    double absDiff = (hdg - brg).abs();
    if(absDiff > 180) {
      return 360 - absDiff;
    }
    return absDiff;
  }

  static bool leftOfCourseLine(double bT, double bC) {
    if(bC <= 180) {
      return (bT >= bC && bT <= bC + 180);
    }

    // brgCourse will be > 180 at this point
    return (bT > bC || bT < bC - 180);
  }

}

class InstrumentListState extends State<InstrumentList> {
  static final DateFormat _hourMinuteFormatter = DateFormat('HH:mm');
  final List<String> _items = Storage().settings.getInstruments().split(","); // get instruments
  // Fractional (0..1) top-left position of the instrument panel as a whole.
  // Tiles used to each carry their own position and be dragged individually,
  // which meant rebuilding the layout by hand and let tiles overlap or strand
  // themselves off-screen. They now flow inside one panel that moves together.
  Offset _panelPos = const Offset(0.01, 0.01);
  static const String _panelKey = "__PANEL";
  static const String _scaleKey = "__SCALE";
  /// Pinch scales the type; every dimension then follows from the text itself.
  /// Sizing cells explicitly meant fonts and cells could disagree and clip.
  double _fontScale = 1.0;
  double _scaleAtGestureStart = 1.0;
  static const double _minScale = 0.6, _maxScale = 2.6;
  /// Where the panel is docked. Layout follows placement: along the top or
  /// bottom a wide strip with many columns reads well; down a side, one or two
  /// columns and many rows does. Column count is therefore derived from the
  /// dock rather than being a separate knob to keep in sync.
  PanelDock _dock = PanelDock.left;
  static const String _dockKey = "__DOCK";
  /// How close to an edge a drag has to end for the panel to snap to it.
  /// Deliberately tight: you have to genuinely take it to the edge, so a panel
  /// parked near one side stays floating.
  static const double _snapFraction = 0.035;

  /// What each tile actually is. The three-letter codes are kept as the stored
  /// identity (layouts and visibility are saved by code) but are not what the
  /// pilot should have to read.
  static const Map<String, String> _tileLabels = {
    "GS": "Ground Speed", "ALT": "Altitude", "MT": "Track",
    "PRV": "Previous", "NXT": "Next", "DIS": "Distance", "BRG": "Bearing",
    "GEL": "Ground Elev", "ETA": "ETA", "ETE": "En Route",
    "VSR": "VS Required", "UPT": "Up Timer", "DNT": "Down Timer",
    "UTC": "UTC", "SRC": "Position From", "FLT": "Flight Time", "ADSB": "Traffic From",
  };

  String _tileUnit(String code) {
    final bool imperial = Storage().settings.getUnits() == "Imperial";
    switch (code) {
      case "GS":  return imperial ? "mph" : "kt";
      case "DIS": return imperial ? "sm" : "nm";
      case "ALT":
      case "GEL": return "ft";
      case "MT":
      case "BRG": return "\u00b0";
      case "VSR": return "fpm";
      case "FLT": return "hr";
      default:    return "";
    }
  }
  bool? _loadedPortrait; // orientation whose positions are currently loaded
  // Tiles currently shown, in the order they were added. The rest are hidden
  // and can be added one by one from the menu.
  final List<String> _visible = [];
  static const int _defaultVisibleCount = 5;
  String _gndSpeed = "0";
  String _altitude = "0";
  String _magneticHeading = "0\u00b0";
  String _timerUp = "00:00";
  String _timerDown = "30:00";
  String _destination = "";
  String _previousDestination = "";
  String _bearing = "0\u00b0";
  String _distance = "";
  String _utc = "00:00";
  String _eta = "";
  String _ete = "";
  String _source = "";
  String _vsr = "";
  String _flightTime = "00:00";
  String _gel = "DL";
  String _adsb = "\u25cb"; // ADSB tile value: ownship tail number, else status circle

  @override
  void dispose() {
    Storage().gpsChange.removeListener(_gpsListener);
    Storage().route.change.removeListener(_routeListener);
    Storage().timeChange.removeListener(_timeListener);
    super.dispose();
  }

  String _distanceFormat(double distance) {
    // if distance is less than 10 then show 1 decimal place, otherwise round it
    return distance < 10 ? distance.toStringAsFixed(1) : distance.round().toString();
  }

  String _truncate(String value) {
    int maxLength = 10;
    return value.length > maxLength ? value.substring(0, maxLength) : value;
  }

  (double, double) _getDistanceBearing() {
    LatLng position = Gps.toLatLng(Storage().position);
    GeoCalculations calculations = GeoCalculations();

    Destination? d = Storage().route.getCurrentWaypoint()?.destination;
    if (d != null) {
      double distance = calculations.calculateDistance(
          position, d.coordinate);
      double bearing = GeoCalculations.getMagneticHeading(calculations.calculateBearing(
          position, d.coordinate), d.geoVariation?? 0);
      return (distance, bearing);
    }
    return (0, 0);
  }


  void _gpsListener() {
    // connect to GPS
    double variation = Storage().area.variation;
    setState(() {
      double q = GeoCalculations.convertSpeed(Storage().position.speed);
      _gndSpeed = _truncate(q.round().toString());
      q = GeoCalculations.convertAltitude(Storage().position.altitude);
      _altitude = _truncate(q.round().toString());
      q = GeoCalculations.getMagneticHeading(Storage().position.heading, variation);
      _magneticHeading = _truncate("${q.round()}\u00b0");
      var (distance, bearing) = _getDistanceBearing();
      _distance = _truncate(_distanceFormat(distance));
      _bearing = _truncate("${bearing.round().toString()}\u00b0");
      Storage().pfdData.to = bearing;

      // CDI
      Waypoint? next = Storage().route.getCurrentWaypoint();
      Waypoint? prev = Storage().route.getLastWaypoint();

      double cdi = 0;
      if (next != null && prev != null) {
        LatLng prevCoordinate = prev.destination.coordinate;
        LatLng nextCoordinate = next.destination.coordinate;

        // The bearing from our CURRENT location to the target
        double brgOrg = GeoCalculations.getMagneticHeading(GeoCalculations().calculateBearing(prevCoordinate, nextCoordinate), variation);
        double brgCur = bearing;
        double brgDif = InstrumentList.angularDifference(brgOrg, brgCur);
        // Distance from our CURRENT position to the destination
        double dstCur = distance;

        // calculate deviation based on bearing diff and distance
        double deviation = dstCur * sin(brgDif * pi / 180); // nm
        // now find course deviation in degrees based on distance and deviation
        cdi = atan2(deviation, dstCur) * 180 / pi;

        // if distance is less than 15 miles then multiple by 4 for LOC sensitivity
        cdi = dstCur < 15 ? min(cdi * 4, 5) : min(cdi, 5);

        // Now determine whether we are LEFT.
        // Account for REVERSE SENSING if we are already BEYOND the target (>90deg)
        bool bLeftOfCourseLine = InstrumentList.leftOfCourseLine(brgCur,  brgOrg);
        if ((bLeftOfCourseLine && brgDif <= 90) || (!bLeftOfCourseLine && brgDif >= 90)) {
          cdi = -cdi;
        }
      }
      Storage().pfdData.cdi = -cdi;

      // VDI

      double vdi = 0;
      double relativeAGL = 0;

      if(next != null) {
        // Fetch the elevation of our destination. If we can't find it
        // then we don't want to display any vertical information
        double? destElev = next.destination is AirportDestination ? (next.destination as AirportDestination).elevation : null;

        if(destElev != null) {
          // Calculate our relative AGL compared to destination. If we are
          // lower then no display info
          relativeAGL = Storage().units.mToF * Storage().position.altitude - destElev;

          // Convert the destination distance to feet.
          double destDist = distance;
          double destInFeet = destDist * 6076.12;

          // Figure out our glide slope now based on our AGL height and distance
          vdi = atan(relativeAGL / destInFeet) * 180 / pi;
          if(vdi >= PfdPainter.vnavHigh) {
            vdi = PfdPainter.vnavHigh;
          }
          else if(vdi <= PfdPainter.vnavLow) {
            vdi = PfdPainter.vnavLow;
          }
        }

        // find time to next, not interested in fuel
        Destination d = Destination.fromLatLng(Gps.toLatLng(Storage().position));
        DestinationCalculations calc = DestinationCalculations(d, next.destination,
            GeoCalculations.convertSpeed(Storage().position.speed), 0, GeoCalculations.convertAltitude(Storage().position.altitude));
        calc.calculateTo();
        if(calc.time.isFinite) {
          Duration time = Duration(seconds: calc.time.round());
          if(time > const Duration(hours: 23)) { // no flight more than this long and saves overflow in instrument
            _eta = "XX:XX";
            _ete = "XX:XX";
            _vsr = "0";
          }
          else {
            _eta =
                _truncate(
                    _hourMinuteFormatter.format(DateTime.now().add(time)));
            _ete = _truncate(
                "${time.inHours.toString().padLeft(2, '0')}:${time.inMinutes.remainder(60).toString().padLeft(2, '0')}");
            if(destElev == null) {
              _vsr = "-";
            }
            else {
              if(time.inMinutes.toDouble() == 0) {
                _vsr = "-";
              }
              else {
                _vsr = _truncate(
                    ((relativeAGL - 1000) / time.inMinutes.toDouble())
                        .round()
                        .toStringAsFixed(0));
              }
            }
          }
        }
        else {
          _eta = "-";
          _ete = "-";
          _vsr = "-";
        }
      }
      Storage().pfdData.vdi = vdi;
      double? elevation = Storage().area.elevation;
      _gel = elevation == null ? "DL" : _truncate(elevation.round().toString());
    });
  }

  String _formatDestination(Destination? d) {
    if(d == null) {
      return "";
    }
    if(Destination.typeGps == d.type) {
      return _truncate(d.facilityName);
    }
    else if((Destination.isAirway(d.type) || (Destination.isProcedure(d.type))) && d.secondaryName != null) {
      return _truncate(d.secondaryName!);
    }
    else {
      return _truncate(d.locationID);
    }
  }

  void _routeListener() {
    setState(() {
      PlanRoute? route = Storage().route;
      Destination? d = route.getCurrentWaypoint()?.destination;
      if(d == null) {
        _eta = "";
        _ete = "";
        _vsr = "";
        _destination = "";
      }
      else {
        _destination = _formatDestination(d);
      }
      var (distance, bearing) = _getDistanceBearing();
      _distance = _truncate(_distanceFormat(distance));
      _bearing = _truncate("${bearing.round().toString()}\u00b0");

      // previous destination
      d = Storage().route.getPreviousDestination();
      if(d == null) {
        _previousDestination = "";
      }
      else {
        _previousDestination = _formatDestination(d);
      }
    });


  }

  void _timeListener() {
    setState(() {
      _timerUp = _truncate(Storage().flightTimer.getTime().toString().substring(2, 7));
      _timerDown = _truncate(Storage().flightDownTimer.getTime().toString().substring(2, 7));
      _utc = _truncate(_hourMinuteFormatter.format(DateTime.now().toUtc()));
      _source = Storage().positionTileLabel;
      // ADSB names the traffic source rather than the receiver's link state:
      // with a web feed available, "where are these targets from" is the
      // question the symbol on the map cannot answer on its own.
      _adsb = Storage().trafficTileLabel;
      _flightTime = _truncate((Storage().flightStatus.flightTime.toDouble() / 3600).toStringAsFixed(2));
    });
  }

  InstrumentListState() {
    Storage().gpsChange.addListener(_gpsListener);
    // connect to dest change
    Storage().route.change.addListener(_routeListener);
    // up timer
    Storage().timeChange.addListener(_timeListener);
  }

  // up timer
  void _startUpTimer() {
    if(Storage().flightTimer.isStarted()) {
      Storage().flightTimer.stop();
    }
    else {
      Storage().flightTimer.reset();
      Storage().flightTimer.start();
    }
    setState(() {
      _timerUp = _truncate(Storage().flightTimer.getTime().toString().substring(2, 7));
    });
  }

  // skip waypoint
  void _planNextWaypoint() {
    Storage().route.advance();
  }

  // skip waypoint
  void _planPreviousWaypoint() {
    Storage().route.back();
  }

  // down timer
  void _startDownTimer() {

    if(Storage().flightDownTimer.isStarted()) {
      Storage().flightDownTimer.stop();
    }
    else {
      Storage().flightDownTimer.reset();
      Storage().flightDownTimer.start();
    }
    setState(() {
      _timerDown = _truncate(Storage().flightDownTimer.getTime().toString().substring(2, 7));
    });
  }

  // down timer
  void _resetTacTimer() {
    Storage().flightStatus.resetFlightTime();
  }


  // ADS-B tile tap: open the receiver status screen.
  void _showAdsbDetails() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const AdsbStatusScreen()),
    );
  }

  // tile dimensions, scaled by the user adjustable factor
  // Cells are rows now (description, value, unit) rather than square pills, so
  // they are sized in logical pixels and scaled by the pinch factor. The old
  // menu scale factor still applies as a coarse base.
  /// The one number that drives the panel. Cell sizes are intrinsic.
  double get _s => _fontScale / Storage().settings.getInstrumentScaleFactor();

  // default layout: a row of tiles near the top that wraps onto new rows

  // load saved positions for the current orientation, filling any gaps with defaults
  void _loadPositions() {
    bool portrait = Constants.isPortrait(context);
    String raw = Storage().settings.getInstrumentPositions(portrait);
    Map<String, Offset> parsed = {};
    if(raw.isNotEmpty) {
      for(String part in raw.split(",")) {
        List<String> f = part.split(":");
        if(f.length == 3) {
          double? dx = double.tryParse(f[1]);
          double? dy = double.tryParse(f[2]);
          if(dx != null && dy != null) {
            parsed[f[0]] = Offset(dx, dy);
          }
        }
      }
    }
    // Per-tile entries from the old layout are simply ignored; only the panel
    // position is read now, defaulting to the top-left corner.
    _panelPos = parsed[_panelKey] ?? const Offset(0.01, 0.01);
    _fontScale = (parsed[_scaleKey]?.dx ?? 1.0).clamp(_minScale, _maxScale);
    final int d = (parsed[_dockKey]?.dx ?? PanelDock.left.index.toDouble()).round();
    _dock = PanelDock.values[d.clamp(0, PanelDock.values.length - 1)];
    _loadedPortrait = portrait;
  }

  void _savePositions() {
    bool portrait = Constants.isPortrait(context);
    String raw = "$_panelKey:${_panelPos.dx.toStringAsFixed(4)}:${_panelPos.dy.toStringAsFixed(4)}"
        ",$_scaleKey:${_fontScale.toStringAsFixed(3)}:0"
        ",$_dockKey:${_dock.index}:0";
    Storage().settings.setInstrumentPositions(portrait, raw);
  }

  List<String> _defaultVisible() {
    return _items.where((c) => c.isNotEmpty).take(_defaultVisibleCount).toList();
  }

  // load which tiles are shown; first run / empty falls back to the default few
  void _loadVisible() {
    String raw = Storage().settings.getInstrumentVisible();
    _visible.clear();
    if(raw.isEmpty) {
      _visible.addAll(_defaultVisible());
    }
    else {
      for(String c in raw.split(",")) {
        if(c.isNotEmpty && _items.contains(c) && !_visible.contains(c)) {
          _visible.add(c);
        }
      }
    }
  }

  /// The tiles actually drawn. The traffic-source readout is forced in whenever
  /// any traffic is coming from the internet feed: that is a safety marker, not
  /// a preference, so it must not be possible to hide it by accident. It is not
  /// written to settings, so the user's own choice is preserved underneath.
  List<String> get _shown =>
      (Storage().usesNetworkTraffic && !_visible.contains("ADSB"))
          ? [..._visible, "ADSB"]
          : _visible;

  void _saveVisible() {
    Storage().settings.setInstrumentVisible(_visible.join(","));
  }

  // show/hide a tile from the menu; added tiles get their default slot
  void _toggleTile(String code) {
    setState(() {
      if(_visible.contains(code)) {
        _visible.remove(code);
      }
      else {
        _visible.add(code);
      }
    });
    _saveVisible();
    _savePositions();
  }

  void _resetLayout() {
    setState(() {
      _visible
        ..clear()
        ..addAll(_defaultVisible());
      _panelPos = const Offset(0.01, 0.01);
      _fontScale = 1.0;
      _dock = PanelDock.left;
    });
    _saveVisible();
    _savePositions();
  }

  /// The text a readout currently shows. Shared with [_measuredCellWidth] so
  /// the column is sized from what is actually drawn in it.
  String _valueFor(String code) {
    switch (code) {
      case "GS":   return _gndSpeed;
      case "ALT":  return _altitude;
      case "MT":   return _magneticHeading;
      case "PRV":  return _previousDestination;
      case "NXT":  return _destination;
      case "BRG":  return _bearing;
      case "DIS":  return _distance;
      case "GEL":  return _gel;
      case "ETA":  return _eta;
      case "ETE":  return _ete;
      case "VSR":  return _vsr;
      case "UTC":  return _utc;
      case "UPT":  return _timerUp;
      case "DNT":  return _timerDown;
      case "SRC":  return _source;
      case "FLT":  return _flightTime;
      case "ADSB": return _adsb; // tail number when reported, else a status dot
      default:     return "";
    }
  }

  // one readout in the panel; it sizes itself to its text
  Widget _makeInstrument(String code) {

    final String value = _valueFor(code);
    Function() cb = () {};

    switch(code) {
      case "PRV":
        cb = _planPreviousWaypoint;
        break;
      case "NXT":
        cb = _planNextWaypoint;
        break;
      case "UPT":
        cb = _startUpTimer;
        break;
      case "DNT":
        cb = _startDownTimer;
        break;
      case "SRC":
        // Opens the ADS-B/position status screen, where the source and its mode
        // are explained in full. Cycling modes from a flight instrument was
        // never the right place for it.
        cb = _showAdsbDetails;
        break;
      case "FLT":
        cb = _resetTacTimer;
        break;
      case "ADSB":
        cb = _showAdsbDetails;
        break;
    }

    final Color fg = Theme.of(context).colorScheme.onSurface;
    final Color? stateColor = _stateColorFor(code);
    final String unit = _tileUnit(code);

    // No explicit size: the cell is as wide and tall as its text needs, and the
    // enclosing Table aligns columns to the widest cell in each.
    return GestureDetector(
      onTap: cb,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 7 * _s, vertical: 4 * _s),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _tileLabels[code] ?? code,
              maxLines: 1,
              softWrap: false,
              style: TextStyle(
                fontSize: 9.5 * _s,
                height: 1.0,
                letterSpacing: 0.4,
                color: fg.withValues(alpha: 0.6),
              ),
            ),
            SizedBox(height: 2 * _s),
            Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  value.isEmpty ? "\u2014" : value,
                  maxLines: 1,
                  softWrap: false,
                  style: TextStyle(
                    fontSize: 16 * _s,
                    height: 1.0,
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [ui.FontFeature.tabularFigures()],
                    color: stateColor ?? fg,
                  ),
                ),
                if (unit.isNotEmpty)
                  Padding(
                    padding: EdgeInsets.only(left: 3 * _s),
                    child: Text(unit,
                      style: TextStyle(
                        fontSize: 9.5 * _s,
                        color: fg.withValues(alpha: 0.55))),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Only tiles that genuinely encode state get a colour; everything else uses
  /// the normal foreground so the panel reads as one table, not a paint chart.
  Color? _stateColorFor(String code) {
    switch (code) {
      case "SRC":
        // Text says whether we have a position; colour says where it came
        // from, so a silent Auto fallback from receiver to this device shows
        // up as a blue -> green change with no label to read.
        return switch (Storage().gpsState) {
          GpsState.externalFix => Colors.lightBlueAccent,
          GpsState.internalFix => Colors.lightGreenAccent,
          // Orange matches the test banner, so a spoofed position reads as
          // test data everywhere it appears.
          GpsState.networkFix => Colors.orangeAccent,
          GpsState.networkNoOwnship ||
          GpsState.networkNoData => Colors.orange,
          GpsState.internalPermissionDenied ||
          GpsState.internalServiceOff => Colors.redAccent,
          GpsState.noProvider => null,
          _ => Colors.amberAccent,
        };
      case "ADSB":
        // Orange wherever the internet feed is involved, matching the position
        // tile, so "not from my receiver" reads the same on both.
        if (Storage().usesNetworkTraffic) {
          return Colors.orangeAccent;
        }
        return Storage().adsbStatus.trafficFresh
            ? Colors.lightGreenAccent
            : (Storage().adsbStatus.connected ? Colors.amberAccent : null);
      case "DNT":
        return Storage().flightDownTimer.isExpired()
            ? Colors.redAccent
            : (Storage().flightDownTimer.isStarted()
                ? Colors.lightGreenAccent : null);
      case "UPT":
        return Storage().flightTimer.isStarted()
            ? Colors.lightGreenAccent : null;
      default:
        return null;
    }
  }

  /// All visible tiles as one cohesive, movable panel. Dragging anywhere on the
  /// panel background moves the whole thing; taps still reach the tiles.
  /// Digits all take the same advance under tabular figures, so a value's width
  /// depends only on how many of them there are. Measuring zeroes instead of the
  /// live number keeps the column still while the number changes -- otherwise
  /// the whole panel twitches once a second.
  static final RegExp _digits = RegExp(r'[0-9]');
  static String _widthTemplate(String s) => s.replaceAll(_digits, '0');

  /// Width one readout needs at the current type size. Measured rather than
  /// assumed, so column counts stay right as the font scales.
  double _measuredCellWidth() {
    double widest = 0;
    for (final String code in _shown) {
      final String label = _tileLabels[code] ?? code;
      final TextPainter tp = TextPainter(
        text: TextSpan(text: label,
            style: TextStyle(fontSize: 9.5 * _s, letterSpacing: 0.4)),
        textDirection: ui.TextDirection.ltr,
      )..layout();
      final String unit = _tileUnit(code);
      final TextPainter vp = TextPainter(
        text: TextSpan(
            text: _widthTemplate(_valueFor(code)) + (unit.isEmpty ? "" : " $unit"),
            style: TextStyle(
              fontSize: 16 * _s,
              fontWeight: FontWeight.w600,
              fontFeatures: const [ui.FontFeature.tabularFigures()],
            )),
        textDirection: ui.TextDirection.ltr,
      )..layout();
      widest = max(widest, max(tp.width, vp.width));
    }
    return widest + 14 * _s;
  }

  /// Columns implied by where the panel is docked and how much room that edge
  /// gives it.
  int _columnsForDock(double screenW, double screenH, double cellW) {
    switch (_dock) {
      case PanelDock.top:
      case PanelDock.bottom:
        // a wide strip: as many as fit, but never so many it needs one row
        return max(1, min(_shown.length, (screenW * 0.96 / cellW).floor()));
      case PanelDock.left:
      case PanelDock.right:
        // a tall strip: keep it narrow, two columns only if there is real room
        return (screenW > cellW * 5 && _shown.length > 8) ? 2 : 1;
      case PanelDock.free:
        // Aim for a square block: cols * cellW ~= rows * cellH, with
        // rows = n / cols, which gives cols = sqrt(n * cellH / cellW).
        final double cellH = 34.0 * _s;
        final int n = _shown.length;
        final int cols = sqrt(n * cellH / cellW).round();
        return cols.clamp(1, max(1, n));
    }
  }

  /// Snap to whichever edge the panel was released nearest, if any.
  PanelDock _dockForPosition(Offset frac) {
    final double x = frac.dx, y = frac.dy;
    final double nearest = [y, 1 - y, x, 1 - x].reduce(min);
    if (nearest > _snapFraction) {
      return PanelDock.free;
    }
    if (nearest == y) return PanelDock.top;
    if (nearest == 1 - y) return PanelDock.bottom;
    if (nearest == x) return PanelDock.left;
    return PanelDock.right;
  }

  Widget _makePanel() {
    final double screenW = Constants.screenWidth(context);
    final double screenH = Constants.screenHeight(context);
    final bool locked = Storage().settings.isInstrumentsLocked();
    final Color surface = Theme.of(context).colorScheme.surface;
    final Color line = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.14);

    final double cellW = _measuredCellWidth();
    final int perRow = _columnsForDock(screenW, screenH, cellW);
    final List<String> shown = _shown;
    final int rows = (shown.length / perRow).ceil();

    final Widget table = Table(
      defaultColumnWidth: FixedColumnWidth(cellW),
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      border: TableBorder.symmetric(inside: BorderSide(color: line, width: 1)),
      children: [
        for (int r = 0; r < rows; r++)
          TableRow(children: [
            for (int c = 0; c < perRow; c++)
              (r * perRow + c) < shown.length
                  ? _makeInstrument(shown[r * perRow + c])
                  : const SizedBox.shrink(),
          ]),
      ],
    );

    final Widget panel = DecoratedBox(
      decoration: BoxDecoration(
        color: surface.withValues(alpha: 0.86),
        borderRadius: const BorderRadius.all(Radius.circular(4)),
        border: Border.all(color: line, width: 1),
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.all(Radius.circular(4)),
        child: IntrinsicWidth(child: table),
      ),
    );

    // Docked edges pin the relevant axis; only a free panel uses both saved
    // coordinates.
    double? left, top, right, bottom;
    switch (_dock) {
      case PanelDock.top:
        top = 0; left = _panelPos.dx * screenW;
        break;
      case PanelDock.bottom:
        bottom = 0; left = _panelPos.dx * screenW;
        break;
      case PanelDock.left:
        left = 0; top = _panelPos.dy * screenH;
        break;
      case PanelDock.right:
        right = 0; top = _panelPos.dy * screenH;
        break;
      case PanelDock.free:
        left = _panelPos.dx * screenW; top = _panelPos.dy * screenH;
        break;
    }

    if (locked) {
      return Positioned(left: left, top: top, right: right, bottom: bottom, child: panel);
    }

    const double pad = 48;
    return Positioned(
      left: left == null ? null : left - pad,
      top: top == null ? null : top - pad,
      right: right == null ? null : right - pad,
      bottom: bottom == null ? null : bottom - pad,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onScaleStart: (_) => _scaleAtGestureStart = _fontScale,
        onScaleUpdate: (details) {
          setState(() {
            if (details.pointerCount > 1) {
              _fontScale = (_scaleAtGestureStart * details.scale)
                  .clamp(_minScale, _maxScale);
            }
            final double nx = (_panelPos.dx * screenW + details.focalPointDelta.dx)
                .clamp(0.0, max(0.0, screenW - 40));
            final double ny = (_panelPos.dy * screenH + details.focalPointDelta.dy)
                .clamp(0.0, max(0.0, screenH - 40));
            _panelPos = Offset(nx / screenW, ny / screenH);
            // Re-dock live so the layout previews where it will land.
            _dock = _dockForPosition(_panelPos);
          });
        },
        onScaleEnd: (_) => _savePositions(),
        child: Padding(
          padding: const EdgeInsets.all(pad),
          child: DottedEditFrame(color: line, child: panel),
        ),
      ),
    );
  }

  // corner menu: tile sizing, reset layout, and help. Lives top-left and is fixed.
  Widget _makeMenu() {
    return Positioned(
      left: 5,
      top: 5,
      child: DropdownButtonHideUnderline(
        child: DropdownButton2<String>(
          dropdownStyleData: DropdownStyleData(
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(10)),
            width: Constants.screenWidth(context) / 2,
          ),
          isExpanded: false,
          customButton: CircleAvatar(radius: 16, backgroundColor: Theme.of(context).scaffoldBackgroundColor.withValues(alpha: 0.7), child: const Icon(Icons.arrow_drop_down),),
          onChanged: (value) {
            setState(() {
            });
          },
          items: [
            DropdownMenuItem(
              value: "4",
              onTap:() {
                // Make a toast and show
                Toast.showToast(context,
                    "You may adjust the size of the tiles using Expand/Contract.\n"
                    "You may drag any tile to move it anywhere on the screen.\n"
                    "Use Lock Tiles to prevent accidentally moving tiles, and Unlock Tiles to move them again.\n"
                    "Each tile is listed in this menu: tap + to show it, or - to hide it.\n"
                    "Use Reset Layout to restore the default tiles and positions.\n\n"
                    "Available Tiles:\n"
                    "GS  - Ground speed.\n"
                    "ALT - GPS altitude.\n"
                    "MT  - Magnetic track.\n"
                    "PRV - Tap to go to the previous waypoint as shown.\n"
                    "NXT - Tap to go to the next waypoint as shown.\n"
                    "DIS - Distance to the next waypoint.\n"
                    "BRG - Bearing to the next waypoint.\n"
                    "GEL - Ground elevation. Needs Elevation charts.\n"
                    "ETA - Estimated time of arrival at the next waypoint.\n"
                    "ETE - Estimated time en-route to the next waypoint.\n"
                    "VSR - VSI required to arrive at the NXT airport 1000ft above its elevation.\n"
                    "UPT - Tap to start/stop the up timer.\n"
                    "DNT - Tap to start/stop the down timer.\n"
                    "UTC - Coordinated Universal Time.\n"
                    "SRC - Which source is driving the aircraft symbol. Device=this machine's GPS (green), ADS-B=the receiver (blue), a tail number=synthesised from the internet feed (orange). Frozen=the last position is still on screen but nothing is refreshing it. Searching / No Fix / No Link / No GPS / Off say why there is none. Tap to open the status screen, where the source is chosen and explained.\n"
                    "FLT - Total flight time in hours. Tap to reset.\n"
                    "ADSB- Where the traffic on the map comes from. ADS-B=your receiver (green), Web=the internet feed (orange, seconds late), Both=receiver targets with feed targets filling the gaps. Quiet=receiver connected but hearing nothing. On the map, a filled dot on a target's label means your receiver heard it; a hollow dot means the feed relayed it. Tap to open the status screen.\n",
                    null, 30);
                },
                child: _menuRow(Icons.help_outline, "Help"),
            ),
            DropdownMenuItem(
              value: "1",
              onTap:() {
                Storage().settings.setInstrumentScaleFactor(Storage().settings.getInstrumentScaleFactor() - 0.1);
              },
              child: _menuRow(Icons.zoom_in, "Expand"),
            ),
            DropdownMenuItem(
              value: "2",
              onTap:() {
                Storage().settings.setInstrumentScaleFactor(Storage().settings.getInstrumentScaleFactor() + 0.1);
              },
              child: _menuRow(Icons.zoom_out, "Contract"),
            ),
            DropdownMenuItem(
              value: "dock",
              onTap: () {
                setState(() {
                  // cycle through the docks; dragging to an edge does this too
                  const List<PanelDock> order = [
                    PanelDock.left, PanelDock.top, PanelDock.right,
                    PanelDock.bottom, PanelDock.free];
                  _dock = order[(order.indexOf(_dock) + 1) % order.length];
                });
                _savePositions();
              },
              child: _menuRow(Icons.dashboard_outlined,
                  "Dock: ${_dock.name}"),
            ),
            DropdownMenuItem(
              value: "lock",
              onTap:() {
                setState(() {
                  Storage().settings.setInstrumentsLocked(!Storage().settings.isInstrumentsLocked());
                });
              },
              child: Storage().settings.isInstrumentsLocked()
                  ? _menuRow(Icons.lock_open, "Unlock Panel")
                  : _menuRow(Icons.lock_outline, "Lock Panel"),
            ),
            DropdownMenuItem(
              value: "3",
              onTap: _resetLayout,
              child: _menuRow(Icons.restart_alt, "Reset Layout"),
            ),
            for(final String code in _items.where((c) => c.isNotEmpty))
              DropdownMenuItem(
                value: "toggle-$code",
                onTap: () => _toggleTile(code),
                child: _menuRow(_visible.contains(code) ? Icons.remove_circle_outline : Icons.add_circle_outline,
                    _tileLabels[code] ?? code),
              ),
          ],
        )
      ),
    );
  }

  // a dropdown menu entry with a leading icon
  Widget _menuRow(IconData icon, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16),
        const SizedBox(width: 8),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {

    // init everything
    _gpsListener();
    _routeListener();
    _timeListener();

    // (re)load tile positions when first built or when orientation changes
    bool portrait = Constants.isPortrait(context);
    if(_loadedPortrait != portrait) {
      _loadPositions();
    }
    // Always reload the shown-tiles list from settings. The map and plate
    // screens each host their own InstrumentList that share this saved list;
    // reloading every build keeps them in sync so a long-lived instance can't
    // overwrite the setting with a stale list (which previously made tiles such
    // as ADSB disappear after being toggled on the other screen).
    _loadVisible();

    // Full screen overlay. The Stack itself does not absorb touches in empty
    // areas, so the underlying map remains fully interactive; only the tiles
    // and the menu button receive gestures.
    return Stack(
      children: <Widget>[
        _makePanel(),
        _makeMenu(),
      ],
    );
  }
}


/// A faint outline shown only while the panel is unlocked, so it is obvious
/// which area accepts the drag/pinch and how far it extends.
class DottedEditFrame extends StatelessWidget {
  final Widget child;
  final Color color;
  const DottedEditFrame({super.key, required this.child, required this.color});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: color, width: 1),
        borderRadius: const BorderRadius.all(Radius.circular(6)),
      ),
      child: child,
    );
  }
}
