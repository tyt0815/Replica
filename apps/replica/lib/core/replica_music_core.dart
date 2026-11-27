import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import '../models/library_models.dart';

class UpdateDownloadProgress {
  const UpdateDownloadProgress({
    required this.downloadedBytes,
    required this.totalBytes,
  });

  final int downloadedBytes;
  final int totalBytes;

  double get ratio =>
      totalBytes > 0 ? (downloadedBytes / totalBytes).clamp(0.0, 1.0) : 0.0;
}

abstract class ReplicaMusicCoreBridge {
  String get coreVersion;
  bool get isNativeLoaded;
  bool isReplicaPlaylist(String rawTitle);
  String? toRemotePlaylistTitle(String displayTitle);
  String toDisplayPlaylistTitle(String rawTitle);
  Future<Map<String, dynamic>> invoke(Map<String, dynamic> request);
  UpdateDownloadProgress readUpdateDownloadProgress() =>
      const UpdateDownloadProgress(downloadedBytes: 0, totalBytes: 0);
  Map<String, UpdateDownloadProgress> readTrackDownloadProgress() => const {};
  void cancelUpdateDownload() {}
  void cancelTrackDownload(String videoId) {}
  void promoteTrackDownload(String videoId) {}
}

typedef _CoreVersionNative = Pointer<Utf8> Function();
typedef _CoreVersionDart = Pointer<Utf8> Function();

typedef _IsPlaylistNative = Bool Function(Pointer<Utf8>);
typedef _IsPlaylistDart = bool Function(Pointer<Utf8>);

typedef _TransformTitleNative = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _TransformTitleDart = Pointer<Utf8> Function(Pointer<Utf8>);

typedef _FreeNative = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);

class _NativeCoreWorker {
  SendPort? _sendPort;
  Future<SendPort>? _starting;
  Completer<SendPort>? _spawnCompleter;
  ReceivePort? _readyPort;
  ReceivePort? _exitPort;
  ReceivePort? _errorPort;
  final Set<Completer<String>> _pendingCalls = {};
  bool _broken = false;
  int _generation = 0;

  bool get isBroken => _broken;

  void _markBroken(Object error, {int? expectedGen}) {
    if (expectedGen != null && expectedGen != _generation) {
      return;
    }
    if (_broken) {
      return;
    }
    _broken = true;
    _sendPort = null;
    _starting = null;
    _readyPort?.close();
    _readyPort = null;
    if (_spawnCompleter != null && !_spawnCompleter!.isCompleted) {
      _spawnCompleter!.completeError(error);
    }
    _spawnCompleter = null;
    _exitPort?.close();
    _exitPort = null;
    _errorPort?.close();
    _errorPort = null;
    final pending = List<Completer<String>>.of(_pendingCalls);
    _pendingCalls.clear();
    for (final completer in pending) {
      if (!completer.isCompleted) {
        completer.completeError(error);
      }
    }
  }

  Future<SendPort> _ensurePort() {
    if (_sendPort != null && !_broken) {
      return Future.value(_sendPort!);
    }
    if (_broken) {
      _broken = false;
    }
    return _starting ??= _spawn();
  }

  Future<SendPort> _spawn() async {
    final gen = ++_generation;
    final ready = ReceivePort();
    final exitPort = ReceivePort();
    final errorPort = ReceivePort();
    final readyCompleter = Completer<SendPort>();
    _readyPort = ready;
    _spawnCompleter = readyCompleter;
    _exitPort = exitPort;
    _errorPort = errorPort;
    ready.listen((msg) {
      ready.close();
      if (identical(_readyPort, ready)) {
        _readyPort = null;
      }
      if (!readyCompleter.isCompleted && msg is SendPort) {
        readyCompleter.complete(msg);
      }
    });
    exitPort.listen((_) {
      if (identical(_exitPort, exitPort)) {
        _markBroken(Exception('네이티브 워커가 예기치 않게 종료되었습니다.'), expectedGen: gen);
      }
    });
    errorPort.listen((err) {
      if (identical(_errorPort, errorPort)) {
        _markBroken(Exception('네이티브 워커 오류: $err'), expectedGen: gen);
      }
    });
    try {
      await Isolate.spawn(
        _workerMain,
        ready.sendPort,
        onExit: exitPort.sendPort,
        onError: errorPort.sendPort,
      );
      final port = await readyCompleter.future;
      if (identical(_spawnCompleter, readyCompleter)) {
        _spawnCompleter = null;
      }
      if (gen != _generation || _broken) {
        throw Exception('네이티브 워커 초기화 중 세션이 중단되었습니다.');
      }
      _sendPort = port;
      _starting = null;
      return port;
    } catch (e) {
      ready.close();
      _markBroken(e, expectedGen: gen);
      rethrow;
    }
  }

