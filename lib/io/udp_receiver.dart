import 'dart:async';

import 'package:avaremp/storage.dart';
import 'package:universal_io/io.dart';

import 'package:avaremp/utils/app_log.dart';

// Get UDP from receivers, handle GDL90
class UdpReceiver {

  final List<RawDatagramSocket> _sockets = [];
  /// Ports with a live socket, or with a bind already in flight. Without this a
  /// second start() would stack another socket on an already-listening port and
  /// every datagram would be delivered (and decoded) twice.
  final Set<int> _boundPorts = {};
  List<int> _ports = [];
  List<bool> _broadcast = [];
  Timer? _rebindTimer;

  Future<void> initChannel(int port, bool broadcast) async {
    if (!_boundPorts.add(port)) {
      return; // already listening, or a bind is already in flight
    }
    try {
      RawDatagramSocket socket = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4, port, reuseAddress: true);
      socket.broadcastEnabled = broadcast;
      socket.listen((e) {
        // Drain the kernel queue: one listen event can signal multiple datagrams.
        // A single receive() drops the rest and corrupts GDL90 byte alignment (bad 0x7E framing → CRC failures).
        while (true) {
          Datagram? dg = socket.receive();
          if (dg == null) {
            break;
          }
          Storage().nmeaBuffer.put(dg.data);
          Storage().gdl90Buffer.put(dg.data);
        }
      },
      onError: (e) {
        AppLog.logMessage("UDP socket error on port $port: $e");
      },
      onDone: () {
        // Socket went away underneath us (interface change, receiver WiFi drop).
        // Release the port so the watchdog below rebinds it.
        _boundPorts.remove(port);
        _sockets.remove(socket);
      });
      _sockets.add(socket);
    }
    catch(e) {
      // Leave the port unbound so the watchdog retries. A bind legitimately
      // fails when the receiver's WiFi is not up yet at launch; previously that
      // left the port dead for the rest of the session with no way back.
      _boundPorts.remove(port);
      AppLog.logMessage("UDP listen error on port $port: $e");
    }
  }

  void start(List<int> ports, List<bool> isBroadcast) {
    _ports = List.from(ports);
    _broadcast = List.from(isBroadcast);
    for(int i = 0; i < _ports.length; i++) {
      initChannel(_ports[i], _broadcast[i]);
    }
    // Watchdog: rebind any port that failed at startup or dropped later. The
    // reception path is meant to stay up for the life of the app, so this keeps
    // running until finish(). Ports already bound short-circuit in initChannel.
    _rebindTimer ??= Timer.periodic(const Duration(seconds: 5), (_) {
      for(int i = 0; i < _ports.length; i++) {
        initChannel(_ports[i], _broadcast[i]);
      }
    });
  }

  void finish() {
    _rebindTimer?.cancel();
    _rebindTimer = null;
    for(RawDatagramSocket socket in _sockets) {
      socket.close();
    }
    // These were never cleared, so repeat stop/start cycles accumulated closed
    // sockets and re-closed them on every subsequent finish().
    _sockets.clear();
    _boundPorts.clear();
  }
}
