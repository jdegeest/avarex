import 'package:flutter/material.dart';

import 'chart.dart';
import 'download.dart';

enum DownloadJobKind { download, update, delete }

enum DownloadJobPhase { queued, starting, downloading, installing, deleting, failed }

// One queued, running or failed download/update/delete.
class DownloadJob {
  final Chart chart;
  final DownloadJobKind kind;
  final bool nextCycle;
  final bool backupServer;
  DownloadJobPhase phase = DownloadJobPhase.queued;
  int downloadedBytes = 0;
  int totalBytes = 0; // 0 when unknown
  double bytesPerSecond = 0;
  String? error;

  DateTime? _lastSample;
  int _lastSampleBytes = 0;

  DownloadJob(this.chart, this.kind, this.nextCycle, this.backupServer);

  bool get active =>
      phase != DownloadJobPhase.queued && phase != DownloadJobPhase.failed;

  // Databases replace files the rest of the app holds open, so they run alone.
  bool get exclusive => chart.filename == "databasesx";

  void _sample(int downloaded, int total) {
    final DateTime now = DateTime.now();
    if (_lastSample != null) {
      final double dt = now.difference(_lastSample!).inMilliseconds / 1000;
      if (dt > 0.2) {
        final double rate = (downloaded - _lastSampleBytes) / dt;
        // smooth so the number is readable
        bytesPerSecond = bytesPerSecond == 0 ? rate : bytesPerSecond * 0.7 + rate * 0.3;
        _lastSample = now;
        _lastSampleBytes = downloaded;
      }
    }
    else {
      _lastSample = now;
      _lastSampleBytes = downloaded;
    }
    downloadedBytes = downloaded;
    totalBytes = total;
  }
}

// Runs chart downloads, updates and deletes from a queue, a few at a time.
// Listeners are notified whenever any job changes.
class DownloadManager extends ChangeNotifier {

  static const int maxConcurrent = 3;

  // Progress 0 means idle to the UI, so an active job always reports at
  // least 1 to make it visible (and notify listeners) right away.
  static const int _started = 1;

  final List<DownloadJob> _jobs = [];

  // Bumped each time a job finishes so screens can re-read charts from disk.
  final ValueNotifier<int> downloads = ValueNotifier<int>(0);

  List<DownloadJob> get jobs => List.unmodifiable(_jobs);

  DownloadJob? jobFor(Chart chart) {
    for (DownloadJob j in _jobs) {
      if (j.chart.filename == chart.filename) {
        return j;
      }
    }
    return null;
  }

  // A chart with a queued or running job (failed jobs don't count).
  bool isBusy(Chart chart) {
    final DownloadJob? j = jobFor(chart);
    return j != null && j.phase != DownloadJobPhase.failed;
  }

  void download(Chart chart, bool nextCycle, bool backupServer, {bool update = false}) {
    _enqueue(DownloadJob(chart, update ? DownloadJobKind.update : DownloadJobKind.download, nextCycle, backupServer));
  }

  void delete(Chart chart) {
    _enqueue(DownloadJob(chart, DownloadJobKind.delete, false, false));
  }

  void retry(DownloadJob job) {
    if (job.phase != DownloadJobPhase.failed) {
      return;
    }
    _jobs.remove(job);
    _enqueue(DownloadJob(job.chart, job.kind, job.nextCycle, job.backupServer));
  }

  // Remove a failed job from the list.
  void dismiss(DownloadJob job) {
    if (job.phase == DownloadJobPhase.failed) {
      _jobs.remove(job);
      job.chart.progress.value = 0;
      notifyListeners();
    }
  }

  void cancel(Chart chart) {
    final DownloadJob? j = jobFor(chart);
    if (j == null) {
      return;
    }
    if (j.phase == DownloadJobPhase.queued || j.phase == DownloadJobPhase.failed) {
      _jobs.remove(j);
      _resetChart(chart);
      notifyListeners();
      return;
    }
    // running: the download reports -1 and _finish removes it
    j.chart.download.cancel();
  }

  void _enqueue(DownloadJob job) {
    final DownloadJob? existing = jobFor(job.chart);
    if (existing != null) {
      if (existing.phase != DownloadJobPhase.failed) {
        return; // already queued or running
      }
      _jobs.remove(existing);
    }
    job.chart.enabled = false;
    job.chart.subtitle = "Queued";
    _jobs.add(job);
    notifyListeners();
    _pump();
  }

  void _pump() {
    final List<DownloadJob> running = _jobs.where((j) => j.active).toList();
    if (running.any((j) => j.exclusive)) {
      return;
    }
    for (DownloadJob j in _jobs.where((j) => j.phase == DownloadJobPhase.queued).toList()) {
      if (running.length >= maxConcurrent) {
        break;
      }
      if (j.exclusive) {
        if (running.isEmpty) {
          _start(j);
        }
        break; // nothing starts past a waiting exclusive job
      }
      _start(j);
      running.add(j);
    }
  }

  void _start(DownloadJob job) {
    final Chart chart = job.chart;
    job.phase = job.kind == DownloadJobKind.delete ? DownloadJobPhase.deleting : DownloadJobPhase.starting;
    chart.subtitle = job.kind == DownloadJobKind.delete ? "Uninstalling" : "Starting";
    chart.progress.value = _started;
    notifyListeners();

    if (job.kind == DownloadJobKind.delete) {
      chart.download.delete(chart, (c, progress) => _onProgress(job, progress));
      return;
    }
    chart.download.download(chart, job.nextCycle, job.backupServer, (c, progress) => _onProgress(job, progress),
        onBytes: (downloaded, total) {
          job._sample(downloaded, total);
          notifyListeners();
        },
        // replace the old cycle only once the new one is safely downloaded
        beforeInstall: job.kind == DownloadJobKind.update ? () => Download().delete(chart, null) : null);
  }

  void _onProgress(DownloadJob job, int progress) {
    if (!_jobs.contains(job)) {
      return;
    }
    final Chart chart = job.chart;
    if (progress < 0) {
      _finish(job, false);
      return;
    }
    if (progress >= 100) {
      _finish(job, true);
      return;
    }
    chart.progress.value = progress == 0 ? _started : progress;
    if (job.kind != DownloadJobKind.delete) {
      if (progress >= 50) {
        job.phase = DownloadJobPhase.installing;
        chart.subtitle = "Installing";
      }
      else {
        job.phase = DownloadJobPhase.downloading;
        chart.subtitle = "Downloading";
      }
    }
    notifyListeners();
  }

  void _finish(DownloadJob job, bool ok) {
    final Chart chart = job.chart;
    final bool cancelled = !ok && chart.download.wasCancelled;
    if (ok || cancelled) {
      _jobs.remove(job);
      chart.enabled = true;
      chart.subtitle = ok ? (job.kind == DownloadJobKind.delete ? "" : "Download Success") : "Cancelled";
      // 100 first so progress listeners see completion, then back to idle
      chart.progress.value = ok ? 100 : -1;
      chart.progress.value = 0;
    }
    else {
      job.phase = DownloadJobPhase.failed;
      job.error = chart.download.lastError ??
          (job.kind == DownloadJobKind.delete ? "Could not uninstall" : "Download failed");
      chart.enabled = true;
      chart.subtitle = "Failed";
      chart.progress.value = -1;
    }
    downloads.value++;
    notifyListeners();
    _pump();
  }

  void _resetChart(Chart chart) {
    chart.enabled = true;
    chart.subtitle = "";
    chart.progress.value = 0;
  }

  // Queued and running jobs.
  int total() {
    return _jobs.where((j) => j.phase != DownloadJobPhase.failed).length;
  }

}
