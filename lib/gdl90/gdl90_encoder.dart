import 'dart:typed_data';

import 'package:geolocator/geolocator.dart';

import 'message_factory.dart';

/// Builds the handful of GDL90 frames needed to *be* a receiver: the
/// heartbeat, an ownship report and an ownship geometric altitude. The
/// mirror of [MessageFactory], so a position sent by one copy of the app is
/// read by another exactly as a Stratux's would be.
class Gdl90Encoder {

  /// Frame a payload: flag, ID + payload + CRC (LSB first), flag, with 0x7E
  /// and 0x7D inside escaped as 0x7D followed by the byte XOR 0x20.
  static Uint8List frame(int id, List<int> payload) {
    final List<int> body = [id, ...payload];
    final int crc = Crc.compute(body);
    body.add(crc & 0xFF);
    body.add((crc >> 8) & 0xFF);
    final List<int> out = [0x7E];
    for (final int b in body) {
      if (b == 0x7E || b == 0x7D) {
        out.add(0x7D);
        out.add(b ^ 0x20);
      }
      else {
        out.add(b);
      }
    }
    out.add(0x7E);
    return Uint8List.fromList(out);
  }

  /// Heartbeat with GPS valid and UTC OK, stamped with the UTC time of day.
  static Uint8List heartbeat({required bool gpsValid, DateTime? now}) {
    final DateTime t = (now ?? DateTime.now()).toUtc();
    final int secs = t.hour * 3600 + t.minute * 60 + t.second;
    final int status1 = (gpsValid ? 0x80 : 0x00) | 0x01; // UAT initialized
    final int status2 = 0x01 | ((secs >> 16) & 0x01) << 7; // UTC OK, ts bit 16
    return frame(MessageType.heartBeat, [
      status1, status2, secs & 0xFF, (secs >> 8) & 0xFF, 0, 0,
    ]);
  }

  /// Ownship report from a [Position] (metres, m/s, degrees) plus vertical
  /// speed in fpm. [icao] identifies the sender; [callSign] names it.
  static Uint8List ownship(Position p, {required int icao, required double vsFpm,
      required bool airborne, String callSign = ""}) {
    final List<int> lat = _semicircles(p.latitude);
    final List<int> lon = _semicircles(p.longitude);
    // altitude in 25 ft steps offset by 1000 ft, 12 bits
    final double altFt = p.altitude * 3.28084;
    final int alt = ((altFt + 1000) / 25).round().clamp(0, 0xFFE);
    // misc: airborne bit 3, track type 1 = true track
    final int misc = (airborne ? 0x08 : 0x00) | 0x01;
    // horizontal velocity in knots, 12 bits; vertical in 64 fpm, 12 bits signed
    final int hv = (p.speed / 0.514444).round().clamp(0, 0xFFE);
    final int vv = (vsFpm / 64).round().clamp(-2047, 2047) & 0xFFF;
    final int trk = ((p.heading % 360) / 1.40625).round() & 0xFF;
    final List<int> name = callSign.toUpperCase().padRight(8).codeUnits.take(8).toList();
    return frame(MessageType.ownShip, [
      0x00, // no alert, ADS-B with ICAO address
      (icao >> 16) & 0xFF, (icao >> 8) & 0xFF, icao & 0xFF,
      ...lat, ...lon,
      (alt >> 4) & 0xFF, ((alt & 0x0F) << 4) | misc,
      0xAA, // NIC 10, NACp 10: a phone's GPS, near enough
      (hv >> 4) & 0xFF, ((hv & 0x0F) << 4) | ((vv >> 8) & 0x0F), vv & 0xFF,
      trk,
      0x01, // emitter category: light aircraft
      ...name,
      0x00,
    ]);
  }

  /// Geometric altitude in 5 ft steps, signed 16 bits, no vertical metrics.
  static Uint8List geometricAltitude(double altitudeM) {
    final int alt = (altitudeM * 3.28084 / 5).round().clamp(-32768, 32767) & 0xFFFF;
    return frame(MessageType.ownShipGeometricAltitude, [
      (alt >> 8) & 0xFF, alt & 0xFF, 0x00, 0x00,
    ]);
  }

  /// Degrees to the 24-bit two's-complement semicircle used for lat/lon.
  static List<int> _semicircles(double degrees) {
    final int v = (degrees * (1 << 23) / 180).round() & 0xFFFFFF;
    return [(v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];
  }
}
