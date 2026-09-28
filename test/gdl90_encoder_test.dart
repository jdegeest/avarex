import 'dart:typed_data';

import 'package:avaremp/gdl90/gdl90_buffer.dart';
import 'package:avaremp/gdl90/gdl90_encoder.dart';
import 'package:avaremp/gdl90/heartbeat_message.dart';
import 'package:avaremp/gdl90/message.dart';
import 'package:avaremp/gdl90/message_factory.dart';
import 'package:avaremp/gdl90/ownship_geometric_altitude_message.dart';
import 'package:avaremp/gdl90/ownship_message.dart';
import 'package:avaremp/storage.dart';
import 'package:avaremp/utils/unit_conversion.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';

/// What one copy of the app sends, another must read back through the same
/// receiver path a Stratux's frames take -- framing, escaping and CRC included.
void main() {
  Storage().units = UnitConversion("Aviation");

  Message? roundTrip(List<int> frame) {
    final Gdl90Buffer buf = Gdl90Buffer();
    buf.put(Uint8List.fromList(frame));
    final Uint8List? raw = buf.get();
    expect(raw, isNotNull, reason: "frame did not survive the buffer");
    return MessageFactory.buildMessage(raw!);
  }

  test('ownship survives framing and CRC', () {
    final Position p = Position(
        latitude: 42.0347, longitude: -93.6199, altitude: 305.0, speed: 51.4444,
        heading: 271.0, accuracy: 0, altitudeAccuracy: 0, headingAccuracy: 0,
        speedAccuracy: 0, timestamp: DateTime.now());
    final Message? m = roundTrip(Gdl90Encoder.ownship(p,
        icao: 0xABCDEF, vsFpm: -512, airborne: true, callSign: "N12345"));
    expect(m, isA<OwnShipMessage>());
    final OwnShipMessage o = m as OwnShipMessage;
    expect(o.icao, 0xABCDEF);
    expect(o.coordinates.latitude, closeTo(42.0347, 0.0001));
    expect(o.coordinates.longitude, closeTo(-93.6199, 0.0001));
    expect(o.altitude, closeTo(305.0, 25 * 0.3048));
    expect(o.velocity, closeTo(51.4444, 0.6));
    expect(o.heading, closeTo(271.0, 1.5));
    expect(o.verticalSpeed, closeTo(-512, 64));
    expect(o.airborne, isTrue);
    expect(o.callSign, "N12345");
  });

  test('bytes needing escape still decode', () {
    // 0x7E and 0x7D appear in the address; the escape must be transparent.
    final Position p = Position(
        latitude: 0.5, longitude: 0.5, altitude: 0, speed: 0, heading: 0,
        accuracy: 0, altitudeAccuracy: 0, headingAccuracy: 0, speedAccuracy: 0,
        timestamp: DateTime.now());
    final Message? m = roundTrip(Gdl90Encoder.ownship(p,
        icao: 0x7E7D7E, vsFpm: 0, airborne: false));
    expect((m as OwnShipMessage).icao, 0x7E7D7E);
  });

  test('heartbeat and geometric altitude decode', () {
    final Message? h = roundTrip(Gdl90Encoder.heartbeat(
        gpsValid: true, now: DateTime.utc(2026, 1, 1, 13, 2, 3)));
    expect(h, isA<HeartbeatMessage>());
    final HeartbeatMessage hb = h as HeartbeatMessage;
    expect(hb.gpsValid, isTrue);
    expect((hb.hour, hb.min, hb.sec), (13, 2, 3));

    final Message? g = roundTrip(Gdl90Encoder.geometricAltitude(1524.0));
    expect(g, isA<OwnShipGeometricAltitudeMessage>());
    expect((g as OwnShipGeometricAltitudeMessage).altitude, closeTo(1524, 2));
  });
}
