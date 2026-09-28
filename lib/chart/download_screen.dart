import 'dart:async';

import 'package:avaremp/utils/faa_dates.dart';
import 'package:avaremp/utils/path_utils.dart';
import 'package:avaremp/storage.dart';
import 'package:avaremp/utils/toast.dart';
import 'package:flutter/material.dart';
import 'package:universal_io/io.dart';
import 'chart.dart';
import '../constants.dart';
import 'download.dart';
import 'download_manager.dart';


const int _stateAbsent = 0;
const int _stateCurrent = 1;
const int _stateExpired = 2;

const Color _absentColor = Constants.chartAbsentColor;
const Color _currentColor = Constants.chartCurrentColor;
const Color _expiredColor = Constants.chartExpiredColor;

const IconData _absentIcon = Icons.cloud_download_outlined;
const IconData _downloadedIcon = Icons.check_circle;
const IconData _expiredIcon = Icons.error;

// Chart types every region should have; offered as one "essentials" download.
const List<String> _essentialSuffixes = ["SEC", "TPP", "CSUP"];

class _Region {
  final String code; // e.g. "nc", also the lowercase filename prefix
  final String name;
  const _Region(this.code, this.name);
}

class DownloadScreen extends StatefulWidget {
  const DownloadScreen({super.key});
  @override
  DownloadScreenState createState() => DownloadScreenState();
}

class DownloadScreenState extends State<DownloadScreen> {

  bool _nextCycle = false;
  bool _backupServer = false;
  String _region = "";
  String _gpsRegion = "";
  int? _freeBytes;

  // Download sizes by "filename|nextCycle|backupServer"; null = unknown.
  static final Map<String, int?> _sizes = {};

  DownloadManager get _manager => Storage().downloadManager;

  @override
  void initState() {
    super.initState();
    _manager.addListener(_onJobsChanged);
    _manager.downloads.addListener(_refreshAll);
    _gpsRegion = _currentRegion();
    _region = _gpsRegion.isNotEmpty ? _gpsRegion : _regions.first.code;
    _refreshAll().then((_) {
      // with no GPS region, open on a region that has something installed
      if (_gpsRegion.isEmpty && mounted) {
        for (_Region r in _regions) {
          if (_chartsIn(r.code).any((c) => c.state != _stateAbsent)) {
            setState(() => _region = r.code);
            break;
          }
        }
      }
      _fetchSizes();
    });
    _removePartialDownloads();
    _updateFreeSpace();
  }

  @override
  void dispose() {
    _manager.removeListener(_onJobsChanged);
    _manager.downloads.removeListener(_refreshAll);
    super.dispose();
  }

  void _onJobsChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  // ---------------------------------------------------------------- data

  static List<_Region> get _regions => _allCharts
      .firstWhere((cg) => cg.title == ChartCategory.sectional)
      .charts
      .map((c) => _Region(_prefix(c).toLowerCase(), c.name))
      .toList();

  static String _prefix(Chart c) => c.filename.split("_").first;

  static String _suffix(Chart c) => c.filename.substring(c.filename.indexOf("_") + 1);

  static List<Chart> _chartsIn(String region) {
    final String prefix = "${region.toUpperCase()}_";
    return [
      for (ChartCategory cg in _allCharts)
        for (Chart c in cg.charts)
          if (c.filename.startsWith(prefix)) c
    ];
  }

  static String _categoryOf(Chart chart) {
    for (ChartCategory cg in _allCharts) {
      if (cg.charts.contains(chart)) {
        return cg.title;
      }
    }
    return "";
  }

  static String _regionNameOf(Chart chart) {
    final String code = _prefix(chart).toLowerCase();
    for (_Region r in _regions) {
      if (r.code == code) {
        return r.name;
      }
    }
    return "";
  }

  static String _labelOf(Chart chart) {
    if (chart == getDatabasesChart()) {
      return "Databases";
    }
    return "${_regionNameOf(chart)} · ${_categoryOf(chart)}";
  }

