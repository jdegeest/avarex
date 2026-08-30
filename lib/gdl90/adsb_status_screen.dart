import 'package:avaremp/gdl90/adsb_status.dart';
import 'package:avaremp/gdl90/ground_station_cache.dart';
import 'package:avaremp/gdl90/stratus_open_mode.dart';
import 'package:avaremp/gdl90/traffic_report_message.dart';
import 'package:avaremp/io/gps.dart';
import 'package:avaremp/io/network_traffic.dart';
import 'package:avaremp/storage.dart';
import 'package:avaremp/utils/geo_calculations.dart';
import 'package:avaremp/utils/toast.dart';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../constants.dart';

/// Full screen showing live ADS-B receiver status (from the GDL90 heartbeat and
/// FIS-B ground uplinks) plus a scrolling log of the last received messages.
/// Tap a message to expand its decoded fields; pause/resume freezes the log.
/// Pushed from the ADSB instrument tile; the AppBar provides the back button.
class AdsbStatusScreen extends StatefulWidget {
  const AdsbStatusScreen({super.key});

  @override
  State<AdsbStatusScreen> createState() => _AdsbStatusScreenState();
}

class _AdsbStatusScreenState extends State<AdsbStatusScreen> {
  final ScrollController _scroll = ScrollController();
  final ScrollController _statusScroll = ScrollController();
  late final TextEditingController _tailController =
      TextEditingController(text: Storage().settings.getNetworkOwnshipTail());

  @override
  void initState() {
    super.initState();
    // Run the log live while the screen is open.
    Storage().adsbStatus.logPaused = false;
  }

  Future<void> _sendStratusOpenMode() async {
    bool ok = await StratusOpenMode.send();
    if (!mounted) {
      return;
    }
    if (ok) {
      Toast.showToast(context, "Sent Stratus Open ADS-B Mode command",
          const Icon(Icons.check, color: Colors.green), 3);
    } else {
      Toast.showToast(context, "Failed to send Stratus Open ADS-B Mode command",
          const Icon(Icons.error, color: Colors.red), 4);
    }
  }

  @override
  void dispose() {
    // Leaving the screen pauses the message log so it stops scrolling/updating.
    Storage().adsbStatus.logPaused = true;
    _scroll.dispose();
    _statusScroll.dispose();
    _tailController.dispose();
    super.dispose();
  }

  /// One line of status. Deliberately not a Card wrapping a dense ListTile: at
  /// roughly 56 px each, the three sections could not be on screen together,
  /// and anything below the fold may as well not exist.
  Widget _row(IconData icon, String title, Color color,
      {String value = "", String? mark, bool bold = false, Widget? trailing}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
      child: Row(
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 8),
          if (mark != null)
            Text("$mark ", style: TextStyle(color: color, fontSize: 11)),
          Expanded(
            child: Text(title,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: bold ? FontWeight.bold : FontWeight.normal)),
          ),
          const SizedBox(width: 8),
          trailing ??
              Text(value, style: TextStyle(color: color, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _statusTile(IconData icon, String title, String value, Color color) =>
      _row(icon, title, color, value: value);

  /// One colour rule for every source row, so "working" looks the same whether
  /// it is a GPS chip, a receiver or a web feed.
  Color _healthColor(SourceHealth h) {
    switch (h) {
      case SourceHealth.absent:
        return Colors.grey;
      case SourceHealth.failed:
        return Colors.red;
      case SourceHealth.idle:
        return Colors.grey;
      case SourceHealth.degraded:
        return Colors.amber;
      case SourceHealth.ok:
        return Colors.green;
    }
  }

  /// One candidate source, describing only itself.
  ///
  /// Two different facts, because in Auto they are not the same one and showing
  /// only eligibility lit both the receiver and this device at once, which said
  /// nothing about which you were actually flying on:
  ///   [inUse]    -- this is the source driving the map right now. Filled dot.
  ///   [eligible] -- the mode permits it, so it can take over. Bold.
  Widget _candidateTile(IconData icon, String title, (String, SourceHealth) status,
      {required bool eligible, required bool inUse}) {
    final (String text, SourceHealth health) = status;
    final Color color = _healthColor(health);
    return _row(icon, title, inUse ? color : color.withValues(alpha: 0.55),
        value: text, bold: eligible, mark: inUse ? "\u25cf" : "\u25cb");
  }

  /// A source selector with every option visible and directly selectable. This
  /// replaced a tile that cycled through the modes and needed a paragraph to
  /// say what the next tap would do; showing the choices says it instead.
  Widget _modeSelector(List<String> modes, String selected, String Function(String) name,
      void Function(String) onSelect) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 2, 14, 4),
      child: SizedBox(
        width: double.infinity,
        child: SegmentedButton<String>(
          showSelectedIcon: false,
          style: const ButtonStyle(
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          segments: [
            for (final String m in modes) ButtonSegment<String>(value: m, label: Text(name(m))),
          ],
          selected: {selected},
          onSelectionChanged: (s) => setState(() => onSelect(s.first)),
        ),
      ),
    );
  }

