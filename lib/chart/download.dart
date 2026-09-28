import 'dart:async';
import 'dart:convert';
import 'dart:core';
import 'dart:isolate';
import 'package:universal_io/io.dart';
import 'package:avaremp/data/main_database_helper.dart';
import 'package:avaremp/utils/faa_dates.dart';
import 'package:avaremp/utils/path_utils.dart';
import 'package:avaremp/storage.dart';
import 'package:path/path.dart' as path;
import 'package:http/http.dart' as http;
import 'chart.dart';
import 'package:archive/archive_io.dart';
// Streaming zip extractor that inflates directly to disk to avoid buffering
// whole files in memory.
import 'chart_extract.dart';

const String _kSetupCancel = 'setupCancel';
const String _kDownloaded = 'downloaded';
const String _kTotal = 'total';
const String _kOk = 'ok';
const String _kProgress = 'progress';
const String _kReply = 'reply';
const String _kZipPath = 'zipPath';
const String _kUrl = 'url';
const String _kDataDir = 'dataDir';
const String _kChartFilename = 'chartFilename';
const String _kError = 'error';

void _chartDownloadIsolateEntry(Map<String, Object?> start) {
  final SendPort mainSend = start[_kReply]! as SendPort;
  final String zipPath = start[_kZipPath]! as String;
  final String url = start[_kUrl]! as String;
  Future(() async {
    final cancelPort = ReceivePort();
    mainSend.send({_kSetupCancel: cancelPort.sendPort});
    var cancelled = false;
    cancelPort.listen((dynamic m) {
      if (m == true) {
        cancelled = true;
      }
    });
    IOSink? out;
    try {
      int total = 0;
      try {
        final http.Response r = await http.head(Uri.parse(url)).timeout(const Duration(seconds: 15));
        total = int.tryParse(r.headers["content-length"] ?? "0") ?? 0;
      } catch (_) {
        // size unknown; fall back to the GET response length
      }
      final request = http.Request('GET', Uri.parse(url));
      final streamedResponse = await request.send().timeout(const Duration(seconds: 30));
      if (streamedResponse.statusCode != 200) {
        // release the connection before failing
        await streamedResponse.stream.listen(null).cancel();
        throw Exception("HTTP ${streamedResponse.statusCode}");
      }
      if (total <= 0) {
        total = streamedResponse.contentLength ?? 0;
      }
      out = File(zipPath).openWrite();
      int downloaded = 0;
      double lastProgress = 0;
      int lastReported = 0;
      // a stalled connection fails instead of hanging forever
      await for (final chunk in streamedResponse.stream.timeout(const Duration(seconds: 60))) {
        if (cancelled) {
          throw Exception("Cancelled");
        }
        downloaded += chunk.length;
        out.add(chunk);
        if (total > 0) {
          final double progress = downloaded / total * 0.5;
          if (progress - lastProgress >= 0.01) {
            mainSend.send({_kDownloaded: downloaded, _kTotal: total});
            lastProgress = progress;
          }
        }
        else if (downloaded - lastReported >= 1 << 20) {
          // size unknown: still report bytes every MB
          mainSend.send({_kDownloaded: downloaded, _kTotal: 0});
          lastReported = downloaded;
        }
      }
      await out.close();
      out = null;
      mainSend.send({_kOk: true});
    } catch (e) {
      try {
        await out?.close();
      } catch (_) {}
      try {
        if (await File(zipPath).exists()) {
          await File(zipPath).delete();
        }
      } catch (_) {}
      mainSend.send({_kOk: false, _kError: _describeError(e)});
    } finally {
      cancelPort.close();
    }
  });
}

void _chartUnzipIsolateEntry(Map<String, Object?> start) {
  final SendPort mainSend = start[_kReply]! as SendPort;
  final String dataDir = start[_kDataDir]! as String;
  final String chartFilename = start[_kChartFilename]! as String;
  Future(() async {
    final cancelPort = ReceivePort();
    mainSend.send({_kSetupCancel: cancelPort.sendPort});
    var cancelled = false;
    cancelPort.listen((dynamic m) {
      if (m == true) {
        cancelled = true;
      }
    });
    InputFileStream? inputStream;
    try {
      inputStream = InputFileStream(
          PathUtils.getLocalFilePath(dataDir, chartFilename));
      final archive = ZipDecoder().decodeStream(inputStream);

      double num = 1;
      for (var file in archive) {
        if (cancelled) {
          inputStream.close();
          mainSend.send({_kOk: false});
          cancelPort.close();
          return;
        }
        if (file.isFile) {
          extractFileStreaming(
              file, PathUtils.getUnzipFilePath(dataDir, file.name));
        }
        final double fraction = num++ / archive.length.toDouble();
        final double progress = 0.5 + (fraction / 2);
        mainSend.send({_kProgress: progress});
      }

      inputStream.close();
      inputStream = null;
      mainSend.send({_kOk: true});
    } catch (e) {
      try {
        inputStream?.close();
      } catch (_) {}
      mainSend.send({_kOk: false, _kError: "Install failed: ${_describeError(e)}"});
    } finally {
      cancelPort.close();
    }
  });
}