  static Iterable<Chart> get _everyChart sync* {
    for (ChartCategory cg in _allCharts) {
      yield* cg.charts;
    }
  }

  String _currentRegion() {
    double? lat;
    double? lon;
    try {
      lat = Storage().position.latitude;
      lon = Storage().position.longitude;
    }
    catch (e) {
      lat = null;
    }
    try {
      if (lat == null || lon == null || (lat == 0 && lon == 0)) {
        lat = Storage().settings.getCenterLatitude();
        lon = Storage().settings.getCenterLongitude();
      }
      return Chart.getChartRegionFromLocation(lat, lon);
    }
    catch (e) {
      return "";
    }
  }

  Future<void> _refreshAll() async {
    await Future.wait(_everyChart.map(_readChartState));
    if (mounted) {
      setState(() {});
    }
    _updateFreeSpace();
  }

  Future<void> _readChartState(Chart chart) async {
    final String cycle = await Download.getChartCycleLocal(chart);
    final bool expired = await Download.isChartExpired(chart);
    if (cycle.isEmpty) {
      chart.state = _stateAbsent;
      chart.icon = _absentIcon;
      chart.color = _absentColor;
    }
    else {
      chart.state = expired ? _stateExpired : _stateCurrent;
      chart.icon = expired ? _expiredIcon : _downloadedIcon;
      chart.color = expired ? _expiredColor : _currentColor;
    }
    if (!_manager.isBusy(chart)) {
      chart.subtitle = cycle.isEmpty ? "" : "$cycle ${FaaDates.getVersionRange(cycle)}";
    }
  }

  String _sizeKey(Chart c) => "${c.filename}|$_nextCycle|$_backupServer";

  // Look up download sizes for the charts shown in the selected region.
  Future<void> _fetchSizes() async {
    final List<Chart> charts = [
      getDatabasesChart(),
      if (_region.isNotEmpty) ..._chartsIn(_region),
    ].where((c) => !_sizes.containsKey(_sizeKey(c))).toList();
    await Future.wait(charts.map((c) async {
      final String key = _sizeKey(c);
      _sizes[key] = await Download.getRemoteSize(c, _nextCycle, _backupServer);
    }));
    if (mounted) {
      setState(() {});
    }
  }

  // Zips left behind when the app was closed mid-download.
  Future<void> _removePartialDownloads() async {
    final String dir = Storage().dataDir;
    for (Chart c in _everyChart) {
      if (_manager.isBusy(c)) {
        continue;
      }
      final File zip = File(PathUtils.getLocalFilePath(dir, c.filename));
      try {
        if (await zip.exists()) {
          await zip.delete();
        }
      }
      catch (e) {
        // leave it; retried next time the screen opens
      }
    }
  }

  Future<void> _updateFreeSpace() async {
    if (!(Platform.isLinux || Platform.isMacOS)) {
      return; // no portable free-space query on mobile
    }
    try {
      final ProcessResult r = await Process.run("df", ["-Pk", Storage().dataDir]);
      final List<String> lines = (r.stdout as String).trim().split("\n");
      final List<String> cols = lines.last.split(RegExp(r"\s+"));
      final int? kb = int.tryParse(cols[3]);
      if (kb != null && mounted) {
        setState(() => _freeBytes = kb * 1024);
      }
    }
    catch (e) {
      // unknown
    }
  }

  static String _formatBytes(num bytes) {
    if (bytes >= 1 << 30) {
      return "${(bytes / (1 << 30)).toStringAsFixed(1)} GB";
    }
    if (bytes >= 1 << 20) {
      return "${(bytes / (1 << 20)).toStringAsFixed(bytes >= 100 << 20 ? 0 : 1)} MB";
    }
    return "${(bytes / 1024).toStringAsFixed(0)} KB";
  }

  static String _formatDuration(double seconds) {
    if (seconds < 60) {
      return "${seconds.ceil()} s";
    }
    if (seconds < 3600) {
      return "${(seconds / 60).ceil()} min";
    }
    return "${(seconds / 3600).toStringAsFixed(1)} h";
  }

  // ---------------------------------------------------------------- actions