  Future<String> call(String requestJson) async {
    final port = await _ensurePort();
    final reply = ReceivePort();
    final completer = Completer<String>();
    _pendingCalls.add(completer);
    late final StreamSubscription<dynamic> sub;
    sub = reply.listen((message) {
      _pendingCalls.remove(completer);
      unawaited(sub.cancel());
      reply.close();
      if (!completer.isCompleted) {
        completer.complete(message as String);
      }
    });
    try {
      port.send([requestJson, reply.sendPort]);
      return await completer.future;
    } catch (_) {
      _pendingCalls.remove(completer);
      unawaited(sub.cancel());
      reply.close();
      rethrow;
    }
  }

  static void _workerMain(SendPort initPort) {
    final inbox = ReceivePort();
    initPort.send(inbox.sendPort);
    final core = NativeReplicaMusicCore.tryOpen();
    inbox.listen((message) {
      if (message is List && message.length == 2) {
        final requestJson = message[0] as String;
        final replyPort = message[1] as SendPort;
        if (core == null) {
          replyPort.send(
            jsonEncode({'ok': false, 'error': '네이티브 코어를 불러오지 못했습니다.'}),
          );
          inbox.close();
        } else {
          replyPort.send(core.invokeRawSync(requestJson));
        }
      }
    });
  }
}

enum _WorkerLane { download, sync }

class _QueuedWorkerTask {
  _QueuedWorkerTask({
    required this.lane,
    required this.requestJson,
    required this.completer,
    this.serialKeys = const {},
    this.highPriority = false,
  });

  final _WorkerLane lane;
  final String requestJson;
  final Completer<String> completer;
  final Set<String> serialKeys;
  final bool highPriority;
}

class _SharedNativeWorkerPool {
  _SharedNativeWorkerPool({
    required this.maxWorkers,
    this.minReservedPerLane = 1,
  });

  final int maxWorkers;
  final int minReservedPerLane;

  final List<_NativeCoreWorker> _idleWorkers = [];
  int _spawnedCount = 0;
  final Map<_WorkerLane, int> _activeByLane = {
    _WorkerLane.download: 0,
    _WorkerLane.sync: 0,
  };
  final Set<String> _activeSerialKeys = {};
  final List<_QueuedWorkerTask> _queue = [];

  int get _maxPerLane => (maxWorkers - minReservedPerLane).clamp(1, maxWorkers);

  int get _maxLowPriorityDownloads => (_maxPerLane - 1).clamp(1, _maxPerLane);

  bool isSerialKeyActive(String serialKey) =>
      serialKey.isNotEmpty && _activeSerialKeys.contains(serialKey);

  bool cancelSerialKey(String serialKey) {
    if (serialKey.isEmpty) {
      return false;
    }
    var cancelledAny = false;
    for (var i = _queue.length - 1; i >= 0; i--) {
      if (_queue[i].serialKeys.contains(serialKey)) {
        final task = _queue.removeAt(i);
        if (!task.completer.isCompleted) {
          task.completer.complete(
            jsonEncode({'ok': false, 'error': '다운로드가 취소되었습니다.'}),
          );
        }
        cancelledAny = true;
      }
    }
    return cancelledAny;
  }

  void promoteSerialKey(String serialKey) {
    if (serialKey.isEmpty) {
      return;
    }
    final idx = _queue.indexWhere(
      (t) => t.serialKeys.contains(serialKey) && !t.highPriority,
    );
    if (idx < 0) {
      return;
    }
    final existing = _queue.removeAt(idx);
    final promoted = _QueuedWorkerTask(
      lane: existing.lane,
      requestJson: existing.requestJson,
      completer: existing.completer,
      serialKeys: existing.serialKeys,
      highPriority: true,
    );
    final insertIdx = _queue.indexWhere((t) => !t.highPriority);
    if (insertIdx < 0) {
      _queue.add(promoted);
    } else {
      _queue.insert(insertIdx, promoted);
    }
    _pump();
  }

  Future<String> submit({
    required _WorkerLane lane,
    required String requestJson,
    Set<String> serialKeys = const {},
    bool highPriority = false,
  }) {
    final completer = Completer<String>();
    final cleanedKeys = serialKeys.where((k) => k.isNotEmpty).toSet();
    final task = _QueuedWorkerTask(
      lane: lane,
      requestJson: requestJson,
      completer: completer,
      serialKeys: cleanedKeys,
      highPriority: highPriority,
    );
    if (highPriority) {
      final insertIdx = _queue.indexWhere((t) => !t.highPriority);
      if (insertIdx < 0) {
        _queue.add(task);
      } else {
        _queue.insert(insertIdx, task);
      }
    } else {
      _queue.add(task);
    }
    _pump();
    return completer.future;
  }

