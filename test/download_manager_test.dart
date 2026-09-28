import 'package:avaremp/chart/chart.dart';
import 'package:avaremp/chart/download.dart';
import 'package:avaremp/chart/download_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Download that finishes only when the test says so.
class FakeDownload extends Download {
  Function(Chart, int)? callback;
  Future<void> Function()? beforeInstall;
  bool started = false;
  bool cancelled = false;

  @override
  bool get wasCancelled => cancelled;

  @override
  Future<void> download(Chart chart, bool nextCycle, bool backupServer, Function(Chart, int)? callback,
      {void Function(int downloaded, int total)? onBytes, Future<void> Function()? beforeInstall}) async {
    started = true;
    this.callback = callback;
    this.beforeInstall = beforeInstall;
    callback!(chart, 0);
  }

  @override
  Future<void> delete(Chart chart, Function(Chart, int)? callback) async {
    started = true;
    this.callback = callback;
    callback?.call(chart, 0);
  }

  @override
  void cancel() {
    cancelled = true;
    callback?.call(_chart!, -1);
  }

  Chart? _chart;
  void finish(int progress) => callback!(_chart!, progress);
}

Chart fakeChart(String filename) {
  final d = FakeDownload();
  final c = Chart(filename, Colors.grey, Icons.abc, filename, 0, "", ValueNotifier<int>(0), true, d, true);
  d._chart = c;
  return c;
}

FakeDownload dl(Chart c) => c.download as FakeDownload;

void main() {
  test('runs at most maxConcurrent at once and starts the next when one finishes', () {
    final m = DownloadManager();
    final charts = List.generate(5, (i) => fakeChart("NE_$i"));
    for (final c in charts) {
      m.download(c, false, false);
    }
    expect(charts.where((c) => dl(c).started).length, DownloadManager.maxConcurrent);
    expect(m.total(), 5);

    dl(charts[0]).finish(100);
    expect(charts.where((c) => dl(c).started).length, DownloadManager.maxConcurrent + 1);
    expect(m.total(), 4);
    expect(charts[0].progress.value, 0);
  });

  test('can add more while downloads are running', () {
    final m = DownloadManager();
    final a = fakeChart("NE_SEC");
    final b = fakeChart("NC_SEC");
    m.download(a, false, false);
    m.download(b, false, false);
    expect(dl(a).started && dl(b).started, isTrue);
  });

  test('duplicate requests are ignored', () {
    final m = DownloadManager();
    final a = fakeChart("NE_SEC");
    m.download(a, false, false);
    m.download(a, false, false);
    expect(m.total(), 1);
  });

  test('databases run alone', () {
    final m = DownloadManager();
    final a = fakeChart("NE_SEC");
    final db = fakeChart("databasesx");
    final b = fakeChart("NC_SEC");
    m.download(a, false, false);
    m.download(db, false, false);
    m.download(b, false, false);
    expect(dl(a).started, isTrue);
    expect(dl(db).started, isFalse); // waits for a
    expect(dl(b).started, isFalse); // nothing jumps a waiting exclusive job

    dl(a).finish(100);
    expect(dl(db).started, isTrue);
    expect(dl(b).started, isFalse);

    dl(db).finish(100);
    expect(dl(b).started, isTrue);
  });

  test('failure keeps the job with its error until retried', () {
    final m = DownloadManager();
    final a = fakeChart("NE_SEC");
    m.download(a, false, false);
    dl(a).lastError = "No connection to server";
    dl(a).finish(-1);

    final job = m.jobFor(a)!;
    expect(job.phase, DownloadJobPhase.failed);
    expect(job.error, "No connection to server");
    expect(a.progress.value, -1);
    expect(m.total(), 0);
    expect(m.isBusy(a), isFalse);

    dl(a).started = false;
    m.retry(job);
    expect(dl(a).started, isTrue);
    expect(m.jobFor(a)!.phase, isNot(DownloadJobPhase.failed));
  });

  test('cancelling a running job removes it without an error', () {
    final m = DownloadManager();
    final a = fakeChart("NE_SEC");
    m.download(a, false, false);
    m.cancel(a);
    expect(m.jobFor(a), isNull);
    expect(a.progress.value, 0);
  });

  test('cancelling a queued job never starts it', () {
    final m = DownloadManager();
    final charts = List.generate(4, (i) => fakeChart("NE_$i"));
    for (final c in charts) {
      m.download(c, false, false);
    }
    m.cancel(charts[3]);
    dl(charts[0]).finish(100);
    expect(dl(charts[3]).started, isFalse);
    expect(m.total(), 2);
  });

  test('updates remove the old cycle only before installing', () {
    final m = DownloadManager();
    final a = fakeChart("NE_SEC");
    m.download(a, false, false, update: true);
    expect(dl(a).beforeInstall, isNotNull);

    final b = fakeChart("NC_SEC");
    m.download(b, false, false);
    expect(dl(b).beforeInstall, isNull);
  });

  test('progress reports a visible value as soon as a job starts', () {
    final m = DownloadManager();
    final a = fakeChart("NE_SEC");
    final seen = <int>[];
    a.progress.addListener(() => seen.add(a.progress.value));
    m.download(a, false, false);
    expect(seen, isNotEmpty);
    expect(a.progress.value, greaterThan(0));
  });
}
