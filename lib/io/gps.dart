import 'dart:async';
import 'dart:math';

import 'package:avaremp/utils/geo_calculations.dart';
import 'package:avaremp/storage.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';


/// What the position source is actually doing. These are deliberately
/// separate states: "no location provider on this system" is permanent and
/// cannot be fixed in settings or by moving outdoors; "provider present but no
/// fix yet" can; and "ADS-B receiver connected but sending no ownship position"
/// is the receiver's GPS problem, not this device's.
enum GpsState {
  internalFix,
  internalSearching,
  internalPermissionDenied,
  internalServiceOff,
  noProvider,
  externalFix,
  externalNoOwnship,
  externalNoData,
  /// Position synthesised from an internet feed by adopting a tail number.
  /// Test data, never a navigation source.
  networkFix,
  /// The feed is answering, but no tail number has been adopted -- either none
  /// was entered or that aircraft is not currently in the feed. Traffic works;
  /// there is simply no ownship.
  networkNoOwnship,
  networkNoData,
}

/// Where the position currently in use actually came from, as opposed to where
/// the user asked it to come from. The two can disagree for a second after a
/// source change, and they used to disagree indefinitely: a receiver that got
/// its fix while the app sat in Network mode kept pushing its own position in,
/// while every label still named the tail number we thought we were spoofing.
enum PositionOrigin {
  /// Nothing has supplied a position since the last source change.
  none,
  internal,
  external,
  network,
}

class Gps {

  static Position fromLatLng(LatLng latLng) {
    return Position(longitude: latLng.longitude, latitude: latLng.latitude, accuracy: 0, altitude: 0, altitudeAccuracy: 0, heading: 0, headingAccuracy: 0, speed: 0, speedAccuracy: 0, timestamp: DateTime.now());
  }

  static Position clone(Position position, double geoidHeight) {
    // apply geoid correction to the non corrected data
    return Position(longitude: position.longitude, latitude: position.latitude, accuracy: position.accuracy, altitude: position.altitude - geoidHeight, altitudeAccuracy: position.altitudeAccuracy, heading: position.heading, headingAccuracy: position.headingAccuracy, speed: position.speed, speedAccuracy: position.speedAccuracy, timestamp: position.timestamp);
  }

  Future<void> requestPermissions() async {
    final GeolocatorPlatform platform = GeolocatorPlatform.instance;
    await platform.requestPermission();
  }


  /// True when the user has actively denied location access. Distinct from
  /// [isProviderUnavailable]: unableToDetermine means the platform has no
  /// location implementation at all, which is not something the user can grant.
  Future<bool> isPermissionDenied() async {
    try {
      final GeolocatorPlatform platform = GeolocatorPlatform.instance;
      LocationPermission permission = await platform.checkPermission();
      return (LocationPermission.denied == permission ||
          LocationPermission.deniedForever == permission);
    }
    catch (e) {
      return false; // no provider to deny; see isProviderUnavailable
    }
  }

  /// True when this system exposes no location provider at all -- typically a
  /// desktop with no GeoClue/location service and no GPS hardware. This is a
  /// permanent condition, not something a user can fix in settings or by
  /// moving outdoors, so it must not be reported as "permission denied" or
  /// "no lock".
  Future<bool> isProviderUnavailable() async {
    try {
      final GeolocatorPlatform platform = GeolocatorPlatform.instance;
      return LocationPermission.unableToDetermine ==
          await platform.checkPermission();
    }
    catch (e) {
      return true; // platform threw: no implementation available
    }
  }

  Future<bool> isDisabled() async {
    try {
      final GeolocatorPlatform platform = GeolocatorPlatform.instance;
      return !(await platform.isLocationServiceEnabled());
    }
    catch (e) {
      return false; // no service to be disabled; see isProviderUnavailable
    }
  }