  bool _canStart(_QueuedWorkerTask task) {
    final laneActive = _activeByLane[task.lane] ?? 0;
    final laneLimit = (task.lane == _WorkerLane.download && !task.highPriority)
        ? _maxLowPriorityDownloads
        : _maxPerLane;
    if (laneActive >= laneLimit) {
      return false;
    }
    final totalActive =
        (_activeByLane[_WorkerLane.download] ?? 0) +
        (_activeByLane[_WorkerLane.sync] ?? 0);
    if (totalActive >= maxWorkers) {
      return false;
    }
    for (final key in task.serialKeys) {
      if (_activeSerialKeys.contains(key)) {
        return false;
      }
    }
    return true;
  }

  _NativeCoreWorker? _acquireWorker() {
    if (_idleWorkers.isNotEmpty) {
      return _idleWorkers.removeLast();
    }
    if (_spawnedCount < maxWorkers) {
      _spawnedCount += 1;
      return _NativeCoreWorker();
    }
    return null;
  }

  void _pump() {
    while (true) {
      final idx = _queue.indexWhere(_canStart);
      if (idx < 0) {
        return;
      }
      final worker = _acquireWorker();
      if (worker == null) {
        return;
      }
      final task = _queue.removeAt(idx);
      _activeByLane[task.lane] = (_activeByLane[task.lane] ?? 0) + 1;
      final serialKeys = task.serialKeys;
      if (serialKeys.isNotEmpty) {
        _activeSerialKeys.addAll(serialKeys);
      }
      unawaited(
        worker
            .call(task.requestJson)
            .then(
              (result) {
                if (!task.completer.isCompleted) {
                  task.completer.complete(result);
                }
              },
              onError: (Object err, StackTrace st) {
                if (!task.completer.isCompleted) {
                  task.completer.completeError(err, st);
                }
              },
            )
            .whenComplete(() {
              _activeByLane[task.lane] = ((_activeByLane[task.lane] ?? 1) - 1)
                  .clamp(0, maxWorkers);
              if (serialKeys.isNotEmpty) {
                _activeSerialKeys.removeAll(serialKeys);
              }
              if (worker.isBroken) {
                _spawnedCount = (_spawnedCount - 1).clamp(0, maxWorkers);
              } else {
                _idleWorkers.add(worker);
              }
              _pump();
            }),
      );
    }
  }
}

final _NativeCoreWorker _localCoreWorker = _NativeCoreWorker();
final _NativeCoreWorker _searchCoreWorker = _NativeCoreWorker();
final _NativeCoreWorker _miscNetworkCoreWorker = _NativeCoreWorker();
final _SharedNativeWorkerPool _sharedWorkerPool = _SharedNativeWorkerPool(
  maxWorkers: 5,
  minReservedPerLane: 1,
);

class NativeReplicaMusicCore implements ReplicaMusicCoreBridge {
  NativeReplicaMusicCore._(DynamicLibrary library)
    : _coreVersion = library
          .lookupFunction<_CoreVersionNative, _CoreVersionDart>(
            'replica_music_core_version',
          ),
      _isPlaylist = library.lookupFunction<_IsPlaylistNative, _IsPlaylistDart>(
        'replica_music_is_playlist',
      ),
      _toRemoteTitle = library
          .lookupFunction<_TransformTitleNative, _TransformTitleDart>(
            'replica_music_to_remote_playlist_title',
          ),
      _toDisplayTitle = library
          .lookupFunction<_TransformTitleNative, _TransformTitleDart>(
            'replica_music_to_display_playlist_title',
          ),
      _invoke = library
          .lookupFunction<_TransformTitleNative, _TransformTitleDart>(
            'replica_music_invoke',
          ),
      _free = library.lookupFunction<_FreeNative, _FreeDart>(
        'replica_music_free',
      );

  final _CoreVersionDart _coreVersion;
  final _IsPlaylistDart _isPlaylist;
  final _TransformTitleDart _toRemoteTitle;
  final _TransformTitleDart _toDisplayTitle;
  final _TransformTitleDart _invoke;
  final _FreeDart _free;

  static ReplicaMusicCoreBridge openOrFallback() {
    final native = tryOpen();
    return native ?? _FallbackReplicaMusicCore();
  }