  /// A group heading, so the three groups do not read as one long list of
  /// near-duplicate rows.
  Widget _sectionHeader(String title, String subtitle) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style:
                  const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.1)),
          Text(subtitle,
              style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.outline)),
        ],
      ),
    );
  }

  Widget _boolTile(IconData icon, String title, bool value) =>
      _row(icon, title, value ? Colors.green : Colors.grey,
          value: value ? "Yes" : "No");

  String _formatTime(DateTime t) {
    String two(int v) => v < 10 ? "0$v" : "$v";
    return "${two(t.hour)}:${two(t.minute)}:${two(t.second)}";
  }

  // Unique color per GDL90 message type. The same colors are used to tint the
  // log rows and to mark each type in the filter list, so the two stay in sync.
  static const Map<int, Color> _typeColors = {
    0x00: Colors.blueGrey, // Heartbeat
    0x07: Colors.teal, // Uplink (FIS-B)
    0x0A: Colors.orange, // Ownship
    0x0B: Colors.deepOrange, // Ownship geo. altitude
    0x14: Colors.blue, // Traffic
    0x1E: Colors.indigo, // Basic report
    0x1F: Colors.cyan, // Long report
    0x4C: Colors.green, // AHRS
    0x7A: Colors.brown, // Device
    0xCC: Colors.purple, // Roll reverse
  };

  // Color for a message type; unknown/unlisted types fall back to grey.
  Color _typeColor(int typeId) => _typeColors[typeId] ?? Colors.grey;

  // Small filled swatch used to mark a message type's color in the filter list.
  Widget _swatch(Color color) {
    return Container(
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        border: Border.all(color: color, width: 2),
        borderRadius: BorderRadius.circular(4),
      ),
    );
  }

  // List of the ground stations currently being received, with distance and
  // bearing from ownship (nearest first). Empty when none are heard.
  Widget _stationList(AdsbStatus s) {
    final List<GroundStation> stations = s.groundStations();
    if (stations.isEmpty) {
      return const SizedBox.shrink();
    }
    final pos = Storage().position;
    final bool havePos = !(pos.latitude == 0 && pos.longitude == 0);
    final LatLng here = LatLng(pos.latitude, pos.longitude);
    final GeoCalculations geo = GeoCalculations();
    final String unit = Storage().settings.getUnits() == "Imperial" ? "sm" : "nm";

    // pair each station with distance/bearing from ownship (null if no fix)
    final List<(GroundStation, double?, double?)> entries = stations.map((st) {
      final double? dist = havePos ? geo.calculateDistance(here, st.coordinates) : null;
      final double? brg = havePos ? geo.calculateBearing(here, st.coordinates) : null;
      return (st, dist, brg);
    }).toList();
    if (havePos) {
      entries.sort((a, b) => (a.$2 ?? 0).compareTo(b.$2 ?? 0));
    }

    return Column(
      children: [for (final e in entries) _stationTile(e.$1, e.$2, e.$3, unit)],
    );
  }

  // One ground-station row: identity (TIS-B site / slot), distance+bearing from
  // ownship, position, and how long ago it was last heard.
  Widget _stationTile(GroundStation st, double? dist, double? brg, String unit) {
    final int agoS = ((DateTime.now().millisecondsSinceEpoch - st.lastSeenMs) / 1000).floor();
    final String name = st.tisbSiteId > 0 ? "TIS-B site ${st.tisbSiteId}" : "Ground station";
    final String db = (dist != null && brg != null)
        ? "${dist.toStringAsFixed(1)} $unit \u2022 ${brg.toStringAsFixed(0)}\u00b0"
        : "position unknown";
    final String coords =
        "${st.coordinates.latitude.toStringAsFixed(3)}\u00b0, ${st.coordinates.longitude.toStringAsFixed(3)}\u00b0";
    return Card(
      margin: const EdgeInsets.fromLTRB(24, 0, 8, 4),
      child: ListTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        leading: const Icon(Icons.cell_tower, size: 20),
        title: Text("$name \u2022 slot ${st.slotId}"),
        subtitle: Text("$db\n$coords"),
        isThreeLine: true,
        trailing: Text("${agoS}s"),
      ),
    );
  }

  // Diagnostics: reception-quality counters to help debug ADS-B issues.
  // Collapsed by default so it doesn't crowd the status tiles.
  Widget _diagnostics(AdsbStatus s) {
    final int tracked = Storage().trafficCache.getTraffic().length;
    // Fixed set/order of stats so nothing reflows as values update each second.
    final List<Widget> cells = [
      _diagCell("Msgs", "${s.totalMessages}"),
      _diagCell("Rate", "${s.messagesPerSecond.toStringAsFixed(1)}/s"),
      _diagCell("Heartbeat", "${s.typeCount(0x00)}"),
      _diagCell("HB seen", _ago(s.secondsSinceHeartbeat)),
      _diagCell("HB up/traf", "${s.lastUplinkCount}/${s.lastTrafficCount}"),
      _diagCell("Uplink", "${s.typeCount(0x07)}"),
      _diagCell("Ownship", "${s.typeCount(0x0A)}"),
      _diagCell("Ownship seen", _ago(s.secondsSinceOwnship)),
      _diagCell("Traffic", "${s.trafficMessageCount}"),
      _diagCell("Traffic seen", _ago(s.secondsSinceTraffic)),
      _diagCell("Tracked", "$tracked"),
      _diagCell("AHRS", "${s.typeCount(0x4C)}"),
      _diagCell("Filt own", "${s.filteredOwnshipCount}"),
      _diagCell("Filt range", "${s.filteredRangeCount}"),
      _diagCell("CRC err", "${s.crcErrors}", warn: true),
      _diagCell("Frame err", "${s.frameErrors}", warn: true),
      _diagCell("Parse err", "${s.parseErrors}", warn: true),
    ];
    // Lay out cells in a stable two-column grid.
    final List<Widget> rows = [];
    for (int i = 0; i < cells.length; i += 2) {
      rows.add(Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          cells[i],
          const SizedBox(width: 16),
          i + 1 < cells.length ? cells[i + 1] : const Expanded(child: SizedBox()),
        ],
      ));
    }
    return Card(
      child: ExpansionTile(
        dense: true,
        leading: const Icon(Icons.analytics_outlined),
        title: const Text("Diagnostics"),
        subtitle: Text("${s.totalMessages} messages received"),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => Storage().adsbStatus.resetDiagnostics(),
              icon: const Icon(Icons.restart_alt, size: 18),
              label: const Text("Reset"),
            ),
          ),
          ...rows,
        ],
      ),
    );
  }

  // "Ns" since an event, or "—" when it has never occurred.
  String _ago(int seconds) => seconds < 0 ? "\u2014" : "${seconds}s";

  // One label/value stat occupying a fixed half-width cell. The label is left-
  // aligned and the value right-aligned, so changing values never shift the
  // layout. When [warn] is set and the value is non-zero it turns red.
  Widget _diagCell(String label, String value, {bool warn = false}) {
    final bool alert = warn && value != "0";
    final Color? color = alert ? Colors.red : null;
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Expanded(
              child: Text(label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
            ),
            const SizedBox(width: 6),
            Text(value,
                style: TextStyle(
                    fontSize: 12,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: color)),
          ],
        ),
      ),
    );
  }

  void _showFilters() {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final AdsbStatus s = Storage().adsbStatus;
            return SafeArea(
              child: ListView(
                shrinkWrap: true,
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child:
                        Text("Show message types", style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  for (final entry in AdsbStatus.filterTypes.entries)
                    CheckboxListTile(
                      dense: true,
                      secondary: _swatch(_typeColor(entry.key)),
                      title: Text(entry.value),
                      value: s.enabledTypes.contains(entry.key),
                      onChanged: (v) {
                        s.setTypeEnabled(entry.key, v ?? false);
                        setSheetState(() {});
                      },
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // Two tabs rather than one split screen. The status sections and the
    // message log were sharing the height 55/45, which left the traffic and
    // receiver settings below the fold with no sign they were there.
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: Constants.appBarBackgroundColor,
          title: const Text("ADS-B Status"),
          actions: [
            IconButton(
              icon: const Icon(Icons.wifi_tethering),
              tooltip: "Stratus Open ADS-B Mode \u2014 send once while on Stratus Wi-Fi",
              onPressed: _sendStratusOpenMode,
            ),
            const SizedBox(width: 10),
          ],
          bottom: const TabBar(tabs: [
            Tab(text: "Status"),
            Tab(text: "Messages"),
          ]),
        ),
        body: TabBarView(children: [
          SingleChildScrollView(
            child: AnimatedBuilder(
                  animation: Listenable.merge([Storage().timeChange, Storage().adsbStatus.change]),
                  builder: (context, _) {
                    final AdsbStatus s = Storage().adsbStatus;
                    final Color connColor =
                        !s.connected ? Colors.grey : (!s.gpsValid ? Colors.amber : Colors.green);
                    return Column(
                      children: [
                        _sectionHeader("POSITION", "driving the aircraft symbol"),
                        _modeSelector(
                          Storage.gpsSourceModes,
                          Storage().gpsSourceMode,
                          Storage.gpsSourceModeName,
                          (m) => Storage().selectGpsSourceMode(m),
                        ),
                        // Every candidate, each describing only itself, with the
                        // selected one marked. The same hardware used to be
                        // described from three different angles in three tiles
                        // that were free to disagree with each other.
                        _candidateTile(
                            Icons.smartphone,
                            "This device's GPS",
                            Storage().deviceGpsHealth,
                            eligible: Storage().acceptsPositionFrom(PositionOrigin.internal),
                            inUse: Storage().positionInUse == PositionOrigin.internal),
                        _candidateTile(
                            Icons.settings_input_antenna,
                            "ADS-B receiver",
                            Storage().receiverPositionHealth,
                            eligible: Storage().acceptsPositionFrom(PositionOrigin.external),
                            inUse: Storage().positionInUse == PositionOrigin.external),
                        _candidateTile(
                            Icons.cloud_outlined,
                            "Internet feed",
                            Storage().feedPositionHealth,
                            eligible: Storage().acceptsPositionFrom(PositionOrigin.network),
                            inUse: Storage().positionInUse == PositionOrigin.network),
                        // The answer to "where is my position actually coming
                        // from", in one sentence -- including when the honest
                        // answer is that it is not coming from anywhere any more.
                        _row(
                            Icons.place_outlined,
                            Gps.isPositionCloseToZero(Storage().position)
                                ? "No position"
                                : "${Storage().position.latitude.toStringAsFixed(4)}, "
                                    "${Storage().position.longitude.toStringAsFixed(4)}"
                                    "   ${(Storage().position.altitude * Storage().units.mToF).round()} ft",
                            Storage().positionIsLive
                                ? Colors.green
                                : (Storage().positionIsFrozen ? Colors.amber : Colors.grey),
                            value: Storage().positionProvenanceShort,
                            bold: true),

                        _sectionHeader("TRAFFIC", "targets on the map"),
                        _modeSelector(
                          Storage.trafficSourceModes,
                          Storage().trafficSourceMode,
                          Storage.trafficSourceModeName,
                          (m) => Storage().selectTrafficSourceMode(m),
                        ),
                        _candidateTile(Icons.settings_input_antenna, "ADS-B receiver",
                            Storage().receiverTrafficHealth,
                            eligible: Storage().usesReceiverTraffic,
                            inUse: Storage().usesReceiverTraffic &&
                                Storage().adsbStatus.trafficFresh),
                        _candidateTile(Icons.cloud_outlined, "Internet feed",
                            Storage().feedTrafficHealth,
                            eligible: Storage().usesNetworkTraffic,
                            inUse: Storage().usesNetworkTraffic &&
                                NetworkTraffic().healthy),
                        // Fly-as belongs with the feed: it is the one setting that
                        // turns feed traffic into a position.
                        if (Storage().needsNetworkFeed)
                          _row(Icons.badge_outlined, "Fly as", Colors.orange,
                              trailing: SizedBox(
                                width: 110,
                                height: 30,
                                child: TextField(
                                  controller: _tailController,
                                  textCapitalization: TextCapitalization.characters,
                                  style: const TextStyle(fontSize: 13),
                                  decoration: const InputDecoration(
                                    hintText: "N719CG",
                                    isDense: true,
                                    contentPadding: EdgeInsets.symmetric(vertical: 6),
                                  ),
                                  onChanged: (v) {
                                    Storage()
                                        .settings
                                        .setNetworkOwnshipTail(v.trim().toUpperCase());
                                    // Drop the old aircraft immediately rather
                                    // than letting its last position sit there
                                    // wearing the new tail number.
                                    Storage().clearNetworkOwnship();
                                  },
                                ),
                              )),

                        _sectionHeader("RECEIVER", "link health"),
                        _statusTile(
                          Icons.settings_input_antenna,
                          "Connection",
                          s.connected ? "Connected" : "Disconnected",
                          connColor,
                        ),
                        _statusTile(
                          Icons.favorite,
                          "Last heartbeat",
                          s.secondsSinceHeartbeat < 0 ? "never" : "${s.secondsSinceHeartbeat}s ago",
                          s.connected ? Colors.green : Colors.red,
                        ),
                        _boolTile(Icons.access_time, "UTC timing OK", s.utcOk),
                        _boolTile(Icons.power_settings_new, "UAT initialized", s.uatInitialized),
                        _statusTile(
                          Icons.cell_tower,
                          "Ground stations received",
                          "${s.towerCount}",
                          s.towerCount > 0 ? Colors.green : Colors.grey,
                        ),
                        _stationList(s),
                        _diagnostics(s),
                      ],
                    );
                  },
                ),
          ),
          Column(children: [
          // Messages header with pause/resume
          AnimatedBuilder(
            animation: Storage().adsbStatus.logChange,
            builder: (context, _) {
              final bool paused = Storage().adsbStatus.logPaused;
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
                child: Row(
                  children: [
                    const Text("Messages (last 50)", style: TextStyle(fontWeight: FontWeight.bold)),
                    const Spacer(),
                    IconButton(
                      tooltip: "Filter types",
                      onPressed: _showFilters,
                      icon: const Icon(Icons.filter_list),
                    ),
                    TextButton.icon(
                      onPressed: () => Storage().adsbStatus.toggleLogPaused(),
                      icon: Icon(paused ? Icons.play_arrow : Icons.pause),
                      label: Text(paused ? "Resume" : "Pause"),
                    ),
                  ],
                ),
              );
            },
          ),
          // Scrolling message list, newest first; tap to expand decoded fields
          Expanded(
            child: AnimatedBuilder(
              animation: Storage().adsbStatus.logChange,
              builder: (context, _) {
                final List<AdsbLogEntry> msgs = Storage().adsbStatus.messages();
                if (msgs.isEmpty) {
                  return const Center(child: Text("No messages received"));
                }
                return ListView.builder(
                  controller: _scroll,
                  itemCount: msgs.length,
                  itemBuilder: (context, i) {
                    final AdsbLogEntry m = msgs[i];
                    // Each message type has its own color (matching the filter
                    // list). Any traffic filtering is noted as a text tag.
                    final Color accent = _typeColor(m.typeId);
                    final Color tileColor = accent.withValues(alpha: 0.14);
                    final String? filterTag = switch (m.filter) {
                      TrafficFilter.ownship => "filtered: ownship",
                      TrafficFilter.range => "filtered: altitude",
                      TrafficFilter.duplicate => "filtered: duplicate",
                      TrafficFilter.none => null,
                    };
                    final String titleText = [
                      m.type,
                      if (m.summary.isNotEmpty) m.summary,
                      if (filterTag != null) filterTag,
                    ].join("  \u2014  ");
                    return ExpansionTile(
                      key: ValueKey(m),
                      dense: true,
                      backgroundColor: tileColor,
                      collapsedBackgroundColor: tileColor,
                      iconColor: accent,
                      collapsedIconColor: accent,
                      title: Text(
                        titleText,
                        style: TextStyle(color: accent, fontWeight: FontWeight.bold),
                      ),
                      subtitle: Text(
                        _formatTime(m.time),
                        style: TextStyle(color: accent.withValues(alpha: 0.8)),
                      ),
                      children: [
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                m.decoded.isEmpty ? "No decode available" : m.decoded,
                                style: const TextStyle(fontFamily: "monospace"),
                              ),
                              const SizedBox(height: 8),
                              const Text("Raw bytes:",
                                  style: TextStyle(fontWeight: FontWeight.bold)),
                              SelectableText(
                                m.raw.isEmpty ? "-" : m.raw,
                                style: const TextStyle(fontFamily: "monospace", fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                );
              },
            ),
          ),
          ]),
        ]),
      ),
    );
  }
}