  // for testing
  static double _countTest = 0;
  StreamSubscription<Position> getStreamMock() {
    final List<LatLng> mockPositions = GeoCalculations().findPoints(const LatLng(40.75, -112), const LatLng(42.75 + 0.75, -112), 1);
    mockPositions.addAll(mockPositions.reversed.toList()); // come back
    mockPositions.addAll(List.generate(90, (int index) {return const LatLng(42.584, -70.916);})); // stay at start for 90 seconds
    return Stream.periodic(const Duration(seconds: 1), (_) {
      _countTest++;

      // change speed to simulate takeoff and landing, to 50 m/s, and one cycle in 180 seconds
      double speed = sin(((_countTest * 2) % 360) * pi / 180) * 50;
      if(speed < 0) {
        speed = 0;
      }

      // change altitude to simulate takeoff and landing, to 1000 meters, and one cycle in 180 seconds
      double altitude = sin(((_countTest * 2) % 360) * pi / 180) * 1000 + 2000;
      if(altitude < 0) {
        altitude = 0;
      }

      // Code returning a value every 1 seconds.
      return Position(
        longitude: mockPositions[_countTest.toInt() % mockPositions.length].longitude,
        latitude: mockPositions[_countTest.toInt() % mockPositions.length].latitude,
        accuracy: 0,
        altitude: altitude,
        altitudeAccuracy: 0,
        heading: 0,
        headingAccuracy: 0,
        speed: speed,
        speedAccuracy: 0,
        timestamp: DateTime.now(),
      );
    }).listen((Position position) {});
  }

  StreamSubscription<Position> getStreamMockFlyPath() {
    // listen for Storage().route.change changes
    List<LatLng> mockPositions = [];

    Storage().rubberBandChange.addListener(() {
      mockPositions = Storage().route.getPathNextHighResolution();
      _countTest = 0;
    });

    return Stream.periodic(const Duration(seconds: 1), (_) {
      _countTest++;

      if(mockPositions.length < 2) {
        return Storage().position;
      }
      if(_countTest.toInt() == mockPositions.length - 2) {
        _countTest = mockPositions.length - 2;
      }
      double longitude0 = mockPositions[_countTest.toInt()].longitude;
      double latitude0  =  mockPositions[_countTest.toInt()].latitude;
      double longitude1 = mockPositions[_countTest.toInt() + 1].longitude;
      double latitude1  =  mockPositions[_countTest.toInt() + 1].latitude;

      double d = GeoCalculations().calculateDistance(LatLng(latitude0, longitude0), LatLng(latitude1, longitude1));
      double speed = Storage().units.toM * d; //to meters
      double heading = GeoCalculations().calculateBearing(LatLng(latitude0, longitude0), LatLng(latitude1, longitude1));

      // Code returning a value every 1 seconds.
      return Position(
        longitude: mockPositions[_countTest.toInt() == mockPositions.length ? mockPositions.length - 1 : _countTest.toInt()].longitude,
        latitude: mockPositions[_countTest.toInt() == mockPositions.length ? mockPositions.length - 1 : _countTest.toInt()].latitude,
        accuracy: 0,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: heading,
        headingAccuracy: 0,
        speed: speed,
        speedAccuracy: 0,
        timestamp: DateTime.now(),
      );
    }).listen((Position position) {});
  }

  StreamSubscription<Position> getStream() {

    StreamSubscription<Position> positionStream;

    const LocationSettings locationSettings = LocationSettings(accuracy: LocationAccuracy.high,);

    positionStream = Geolocator.getPositionStream(locationSettings: locationSettings).listen((Position? position) {});

    return positionStream;
  }

  static LatLng toLatLng(Position position) {
    return LatLng(position.latitude, position.longitude);
  }

  static bool isPositionCloseToZero(Position p) {
    const int roundingFactor = 100000;
    int roundedLongitude = (p.longitude * roundingFactor).round();
    int roundedLatitude = (p.latitude * roundingFactor).round();
    return roundedLongitude == 0 && roundedLatitude == 0;
  }


}