// Short, human readable reason for a failed download.
String _describeError(Object e) {
  if (e is TimeoutException) {
    return "Server did not respond";
  }
  if (e is SocketException) {
    return "No connection to server";
  }
  final String s = e.toString().replaceFirst("Exception: ", "");
  if (s.startsWith("HTTP 404")) {
    return "Not available on server for this cycle";
  }
  return s;
}

class Download {

  // Why the last download() failed, or null.
  String? lastError;
  // Set when the failure was a user cancel rather than an error.
  bool get wasCancelled => _cancelDownloadAndDelete;

  static final Map<String, String> _cycleCache = {};

  static String serverFor(bool backupServer) =>
      backupServer ? "https://avare.bubble.org/" : "http://www.apps4av.org/regions/";

  // The cycle the server is serving, cached per server for this session.
  static Future<String> getServerCycle(bool backupServer) async {
    final String server = serverFor(backupServer);
    final String? cached = _cycleCache[server];
    if (cached != null) {
      return cached;
    }
    final String cycle = (await http.read(Uri.parse("$server/version.php"))
        .timeout(const Duration(seconds: 30))).trim();
    _cycleCache[server] = cycle;
    return cycle;
  }

  static String _downloadUrl(Chart chart, String server, String cycle) {
    return !chart.check
        ? "$server/static/${chart.filename}.zip"
        : "$server/$cycle/${chart.filename}.zip";
  }

