import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/replica_music_core.dart';
import '../models/library_models.dart';

typedef StoragePermissionCheck = Future<bool> Function();

class DownloadManager {
  DownloadManager({
    required this.core,
    required this.getStorageDir,
    required this.ensureStoragePermission,
    this.getPreferredAudioFormat,
    this.onDownloadedListChanged,
    this.onDownloadingIdsChanged,
    this.onDownloadingTracksChanged,
    this.fileExistsOverride,
  });

  final ReplicaMusicCoreBridge core;
  final String Function() getStorageDir;
  final StoragePermissionCheck ensureStoragePermission;
  final String Function()? getPreferredAudioFormat;
  final void Function(List<TrackItem> tracks)? onDownloadedListChanged;
  final void Function(Set<String> trackIds)? onDownloadingIdsChanged;
  final void Function(List<TrackItem> tracks)? onDownloadingTracksChanged;
  final bool Function(String path)? fileExistsOverride;

  final Map<String, TrackItem> _downloadedById = {};
  final Map<String, Future<String?>> _inFlight = {};
  final Map<String, TrackItem> _inFlightTracks = {};
  final Map<String, int> _bulkRequestCounts = {};
  final Set<String> _prefetching = {};
  final ValueNotifier<Map<String, UpdateDownloadProgress>> downloadProgress =
      ValueNotifier<Map<String, UpdateDownloadProgress>>(const {});
  Timer? _progressTimer;
  Future<bool>? _pendingPermissionCheck;

  List<TrackItem> get downloadedTracks =>
      List<TrackItem>.unmodifiable(_downloadedById.values);

  List<TrackItem> get downloadingTracks =>
      List<TrackItem>.unmodifiable(_inFlightTracks.values);

  void _notifyDownloadingChanged() {
    onDownloadingIdsChanged?.call(Set<String>.unmodifiable(_inFlight.keys));
    onDownloadingTracksChanged?.call(downloadingTracks);
    if (_inFlight.isEmpty) {
      _progressTimer?.cancel();
      _progressTimer = null;
      if (downloadProgress.value.isNotEmpty) {
        downloadProgress.value = const {};
      }
      return;
    }
    _pollProgressNow();
    _progressTimer ??= Timer.periodic(
      const Duration(milliseconds: 150),
      (_) => _pollProgressNow(),
    );
  }

  void _pollProgressNow() {
    if (_inFlight.isEmpty) {
      _progressTimer?.cancel();
      _progressTimer = null;
      if (downloadProgress.value.isNotEmpty) {
        downloadProgress.value = const {};
      }
      return;
    }
    final latest = core.readTrackDownloadProgress();
    final filtered = <String, UpdateDownloadProgress>{};
    for (final id in _inFlight.keys) {
      final entry = latest[id];
      if (entry != null) {
        filtered[id] = entry;
      }
    }
    final current = downloadProgress.value;
    var changed = filtered.length != current.length;
    if (!changed) {
      for (final entry in filtered.entries) {
        final prev = current[entry.key];
        if (prev == null ||
            prev.downloadedBytes != entry.value.downloadedBytes ||
            prev.totalBytes != entry.value.totalBytes) {
          changed = true;
          break;
        }
      }
    }
    if (changed) {
      downloadProgress.value = Map<String, UpdateDownloadProgress>.unmodifiable(
        filtered,
      );
    }
  }

  void dispose() {
    _progressTimer?.cancel();
    _progressTimer = null;
    downloadProgress.dispose();
  }

  void removeFromDownloadedIndex(String videoId) {
    _downloadedById.remove(videoId);
  }

  void _retainBulk(String videoId) {
    _bulkRequestCounts[videoId] = (_bulkRequestCounts[videoId] ?? 0) + 1;
  }

  void _releaseBulk(String videoId) {
    final next = (_bulkRequestCounts[videoId] ?? 1) - 1;
    if (next <= 0) {
      _bulkRequestCounts.remove(videoId);
    } else {
      _bulkRequestCounts[videoId] = next;
    }
  }

  Future<bool> _checkPermissionDeduped() {
    final existing = _pendingPermissionCheck;
    if (existing != null) {
      return existing;
    }
    final future = ensureStoragePermission();
    _pendingPermissionCheck = future;
    future.whenComplete(() {
      if (identical(_pendingPermissionCheck, future)) {
        _pendingPermissionCheck = null;
      }
    });
    return future;
  }

  bool _fileExists(String path) {
    if (path.isEmpty) {
      return false;
    }
    final override = fileExistsOverride;
    if (override != null) {
      return override(path);
    }
    try {
      return File(path).existsSync();
    } catch (_) {
      return false;
    }
  }

  void updateDownloadedIndex(List<TrackItem> tracks) {
    _downloadedById
      ..clear()
      ..addEntries(tracks.map((t) => MapEntry(t.id, t)));
  }

  Future<List<TrackItem>> refreshDownloadedTracks() async {
    final storageDir = getStorageDir();
    if (storageDir.isEmpty || !core.isNativeLoaded) {
      return downloadedTracks;
    }
    try {
      final data = await core.invoke({
        'op': 'list_downloaded',
        'storage_dir': storageDir,
      });
      final rawList = (data['tracks'] as List<dynamic>?) ?? const [];
      final tracks = rawList
          .whereType<Map<String, dynamic>>()
          .map((item) => TrackItem.fromCoreJson(item, isDownloaded: true))
          .toList(growable: false);
      updateDownloadedIndex(tracks);
      onDownloadedListChanged?.call(tracks);
      return tracks;
    } catch (_) {
      return downloadedTracks;
    }
  }

