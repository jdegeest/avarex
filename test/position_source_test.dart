import 'package:avaremp/io/gps.dart';
import 'package:avaremp/storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// The selected source must be the only source. A receiver that acquired its
/// own fix while the app sat in Network mode used to push its position in
/// anyway, so the map flew on real GPS while every label still named the tail
/// number being spoofed.
void main() {
  final Storage s = Storage();

  setUp(() {
    s.gpsSourceMode = "Auto";
    s.gpsInternal = true;
  });

  test('Internal admits only this device', () {
    s.gpsSourceMode = "Internal";
    expect(s.acceptsPositionFrom(PositionOrigin.internal), isTrue);
    expect(s.acceptsPositionFrom(PositionOrigin.external), isFalse);
    expect(s.acceptsPositionFrom(PositionOrigin.network), isFalse);
  });

  test('External admits only the receiver', () {
    s.gpsSourceMode = "External";
    expect(s.acceptsPositionFrom(PositionOrigin.external), isTrue);
    expect(s.acceptsPositionFrom(PositionOrigin.internal), isFalse);
    expect(s.acceptsPositionFrom(PositionOrigin.network), isFalse);
  });

  test('Network admits only the feed, receiver fix or not', () {
    s.gpsSourceMode = "Network";
    expect(s.acceptsPositionFrom(PositionOrigin.network), isTrue);
    expect(s.acceptsPositionFrom(PositionOrigin.external), isFalse);
    expect(s.acceptsPositionFrom(PositionOrigin.internal), isFalse);
  });

  test('Auto lets the receiver win and this device fill in', () {
    s.gpsSourceMode = "Auto";
    s.gpsInternal = false; // receiver is talking
    expect(s.acceptsPositionFrom(PositionOrigin.external), isTrue);
    expect(s.acceptsPositionFrom(PositionOrigin.internal), isFalse);
    s.gpsInternal = true; // receiver went quiet
    expect(s.acceptsPositionFrom(PositionOrigin.external), isTrue);
    expect(s.acceptsPositionFrom(PositionOrigin.internal), isTrue);
  });

  test('Auto never falls back to the internet feed', () {
    s.gpsSourceMode = "Auto";
    expect(s.acceptsPositionFrom(PositionOrigin.network), isFalse);
    s.gpsInternal = false;
    expect(s.acceptsPositionFrom(PositionOrigin.network), isFalse);
  });
}