  static NativeReplicaMusicCore? tryOpen() {
    for (final candidate in _libraryCandidates()) {
      try {
        return NativeReplicaMusicCore._(DynamicLibrary.open(candidate));
      } catch (_) {}
    }
    return null;
  }

  static List<String> _libraryCandidates() {
    if (Platform.isAndroid) {
      return const ['libreplica_music_core.so'];
    }
    if (Platform.isWindows) {
      final sep = Platform.pathSeparator;
      final cwd = Directory.current.path;
      return [
        'replica_music_core.dll',
        '$cwd${sep}target${sep}debug${sep}replica_music_core.dll',
        '$cwd$sep..$sep..${sep}target${sep}debug${sep}replica_music_core.dll',
        '$cwd$sep..$sep..${sep}target${sep}release${sep}replica_music_core.dll',
      ];
    }
    return const ['libreplica_music_core.so'];
  }

  @override
  bool get isNativeLoaded => true;

  @override
  String get coreVersion {
    final ptr = _coreVersion();
    if (ptr == nullptr) {
      return '0.14.17';
    }
    try {
      return ptr.toDartString();
    } finally {
      _free(ptr);
    }
  }

  @override
  bool isReplicaPlaylist(String rawTitle) {
    final input = rawTitle.toNativeUtf8();
    try {
      return _isPlaylist(input);
    } finally {
      malloc.free(input);
    }
  }

  @override
  String? toRemotePlaylistTitle(String displayTitle) {
    final input = displayTitle.toNativeUtf8();
    try {
      final result = _toRemoteTitle(input);
      if (result == nullptr) {
        return null;
      }
      try {
        return result.toDartString();
      } finally {
        _free(result);
      }
    } finally {
      malloc.free(input);
    }
  }

  @override
  String toDisplayPlaylistTitle(String rawTitle) {
    final input = rawTitle.toNativeUtf8();
    try {
      final result = _toDisplayTitle(input);
      if (result == nullptr) {
        return rawTitle;
      }
      try {
        return result.toDartString();
      } finally {
        _free(result);
      }
    } finally {
      malloc.free(input);
    }
  }

  String invokeRawSync(String requestJson) {
    final input = requestJson.toNativeUtf8();
    try {
      final result = _invoke(input);
      if (result == nullptr) {
        return jsonEncode({'ok': false, 'error': '코어 응답이 비어 있습니다.'});
      }
      try {
        return result.toDartString();
      } finally {
        _free(result);
      }
    } finally {
      malloc.free(input);
    }
  }

  static const Set<String> _syncOps = {
    'list_playlists',
    'playlist_tracks',
    'create_playlist',
    'rename_playlist',
    'add_to_playlist',
    'remove_from_playlist',
    'delete_playlist',
    'sync_playlist_tracks',
    'record_history_track',
    'trim_history_playlist',
  };

  static const Set<String> _localOps = {
    'list_downloaded',
    'delete_downloaded',
    'storage_usage',
    'enqueue_error_report',
    'list_error_reports',
    'clear_error_reports',
  };

  @override
  Future<Map<String, dynamic>> invoke(Map<String, dynamic> request) async {
    final op = request['op'] as String?;
    final highPriority = request['priority'] == true;
    final cleanRequest = request.containsKey('priority')
        ? (Map<String, dynamic>.of(request)..remove('priority'))
        : request;
    final encoded = jsonEncode(cleanRequest);

    final String raw;
    if (op == 'download_track' || op == 'download_update') {
      final downloadSerialKeys = <String>{};
      if (op == 'download_track') {
        final track = cleanRequest['track'];
        if (track is Map) {
          final videoId = (track['video_id'] as String?)?.trim();
          if (videoId != null && videoId.isNotEmpty) {
            downloadSerialKeys.add('dl:$videoId');
          }
        }
      } else {
        downloadSerialKeys.add('dl:__update__');
      }
      raw = await _sharedWorkerPool.submit(
        lane: _WorkerLane.download,
        requestJson: encoded,
        serialKeys: downloadSerialKeys,
        highPriority: highPriority,
      );
    } else if (_syncOps.contains(op)) {
      final playlistId = (cleanRequest['playlist_id'] as String?)?.trim();
      final serialKeys = <String>{};
      if (op == 'list_playlists' ||
          op == 'create_playlist' ||
          op == 'rename_playlist' ||
          op == 'delete_playlist') {
        serialKeys.add('pl:__global__');
      }
      if (playlistId != null && playlistId.isNotEmpty) {
        serialKeys.add('pl:$playlistId');
      }
      raw = await _sharedWorkerPool.submit(
        lane: _WorkerLane.sync,
        requestJson: encoded,
        serialKeys: serialKeys,
        highPriority: highPriority,
      );
    } else if (_localOps.contains(op)) {
      raw = await _localCoreWorker.call(encoded);
    } else if (op == 'search') {
      raw = await _searchCoreWorker.call(encoded);
    } else {
      raw = await _miscNetworkCoreWorker.call(encoded);
    }

    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    if (decoded['ok'] != true) {
      throw Exception(decoded['error']?.toString() ?? '알 수 없는 오류가 발생했습니다.');
    }
    return (decoded['data'] as Map<String, dynamic>?) ?? <String, dynamic>{};
  }