  void _startDownload(Chart chart) {
    _manager.download(chart, _nextCycle, _backupServer, update: chart.state == _stateExpired);
  }

  Future<void> _confirmDelete(Chart chart) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text("Delete ${_labelOf(chart)}?"),
        content: const Text("It can be downloaded again later."),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text("Cancel")),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text("Delete")),
        ],
      ),
    );
    if (ok == true) {
      _manager.delete(chart);
    }
  }

  void _downloadMany(Iterable<Chart> charts) {
    int count = 0;
    for (Chart c in charts) {
      if (!_manager.isBusy(c)) {
        _startDownload(c);
        count++;
      }
    }
    if (count > 0 && mounted) {
      Toast.showToast(context, "Queued $count item${count == 1 ? '' : 's'}", null, 2);
    }
  }

  void _setNextCycle(bool v) {
    setState(() => _nextCycle = v);
    _fetchSizes();
  }

  void _setBackupServer(bool v) {
    setState(() => _backupServer = v);
    _fetchSizes();
  }

  void _selectRegion(String code) {
    setState(() => _region = code);
    _fetchSizes();
  }

  void _showMap() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return Dialog.fullscreen(
          child: Container(
            color: Colors.black,
            child: Stack(
              children: [
                Center(child: InteractiveViewer(child: Image.asset('assets/images/regions.png'))),
                Align(alignment: Alignment.topRight, child: IconButton(icon: const Icon(Icons.close, size: 36), onPressed: () {Navigator.of(context).pop();}))
              ]
            ),
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final List<DownloadJob> jobs = _manager.jobs;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Constants.appBarBackgroundColor,
        title: const Text("Downloads"),
        actions: [
          IconButton(
            icon: const Icon(Icons.map_outlined),
            tooltip: "Regions map",
            onPressed: _showMap,
          ),
          PopupMenuButton<String>(
            tooltip: "Download options",
            onSelected: (v) {
              if (v == "cycle") {
                _setNextCycle(!_nextCycle);
              }
              else if (v == "server") {
                _setBackupServer(!_backupServer);
              }
            },
            itemBuilder: (context) => [
              CheckedPopupMenuItem(value: "cycle", checked: _nextCycle, child: const Text("Download next cycle")),
              CheckedPopupMenuItem(value: "server", checked: _backupServer, child: const Text("Use backup server")),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        children: [
          if (_nextCycle || _backupServer) _buildOptionsNotice(),
          _buildExpiredBanner(),
          _buildDatabasesCard(),
          if (jobs.isNotEmpty) _buildJobsCard(jobs),
          _buildRegionPicker(),
          if (_region.isNotEmpty) _buildRegionCard(),
          _buildFooter(),
        ],
      ),
    );
  }

  Widget _buildOptionsNotice() {
    final List<String> parts = [
      if (_nextCycle) "next cycle",
      if (_backupServer) "backup server",
    ];
    return Card(
      color: Theme.of(context).colorScheme.tertiaryContainer,
      child: ListTile(
        dense: true,
        leading: const Icon(Icons.tune),
        title: Text("Downloading from ${parts.join(' and ')}"),
        trailing: TextButton(
          onPressed: () {
            _setNextCycle(false);
            _setBackupServer(false);
          },
          child: const Text("Reset"),
        ),
      ),
    );
  }

  Widget _buildExpiredBanner() {
    final List<Chart> expired = _everyChart
        .where((c) => c.state == _stateExpired && !_manager.isBusy(c))
        .toList();
    if (expired.isEmpty) {
      return const SizedBox.shrink();
    }
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Card(
      color: cs.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Row(
          children: [
            Icon(Icons.warning_amber, color: cs.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                "${expired.length} item${expired.length == 1 ? ' is' : 's are'} out of date",
                style: TextStyle(color: cs.onErrorContainer, fontWeight: FontWeight.w600),
              ),
            ),
            FilledButton(
              onPressed: () => _downloadMany(expired),
              child: const Text("Update all"),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDatabasesCard() {
    final Chart db = getDatabasesChart();
    final bool missing = db.state == _stateAbsent;
    return Card(
      child: _buildChartRow(
        db,
        title: "Databases",
        hint: missing ? "Required: airports, navaids and more" : null,
      ),
    );
  }

  Widget _buildJobsCard(List<DownloadJob> jobs) {
    final int running = jobs.where((j) => j.active).length;
    final int queued = jobs.where((j) => j.phase == DownloadJobPhase.queued).length;
    final int failed = jobs.where((j) => j.phase == DownloadJobPhase.failed).length;
    final List<String> parts = [
      if (running > 0) "$running running",
      if (queued > 0) "$queued queued",
      if (failed > 0) "$failed failed",
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
              child: Row(
                children: [
                  const Icon(Icons.downloading, size: 20),
                  const SizedBox(width: 8),
                  const Text("Activity", style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(parts.join(" · "),
                        style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.outline)),
                  ),
                  if (queued > 0)
                    TextButton(
                      onPressed: () {
                        for (DownloadJob j in jobs.where((j) => j.phase == DownloadJobPhase.queued)) {
                          _manager.cancel(j.chart);
                        }
                      },
                      child: const Text("Clear queue"),
                    ),
                ],
              ),
            ),
            for (DownloadJob j in jobs) _buildJobRow(j),
          ],
        ),
      ),
    );
  }

  Widget _buildJobRow(DownloadJob job) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final int p = job.chart.progress.value;
    String status;
    double? bar;
    switch (job.phase) {
      case DownloadJobPhase.queued:
        status = job.kind == DownloadJobKind.delete ? "Waiting to uninstall" : "Waiting";
        bar = 0;
        break;
      case DownloadJobPhase.starting:
        status = "Connecting…";
        bar = null;
        break;
      case DownloadJobPhase.downloading:
        if (job.totalBytes > 0) {
          status = "${_formatBytes(job.downloadedBytes)} of ${_formatBytes(job.totalBytes)}";
          bar = job.downloadedBytes / job.totalBytes;
        }
        else {
          status = _formatBytes(job.downloadedBytes);
          bar = null;
        }
        if (job.bytesPerSecond > 0) {
          status += " · ${_formatBytes(job.bytesPerSecond)}/s";
          if (job.totalBytes > 0) {
            status += " · ${_formatDuration((job.totalBytes - job.downloadedBytes) / job.bytesPerSecond)} left";
          }
        }
        break;
      case DownloadJobPhase.installing:
        status = "Installing…";
        bar = ((p - 50) / 50).clamp(0.0, 1.0);
        break;
      case DownloadJobPhase.deleting:
        status = "Uninstalling…";
        bar = (p / 100).clamp(0.0, 1.0);
        break;
      case DownloadJobPhase.failed:
        status = job.error ?? "Failed";
        bar = null;
        break;
    }
    final bool failed = job.phase == DownloadJobPhase.failed;
    final String verb = switch (job.kind) {
      DownloadJobKind.download => "",
      DownloadJobKind.update => "Update · ",
      DownloadJobKind.delete => "Delete · ",
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 4, 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("$verb${_labelOf(job.chart)}", style: const TextStyle(fontWeight: FontWeight.w500)),
                const SizedBox(height: 4),
                if (!failed)
                  LinearProgressIndicator(
                    value: bar,
                    minHeight: 4,
                    borderRadius: BorderRadius.circular(2),
                    backgroundColor: cs.surfaceContainerHighest,
                  ),
                const SizedBox(height: 4),
                Text(status, style: TextStyle(fontSize: 12, color: failed ? cs.error : cs.outline)),
              ],
            ),
          ),
          if (failed) ...[
            IconButton(icon: const Icon(Icons.refresh), tooltip: "Retry", onPressed: () => _manager.retry(job)),
            IconButton(icon: const Icon(Icons.close), tooltip: "Dismiss", onPressed: () => _manager.dismiss(job)),
          ]
          else
            IconButton(icon: const Icon(Icons.close), tooltip: "Cancel", onPressed: () => _manager.cancel(job.chart)),
        ],
      ),
    );
  }

  Color _regionColor(String code) {
    final List<Chart> charts = _chartsIn(code);
    if (charts.any((c) => c.state == _stateExpired)) {
      return _expiredColor;
    }
    if (charts.any((c) => c.state == _stateCurrent)) {
      return _currentColor;
    }
    return _absentColor;
  }

  Widget _buildRegionPicker() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("Regions", style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (_Region r in _regions)
                ChoiceChip(
                  showCheckmark: false,
                  selected: r.code == _region,
                  onSelected: (_) => _selectRegion(r.code),
                  avatar: r.code == _gpsRegion
                      ? const Icon(Icons.my_location, size: 16)
                      : Icon(Icons.circle, size: 10, color: _regionColor(r.code)),
                  label: Text(r.name),
                  tooltip: r.code == _gpsRegion ? "Your current region" : null,
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRegionCard() {
    final List<Chart> charts = _chartsIn(_region);
    final String name = _regions.firstWhere((r) => r.code == _region).name;
    final int installed = charts.where((c) => c.state != _stateAbsent).length;
    final List<Chart> essentials = charts
        .where((c) => _essentialSuffixes.contains(_suffix(c)) && c.state != _stateCurrent)
        .toList();
    final List<Chart> expired = charts.where((c) => c.state == _stateExpired).toList();
    final List<Chart> pending = [...essentials, ...expired.where((c) => !essentials.contains(c))]
        .where((c) => !_manager.isBusy(c))
        .toList();
    final bool onlyUpdates = pending.every((c) => c.state == _stateExpired);
    int? pendingSize = 0;
    for (Chart c in pending) {
      final int? s = _sizes[_sizeKey(c)];
      pendingSize = (s == null || pendingSize == null) ? null : pendingSize + s;
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 12, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(name, style: Theme.of(context).textTheme.titleMedium),
                        Text("$installed of ${charts.length} installed",
                            style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.outline)),
                      ],
                    ),
                  ),
                  if (pending.isNotEmpty)
                    FilledButton.tonalIcon(
                      icon: const Icon(Icons.download, size: 18),
                      onPressed: () => _downloadMany(pending),
                      label: Text("${onlyUpdates ? 'Update ${pending.length}' : 'Get essentials'}"
                          "${pendingSize != null && pendingSize > 0 ? ' (${_formatBytes(pendingSize)})' : ''}"),
                    ),
                ],
              ),
            ),
            if (pending.isNotEmpty && !onlyUpdates)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: Text("Essentials: Sectional, Plates and CSUP, plus anything out of date",
                    style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.outline)),
              ),
            const Divider(height: 8),
            for (Chart c in charts) _buildChartRow(c, title: _categoryOf(c)),
          ],
        ),
      ),
    );
  }

  Widget _buildChartRow(Chart chart, {required String title, String? hint}) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final DownloadJob? job = _manager.jobFor(chart);
    final bool busy = job != null && job.phase != DownloadJobPhase.failed;
    final int? size = _sizes[_sizeKey(chart)];

    String status;
    Color statusColor;
    if (job != null && job.phase == DownloadJobPhase.failed) {
      status = job.error ?? "Failed";
      statusColor = cs.error;
    }
    else if (busy) {
      status = job.phase == DownloadJobPhase.queued ? "Waiting" : chart.subtitle;
      statusColor = cs.primary;
    }
    else if (chart.state == _stateAbsent) {
      status = hint ?? "Not installed${size != null ? ' · ${_formatBytes(size)}' : ''}";
      statusColor = cs.outline;
    }
    else if (chart.state == _stateExpired) {
      status = "Out of date · ${chart.subtitle}";
      statusColor = _expiredColor;
    }
    else {
      status = chart.check ? chart.subtitle : "Installed";
      statusColor = _currentColor;
    }

    final List<Widget> actions = [];
    if (busy) {
      final int p = chart.progress.value;
      actions.add(SizedBox(
        width: 40,
        height: 40,
        child: Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                value: job.phase == DownloadJobPhase.queued ? 0 : (p <= 1 ? null : p / 100),
                strokeWidth: 3,
                backgroundColor: cs.outlineVariant,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 14),
              tooltip: "Cancel",
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              onPressed: () => _manager.cancel(chart),
            ),
          ],
        ),
      ));
    }
    else if (job != null) {
      actions.add(IconButton(icon: const Icon(Icons.refresh), tooltip: "Retry", onPressed: () => _manager.retry(job)));
    }
    else {
      if (chart.state == _stateAbsent) {
        actions.add(IconButton(icon: const Icon(Icons.download), tooltip: "Download", onPressed: () => _startDownload(chart)));
      }
      else if (chart.state == _stateExpired) {
        actions.add(IconButton(icon: const Icon(Icons.sync), tooltip: "Update", color: _expiredColor, onPressed: () => _startDownload(chart)));
      }
      if (chart.state != _stateAbsent) {
        actions.add(IconButton(icon: const Icon(Icons.delete_outline), tooltip: "Delete", onPressed: () => _confirmDelete(chart)));
      }
    }

    return ListTile(
      dense: true,
      leading: Icon(busy ? Icons.downloading : chart.icon, color: busy ? cs.primary : chart.color),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w500)),
      subtitle: Text(status, style: TextStyle(fontSize: 11, color: statusColor)),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: actions),
    );
  }

  Widget _buildFooter() {
    final List<String> parts = [
      if (_freeBytes != null) "${_formatBytes(_freeBytes!)} free",
      "Up to ${DownloadManager.maxConcurrent} downloads at once",
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
      child: Text(parts.join(" · "),
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.outline)),
    );
  }

  // ---------------------------------------------------------------- static API used elsewhere

  static Future<bool> isAnyChartExpired() async {

    for(ChartCategory cg in _allCharts) {
      for(Chart chart in cg.charts) {
        if(await Download.isChartExpired(chart)) {
          return true;
        }
      }
    }
    return false;
  }

  static Future<bool> doesAnyChartExists() async {

    for(ChartCategory cg in _allCharts) {
      for(Chart chart in cg.charts) {
        bool exists = (await Download.getChartCycleLocal(chart)).isNotEmpty;
        if(exists) {
          return true;
        }
      }
    }
    return false;
  }

  // The single "DatabasesX" chart that holds the aeronautical databases the app
  // needs to function (airports, navaids, nasr.mbtiles, ...).
  static Chart getDatabasesChart() {
    return _allCharts
        .firstWhere((cg) => cg.title == ChartCategory.databases)
        .charts
        .first;
  }

  // Whether the required databases have been downloaded locally.
  static Future<bool> doDatabasesExist() async {
    return (await Download.getChartCycleLocal(getDatabasesChart())).isNotEmpty;
  }

  // Find a chart by its download filename (e.g. "NE_SEC", "NE_TPP"), or null.
  static Chart? getChartByFilename(String filename) {
    for (ChartCategory cg in _allCharts) {
      for (Chart chart in cg.charts) {
        if (chart.filename == filename) {
          return chart;
        }
      }
    }
    return null;
  }

  static List<String> getCategories() {

    List<String> ret = [];

    for(ChartCategory cg in _allCharts) {
      if(cg.isChart) {
        ret.add(cg.title);
      }
    }

    return(ret);
  }

  static final List<ChartCategory> _allCharts = [
    ChartCategory(
      ChartCategory.databases,
      _absentColor,
      [
        Chart('DatabasesX', _absentColor, _absentIcon, 'databasesx', _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
      ],
      false,
    ),
    ChartCategory(
      ChartCategory.sectional,
      _absentColor,
      [
        Chart('Northeast',     _absentColor, _absentIcon, 'NE_SEC',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('North Central', _absentColor, _absentIcon, 'NC_SEC',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('Northwest',     _absentColor, _absentIcon, 'NW_SEC',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('Southeast',     _absentColor, _absentIcon, 'SE_SEC',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('South Central', _absentColor, _absentIcon, 'SC_SEC',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('Southwest',     _absentColor, _absentIcon, 'SW_SEC',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('East Central',  _absentColor, _absentIcon, 'EC_SEC',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('Alaska',        _absentColor, _absentIcon, 'AK_SEC',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('Pacific',       _absentColor, _absentIcon, 'PAC_SEC', _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
      ], true,
    ),
    ChartCategory(
      ChartCategory.tac,
      _absentColor,
      [
        Chart('Northeast',     _absentColor, _absentIcon, 'NE_TAC',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('North Central', _absentColor, _absentIcon, 'NC_TAC',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('Northwest',     _absentColor, _absentIcon, 'NW_TAC',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('Southeast',     _absentColor, _absentIcon, 'SE_TAC',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('South Central', _absentColor, _absentIcon, 'SC_TAC',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('Southwest',     _absentColor, _absentIcon, 'SW_TAC',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('East Central',  _absentColor, _absentIcon, 'EC_TAC',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('Alaska',        _absentColor, _absentIcon, 'AK_TAC',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('Pacific',       _absentColor, _absentIcon, 'PAC_TAC', _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
      ], true,
    ),
    ChartCategory(
      ChartCategory.ifrl,
      _absentColor,
      [
        Chart('Northeast',     _absentColor, _absentIcon, 'NE_ENR_L',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('North Central', _absentColor, _absentIcon, 'NC_ENR_L',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('Northwest',     _absentColor, _absentIcon, 'NW_ENR_L',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('Southeast',     _absentColor, _absentIcon, 'SE_ENR_L',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('South Central', _absentColor, _absentIcon, 'SC_ENR_L',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('Southwest',     _absentColor, _absentIcon, 'SW_ENR_L',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('East Central',  _absentColor, _absentIcon, 'EC_ENR_L',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('Alaska',        _absentColor, _absentIcon, 'AK_ENR_L',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('Pacific',       _absentColor, _absentIcon, 'PAC_ENR_L', _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
      ], true,
    ),
    ChartCategory(
      ChartCategory.ifrh,
      _absentColor,
      [
        Chart('Northeast',     _absentColor, _absentIcon, 'NE_ENR_H',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('North Central', _absentColor, _absentIcon, 'NC_ENR_H',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('Northwest',     _absentColor, _absentIcon, 'NW_ENR_H',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('Southeast',     _absentColor, _absentIcon, 'SE_ENR_H',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('South Central', _absentColor, _absentIcon, 'SC_ENR_H',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('Southwest',     _absentColor, _absentIcon, 'SW_ENR_H',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('East Central',  _absentColor, _absentIcon, 'EC_ENR_H',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('Alaska',        _absentColor, _absentIcon, 'AK_ENR_H',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('Pacific',       _absentColor, _absentIcon, 'PAC_ENR_H', _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
      ], true,
    ),
    ChartCategory(
      ChartCategory.ifra,
      _absentColor,
      [
        Chart('Northeast',     _absentColor, _absentIcon, 'NE_ENR_A',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('North Central', _absentColor, _absentIcon, 'NC_ENR_A',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('Northwest',     _absentColor, _absentIcon, 'NW_ENR_A',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('Southeast',     _absentColor, _absentIcon, 'SE_ENR_A',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('South Central', _absentColor, _absentIcon, 'SC_ENR_A',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('Southwest',     _absentColor, _absentIcon, 'SW_ENR_A',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('East Central',  _absentColor, _absentIcon, 'EC_ENR_A',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('Alaska',        _absentColor, _absentIcon, 'AK_ENR_A',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('Pacific',       _absentColor, _absentIcon, 'PAC_ENR_A', _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
      ], true,
    ),
    ChartCategory(
      ChartCategory.heli,
      _absentColor,
      [
        Chart('Northeast',     _absentColor, _absentIcon, 'NE_HEL',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('North Central', _absentColor, _absentIcon, 'NC_HEL',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('Northwest',     _absentColor, _absentIcon, 'NW_HEL',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('Southeast',     _absentColor, _absentIcon, 'SE_HEL',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('South Central', _absentColor, _absentIcon, 'SC_HEL',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('Southwest',     _absentColor, _absentIcon, 'SW_HEL',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('East Central',  _absentColor, _absentIcon, 'EC_HEL',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('Alaska',        _absentColor, _absentIcon, 'AK_HEL',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('Pacific',       _absentColor, _absentIcon, 'PAC_HEL', _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
      ], true,
    ),
    ChartCategory(
      ChartCategory.flyway,
      _absentColor,
      [
        Chart('Northeast',     _absentColor, _absentIcon, 'NE_FLY',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('North Central', _absentColor, _absentIcon, 'NC_FLY',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('Northwest',     _absentColor, _absentIcon, 'NW_FLY',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('Southeast',     _absentColor, _absentIcon, 'SE_FLY',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('South Central', _absentColor, _absentIcon, 'SC_FLY',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('Southwest',     _absentColor, _absentIcon, 'SW_FLY',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('East Central',  _absentColor, _absentIcon, 'EC_FLY',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('Alaska',        _absentColor, _absentIcon, 'AK_FLY',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('Pacific',       _absentColor, _absentIcon, 'PAC_FLY', _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
      ], true,
    ),

    ChartCategory(
      ChartCategory.plates,
      _absentColor,
      [
        Chart('Northeast',     _absentColor, _absentIcon, 'NE_TPP',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('North Central', _absentColor, _absentIcon, 'NC_TPP',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('Northwest',     _absentColor, _absentIcon, 'NW_TPP',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('Southeast',     _absentColor, _absentIcon, 'SE_TPP',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('South Central', _absentColor, _absentIcon, 'SC_TPP',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('Southwest',     _absentColor, _absentIcon, 'SW_TPP',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('East Central',  _absentColor, _absentIcon, 'EC_TPP',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('Alaska',        _absentColor, _absentIcon, 'AK_TPP',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('Pacific',       _absentColor, _absentIcon, 'PAC_TPP', _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
      ], false,
    ),
    ChartCategory(
      ChartCategory.csup,
      _absentColor,
      [
        Chart('Northeast',     _absentColor, _absentIcon, 'NE_CSUP',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('North Central', _absentColor, _absentIcon, 'NC_CSUP',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('Northwest',     _absentColor, _absentIcon, 'NW_CSUP',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('Southeast',     _absentColor, _absentIcon, 'SE_CSUP',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('South Central', _absentColor, _absentIcon, 'SC_CSUP',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('Southwest',     _absentColor, _absentIcon, 'SW_CSUP',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('East Central',  _absentColor, _absentIcon, 'EC_CSUP',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('Alaska',        _absentColor, _absentIcon, 'AK_CSUP',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
        Chart('Pacific',       _absentColor, _absentIcon, 'PAC_CSUP', _stateAbsent, "", ValueNotifier<int>(0), true, Download(), true),
      ], false,
    ),
    ChartCategory(
      ChartCategory.elevation,
      _absentColor,
      [
        Chart('Northeast',     _absentColor, _absentIcon, 'NE_ELEVATION',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), false),
        Chart('North Central', _absentColor, _absentIcon, 'NC_ELEVATION',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), false),
        Chart('Northwest',     _absentColor, _absentIcon, 'NW_ELEVATION',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), false),
        Chart('Southeast',     _absentColor, _absentIcon, 'SE_ELEVATION',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), false),
        Chart('South Central', _absentColor, _absentIcon, 'SC_ELEVATION',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), false),
        Chart('Southwest',     _absentColor, _absentIcon, 'SW_ELEVATION',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), false),
        Chart('East Central',  _absentColor, _absentIcon, 'EC_ELEVATION',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), false),
        Chart('Alaska',        _absentColor, _absentIcon, 'AK_ELEVATION',  _stateAbsent, "", ValueNotifier<int>(0), true, Download(), false),
        Chart('Pacific',       _absentColor, _absentIcon, 'PAC_ELEVATION', _stateAbsent, "", ValueNotifier<int>(0), true, Download(), false),
      ], false,
    ),
  ];
}
