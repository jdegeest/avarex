import 'package:avaremp/gdl90/traffic_report_message.dart';
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

  sharedSourceTests();

  test('Auto never falls back to the internet feed', () {
    s.gpsSourceMode = "Auto";
    expect(s.acceptsPositionFrom(PositionOrigin.network), isFalse);
    s.gpsInternal = false;
    expect(s.acceptsPositionFrom(PositionOrigin.network), isFalse);
  });

  // Traffic source is chosen independently of position source. Sharing one mode
  // meant you could not watch the receiver's targets while flying a synthesised
  // position, or the reverse.
  group('traffic admission', () {
    const List<(String, bool, bool)> cases = [
      // mode,      receiver accepted, feed accepted
      ("Receiver",  true,  false),
      ("Internet",  false, true),
      ("Both",      true,  true),
    ];

    for (final (String mode, bool receiver, bool feed) in cases) {
      test(mode, () {
        s.trafficSourceMode = mode;
        expect(s.acceptsTrafficFrom(TrafficSource.receiver), receiver);
        expect(s.acceptsTrafficFrom(TrafficSource.network), feed);
        expect(s.usesReceiverTraffic, receiver);
        expect(s.usesNetworkTraffic, feed);
      });
    }

    test('the feed runs whenever either half of the app wants it', () {
      s.trafficSourceMode = "Receiver";
      s.gpsSourceMode = "Auto";
      expect(s.needsNetworkFeed, isFalse);
      s.gpsSourceMode = "Network"; // position from the feed, traffic from the receiver
      expect(s.needsNetworkFeed, isTrue);
      s.gpsSourceMode = "Auto";
      s.trafficSourceMode = "Both"; // traffic from the feed, position from the receiver
      expect(s.needsNetworkFeed, isTrue);
    });
  });

  group('age wording', () {
    test('reads as a person would say it', () {
      expect(Storage.describeAge(500), "just now");
      expect(Storage.describeAge(12000), "12 s ago");
      expect(Storage.describeAge(240000), "4 min ago");
      expect(Storage.describeAge(7200000), "2 h ago");
    });
  });

  // Auto permits two sources at once, so "which source may supply a position"
  // and "which source is supplying it" are different questions. Answering only
  // the first lit up the receiver and this device simultaneously, which told
  // you nothing about what you were actually flying on.
  group('Auto distinguishes eligible from in use', () {
    test('both are eligible while the receiver is quiet', () {
      s.gpsSourceMode = "Auto";
      s.gpsInternal = true; // receiver has been silent past the switchover
      expect(s.acceptsPositionFrom(PositionOrigin.external), isTrue);
      expect(s.acceptsPositionFrom(PositionOrigin.internal), isTrue);
    });

    test('the traffic selection has no say in what may supply a position', () {
      s.gpsSourceMode = "Auto";
      s.gpsInternal = false; // receiver is talking, so it owns the position
      for (final String t in Storage.trafficSourceModes) {
        s.trafficSourceMode = t;
        expect(s.acceptsPositionFrom(PositionOrigin.external), isTrue, reason: t);
        expect(s.acceptsPositionFrom(PositionOrigin.internal), isFalse, reason: t);
        expect(s.acceptsPositionFrom(PositionOrigin.network), isFalse, reason: t);
      }
      s.trafficSourceMode = "Receiver";
    });
  });
}

/// A fix shared by another device is its own source: last in line behind the
/// receiver and this device's own GPS in Auto, and never dressed up as ADS-B.
void sharedSourceTests() {
  final Storage s = Storage();

  test('Auto takes a shared fix only when nothing closer is delivering', () {
    s.gpsSourceMode = "Auto";
    s.gpsInternal = true; // no receiver talking
    // fresh install: this device's GPS has never delivered
    expect(s.acceptsPositionFrom(PositionOrigin.shared), isTrue);
    s.gpsInternal = false; // receiver talking
    expect(s.acceptsPositionFrom(PositionOrigin.shared), isFalse);
  });

  test('Internal and Network never take a shared fix; External does', () {
    s.gpsSourceMode = "Internal";
    expect(s.acceptsPositionFrom(PositionOrigin.shared), isFalse);
    s.gpsSourceMode = "Network";
    expect(s.acceptsPositionFrom(PositionOrigin.shared), isFalse);
    s.gpsSourceMode = "External";
    expect(s.acceptsPositionFrom(PositionOrigin.shared), isTrue);
  });
}