  // Download size in bytes from the server, or null if unknown.
  static Future<int?> getRemoteSize(Chart chart, bool nextCycle, bool backupServer) async {
    try {
      String cycle = await getServerCycle(backupServer);
      if (nextCycle) {
        cycle = FaaDates.getNextCycle(cycle);
      }
      final http.Response r = await http
          .head(Uri.parse(_downloadUrl(chart, serverFor(backupServer), cycle)))
          .timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) {
        return null;
      }
      return int.tryParse(r.headers["content-length"] ?? "");
    }
    catch (e) {
      return null;
    }
  }

  bool _cancelDownloadAndDelete = false;
  SendPort? _chartDownloadCancelSendPort;
  SendPort? _chartUnzipCancelSendPort;

  // download close db
  static Future<void> _invalidateSqlite() async {
      await MainDatabaseHelper.invalidateConnection();
  }

  static Future<void> _deleteZipFile(File file) async {
    bool exists = await file.exists();
    if(exists) {
      try {
        await file.delete();
      }
      catch (e) {
        Storage().setException("Unable to delete file ${file.path}");
      }
    }
  }

  void cancel() {
    _cancelDownloadAndDelete = true;
    _chartDownloadCancelSendPort?.send(true);
    _chartUnzipCancelSendPort?.send(true);
  }

  static Future<String> getChartCycleLocal(Chart chart) async {
    String dir = Storage().dataDir;
    try {
      String version = await File(path.join(dir, chart.filename))
          .openRead()
          .map(utf8.decode)
          .transform(const LineSplitter()).elementAt(0);
      return version;
    }
    catch(e) {
      return "";
    }
  }

  static Future<bool> isChartExpired(Chart chart) async {
    //update chart instance to reflect state on disk

    String current = FaaDates.getCurrentCycle();
    String version = await getChartCycleLocal(chart);

    if(version.isEmpty) {
      return false; // not downloaded yet
    }
    if(!chart.check) {
      return false; // static files do not expire
    }

    return current != version;
  }

  Future<void> delete(Chart chart, Function(Chart, int)? callback) async {
    _cancelDownloadAndDelete = false;
    if(null != callback) {
      callback(chart, 0); // start
    }

    String dir = Storage().dataDir;
    String file = path.join(dir, chart.filename);

    List<String> s;
    try {
      s = await File(file).readAsLines(); // list of files to delete from manifest
    }
    catch(e) {
      if(null != callback) {
        callback(chart, -1);
      }
      return;
    }

    await _invalidateSqlite();

    double progress = 0;
    double lastProgress = 0;

    for(int index = 1; index < s.length; index++) { // skip version
      if(PathUtils.shouldNotDelete(s[index])) {
        // save some files forever
        continue;
      }
      File f = File(path.join(dir, s[index]));
      try {
        await f.delete(recursive: true);
      }
      catch(e) {
        continue; // try all
      }
      if(_cancelDownloadAndDelete) {
        if(null != callback) {
          callback(chart, -1);
        }
        return;
      }
      progress = index / s.length;
      if (progress - lastProgress >= 0.01) { // 1% change min
        if(null != callback) {
          callback(chart, (progress * 100).toInt());
        }
        lastProgress = progress;
      }
    }
    await _deleteZipFile(File(file));

    await Storage().checkChartsExist();
    await Storage().checkDataExpiry();

    await _invalidateSqlite();

    if(null != callback) {
      callback(chart, 100); // done
    }
  }

  // onBytes reports raw transfer progress; beforeInstall runs after the zip is
  // fully downloaded and before it is unzipped (e.g. to remove the old cycle).
  Future<void> download(Chart chart, bool nextCycle, bool backupServer, Function(Chart, int)? callback,
      {void Function(int downloaded, int total)? onBytes, Future<void> Function()? beforeInstall}) async {

    String server = serverFor(backupServer);
    lastError = null;
    _cancelDownloadAndDelete = false;
    _chartDownloadCancelSendPort = null;
    _chartUnzipCancelSendPort = null;
    double lastProgress = 0;
    final String dataDir = Storage().dataDir;
    final String zipPath = PathUtils.getLocalFilePath(dataDir, chart.filename);
    File localFile = File(zipPath);
    callback!(chart, 0); // download start signal

    String currentCycle;
    try {
      currentCycle = await getServerCycle(backupServer);
      if(nextCycle) {
        currentCycle = FaaDates.getNextCycle(currentCycle);
      }
    }
    catch(e) {
      lastError = "Could not reach server: ${_describeError(e)}";
      callback(chart, -1); // cycle not known
      return;
    }

    // start fresh
    await _deleteZipFile(localFile);

    if(_cancelDownloadAndDelete) {
      callback(chart, -1);
      return;
    }

    final String downloadUrl = _downloadUrl(chart, server, currentCycle);

    final receivePort = ReceivePort();
    final downloadCompleter = Completer<bool>();
    late final StreamSubscription<dynamic> downloadSub;
    downloadSub = receivePort.listen((dynamic message) {
      if (message is! Map) {
        return;
      }
      final map = message.cast<String, Object?>();
      if (map.containsKey(_kSetupCancel)) {
        _chartDownloadCancelSendPort = map[_kSetupCancel] as SendPort;
        return;
      }
      if (map.containsKey(_kDownloaded) && map.containsKey(_kTotal)) {
        final int total = map[_kTotal]! as int;
        onBytes?.call(map[_kDownloaded]! as int, total);
        if (total > 0) {
          final int downloaded = map[_kDownloaded]! as int;
          final double progress = downloaded / total * 0.5;
          if (progress - lastProgress >= 0.01) {
            callback(chart, (progress * 100).toInt());
            lastProgress = progress;
          }
        }
        return;
      }
      if (map.containsKey(_kOk)) {
        final bool ok = map[_kOk]! as bool;
        if (ok) {
          callback(chart, 50); // unzip start
          downloadCompleter.complete(true);
        } else {
          lastError = map[_kError] as String?;
          downloadCompleter.complete(false);
        }
      }
    });

    await Isolate.spawn(
      _chartDownloadIsolateEntry,
      <String, Object?>{
        _kReply: receivePort.sendPort,
        _kZipPath: zipPath,
        _kUrl: downloadUrl,
      },
    );

    final bool downloadOk = await downloadCompleter.future;
    await downloadSub.cancel();
    receivePort.close();
    _chartDownloadCancelSendPort = null;

    if (!downloadOk) {
      callback(chart, -1);
      return;
    }

    if(_cancelDownloadAndDelete) {
      callback(chart, -1);
      return;
    }

    if (beforeInstall != null) {
      await beforeInstall();
    }

    await _invalidateSqlite();

    if(_cancelDownloadAndDelete) {
      callback(chart, -1);
      await _deleteZipFile(localFile);
      return;
    }

    final unzipReceive = ReceivePort();
    final unzipCompleter = Completer<bool>();
    late final StreamSubscription<dynamic> unzipSub;
    unzipSub = unzipReceive.listen((dynamic message) {
      if (message is! Map) {
        return;
      }
      final map = message.cast<String, Object?>();
      if (map.containsKey(_kSetupCancel)) {
        _chartUnzipCancelSendPort = map[_kSetupCancel] as SendPort;
        return;
      }
      if (map.containsKey(_kProgress)) {
        final double progress = map[_kProgress]! as double;
        if (progress - lastProgress >= 0.01) {
          callback(chart, (progress * 100).toInt());
          lastProgress = progress;
        }
        return;
      }
      if (map.containsKey(_kOk)) {
        lastError = map[_kError] as String?;
        unzipCompleter.complete(map[_kOk]! as bool);
      }
    });

    await Isolate.spawn(
      _chartUnzipIsolateEntry,
      <String, Object?>{
        _kReply: unzipReceive.sendPort,
        _kDataDir: dataDir,
        _kChartFilename: chart.filename,
      },
    );

    final bool unzipOk = await unzipCompleter.future;
    await unzipSub.cancel();
    unzipReceive.close();
    _chartUnzipCancelSendPort = null;

    if (!unzipOk) {
      callback(chart, -1);
      await _deleteZipFile(localFile);
      return;
    }

    if(_cancelDownloadAndDelete) {
      callback(chart, -1);
      await _deleteZipFile(localFile);
      return;
    }

    try {
      await Storage().checkDataExpiry();
      await Storage().checkChartsExist();
      await _invalidateSqlite();
      callback(chart, 100); // done
    } catch (e) {
      callback(chart, -1);
    }

    // clean up
    await _deleteZipFile(localFile);

  }
}