  @override
  void cancelTrackDownload(String videoId) {
    final trimmed = videoId.trim();
    if (trimmed.isEmpty) {
      return;
    }
    final serialKey = 'dl:$trimmed';
    _sharedWorkerPool.cancelSerialKey(serialKey);
    if (!_sharedWorkerPool.isSerialKeyActive(serialKey)) {
      return;
    }
    try {
      invokeRawSync(
        jsonEncode({'op': 'cancel_track_download', 'video_id': trimmed}),
      );
    } catch (_) {}
  }

  @override
  void promoteTrackDownload(String videoId) {
    final trimmed = videoId.trim();
    if (trimmed.isNotEmpty) {
      _sharedWorkerPool.promoteSerialKey('dl:$trimmed');
    }
  }

  @override
  UpdateDownloadProgress readUpdateDownloadProgress() {
    try {
      final raw = invokeRawSync('{"op":"update_download_progress"}');
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      if (decoded['ok'] != true) {
        return const UpdateDownloadProgress(downloadedBytes: 0, totalBytes: 0);
      }
      final data = (decoded['data'] as Map<String, dynamic>?) ?? const {};
      final progress = (data['progress'] as Map<String, dynamic>?) ?? const {};
      return UpdateDownloadProgress(
        downloadedBytes: (progress['downloaded_bytes'] as num?)?.toInt() ?? 0,
        totalBytes: (progress['total_bytes'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return const UpdateDownloadProgress(downloadedBytes: 0, totalBytes: 0);
    }
  }

  @override
  Map<String, UpdateDownloadProgress> readTrackDownloadProgress() {
    try {
      final raw = invokeRawSync('{"op":"track_download_progress"}');
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      if (decoded['ok'] != true) {
        return const {};
      }
      final data = (decoded['data'] as Map<String, dynamic>?) ?? const {};
      final rawMap = (data['progress'] as Map<String, dynamic>?) ?? const {};
      if (rawMap.isEmpty) {
        return const {};
      }
      final result = <String, UpdateDownloadProgress>{};
      for (final entry in rawMap.entries) {
        final val = entry.value;
        if (val is Map<String, dynamic>) {
          result[entry.key] = UpdateDownloadProgress(
            downloadedBytes: (val['downloaded_bytes'] as num?)?.toInt() ?? 0,
            totalBytes: (val['total_bytes'] as num?)?.toInt() ?? 0,
          );
        }
      }
      return result;
    } catch (_) {
      return const {};
    }
  }

  @override
  void cancelUpdateDownload() {
    try {
      invokeRawSync('{"op":"cancel_update_download"}');
    } catch (_) {}
  }
}

class _FallbackReplicaMusicCore implements ReplicaMusicCoreBridge {
  static const _suffix = '.rm';

  @override
  bool get isNativeLoaded => false;

  @override
  String get coreVersion => '0.3.0';

  @override
  bool isReplicaPlaylist(String rawTitle) {
    final trimmed = rawTitle.trim();
    return trimmed.endsWith(_suffix) && trimmed.length > _suffix.length;
  }

  @override
  String? toRemotePlaylistTitle(String displayTitle) {
    final clean = toDisplayPlaylistTitle(displayTitle);
    if (clean.isEmpty) {
      return null;
    }
    return '$clean$_suffix';
  }

  @override
  String toDisplayPlaylistTitle(String rawTitle) =>
      stripPlaylistTimestampAndSuffix(rawTitle);

  @override
  Future<Map<String, dynamic>> invoke(Map<String, dynamic> request) async {
    throw Exception('네이티브 코어가 로드되지 않았습니다.');
  }

  @override
  UpdateDownloadProgress readUpdateDownloadProgress() =>
      const UpdateDownloadProgress(downloadedBytes: 0, totalBytes: 0);

  @override
  Map<String, UpdateDownloadProgress> readTrackDownloadProgress() => const {};

  @override
  void cancelUpdateDownload() {}

  @override
  void cancelTrackDownload(String videoId) {}

  @override
  void promoteTrackDownload(String videoId) {}
}
