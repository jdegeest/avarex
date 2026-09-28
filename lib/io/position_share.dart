import 'dart:async';
import 'dart:math';

import 'package:avaremp/gdl90/gdl90_encoder.dart';
import 'package:avaremp/io/gps.dart';
import 'package:avaremp/storage.dart';
import 'package:avaremp/utils/app_log.dart';
import 'package:flutter/foundation.dart';
import 'package:universal_io/io.dart';

/// Hands this device's GPS fix to every other copy of the app on the local
/// network, so a tablet or desktop with no GPS of its own can fly on a phone's.
///
/// The fix goes out as plain GDL90 -- the frames a Stratux would send -- on
/// the port the app already listens to. The other side needs nothing new: the
/// phone simply shows up there as an ADS-B receiver, and Auto picks it up.
/// Broadcast is the discovery: anyone on the subnet hears it. A Tailscale or
/// other routed peer will not, so one extra unicast address can be named.
///
/// Only this device's own fix is ever shared. A position that itself came
/// from a receiver, the feed or a guess is not re-broadcast, so two sharers
/// can never feed each other's positions round in a loop.
class PositionShare {
  static final PositionShare _instance = PositionShare._();
  factory PositionShare() => _instance;
  PositionShare._();

  /// Standard GDL90 port; the receive side binds it already.
  static const int port = 4000;
  static const Duration _period = Duration(seconds: 1);

  RawDatagramSocket? _socket;
  Timer? _timer;
  int _sent = 0;
  String lastError = "";
  final ValueNotifier<int> change = ValueNotifier<int>(0);

  bool get running => _timer != null;
  /// Frames sent so far this session; the status screen shows it ticking.
  int get sent => _sent;
  /// True while a fix is actually going out, not merely enabled.
  bool get transmitting => running && _shareable;

  /// Addresses in this range are ours, not real aircraft: how a listener
  /// tells a shared phone from a receiver's own ownship.
  static bool isSharedAddress(int icao) => (icao & 0xF00000) == 0xF00000;

  /// The ICAO-style address that marks these frames as ours. Random once per
  /// install and then fixed, so a listener can tell two phones apart, and so
  /// this device can recognise its own frames coming back off the wire.
  int get icao {
    int v = Storage().settings.getShareIcao();
    if (v == 0) {
      // private-use range, never a real aircraft
      v = 0xF00000 | Random.secure().nextInt(0x0FFFFF);
      Storage().settings.setShareIcao(v);
    }
    return v;
  }

  /// What the other side will call this device.
  String get callSign {
    final String name = Storage().settings.getShareName().trim();
    if (name.isNotEmpty) {
      return name;
    }
    if (Platform.isAndroid || Platform.isIOS) {
      return "PHONE";
    }
    try {
      return Platform.localHostname;
    }
    catch (_) {
      return "AVAREX";
    }
  }

  bool get _shareable =>
      Storage().positionInUse == PositionOrigin.internal &&
      !Gps.isPositionCloseToZero(Storage().position);

  /// Start or stop to match the saved setting. Called whenever IO starts and
  /// whenever the setting is toggled.
  void applySetting() {
    if (Storage().settings.getSharePosition()) {
      start();
    }
    else {
      stop();
    }
  }

  Future<void> start() async {
    if (running) {
      return;
    }
    _timer = Timer.periodic(_period, (_) => _tick());
    change.value++;
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _socket?.close();
    _socket = null;
    change.value++;
  }

  /// Where a broadcast has to be aimed to actually reach the LAN. The
  /// limited broadcast (255.255.255.255) follows the default route, and with
  /// a VPN or Tailscale exit node up that route is the tunnel, so the LAN
  /// never hears it. The directed broadcast of each interface's own subnet
  /// (192.168.3.255) rides the interface's connected route instead. The
  /// platform does not expose prefix lengths, so /24 is assumed -- true of
  /// nearly every home and cockpit Wi-Fi.
  Future<List<InternetAddress>> _broadcastTargets() async {
    final Set<String> targets = {"255.255.255.255"};
    try {
      final List<NetworkInterface> ifs =
          await NetworkInterface.list(type: InternetAddressType.IPv4);
      for (final NetworkInterface i in ifs) {
        for (final InternetAddress a in i.addresses) {
          final List<String> o = a.address.split(".");
          if (o.length != 4 || a.isLoopback || o[0] == "100") {
            continue; // 100.x is the tailnet, which carries no broadcasts
          }
          targets.add("${o[0]}.${o[1]}.${o[2]}.255");
        }
      }
    }
    catch (_) {
      // no interface listing on this platform; the limited broadcast remains
    }
    return targets.map(InternetAddress.new).toList();
  }

  Future<void> _tick() async {
    if (!_shareable) {
      return; // nothing of our own to share right now
    }
    try {
      _socket ??= await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0)
        ..broadcastEnabled = true;
      final RawDatagramSocket s = _socket!;
      final Storage st = Storage();
      // No heartbeat: that is a receiver announcing itself, and a phone is
      // not a receiver. The listener keys a shared fix off the ownship's own
      // address instead, so it can never be mistaken for ADS-B.
      final List<List<int>> frames = [
        Gdl90Encoder.ownship(st.position, icao: icao, vsFpm: st.vSpeed,
            airborne: st.airborne, callSign: callSign),
        Gdl90Encoder.geometricAltitude(st.position.altitude),
      ];
      final List<InternetAddress> to = await _broadcastTargets();
      final String extra = st.settings.getShareUnicastHost().trim();
      if (extra.isNotEmpty) {
        try {
          to.add((await InternetAddress.lookup(extra)).first);
        }
        catch (e) {
          lastError = "cannot resolve $extra";
        }
      }
      for (final InternetAddress a in to) {
        for (final List<int> f in frames) {
          s.send(f, a, port);
        }
      }
      _sent++;
      lastError = "";
    }
    catch (e) {
      lastError = e.toString();
      AppLog.logMessage("Position share send error: $e");
      _socket?.close();
      _socket = null; // rebind next tick: the interface may have changed
    }
    change.value++;
  }
}
