import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

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

class NativeReplicaMusicCore implements ReplicaMusicCoreBridge {
  NativeReplicaMusicCore._();

  static const _suffix = '.rm';
  static const _channel = MethodChannel('io.replicamedia.replica/backend');

  UpdateDownloadProgress _cachedUpdateProgress = const UpdateDownloadProgress(
    downloadedBytes: 0,
    totalBytes: 0,
  );
  Map<String, UpdateDownloadProgress> _cachedTrackProgress = const {};
  bool _pollingUpdate = false;
  bool _pollingTrack = false;

  static ReplicaMusicCoreBridge openOrFallback() {
    if (Platform.isAndroid) {
      return NativeReplicaMusicCore._();
    }
    return _FallbackReplicaMusicCore();
  }

  static NativeReplicaMusicCore? tryOpen() {
    if (Platform.isAndroid) {
      return NativeReplicaMusicCore._();
    }
    return null;
  }

  @override
  bool get isNativeLoaded => true;

  @override
  String get coreVersion => '0.6.1';

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
    final cleanRequest = request.containsKey('priority')
        ? (Map<String, dynamic>.of(request)..remove('priority'))
        : request;
    final raw = await _channel.invokeMethod<String>('invoke', {
      'request': jsonEncode(cleanRequest),
    });
    if (raw == null || raw.isEmpty) {
      throw Exception('백엔드 응답이 비어 있습니다.');
    }
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    if (decoded['ok'] != true) {
      throw Exception(decoded['error']?.toString() ?? '알 수 없는 오류가 발생했습니다.');
    }
    return (decoded['data'] as Map<String, dynamic>?) ?? <String, dynamic>{};
  }

  @override
  UpdateDownloadProgress readUpdateDownloadProgress() {
    if (!_pollingUpdate) {
      _pollingUpdate = true;
      unawaited(
        _channel
            .invokeMapMethod<String, dynamic>('updateProgress')
            .then((map) {
              if (map != null) {
                _cachedUpdateProgress = UpdateDownloadProgress(
                  downloadedBytes:
                      (map['downloaded_bytes'] as num?)?.toInt() ?? 0,
                  totalBytes: (map['total_bytes'] as num?)?.toInt() ?? 0,
                );
              }
            })
            .catchError((_) {})
            .whenComplete(() => _pollingUpdate = false),
      );
    }
    return _cachedUpdateProgress;
  }

  @override
  Map<String, UpdateDownloadProgress> readTrackDownloadProgress() {
    if (!_pollingTrack) {
      _pollingTrack = true;
      unawaited(
        _channel
            .invokeMapMethod<String, dynamic>('trackProgress')
            .then((map) {
              if (map != null) {
                final next = <String, UpdateDownloadProgress>{};
                for (final entry in map.entries) {
                  final val = entry.value;
                  if (val is Map) {
                    next[entry.key] = UpdateDownloadProgress(
                      downloadedBytes:
                          (val['downloaded_bytes'] as num?)?.toInt() ?? 0,
                      totalBytes: (val['total_bytes'] as num?)?.toInt() ?? 0,
                    );
                  }
                }
                _cachedTrackProgress = next;
              }
            })
            .catchError((_) {})
            .whenComplete(() => _pollingTrack = false),
      );
    }
    return _cachedTrackProgress;
  }

  @override
  void cancelUpdateDownload() {
    unawaited(
      _channel.invokeMethod<bool>('cancelUpdate').catchError((_) => false),
    );
  }

  @override
  void cancelTrackDownload(String videoId) {
    final trimmed = videoId.trim();
    if (trimmed.isEmpty) return;
    unawaited(
      _channel
          .invokeMethod<bool>('cancelTrack', {'video_id': trimmed})
          .catchError((_) => false),
    );
  }

  @override
  void promoteTrackDownload(String videoId) {}
}

class _FallbackReplicaMusicCore implements ReplicaMusicCoreBridge {
  static const _suffix = '.rm';

  @override
  bool get isNativeLoaded => false;

  @override
  String get coreVersion => '0.6.1';

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
    throw Exception('네이티브 백엔드가 로드되지 않았습니다.');
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