  String? resolveLocalPath(TrackItem track) {
    final indexed = _downloadedById[track.id];
    if (indexed != null) {
      final path = indexed.filePath;
      if (path != null && _fileExists(path)) {
        return path;
      }
      _downloadedById.remove(track.id);
      unawaited(refreshDownloadedTracks());
    }
    if (track.filePath != null && _fileExists(track.filePath!)) {
      return track.filePath;
    }
    return null;
  }

  String? resolveLocalThumbnailPath(String videoId) {
    final storageDir = getStorageDir();
    if (storageDir.isEmpty || videoId.isEmpty) {
      return null;
    }
    final path =
        '$storageDir${Platform.pathSeparator}.meta${Platform.pathSeparator}$videoId.jpg';
    return _fileExists(path) ? path : null;
  }

  void cancelPlaybackDownload(String videoId) {
    if (videoId.isEmpty ||
        !_inFlight.containsKey(videoId) ||
        (_bulkRequestCounts[videoId] ?? 0) > 0) {
      return;
    }
    _inFlight.remove(videoId);
    _inFlightTracks.remove(videoId);
    _notifyDownloadingChanged();
    core.cancelTrackDownload(videoId);
  }

  Future<String?> ensureLocalFile(
    TrackItem track, {
    bool allowNetwork = true,
    bool highPriority = true,
    bool isBulk = false,
  }) async {
    final existing = resolveLocalPath(track);
    if (existing != null) {
      return existing;
    }
    if (!allowNetwork) {
      return null;
    }
    if (isBulk) {
      _retainBulk(track.id);
    }
    final inFlight = _inFlight[track.id];
    if (inFlight != null) {
      if (highPriority) {
        core.promoteTrackDownload(track.id);
      }
      try {
        return await inFlight;
      } finally {
        if (isBulk) {
          _releaseBulk(track.id);
        }
      }
    }
    final future = _downloadTrackInternal(track, highPriority: highPriority);
    _inFlight[track.id] = future;
    _inFlightTracks[track.id] = track;
    _notifyDownloadingChanged();
    try {
      return await future;
    } finally {
      if (isBulk) {
        _releaseBulk(track.id);
      }
      if (identical(_inFlight[track.id], future)) {
        _inFlight.remove(track.id);
        _inFlightTracks.remove(track.id);
        _notifyDownloadingChanged();
      }
    }
  }

  Future<String?> _downloadTrackInternal(
    TrackItem track, {
    required bool highPriority,
  }) async {
    final storageDir = getStorageDir();
    if (storageDir.isEmpty) {
      throw Exception('저장소 경로가 준비되지 않았습니다.');
    }
    final granted = await _checkPermissionDeduped();
    if (!granted) {
      return null;
    }
    final rawFormat = getPreferredAudioFormat?.call().trim().toLowerCase();
    final format = rawFormat == 'm4a' ? 'm4a' : 'opus';
    final data = await core.invoke({
      'op': 'download_track',
      'track': track.toCoreJson(),
      'storage_dir': storageDir,
      'format': format,
      if (highPriority) 'priority': true,
    });
    final downloaded =
        (data['downloaded'] as Map<String, dynamic>?) ?? const {};
    final filePath = downloaded['file_path'] as String?;
    final bytes = (downloaded['bytes'] as num?)?.toInt();
    if (filePath != null && filePath.isNotEmpty) {
      _downloadedById[track.id] = track.copyWith(
        filePath: filePath,
        bytes: bytes,
        isDownloaded: true,
      );
      onDownloadedListChanged?.call(downloadedTracks);
    }
    return filePath;
  }

  Future<void> invalidateLocalFile(String videoId) async {
    _downloadedById.remove(videoId);
    final storageDir = getStorageDir();
    if (storageDir.isEmpty || !core.isNativeLoaded) {
      return;
    }
    try {
      await core.invoke({
        'op': 'delete_downloaded',
        'video_id': videoId,
        'storage_dir': storageDir,
      });
      await refreshDownloadedTracks();
    } catch (_) {}
  }

  void prefetchTrack(TrackItem track) {
    if (resolveLocalPath(track) != null ||
        _inFlight.containsKey(track.id) ||
        _prefetching.contains(track.id)) {
      return;
    }
    final storageDir = getStorageDir();
    if (storageDir.isEmpty || !core.isNativeLoaded) {
      return;
    }
    _prefetching.add(track.id);
    unawaited(() async {
      try {
        await ensureLocalFile(track, allowNetwork: true, highPriority: false);
      } catch (_) {
      } finally {
        _prefetching.remove(track.id);
      }
    }());
  }

  void promoteTrackDownload(String videoId) {
    core.promoteTrackDownload(videoId);
  }

  void cancelDownload(String videoId) {
    _inFlight.remove(videoId);
    _inFlightTracks.remove(videoId);
    _notifyDownloadingChanged();
    core.cancelTrackDownload(videoId);
  }
}
