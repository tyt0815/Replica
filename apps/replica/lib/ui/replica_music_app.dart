import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../core/error_reporter.dart';
import '../core/platform_adapters.dart';
import '../core/replica_music_core.dart';
import '../core/thumbnail_cache.dart';
import '../models/library_models.dart';
import '../playback/download_manager.dart';
import '../playback/playback_persistence.dart';
import '../playback/replica_audio_handler.dart';
import '../theme/replica_music_theme.dart';
import 'coss_components.dart';
import 'now_playing_sheet.dart';

enum _PlaylistAutoDownload {
  off('안 함'),
  wifiOnly('Wi-Fi에서만'),
  always('항상');

  const _PlaylistAutoDownload(this.label);

  final String label;
}

class ReplicaMusicApp extends StatefulWidget {
  const ReplicaMusicApp({
    super.key,
    required this.core,
    this.adapters,
    this.audioEngine,
    this.audioServiceHandler,
    this.fileExistsOverride,
  });

  final ReplicaMusicCoreBridge core;
  final PlatformAdapters? adapters;
  final AudioEngineBackend? audioEngine;
  final ReplicaAudioServiceHandler? audioServiceHandler;
  final bool Function(String path)? fileExistsOverride;

  @override
  State<ReplicaMusicApp> createState() => _ReplicaMusicAppState();
}

class _ReplicaMusicAppState extends State<ReplicaMusicApp>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  late final PlatformAdapters _adapters;
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  final GlobalKey<ScaffoldMessengerState> _messengerKey =
      GlobalKey<ScaffoldMessengerState>();

  static const String _allSongsPlaylistId = '__local_all_songs__';
  static const String _localHistoryPlaylistId = '__local_history_rm__';
  static const int _historyMaxCount = 100;

  ThemeMode _themeMode = ThemeMode.system;
  String _audioFormat = 'opus';
  int _autoDeleteUnusedDays = 0;
  int _maxStorageGb = 0;
  int _tabIndex = 1;
  bool _isNowPlayingOpen = false;
  bool _nowPlayingOnRight = true;
  AppEnvironmentInfo _env = const AppEnvironmentInfo(
    version: '0.16.1',
    cacheDir: '',
    storageDir: '',
  );
  Map<String, dynamic>? _webSession;
  String? _accountName;
  String? _accountHandle;
  String? _accountAvatarUrl;

  List<PlaylistItem> _rawPlaylists = initialLocalPlaylists();
  List<TrackItem> _downloadedTracks = const [];
  List<TrackItem> _searchResults = const [];
  Map<String, int> _lastPlayedMs = {};
  String? _selectedPlaylistId;
  bool _isEditingPlaylist = false;
  bool _isSavingPlaylistEdit = false;
  List<TrackItem> _editingTracks = const [];
  final Set<TrackItem> _selectedEditingTracks = {};
  final Map<String, _PlaylistAutoDownload> _autoDownloadByPlaylist = {};
  bool _isSavingPlaylistSettings = false;
  bool _isRunningStorageCleanup = false;
  int _cachedDownloadedBytes = 0;
  int _sessionGeneration = 0;
  Set<String> _downloadingTrackIds = {};
  List<TrackItem> _downloadingTracks = const [];
  final Map<String, int> _syncingPlaylistCounts = {};
  final Map<String, Future<void>> _inFlightPlaylistLoads = {};
  final Set<String> _loadedRemotePlaylistIds = {};
  final Map<String, ({int done, int total})> _playlistDownloadProgress = {};
  final Set<String> _cancelledBulkPlaylists = {};
  List<TrackItem> _pendingHistoryTracks = [];
  final Map<String, ({TrackItem track, int syncedAtMs})>
  _recentlySyncedHistory = {};
  bool _isFlushingPendingHistory = false;
  String? _lastHistoryRecordedTrackId;
  Future<void> _historySyncChain = Future<void>.value();
  Future<void> _jsonWriteChain = Future<void>.value();

  bool _isTrackDownloading(String trackId) =>
      _downloadingTrackIds.contains(trackId);

  bool _isPlaylistSyncing(String playlistId) =>
      (_syncingPlaylistCounts[playlistId] ?? 0) > 0;

  void _beginPlaylistSync(String playlistId) {
    if (!mounted) {
      return;
    }
    setState(() {
      _syncingPlaylistCounts[playlistId] =
          (_syncingPlaylistCounts[playlistId] ?? 0) + 1;
    });
  }

  void _endPlaylistSync(String playlistId) {
    if (!mounted) {
      return;
    }
    setState(() {
      final next = (_syncingPlaylistCounts[playlistId] ?? 1) - 1;
      if (next <= 0) {
        _syncingPlaylistCounts.remove(playlistId);
      } else {
        _syncingPlaylistCounts[playlistId] = next;
      }
    });
  }

  late final DownloadManager _downloadManager;
  late final PlaybackPersistence _playbackPersistence;
  late final ReplicaPlaybackController _playback;
  late final ErrorReporter _errorReporter;
  int _errorLogCount = 0;
  bool _isSearching = false;
  bool _isSyncingPlaylists = false;
  bool _isCheckingUpdate = false;
  bool _isUpdatingApp = false;
  String? _searchError;
  String? _toastMessage;
  Timer? _toastTimer;

  final TextEditingController _searchController = TextEditingController();
  final ScrollController _libraryScrollController = ScrollController();
  final ScrollController _detailScrollController = ScrollController();
  final ScrollController _searchScrollController = ScrollController();
  late final PageController _tabPageController;
  late final AnimationController _nowPlayingSheetController;
  final ValueNotifier<double> _dockPagePosition = ValueNotifier<double>(0.0);

  TrackItem? get _activeTrack => _playback.activeTrack;
  bool get _isPlaying => _playback.isPlaying;
  bool get _isDownloadingTrack => _playback.isLoading;
  bool get _hasPreviousTrack => _playback.hasPrevious;
  bool get _hasNextTrack => _playback.hasNext;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tabPageController = PageController(
      initialPage: (_tabIndex - 1).clamp(0, 1),
    );
    _tabPageController.addListener(_onTabPageScroll);
    _nowPlayingSheetController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
      reverseDuration: const Duration(milliseconds: 240),
    );
    _adapters = widget.adapters ?? PlatformAdapters();
    _errorReporter = ErrorReporter(core: widget.core);
    _downloadManager = DownloadManager(
      core: widget.core,
      getStorageDir: () => _env.storageDir,
      ensureStoragePermission: _ensureStoragePermissionForDownload,
      getPreferredAudioFormat: () => _audioFormat,
      fileExistsOverride: widget.fileExistsOverride,
      onDownloadedListChanged: (tracks) {
        if (!mounted) {
          return;
        }
        final grew = tracks.length > _downloadedTracks.length;
        final totalBytes = _computeDownloadedBytes(tracks);
        final downloadedMap = {for (final t in tracks) t.id: t};
        setState(() {
          _downloadedTracks = tracks;
          _cachedDownloadedBytes = totalBytes;
          _rawPlaylists = _applyDownloadedState(_rawPlaylists);
          if (_searchResults.isNotEmpty) {
            _searchResults = _searchResults
                .map((t) {
                  final cached = downloadedMap[t.id];
                  if (cached != null) {
                    return t.copyWith(
                      filePath: cached.filePath,
                      bytes: cached.bytes,
                      isDownloaded: true,
                    );
                  }
                  return t.copyWith(isDownloaded: false);
                })
                .toList(growable: false);
          }
        });
        if (grew && _playlistDownloadProgress.isEmpty) {
          unawaited(_runStorageCleanup());
        }
      },
      onDownloadingIdsChanged: (ids) {
        if (!mounted) {
          return;
        }
        setState(() => _downloadingTrackIds = ids);
      },
      onDownloadingTracksChanged: (tracks) {
        if (!mounted) {
          return;
        }
        setState(() => _downloadingTracks = tracks);
      },
    );
    _playbackPersistence = PlaybackPersistence(
      getDataDir: () => _env.effectiveDataDir,
    );
    _playback = ReplicaPlaybackController(
      downloadManager: _downloadManager,
      persistence: _playbackPersistence,
      engine: widget.audioEngine,
      serviceHandler: widget.audioServiceHandler,
      onMessage: _showSnack,
      onError: (source, message, stackTrace) {
        unawaited(
          _recordErrorReport(
            source: source,
            message: message,
            stackTrace: stackTrace,
          ),
        );
      },
      onTrackUpdated: (updated) {
        if (!mounted) {
          return;
        }
        setState(() {
          _searchResults = _searchResults
              .map((t) => t.id == updated.id ? updated : t)
              .toList(growable: false);
        });
      },
      onTrackPlayed: (track) {
        if (!mounted) {
          return;
        }
        unawaited(_recordTrackPlayed(track));
      },
    );
    _playback.snapshot.addListener(_onPlaybackSnapshotChanged);
    unawaited(_playback.initialize());
    _bootstrap();
  }

  String? _lastUiTrackId;
  bool _lastUiPlaying = false;
  bool _lastUiLoading = false;
  int _lastUiQueueLen = 0;

  void _onPlaybackSnapshotChanged() {
    if (!mounted) {
      return;
    }
    final snap = _playback.snapshot.value;
    final trackId = snap?.track.id;
    final playing = snap?.isPlaying ?? false;
    final loading = snap?.isDownloading ?? false;
    final queueLen = snap?.queue.length ?? 0;
    if (trackId != _lastUiTrackId ||
        playing != _lastUiPlaying ||
        loading != _lastUiLoading ||
        queueLen != _lastUiQueueLen) {
      _lastUiTrackId = trackId;
      _lastUiPlaying = playing;
      _lastUiLoading = loading;
      _lastUiQueueLen = queueLen;
      setState(() {});
    }
  }

  void _onTabPageScroll() {
    if (!_tabPageController.hasClients) {
      return;
    }
    final page = _tabPageController.page;
    if (page != null && (page - _dockPagePosition.value).abs() > 0.001) {
      _dockPagePosition.value = page.clamp(0.0, 1.0);
    }
  }

  void _selectTab(int index, {bool animate = true}) {
    final target = index.clamp(0, 2);
    if (target != 2) {
      FocusManager.instance.primaryFocus?.unfocus();
    }
    if (target == 1 && _tabIndex == 1 && _selectedPlaylistId != null) {
      setState(() => _selectedPlaylistId = null);
      return;
    }
    final wasSettings = _tabIndex == 0;
    if (_tabIndex != target) {
      setState(() => _tabIndex = target);
    }
    if (target == 0) {
      return;
    }
    final pageIndex = (target - 1).clamp(0, 1);
    if (_tabPageController.hasClients) {
      if (animate && !wasSettings) {
        unawaited(
          _tabPageController.animateToPage(
            pageIndex,
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
          ),
        );
      } else {
        _tabPageController.jumpToPage(pageIndex);
      }
    } else {
      _dockPagePosition.value = pageIndex.toDouble();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshDownloadedTracks());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tabPageController.removeListener(_onTabPageScroll);
    _tabPageController.dispose();
    _nowPlayingSheetController.dispose();
    _dockPagePosition.dispose();
    _playback.snapshot.removeListener(_onPlaybackSnapshotChanged);
    unawaited(_playback.dispose());
    _downloadManager.dispose();
    _toastTimer?.cancel();
    _searchController.dispose();
    _libraryScrollController.dispose();
    _detailScrollController.dispose();
    _searchScrollController.dispose();
    super.dispose();
  }

  File? _appSettingsFile() {
    final dir = _env.effectiveDataDir;
    if (dir.isEmpty) {
      return null;
    }
    return File('$dir${Platform.pathSeparator}app_settings.json');
  }

  void _loadAppSettings() {
    final file = _appSettingsFile();
    if (file == null || !file.existsSync()) {
      return;
    }
    try {
      final raw = jsonDecode(file.readAsStringSync());
      if (raw is! Map<String, dynamic>) {
        return;
      }
      final themeStr = raw['theme_mode'] as String?;
      final parsedTheme = switch (themeStr) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
      final rawAudioFormat = (raw['audio_format'] as String?)
          ?.trim()
          .toLowerCase();
      final parsedAudioFormat = rawAudioFormat == 'm4a' ? 'm4a' : 'opus';
      final rawNowPlayingOnRight = raw['now_playing_on_right'];
      final rawUnusedDays = (raw['auto_delete_unused_days'] as num?)?.toInt();
      final rawMaxGb = (raw['max_storage_gb'] as num?)?.toInt();
      if (mounted) {
        setState(() {
          _themeMode = parsedTheme;
          final downloadModes = raw['playlist_auto_download'];
          final legacyIds = raw['auto_download_playlist_ids'];
          if (downloadModes is Map<String, dynamic>) {
            for (final entry in downloadModes.entries) {
              final mode = _PlaylistAutoDownload.values
                  .where((mode) => mode.name == entry.value)
                  .firstOrNull;
              if (mode != null && mode != _PlaylistAutoDownload.off) {
                _autoDownloadByPlaylist[entry.key] = mode;
              }
            }
          } else if (legacyIds is List) {
            for (final id in legacyIds.whereType<String>()) {
              _autoDownloadByPlaylist[id] = _PlaylistAutoDownload.always;
            }
          }
          if (rawAudioFormat == 'opus' || rawAudioFormat == 'm4a') {
            _audioFormat = parsedAudioFormat;
          }
          if (rawNowPlayingOnRight is bool) {
            _nowPlayingOnRight = rawNowPlayingOnRight;
          }
          if (rawUnusedDays != null && rawUnusedDays >= 0) {
            _autoDeleteUnusedDays = rawUnusedDays;
          }
          if (rawMaxGb != null && rawMaxGb >= 0) {
            _maxStorageGb = rawMaxGb;
          }
        });
      }
    } catch (_) {}
  }

  Future<void> _writeJsonFileAtomic(File file, Object data) {
    final encoded = jsonEncode(data);
    _jsonWriteChain = _jsonWriteChain
        .then((_) async {
          try {
            await file.parent.create(recursive: true);
            final tmp = File(
              '${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
            );
            await tmp.writeAsString(encoded);
            try {
              await tmp.rename(file.path);
            } catch (_) {
              if (await file.exists()) {
                await file.delete();
              }
              await tmp.rename(file.path);
            }
          } catch (_) {}
        })
        .catchError((_) {});
    return _jsonWriteChain;
  }

  Future<void> _deleteFileSerialized(File? file) {
    if (file == null) {
      return Future<void>.value();
    }
    _jsonWriteChain = _jsonWriteChain
        .then((_) async {
          try {
            if (await file.exists()) {
              await file.delete();
            }
          } catch (_) {}
        })
        .catchError((_) {});
    return _jsonWriteChain;
  }

  Future<void> _saveAppSettings() async {
    final file = _appSettingsFile();
    if (file == null) {
      return;
    }
    await _writeJsonFileAtomic(file, {
      'theme_mode': _themeMode.name,
      'audio_format': _audioFormat,
      'playlist_auto_download': _autoDownloadByPlaylist.map(
        (id, mode) => MapEntry(id, mode.name),
      ),
      'now_playing_on_right': _nowPlayingOnRight,
      'auto_delete_unused_days': _autoDeleteUnusedDays,
      'max_storage_gb': _maxStorageGb,
    });
  }

  Future<void> _setThemeMode(ThemeMode mode) async {
    if (mounted) {
      setState(() => _themeMode = mode);
    }
    await _saveAppSettings();
  }

  Future<void> _setAudioFormat(String format) async {
    final normalized = format == 'm4a' ? 'm4a' : 'opus';
    if (mounted) {
      setState(() => _audioFormat = normalized);
    }
    await _saveAppSettings();
  }

  Future<void> _setAutoDeleteUnusedDays(int days) async {
    if (mounted) {
      setState(() => _autoDeleteUnusedDays = days);
    }
    await _saveAppSettings();
    if (days > 0) {
      await _runStorageCleanup();
    }
  }

  Future<void> _setMaxStorageGb(int gb) async {
    if (mounted) {
      setState(() => _maxStorageGb = gb);
    }
    await _saveAppSettings();
    if (gb > 0) {
      await _runStorageCleanup();
    }
  }

  File? _playHistoryTimesFile() {
    final dir = _env.effectiveDataDir;
    if (dir.isEmpty) {
      return null;
    }
    return File('$dir${Platform.pathSeparator}play_history_times.json');
  }

  void _loadPlayHistoryTimes() {
    final file = _playHistoryTimesFile();
    if (file == null || !file.existsSync()) {
      return;
    }
    try {
      final raw = jsonDecode(file.readAsStringSync());
      if (raw is! Map) {
        return;
      }
      final loaded = <String, int>{};
      for (final entry in raw.entries) {
        final key = entry.key?.toString() ?? '';
        final val = (entry.value as num?)?.toInt();
        if (key.isNotEmpty && val != null && val > 0) {
          loaded[key] = val;
        }
      }
      _lastPlayedMs = loaded;
    } catch (_) {}
  }

  Future<void> _savePlayHistoryTimes() async {
    final file = _playHistoryTimesFile();
    if (file == null) {
      return;
    }
    await _writeJsonFileAtomic(file, _lastPlayedMs);
  }

  File? _pendingHistoryFile() {
    final dir = _env.effectiveDataDir;
    if (dir.isEmpty) {
      return null;
    }
    return File('$dir${Platform.pathSeparator}pending_history.json');
  }

  void _loadPendingHistoryTracks() {
    final file = _pendingHistoryFile();
    if (file == null || !file.existsSync()) {
      return;
    }
    try {
      final raw = jsonDecode(file.readAsStringSync());
      if (raw is! List) {
        return;
      }
      _pendingHistoryTracks = raw
          .whereType<Map<String, dynamic>>()
          .map(TrackItem.fromCoreJson)
          .where((t) => t.id.isNotEmpty)
          .toList(growable: true);
    } catch (_) {}
  }

  Future<void> _savePendingHistoryTracks() async {
    final file = _pendingHistoryFile();
    if (file == null) {
      return;
    }
    await _writeJsonFileAtomic(
      file,
      _pendingHistoryTracks.map((t) => t.toCoreJson()).toList(growable: false),
    );
  }

  void _enqueuePendingHistoryTrack(TrackItem track) {
    _pendingHistoryTracks.removeWhere((t) => t.id == track.id);
    _pendingHistoryTracks.add(track);
    if (_pendingHistoryTracks.length > 50) {
      _pendingHistoryTracks.removeRange(0, _pendingHistoryTracks.length - 50);
    }
    unawaited(_savePendingHistoryTracks());
  }

  void _flushPendingHistoryTracks() {
    if (_isFlushingPendingHistory ||
        _webSession == null ||
        !widget.core.isNativeLoaded ||
        _pendingHistoryTracks.isEmpty) {
      return;
    }
    _isFlushingPendingHistory = true;
    final gen = _sessionGeneration;
    _historySyncChain = _historySyncChain
        .then((_) async {
          try {
            final toReplay = List<TrackItem>.of(_pendingHistoryTracks);
            for (final track in toReplay) {
              if (gen != _sessionGeneration || _webSession == null) {
                return;
              }
              final ok = await _syncHistoryTrackToRemote(
                track,
                sessionGen: gen,
                requeueOnFailure: false,
              );
              if (!ok) {
                return;
              }
              _pendingHistoryTracks.removeWhere((t) => t.id == track.id);
              await _savePendingHistoryTracks();
            }
          } finally {
            _isFlushingPendingHistory = false;
          }
        })
        .catchError((_) {
          _isFlushingPendingHistory = false;
        });
  }

  Future<Map<String, int>> _resolveLastPlayedTimesAsync(
    List<TrackItem> tracks,
  ) async {
    final result = <String, int>{};
    for (final track in tracks) {
      final recorded = _lastPlayedMs[track.id];
      if (recorded != null && recorded > 0) {
        result[track.id] = recorded;
        continue;
      }
      final path = track.filePath;
      if (path != null && path.isNotEmpty) {
        try {
          final file = File(path);
          if (await file.exists()) {
            result[track.id] =
                (await file.lastModified()).millisecondsSinceEpoch;
            continue;
          }
        } catch (_) {}
      }
      result[track.id] = 0;
    }
    return result;
  }

  int _downloadedFileBytes(TrackItem track) {
    if (track.bytes > 0) {
      return track.bytes;
    }
    final path = track.filePath;
    if (path == null || path.isEmpty) {
      return 0;
    }
    try {
      final file = File(path);
      if (file.existsSync()) {
        return file.lengthSync();
      }
    } catch (_) {}
    return 0;
  }

  int _computeDownloadedBytes(List<TrackItem> tracks) {
    var total = 0;
    for (final track in tracks) {
      total += track.bytes > 0 ? track.bytes : _downloadedFileBytes(track);
    }
    return total;
  }

  int _totalDownloadedBytes() => _cachedDownloadedBytes;

  String _formatBytesLabel(int bytes) {
    if (bytes <= 0) {
      return '0 MB';
    }
    const gb = 1024 * 1024 * 1024;
    const mb = 1024 * 1024;
    if (bytes >= gb) {
      return '${(bytes / gb).toStringAsFixed(2)} GB';
    }
    return '${(bytes / mb).toStringAsFixed(1)} MB';
  }

  Future<void> _runStorageCleanup() async {
    if (_isRunningStorageCleanup ||
        _env.storageDir.isEmpty ||
        (_autoDeleteUnusedDays <= 0 && _maxStorageGb <= 0)) {
      return;
    }
    _isRunningStorageCleanup = true;
    try {
      final activeId = _playback.activeTrack?.id;
      final candidates = List<TrackItem>.of(_downloadedTracks);
      final lastPlayedById = await _resolveLastPlayedTimesAsync(candidates);
      final toDelete = <String>{};

      if (_autoDeleteUnusedDays > 0) {
        final cutoffMs =
            DateTime.now().millisecondsSinceEpoch -
            (_autoDeleteUnusedDays * Duration.millisecondsPerDay);
        for (final track in candidates) {
          if (track.id == activeId) {
            continue;
          }
          final lastMs = lastPlayedById[track.id] ?? 0;
          if (lastMs > 0 && lastMs < cutoffMs) {
            toDelete.add(track.id);
          }
        }
      }

      if (_maxStorageGb > 0) {
        final limitBytes = _maxStorageGb * 1024 * 1024 * 1024;
        final remaining = candidates
            .where((t) => !toDelete.contains(t.id))
            .toList(growable: true);
        var totalBytes = 0;
        for (final t in remaining) {
          totalBytes += _downloadedFileBytes(t);
        }
        if (totalBytes > limitBytes) {
          remaining.sort(
            (a, b) => (lastPlayedById[a.id] ?? 0).compareTo(
              lastPlayedById[b.id] ?? 0,
            ),
          );
          for (final track in remaining) {
            if (totalBytes <= limitBytes) {
              break;
            }
            if (track.id == activeId) {
              continue;
            }
            final size = _downloadedFileBytes(track);
            toDelete.add(track.id);
            totalBytes -= size;
          }
        }
      }

      if (toDelete.isEmpty) {
        return;
      }
      for (final videoId in toDelete) {
        _downloadManager.removeFromDownloadedIndex(videoId);
        try {
          await widget.core.invoke({
            'op': 'delete_downloaded',
            'video_id': videoId,
            'storage_dir': _env.storageDir,
          });
        } catch (_) {}
      }
      await _refreshDownloadedTracks();
    } finally {
      _isRunningStorageCleanup = false;
    }
  }

  String get _currentDeviceName => sanitizeDeviceName(_env.deviceName);

  String get _currentHistoryRemoteTitle =>
      buildHistoryRemoteTitle(_currentDeviceName);

  bool _isHistoryPlaylist(PlaylistItem playlist) =>
      isHistoryRemoteTitle(playlist.remoteTitle);

  bool _isLegacyHistoryPlaylist(PlaylistItem playlist) =>
      playlist.remoteTitle.trim().toLowerCase() == legacyHistoryTitle;

  bool _isCurrentDeviceHistory(PlaylistItem playlist) {
    if (playlist.id == _localHistoryPlaylistId) {
      return true;
    }
    final device = extractHistoryDeviceName(playlist.remoteTitle);
    if (device != null) {
      return device.toLowerCase() == _currentDeviceName.toLowerCase();
    }
    return false;
  }

  bool _isOtherDeviceHistory(PlaylistItem playlist) =>
      _isHistoryPlaylist(playlist) && !_isCurrentDeviceHistory(playlist);

  String _displayTitleForPlaylist(PlaylistItem playlist) {
    if (playlist.id == _allSongsPlaylistId) {
      return '저장된 곡';
    }
    if (_isLegacyHistoryPlaylist(playlist)) {
      return '기록';
    }
    final device = extractHistoryDeviceName(playlist.remoteTitle);
    if (device != null) {
      return device;
    }
    return _cachedDisplayPlaylistTitle(playlist.remoteTitle);
  }

  List<TrackItem> _capHistoryTracks(List<TrackItem> tracks) {
    if (tracks.length > _historyMaxCount) {
      return tracks.sublist(0, _historyMaxCount);
    }
    return tracks;
  }

  void _scheduleRemoteHistoryTrim() {
    if (_webSession == null || !widget.core.isNativeLoaded) {
      return;
    }
    final gen = _sessionGeneration;
    _historySyncChain = _historySyncChain
        .then<void>((_) async {
          await _trimRemoteHistoryPlaylist(
            sessionGen: gen,
            maxTracks: _historyMaxCount,
          );
        })
        .catchError((_) {});
  }

  Future<void> _trimRemoteHistoryPlaylist({
    required int sessionGen,
    required int maxTracks,
  }) async {
    final session = _webSession;
    if (session == null ||
        maxTracks <= 0 ||
        !widget.core.isNativeLoaded ||
        sessionGen != _sessionGeneration) {
      return;
    }
    PlaylistItem? remoteHistory;
    for (final p in _rawPlaylists) {
      if (_isCurrentDeviceHistory(p) && p.isRemote) {
        remoteHistory = p;
        break;
      }
    }
    if (remoteHistory == null || remoteHistory.id.isEmpty) {
      return;
    }
    _beginPlaylistSync(remoteHistory.id);
    try {
      final data = await widget.core.invoke({
        'op': 'trim_history_playlist',
        'playlist_id': remoteHistory.id,
        'max_tracks': maxTracks,
        'session': session,
      });
      if (!mounted || sessionGen != _sessionGeneration || _webSession == null) {
        return;
      }
      final rawList = (data['tracks'] as List<dynamic>?) ?? const [];
      final downloadedMap = {for (final t in _downloadedTracks) t.id: t};
      final trimmedTracks = rawList
          .whereType<Map<String, dynamic>>()
          .map((item) {
            final parsed = TrackItem.fromCoreJson(item);
            final cached = downloadedMap[parsed.id];
            return cached != null
                ? parsed.copyWith(
                    filePath: cached.filePath,
                    bytes: cached.bytes,
                    isDownloaded: true,
                  )
                : parsed;
          })
          .toList(growable: false);
      _loadedRemotePlaylistIds.add(remoteHistory.id);
      setState(() {
        _rawPlaylists = _rawPlaylists
            .map(
              (p) => p.id == remoteHistory!.id
                  ? p.copyWith(
                      tracks: trimmedTracks,
                      thumbnail: trimmedTracks.isNotEmpty
                          ? trimmedTracks.first.thumbnail
                          : '',
                    )
                  : p,
            )
            .toList(growable: false);
      });
      unawaited(_saveCachedPlaylists());
    } catch (_) {
    } finally {
      _endPlaylistSync(remoteHistory.id);
    }
  }

  bool _isHistoryTopTrack(String trackId) {
    for (final p in _rawPlaylists) {
      if (_isCurrentDeviceHistory(p)) {
        return p.tracks.isNotEmpty && p.tracks.first.id == trackId;
      }
    }
    return false;
  }

  ({String? preservedSetVideoId, List<TrackItem> overflowTargets})
  _inspectHistoryBeforeInsert(TrackItem track) {
    String? preservedSetVideoId;
    var overflowTargets = const <TrackItem>[];
    final idx = _rawPlaylists.indexWhere(_isCurrentDeviceHistory);
    if (idx >= 0) {
      final existing = _rawPlaylists[idx];
      for (final t in existing.tracks) {
        if (t.id == track.id &&
            t.setVideoId != null &&
            t.setVideoId!.isNotEmpty) {
          preservedSetVideoId = t.setVideoId;
          break;
        }
      }
      final trackToInsert = preservedSetVideoId != null
          ? track.copyWith(setVideoId: preservedSetVideoId)
          : track;
      final fullUpdated = [
        trackToInsert,
        ...existing.tracks.where((t) => t.id != track.id),
      ];
      if (fullUpdated.length > _historyMaxCount) {
        overflowTargets = fullUpdated.sublist(_historyMaxCount);
      }
    }
    return (
      preservedSetVideoId: preservedSetVideoId,
      overflowTargets: overflowTargets,
    );
  }

  void _applyTrackToLocalHistory(
    TrackItem track, {
    String? preservedSetVideoId,
  }) {
    if (!mounted) {
      return;
    }
    setState(() {
      final idx = _rawPlaylists.indexWhere(_isCurrentDeviceHistory);
      if (idx >= 0) {
        final existing = _rawPlaylists[idx];
        final trackToInsert = preservedSetVideoId != null
            ? track.copyWith(setVideoId: preservedSetVideoId)
            : track;
        final fullUpdated = [
          trackToInsert,
          ...existing.tracks.where((t) => t.id != track.id),
        ];
        final updatedTracks = _capHistoryTracks(fullUpdated);
        final updated = existing.copyWith(
          tracks: updatedTracks,
          thumbnail: track.thumbnail.isNotEmpty
              ? track.thumbnail
              : existing.thumbnail,
        );
        final next = List<PlaylistItem>.of(_rawPlaylists);
        next[idx] = updated;
        _rawPlaylists = next;
      } else {
        final localHistory = PlaylistItem(
          id: _localHistoryPlaylistId,
          remoteTitle: _currentHistoryRemoteTitle,
          owner: _webSession != null ? 'YouTube' : '로컬',
          description: '최근 재생한 곡 기록',
          coverColor: const Color(0xFF27272A),
          thumbnail: track.thumbnail,
          tracks: [track],
          isRemote: false,
        );
        _rawPlaylists = [localHistory, ..._rawPlaylists];
      }
    });
    unawaited(_saveCachedPlaylists());
  }

  Future<void> _recordTrackPlayed(TrackItem track) async {
    _lastPlayedMs[track.id] = DateTime.now().millisecondsSinceEpoch;
    unawaited(_savePlayHistoryTimes());
    if (_lastHistoryRecordedTrackId == track.id &&
        _isHistoryTopTrack(track.id)) {
      return;
    }
    _lastHistoryRecordedTrackId = track.id;

    final inspected = _inspectHistoryBeforeInsert(track);
    _applyTrackToLocalHistory(
      track,
      preservedSetVideoId: inspected.preservedSetVideoId,
    );

    final isOnline = _webSession != null && widget.core.isNativeLoaded;
    if (isOnline) {
      final gen = _sessionGeneration;
      final targets = inspected.overflowTargets;
      final knownSetVideoId = inspected.preservedSetVideoId;
      _historySyncChain = _historySyncChain
          .then<void>((_) async {
            await _syncHistoryTrackToRemote(
              track,
              sessionGen: gen,
              requeueOnFailure: true,
              existingSetVideoId: knownSetVideoId,
              trimTargets: targets,
            );
          })
          .catchError((_) {});
    } else {
      _enqueuePendingHistoryTrack(track);
    }
  }

  Future<bool> _syncHistoryTrackToRemote(
    TrackItem track, {
    required int sessionGen,
    required bool requeueOnFailure,
    String? existingSetVideoId,
    List<TrackItem> trimTargets = const [],
  }) async {
    final session = _webSession;
    if (session == null ||
        !widget.core.isNativeLoaded ||
        sessionGen != _sessionGeneration) {
      return false;
    }
    final targetRemoteTitle = _currentHistoryRemoteTitle;
    try {
      PlaylistItem? remoteHistory;
      for (final p in _rawPlaylists) {
        if (_isCurrentDeviceHistory(p) && p.isRemote) {
          remoteHistory = p;
          break;
        }
      }
      if (remoteHistory == null) {
        final listData = await widget.core.invoke({
          'op': 'list_playlists',
          'session': session,
        });
        if (sessionGen != _sessionGeneration || _webSession == null) {
          return false;
        }
        final rawList = (listData['playlists'] as List<dynamic>?) ?? const [];
        PlaylistItem? legacyHistory;
        for (final item in rawList.whereType<Map<String, dynamic>>()) {
          final parsed = PlaylistItem.fromCoreJson(item);
          if (_isCurrentDeviceHistory(parsed)) {
            remoteHistory = parsed;
            break;
          }
          if (legacyHistory == null && _isLegacyHistoryPlaylist(parsed)) {
            legacyHistory = parsed;
          }
        }
        if (remoteHistory == null && legacyHistory != null) {
          await widget.core.invoke({
            'op': 'rename_playlist',
            'playlist_id': legacyHistory.id,
            'new_remote_title': targetRemoteTitle,
            'session': session,
          });
          remoteHistory = legacyHistory.copyWith(
            remoteTitle: targetRemoteTitle,
          );
        }
      }
      if (remoteHistory == null) {
        final createdData = await widget.core.invoke({
          'op': 'create_playlist',
          'title': 'History',
          'remote_title': targetRemoteTitle,
          'session': session,
        });
        if (sessionGen != _sessionGeneration || _webSession == null) {
          return false;
        }
        final rawPl =
            (createdData['playlist'] as Map<String, dynamic>?) ?? const {};
        if (rawPl.isNotEmpty && mounted) {
          final created = PlaylistItem.fromCoreJson(rawPl);
          if (created.id.isNotEmpty) {
            final local = _rawPlaylists
                .where(_isCurrentDeviceHistory)
                .firstOrNull;
            final bound = created.copyWith(tracks: local?.tracks);
            setState(() {
              _rawPlaylists = [
                bound,
                ..._rawPlaylists.where(
                  (p) => !_isCurrentDeviceHistory(p) && p.id != bound.id,
                ),
              ];
              if (_selectedPlaylistId == _localHistoryPlaylistId) {
                _selectedPlaylistId = bound.id;
              }
            });
            remoteHistory = bound;
            await _saveCachedPlaylists();
          }
        }
      }
      if (remoteHistory == null || remoteHistory.id.isEmpty) {
        if (requeueOnFailure) {
          _enqueuePendingHistoryTrack(track);
        }
        return false;
      }

      final historyLoaded = _loadedRemotePlaylistIds.contains(remoteHistory.id);
      String? resolvedSetVideoId = existingSetVideoId?.trim();
      if (resolvedSetVideoId == null || resolvedSetVideoId.isEmpty) {
        resolvedSetVideoId = null;
        if (historyLoaded) {
          for (final t in remoteHistory.tracks) {
            if (t.id == track.id &&
                t.setVideoId != null &&
                t.setVideoId!.isNotEmpty) {
              resolvedSetVideoId = t.setVideoId;
              break;
            }
          }
        }
      }

      final trimPayload = historyLoaded
          ? trimTargets
                .map((t) => {'video_id': t.id, 'set_video_id': ?t.setVideoId})
                .toList(growable: false)
          : const <Map<String, dynamic>>[];

      _beginPlaylistSync(remoteHistory.id);
      final Map<String, dynamic> recordData;
      try {
        recordData = await widget.core.invoke({
          'op': 'record_history_track',
          'playlist_id': remoteHistory.id,
          'video_id': track.id,
          'track': track.toCoreJson(),
          'existing_set_video_id': ?resolvedSetVideoId,
          'playlist_loaded': historyLoaded,
          'max_tracks': _historyMaxCount,
          if (trimPayload.isNotEmpty) 'trim_targets': trimPayload,
          'session': session,
        });
      } finally {
        _endPlaylistSync(remoteHistory.id);
      }
      if (!mounted || sessionGen != _sessionGeneration || _webSession == null) {
        return false;
      }
      final returnedSvid = (recordData['set_video_id'] as String?)?.trim();
      final rawTracks = recordData['tracks'] as List<dynamic>?;
      final downloadedMap = {for (final t in _downloadedTracks) t.id: t};

      List<TrackItem> mergedTracks;
      if (rawTracks != null) {
        _loadedRemotePlaylistIds.add(remoteHistory.id);
        mergedTracks = rawTracks
            .whereType<Map<String, dynamic>>()
            .map((item) {
              final parsed = TrackItem.fromCoreJson(item);
              final cached = downloadedMap[parsed.id];
              return cached != null
                  ? parsed.copyWith(
                      filePath: cached.filePath,
                      bytes: cached.bytes,
                      isDownloaded: true,
                    )
                  : parsed;
            })
            .toList(growable: false);
      } else {
        PlaylistItem? latestHistory;
        for (final p in _rawPlaylists) {
          if (_isCurrentDeviceHistory(p)) {
            latestHistory = p;
            break;
          }
        }
        final baseTracks = latestHistory?.tracks ?? remoteHistory.tracks;
        final cached = downloadedMap[track.id];
        final updatedTrack = track.copyWith(
          setVideoId: (returnedSvid != null && returnedSvid.isNotEmpty)
              ? returnedSvid
              : resolvedSetVideoId,
          filePath: cached?.filePath,
          bytes: cached?.bytes,
          isDownloaded: cached != null ? true : track.isDownloaded,
        );
        if (baseTracks.isNotEmpty && baseTracks.first.id != track.id) {
          var replaced = false;
          mergedTracks = baseTracks
              .map((t) {
                if (t.id == track.id) {
                  replaced = true;
                  return updatedTrack;
                }
                return t;
              })
              .toList(growable: false);
          if (!replaced) {
            mergedTracks = [...mergedTracks, updatedTrack];
          }
        } else {
          mergedTracks = [
            updatedTrack,
            ...baseTracks.where((t) => t.id != track.id),
          ];
        }
      }

      if (_pendingHistoryTracks.isNotEmpty) {
        final remainingPending = _pendingHistoryTracks
            .where((t) => t.id != track.id)
            .toList(growable: false)
            .reversed
            .toList(growable: false);
        if (remainingPending.isNotEmpty) {
          final pendingIds = remainingPending.map((t) => t.id).toSet();
          mergedTracks = [
            ...remainingPending.map((t) {
              final cached = downloadedMap[t.id];
              return cached != null
                  ? t.copyWith(
                      filePath: cached.filePath,
                      bytes: cached.bytes,
                      isDownloaded: true,
                    )
                  : t;
            }),
            ...mergedTracks.where((t) => !pendingIds.contains(t.id)),
          ];
        }
      }

      mergedTracks = _capHistoryTracks(mergedTracks);
      final finalHistory = remoteHistory.copyWith(
        tracks: mergedTracks.isNotEmpty ? mergedTracks : [track],
        thumbnail: mergedTracks.isNotEmpty
            ? mergedTracks.first.thumbnail
            : track.thumbnail,
        hasPendingLocalEdit: false,
      );
      setState(() {
        final wasViewingLocalHistory =
            _selectedPlaylistId == _localHistoryPlaylistId;
        final withoutOld = _rawPlaylists
            .where(
              (p) => !_isCurrentDeviceHistory(p) && p.id != finalHistory.id,
            )
            .toList(growable: false);
        _rawPlaylists = [finalHistory, ...withoutOld];
        if (wasViewingLocalHistory) {
          _selectedPlaylistId = finalHistory.id;
        }
      });
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final syncedTrack = mergedTracks.firstWhere(
        (t) => t.id == track.id,
        orElse: () => track.copyWith(
          setVideoId: (returnedSvid != null && returnedSvid.isNotEmpty)
              ? returnedSvid
              : resolvedSetVideoId,
        ),
      );
      _recentlySyncedHistory[track.id] = (
        track: syncedTrack,
        syncedAtMs: nowMs,
      );
      _recentlySyncedHistory.removeWhere(
        (_, v) => nowMs - v.syncedAtMs > 15000,
      );
      unawaited(_saveCachedPlaylists());
      return true;
    } catch (e, st) {
      unawaited(
        _recordErrorReport(
          source: 'HistorySync',
          message: '기록 동기화 실패 (${track.id}): $e',
          stackTrace: st.toString(),
        ),
      );
      if (requeueOnFailure) {
        _enqueuePendingHistoryTrack(track);
      }
      return false;
    }
  }

  Future<void> _setNowPlayingOnRight(bool onRight) async {
    if (_nowPlayingOnRight == onRight) {
      return;
    }
    if (mounted) {
      setState(() => _nowPlayingOnRight = onRight);
    }
    await _saveAppSettings();
  }

  File? _playlistsCacheFile() {
    final dir = _env.effectiveDataDir;
    if (dir.isEmpty) {
      return null;
    }
    return File('$dir${Platform.pathSeparator}playlists_cache.json');
  }

  void _loadCachedPlaylists() {
    final file = _playlistsCacheFile();
    if (file == null || !file.existsSync()) {
      return;
    }
    try {
      final raw = jsonDecode(file.readAsStringSync());
      if (raw is! List) {
        return;
      }
      final loaded = raw
          .whereType<Map<String, dynamic>>()
          .map(PlaylistItem.fromCacheJson)
          .where((p) => p.id.isNotEmpty && p.remoteTitle.isNotEmpty)
          .toList(growable: false);
      if (mounted) {
        setState(() => _rawPlaylists = _applyDownloadedState(loaded));
      }
    } catch (_) {}
  }

  Future<void> _saveCachedPlaylists() async {
    final file = _playlistsCacheFile();
    if (file == null) {
      return;
    }
    final encoded = _rawPlaylists
        .map((p) => p.toCacheJson())
        .toList(growable: false);
    await _writeJsonFileAtomic(file, encoded);
  }

  List<PlaylistItem> _applyDownloadedState(List<PlaylistItem> playlists) {
    final downloadedMap = {for (final t in _downloadedTracks) t.id: t};
    return playlists
        .map((pl) {
          final mergedTracks = pl.tracks
              .map((t) {
                final cached = downloadedMap[t.id];
                if (cached != null) {
                  return t.copyWith(
                    filePath: cached.filePath,
                    bytes: cached.bytes,
                    isDownloaded: true,
                  );
                }
                return t.copyWith(isDownloaded: false);
              })
              .toList(growable: false);
          return pl.copyWith(tracks: mergedTracks);
        })
        .toList(growable: false);
  }

  File? _accountProfileCacheFile() {
    final dir = _env.effectiveDataDir;
    if (dir.isEmpty) {
      return null;
    }
    return File('$dir${Platform.pathSeparator}account_profile.json');
  }

  void _loadCachedAccountProfile() {
    final file = _accountProfileCacheFile();
    if (file == null || !file.existsSync()) {
      return;
    }
    try {
      final raw = jsonDecode(file.readAsStringSync());
      if (raw is! Map<String, dynamic>) {
        return;
      }
      if (mounted) {
        setState(() {
          _accountName = raw['name'] as String?;
          _accountHandle = raw['handle'] as String?;
          _accountAvatarUrl = raw['avatar_url'] as String?;
        });
      }
    } catch (_) {}
  }

  Future<void> _saveCachedAccountProfile() async {
    final file = _accountProfileCacheFile();
    if (file == null) {
      return;
    }
    await _writeJsonFileAtomic(file, {
      'name': _accountName,
      'handle': _accountHandle,
      'avatar_url': _accountAvatarUrl,
    });
  }

  Future<void> _refreshAccountProfile() async {
    final session = _webSession;
    final gen = _sessionGeneration;
    if (session == null || !widget.core.isNativeLoaded) {
      return;
    }
    try {
      final data = await widget.core.invoke({
        'op': 'account_profile',
        'session': session,
      });
      final profile = (data['profile'] as Map<String, dynamic>?) ?? const {};
      final name = (profile['name'] as String?)?.trim();
      final handle = (profile['handle'] as String?)?.trim();
      final avatar = (profile['avatar_url'] as String?)?.trim();
      if (!mounted || gen != _sessionGeneration || _webSession == null) {
        return;
      }
      setState(() {
        if (name != null && name.isNotEmpty) {
          _accountName = name;
        }
        _accountHandle = (handle != null && handle.isNotEmpty) ? handle : null;
        _accountAvatarUrl = (avatar != null && avatar.isNotEmpty)
            ? avatar
            : null;
      });
      await _saveCachedAccountProfile();
    } catch (_) {}
  }

  Future<void> _bootstrap() async {
    final env = await _adapters.loadEnvironment(
      fallbackVersion: widget.core.coreVersion,
    );
    final session = await _adapters.readWebSession();
    if (!mounted) {
      return;
    }
    setState(() {
      _env = env;
      _webSession = session;
    });
    ThumbnailCache.instance.configure(
      cacheDir: env.cacheDir,
      storageDir: env.storageDir,
    );
    await _errorReporter.initialize(
      dataDir: env.effectiveDataDir,
      appVersion: env.version,
    );
    if (mounted) {
      setState(() => _errorLogCount = _errorReporter.logCount);
    }
    _loadAppSettings();
    _loadPlayHistoryTimes();
    _loadPendingHistoryTracks();
    _loadCachedPlaylists();
    _playback.restorePersistedState();
    if (session != null) {
      _loadCachedAccountProfile();
    }

    final startupTasks = <Future<void>>[
      _refreshDownloadedTracks().then((_) => _runStorageCleanup()),
      if (session != null) _refreshAccountProfile(),
      if (session != null) _syncRemotePlaylists(silent: true),
    ];
    await Future.wait(startupTasks);
  }

  void _showSnack(String message) {
    _toastTimer?.cancel();
    if (!mounted) {
      return;
    }
    setState(() => _toastMessage = message);
    _toastTimer = Timer(const Duration(milliseconds: 2600), () {
      if (mounted) {
        setState(() => _toastMessage = null);
      }
    });
  }

  final Map<String, String> _displayTitleCache = {};
  final Set<String> _pendingHeroPalettes = {};

  String _cachedDisplayPlaylistTitle(String remoteTitle) {
    return _displayTitleCache.putIfAbsent(
      remoteTitle,
      () => widget.core.toDisplayPlaylistTitle(remoteTitle),
    );
  }

  PlaylistItem get _allSongsPlaylist => PlaylistItem(
    id: _allSongsPlaylistId,
    remoteTitle: '저장된 곡.rm',
    owner: '로컬',
    description: '기기에 다운로드된 모든 곡',
    coverColor: replicaAccentColor,
    thumbnail: _downloadedTracks.isNotEmpty
        ? _downloadedTracks.first.thumbnail
        : '',
    tracks: _downloadedTracks,
    isRemote: false,
  );

  List<PlaylistItem> get _visiblePlaylists => _rawPlaylists
      .where((item) => widget.core.isReplicaPlaylist(item.remoteTitle))
      .toList(growable: false);

  PlaylistItem? get _selectedPlaylist {
    if (_selectedPlaylistId == null) {
      return null;
    }
    if (_selectedPlaylistId == _allSongsPlaylistId) {
      return _allSongsPlaylist;
    }
    for (final item in _visiblePlaylists) {
      if (item.id == _selectedPlaylistId) {
        return item;
      }
    }
    return null;
  }

  Future<void> _refreshLibrary() async {
    await _refreshDownloadedTracks();
    if (_webSession != null) {
      await _syncRemotePlaylists(silent: false);
    } else {
      _loadCachedPlaylists();
    }
  }

  Future<void> _refreshDownloadedTracks() async {
    await _downloadManager.refreshDownloadedTracks();
  }

  Future<void> _syncRemotePlaylists({bool silent = false}) async {
    final session = _webSession;
    final gen = _sessionGeneration;
    if (session == null || _isSyncingPlaylists) {
      return;
    }
    setState(() => _isSyncingPlaylists = true);
    try {
      final data = await widget.core.invoke({
        'op': 'list_playlists',
        'session': session,
      });
      if (!mounted || gen != _sessionGeneration || _webSession == null) {
        return;
      }
      final rawList = (data['playlists'] as List<dynamic>?) ?? const [];
      final parsedRemote = rawList
          .whereType<Map<String, dynamic>>()
          .map(PlaylistItem.fromCoreJson)
          .toList(growable: true);

      final hasCurrentDeviceRemote = parsedRemote.any(_isCurrentDeviceHistory);
      if (!hasCurrentDeviceRemote) {
        final legacyIdx = parsedRemote.indexWhere(_isLegacyHistoryPlaylist);
        if (legacyIdx >= 0) {
          final legacy = parsedRemote[legacyIdx];
          final targetTitle = _currentHistoryRemoteTitle;
          try {
            await widget.core.invoke({
              'op': 'rename_playlist',
              'playlist_id': legacy.id,
              'new_remote_title': targetTitle,
              'session': session,
            });
            if (!mounted || gen != _sessionGeneration || _webSession == null) {
              return;
            }
            parsedRemote[legacyIdx] = legacy.copyWith(remoteTitle: targetTitle);
          } catch (_) {}
        }
      }

      final existingById = {for (final p in _rawPlaylists) p.id: p};
      PlaylistItem? localCurrentHistory;
      for (final p in _rawPlaylists) {
        if (_isCurrentDeviceHistory(p)) {
          localCurrentHistory = p;
          break;
        }
      }

      String? remoteCurrentHistoryId;
      final playlistsToPush = <PlaylistItem>[];
      final playlistsToRefresh = <PlaylistItem>[];
      final remote = <PlaylistItem>[];

      for (final parsed in parsedRemote) {
        if (_isCurrentDeviceHistory(parsed)) {
          remoteCurrentHistoryId = parsed.id;
          final existing = existingById[parsed.id] ?? localCurrentHistory;
          final merged = existing != null && existing.tracks.isNotEmpty
              ? parsed.copyWith(
                  tracks: existing.tracks,
                  thumbnail: existing.thumbnail.isNotEmpty
                      ? existing.thumbnail
                      : parsed.thumbnail,
                  hasPendingLocalEdit: existing.hasPendingLocalEdit,
                )
              : parsed;
          remote.add(merged);
          continue;
        }

        if (_isOtherDeviceHistory(parsed)) {
          final existing = existingById[parsed.id];
          remote.add(
            existing != null && existing.tracks.isNotEmpty
                ? parsed.copyWith(
                    tracks: existing.tracks,
                    thumbnail: existing.thumbnail.isNotEmpty
                        ? existing.thumbnail
                        : parsed.thumbnail,
                  )
                : parsed,
          );
          continue;
        }

        final existing = existingById[parsed.id];
        if (existing == null) {
          remote.add(parsed);
          continue;
        }

        final localTs = existing.updatedAt;
        final remoteTs = parsed.updatedAt;
        if (existing.hasPendingLocalEdit || localTs > remoteTs) {
          final effectiveTs = localTs > remoteTs
              ? localTs
              : nextPlaylistTimestamp(remoteTs);
          final effectiveTitle = buildVersionedRemoteTitle(
            parsed.remoteTitle,
            effectiveTs,
          );
          final merged = parsed.copyWith(
            remoteTitle: effectiveTitle,
            updatedAt: effectiveTs,
            tracks: existing.tracks,
            thumbnail: existing.thumbnail.isNotEmpty
                ? existing.thumbnail
                : parsed.thumbnail,
            hasPendingLocalEdit: true,
          );
          remote.add(merged);
          playlistsToPush.add(merged);
        } else if (remoteTs > localTs) {
          _loadedRemotePlaylistIds.remove(parsed.id);
          final merged = parsed.copyWith(
            tracks: existing.tracks,
            hasPendingLocalEdit: false,
          );
          remote.add(merged);
          if (_selectedPlaylistId == parsed.id) {
            playlistsToRefresh.add(merged);
          }
        } else {
          final merged = existing.tracks.isNotEmpty
              ? parsed.copyWith(
                  tracks: existing.tracks,
                  thumbnail: existing.thumbnail.isNotEmpty
                      ? existing.thumbnail
                      : parsed.thumbnail,
                  hasPendingLocalEdit: false,
                )
              : parsed;
          if (remoteTs > 0 && existing.tracks.isNotEmpty) {
            _loadedRemotePlaylistIds.add(parsed.id);
          }
          remote.add(merged);
        }
      }

      if (remoteCurrentHistoryId == null &&
          localCurrentHistory != null &&
          localCurrentHistory.tracks.isNotEmpty) {
        remote.insert(0, localCurrentHistory);
      }
      if (!mounted || gen != _sessionGeneration || _webSession == null) {
        return;
      }
      setState(() {
        _rawPlaylists = _applyDownloadedState(remote);
        if (remoteCurrentHistoryId != null &&
            _selectedPlaylistId == _localHistoryPlaylistId) {
          _selectedPlaylistId = remoteCurrentHistoryId;
        }
      });
      await _saveCachedPlaylists();
      for (final pl in playlistsToPush) {
        unawaited(
          _pushLocalPlaylistToRemote(
            pl,
            pl.tracks,
            targetRemoteTitle: pl.remoteTitle,
            targetUpdatedAt: pl.updatedAt,
          ),
        );
      }
      final pushingIds = playlistsToPush.map((playlist) => playlist.id).toSet();
      final refreshing = {
        for (final pl in playlistsToRefresh) pl.id: pl,
        for (final pl in remote)
          if (_autoDownloadByPlaylist.containsKey(pl.id) &&
              !pushingIds.contains(pl.id))
            pl.id: pl,
      };
      for (final pl in refreshing.values) {
        unawaited(_loadPlaylistTracks(pl, forceRefresh: true));
      }
      _flushPendingHistoryTracks();
    } catch (e) {
      if (!silent) {
        _showSnack(
          '재생목록 동기화 실패 (오프라인 캐시 유지): ${e.toString().replaceFirst('Exception: ', '')}',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSyncingPlaylists = false);
      }
    }
  }

  Future<void> _loadPlaylistTracks(
    PlaylistItem playlist, {
    bool forceRefresh = false,
  }) {
    if (!playlist.isRemote) {
      return Future<void>.value();
    }
    final existing = _inFlightPlaylistLoads[playlist.id];
    if (existing != null && !forceRefresh) {
      return existing;
    }
    final future = _loadPlaylistTracksInternal(
      playlist,
      forceRefresh: forceRefresh,
    );
    _inFlightPlaylistLoads[playlist.id] = future;
    future.whenComplete(() {
      if (identical(_inFlightPlaylistLoads[playlist.id], future)) {
        _inFlightPlaylistLoads.remove(playlist.id);
      }
    });
    return future;
  }

  Future<void> _loadPlaylistTracksInternal(
    PlaylistItem playlist, {
    bool forceRefresh = false,
  }) async {
    final gen = _sessionGeneration;

    PlaylistItem? findCurrentPlaylist() {
      for (final p in _rawPlaylists) {
        if (p.id == playlist.id) {
          return p;
        }
      }
      return null;
    }

    final isCurrentHistory = _isCurrentDeviceHistory(playlist);
    final localBeforeWait = findCurrentPlaylist();
    if (localBeforeWait != null && !forceRefresh) {
      if (isCurrentHistory &&
          !localBeforeWait.hasPendingLocalEdit &&
          (localBeforeWait.tracks.isNotEmpty ||
              _loadedRemotePlaylistIds.contains(playlist.id))) {
        return;
      }
      if (!isCurrentHistory &&
          !localBeforeWait.hasPendingLocalEdit &&
          _loadedRemotePlaylistIds.contains(playlist.id)) {
        return;
      }
    }

    if (isCurrentHistory) {
      await _historySyncChain;
      if (!mounted || gen != _sessionGeneration) {
        return;
      }
    }

    final localAfterWait = findCurrentPlaylist();
    if (localAfterWait != null && _webSession != null) {
      if (localAfterWait.hasPendingLocalEdit) {
        await _pushLocalPlaylistToRemote(
          localAfterWait,
          localAfterWait.tracks,
          targetRemoteTitle: _isHistoryPlaylist(localAfterWait)
              ? null
              : localAfterWait.remoteTitle,
          targetUpdatedAt: _isHistoryPlaylist(localAfterWait)
              ? null
              : localAfterWait.updatedAt,
        );
        return;
      }
      if (isCurrentHistory &&
          !forceRefresh &&
          (localAfterWait.tracks.isNotEmpty ||
              _loadedRemotePlaylistIds.contains(playlist.id))) {
        return;
      }
    }

    _beginPlaylistSync(playlist.id);
    try {
      final data = await widget.core.invoke({
        'op': 'playlist_tracks',
        'playlist_id': playlist.id,
        if (_webSession != null) 'session': _webSession,
      });
      if (!mounted || gen != _sessionGeneration) {
        return;
      }
      _loadedRemotePlaylistIds.add(playlist.id);
      final latestPlaylist = findCurrentPlaylist();
      if (latestPlaylist == null) {
        return;
      }
      if (!isCurrentHistory && latestPlaylist.hasPendingLocalEdit) {
        return;
      }
      final rawList = (data['tracks'] as List<dynamic>?) ?? const [];
      final downloadedMap = {for (final t in _downloadedTracks) t.id: t};
      var remoteTracks = rawList
          .whereType<Map<String, dynamic>>()
          .map((item) {
            final parsed = TrackItem.fromCoreJson(item);
            final cached = downloadedMap[parsed.id];
            return cached != null
                ? parsed.copyWith(
                    filePath: cached.filePath,
                    bytes: cached.bytes,
                    isDownloaded: true,
                  )
                : parsed;
          })
          .toList(growable: false);
      if (!mounted || gen != _sessionGeneration) {
        return;
      }

      if (isCurrentHistory) {
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        _recentlySyncedHistory.removeWhere(
          (_, v) => nowMs - v.syncedAtMs > 8000,
        );
        final protectedTracks = <TrackItem>[];
        if (_pendingHistoryTracks.isNotEmpty) {
          protectedTracks.addAll(_pendingHistoryTracks.reversed);
        }
        if (_recentlySyncedHistory.isNotEmpty) {
          final recentSorted = _recentlySyncedHistory.values.toList()
            ..sort((a, b) => b.syncedAtMs.compareTo(a.syncedAtMs));
          for (final entry in recentSorted) {
            if (!protectedTracks.any((t) => t.id == entry.track.id)) {
              protectedTracks.add(entry.track);
            }
          }
        }
        if (protectedTracks.isNotEmpty) {
          final protectedIds = protectedTracks.map((t) => t.id).toSet();
          remoteTracks = [
            ...protectedTracks.map((t) {
              final cached = downloadedMap[t.id];
              return cached != null
                  ? t.copyWith(
                      filePath: cached.filePath,
                      bytes: cached.bytes,
                      isDownloaded: true,
                    )
                  : t;
            }),
            ...remoteTracks.where((t) => !protectedIds.contains(t.id)),
          ];
        }
      }

      final needsRemoteHistoryTrim =
          isCurrentHistory && remoteTracks.length > _historyMaxCount;
      if (needsRemoteHistoryTrim) {
        remoteTracks = remoteTracks.sublist(0, _historyMaxCount);
      }

      setState(() {
        _rawPlaylists = _rawPlaylists
            .map(
              (p) => p.id == playlist.id
                  ? p.copyWith(
                      tracks: remoteTracks,
                      hasPendingLocalEdit: false,
                      thumbnail: remoteTracks.isNotEmpty
                          ? remoteTracks.first.thumbnail
                          : '',
                    )
                  : p,
            )
            .toList(growable: false);
      });
      unawaited(_saveCachedPlaylists());
      _maybeAutoDownload(latestPlaylist, remoteTracks);
      if (needsRemoteHistoryTrim) {
        _scheduleRemoteHistoryTrim();
      }
    } catch (e) {
      if (playlist.tracks.isEmpty) {
        _showSnack(
          '오프라인 상태이거나 곡 목록을 불러오지 못했습니다: ${e.toString().replaceFirst('Exception: ', '')}',
        );
      }
    } finally {
      _endPlaylistSync(playlist.id);
    }
  }

  Future<void> _handleAccountAction() async {
    if (_webSession != null) {
      _sessionGeneration += 1;
      await _adapters.logoutWebSession();
      if (!mounted) {
        return;
      }
      setState(() {
        _webSession = null;
        _accountName = null;
        _accountHandle = null;
        _accountAvatarUrl = null;
        _pendingHistoryTracks = [];
        _recentlySyncedHistory.clear();
        _loadedRemotePlaylistIds.clear();
        _cancelledBulkPlaylists.clear();
        _rawPlaylists = _rawPlaylists
            .where((p) => !p.isRemote)
            .toList(growable: false);
        _selectedPlaylistId = null;
      });
      await _deleteFileSerialized(_pendingHistoryFile());
      await _deleteFileSerialized(_accountProfileCacheFile());
      await _saveCachedPlaylists();
      _showSnack('Google 계정 연결을 해제했습니다.');
      return;
    }
    try {
      final session = await _adapters.loginWebSession();
      if (!mounted || session == null) {
        return;
      }
      _sessionGeneration += 1;
      setState(() => _webSession = session);
      _showSnack('Google 계정이 연결되었습니다.');
      await _refreshAccountProfile();
      await _syncRemotePlaylists(silent: false);
    } catch (e) {
      _showSnack(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _runSearch(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      return;
    }
    setState(() {
      _isSearching = true;
      _searchError = null;
    });
    try {
      final data = await widget.core.invoke({
        'op': 'search',
        'query': trimmed,
        if (_webSession != null) 'session': _webSession,
      });
      final rawList = (data['tracks'] as List<dynamic>?) ?? const [];
      final downloadedMap = {for (final t in _downloadedTracks) t.id: t};
      final results = rawList
          .whereType<Map<String, dynamic>>()
          .map((item) {
            final parsed = TrackItem.fromCoreJson(item);
            final cached = downloadedMap[parsed.id];
            return cached != null
                ? parsed.copyWith(filePath: cached.filePath, isDownloaded: true)
                : parsed;
          })
          .toList(growable: false);
      if (mounted) {
        setState(() => _searchResults = results);
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _searchError = e.toString().replaceFirst('Exception: ', ''),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSearching = false);
      }
    }
  }

  Future<void> _downloadAndPlay(
    TrackItem track, {
    List<TrackItem>? queue,
  }) async {
    await _playback.playTrack(track, queue: queue);
  }

  void _onTrackRowTap(TrackItem track, {required List<TrackItem> queue}) {
    unawaited(_downloadAndPlay(track, queue: queue));
  }

  Future<void> _skipToNextTrack() async {
    await _playback.skipToNext();
  }

  Future<void> _skipToPreviousTrack() async {
    await _playback.skipToPrevious();
  }

  Future<void> _togglePlayback() async {
    await _playback.togglePlayPause();
  }

  Future<void> _seekPlayback(int positionMs) async {
    await _playback.seek(positionMs);
  }

  Future<void> _recordErrorReport({
    required String source,
    required String message,
    String? stackTrace,
  }) async {
    await _errorReporter.reportError(
      source: source,
      message: message,
      stackTrace: stackTrace,
    );
    if (mounted) {
      setState(() => _errorLogCount = _errorReporter.logCount);
    }
  }

  String _formatLogTimestamp(int createdAtMs) {
    if (createdAtMs <= 0) {
      return '시간 정보 없음';
    }
    final dt = DateTime.fromMillisecondsSinceEpoch(createdAtMs).toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
  }

  Future<void> _shareErrorLog(Map<String, dynamic> report) async {
    final title = (report['title'] as String?)?.trim() ?? 'Replica 오류 로그';
    final body = (report['body'] as String?)?.trim() ?? '';
    final fullText = '$title\n\n$body';
    try {
      final cacheDir = _env.cacheDir.isNotEmpty
          ? _env.cacheDir
          : Directory.systemTemp.path;
      final file = await _errorReporter.writeLogShareFile(
        cacheDir: cacheDir,
        report: report,
      );
      final openedNative = await _adapters.shareTextFile(
        path: file.path,
        subject: title,
        text: fullText,
      );
      if (!openedNative && mounted) {
        _showSnack('오류 로그를 클립보드에 복사했습니다.');
      }
    } catch (e) {
      if (mounted) {
        _showSnack(
          '오류 로그 공유 실패: ${e.toString().replaceFirst('Exception: ', '')}',
        );
      }
    }
  }

  Future<T?> _showPaneDialog<T>({
    required WidgetBuilder builder,
    bool fromNowPlaying = false,
    bool barrierDismissible = true,
  }) {
    final dialogContext = _navigatorKey.currentContext;
    if (dialogContext == null) {
      return Future.value(null);
    }
    return showDialog<T>(
      context: dialogContext,
      barrierDismissible: barrierDismissible,
      builder: (ctx) {
        return LayoutBuilder(
          builder: (ctx, constraints) {
            final isSplit =
                constraints.maxWidth > constraints.maxHeight &&
                (constraints.maxWidth / 2) < constraints.maxHeight;
            final content = builder(ctx);
            if (!isSplit) {
              return content;
            }
            final paneWidth = constraints.maxWidth / 2;
            final targetOnRight = fromNowPlaying
                ? _nowPlayingOnRight
                : !_nowPlayingOnRight;
            final leftPad = targetOnRight ? paneWidth : 0.0;
            final rightPad = targetOnRight ? 0.0 : paneWidth;
            return Padding(
              padding: EdgeInsets.only(left: leftPad, right: rightPad),
              child: content,
            );
          },
        );
      },
    );
  }

  Future<void> _openErrorLogDetailDialog(Map<String, dynamic> report) async {
    final title = (report['title'] as String?)?.trim() ?? '오류 로그';
    final body = (report['body'] as String?)?.trim() ?? '';
    final createdAtMs = (report['created_at_ms'] as num?)?.toInt() ?? 0;
    await _showPaneDialog<void>(
      fromNowPlaying: false,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 24,
          ),
          title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _formatLogTimestamp(createdAtMs),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  SelectableText(
                    body.isEmpty ? '상세 내용이 없습니다.' : body,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('닫기'),
            ),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: replicaAccentColor,
                foregroundColor: Colors.white,
              ),
              onPressed: () async {
                Navigator.of(ctx).pop();
                await _shareErrorLog(report);
              },
              icon: const Icon(Icons.share_rounded, size: 18),
              label: const Text('공유'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _openErrorLogSheet() async {
    var logs = await _errorReporter.listLogs();
    if (!mounted) {
      return;
    }
    setState(() => _errorLogCount = logs.length);
    await _showPaneDialog<void>(
      fromNowPlaying: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final theme = Theme.of(ctx);
            final maxHeight = (MediaQuery.sizeOf(ctx).height * 0.68).clamp(
              260.0,
              520.0,
            );
            return Dialog(
              key: const Key('error-log-sheet'),
              insetPadding: const EdgeInsets.symmetric(
                horizontal: 18,
                vertical: 24,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(22),
              ),
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 440,
                  maxHeight: maxHeight,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 18, 10, 6),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '오류 로그',
                                  style: theme.textTheme.titleLarge?.copyWith(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: -0.3,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  logs.isEmpty
                                      ? '저장된 로그 없음'
                                      : '최신순 · ${logs.length}건',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (logs.isNotEmpty)
                            TextButton(
                              onPressed: () async {
                                await _errorReporter.clearLogs();
                                logs = const [];
                                if (mounted) {
                                  setState(() => _errorLogCount = 0);
                                }
                                setDialogState(() {});
                              },
                              child: const Text('모두 삭제'),
                            ),
                          IconButton(
                            tooltip: '닫기',
                            onPressed: () => Navigator.of(ctx).pop(),
                            icon: const Icon(Icons.close_rounded),
                          ),
                        ],
                      ),
                    ),
                    Flexible(
                      child: logs.isEmpty
                          ? Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                                vertical: 40,
                              ),
                              child: Center(
                                child: Text(
                                  '저장된 오류 로그가 없습니다.',
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            )
                          : ListView.separated(
                              shrinkWrap: true,
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              itemCount: logs.length,
                              separatorBuilder: (_, _) => const Divider(
                                height: 1,
                                indent: 20,
                                endIndent: 20,
                              ),
                              itemBuilder: (_, index) {
                                final report = logs[index];
                                final title =
                                    (report['title'] as String?)?.trim() ??
                                    '오류 로그';
                                final createdAtMs =
                                    (report['created_at_ms'] as num?)
                                        ?.toInt() ??
                                    0;
                                return ListTile(
                                  key: Key('error-log-item-$index'),
                                  contentPadding: const EdgeInsets.fromLTRB(
                                    20,
                                    4,
                                    12,
                                    4,
                                  ),
                                  title: Text(
                                    title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  subtitle: Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: Text(
                                      _formatLogTimestamp(createdAtMs),
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            color: theme
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                    ),
                                  ),
                                  trailing: IconButton(
                                    key: Key('error-log-share-$index'),
                                    tooltip: '공유',
                                    onPressed: () =>
                                        unawaited(_shareErrorLog(report)),
                                    icon: const Icon(
                                      Icons.share_rounded,
                                      color: replicaAccentColor,
                                    ),
                                  ),
                                  onTap: () => unawaited(
                                    _openErrorLogDetailDialog(report),
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _openNowPlayingSheet() {
    if (_activeTrack == null) {
      return;
    }
    setState(() => _isNowPlayingOpen = true);
    unawaited(_nowPlayingSheetController.forward());
  }

  void _closeNowPlayingSheet() {
    if ((!_isNowPlayingOpen && _nowPlayingSheetController.value == 0) ||
        !mounted) {
      return;
    }
    setState(() => _isNowPlayingOpen = false);
    unawaited(_nowPlayingSheetController.reverse());
  }

  Widget _buildNowPlayingWidget(
    BuildContext context, {
    bool allowDismiss = true,
  }) {
    if (_activeTrack == null) {
      final theme = Theme.of(context);
      final isDark = theme.brightness == Brightness.dark;
      return ColoredBox(
        key: const Key('now-playing-empty-pane'),
        color: isDark ? const Color(0xFF141418) : const Color(0xFFF3F3F7),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.music_note_rounded,
                  size: 56,
                  color: theme.colorScheme.onSurfaceVariant.withValues(
                    alpha: 0.45,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '재생 중인 곡 없음',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '곡을 선택해 재생하세요.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return NowPlayingSheet(
      stateListenable: _playback.snapshot,
      onTogglePlay: () => unawaited(_togglePlayback()),
      onSkipPrevious: () => unawaited(_skipToPreviousTrack()),
      onSkipNext: () => unawaited(_skipToNextTrack()),
      onSeek: (ms) => unawaited(_seekPlayback(ms)),
      onToggleShuffle: _playback.toggleShuffle,
      onCycleRepeat: _playback.cycleRepeatMode,
      onSelectQueueTrack: (track) =>
          unawaited(_downloadAndPlay(track, queue: _playback.queue)),
      onGetVolume: _adapters.getMediaVolume,
      onSetVolume: _adapters.setMediaVolume,
      volumeStream: _adapters.mediaVolumeStream,
      onClose: allowDismiss ? _closeNowPlayingSheet : null,
      allowDismiss: allowDismiss,
      onOpenTrackMenu: (anchorContext, track) async {
        final action = await _showContextMenu(anchorContext, [
          (value: 'add_to_playlist', label: '재생 목록에 추가', enabled: true),
          (value: 'delete', label: '로컬 파일 삭제', enabled: track.isDownloaded),
        ]);
        if (action != null && mounted) {
          if (action == 'delete') {
            await _deleteDownloadedTrack(track, removeFromQueue: true);
          } else {
            await _handleTrackMenuAction(
              action,
              track,
              queue: _playback.queue,
              fromNowPlaying: true,
            );
          }
        }
      },
    );
  }

  Future<void> _deleteDownloadedTrack(
    TrackItem track, {
    bool removeFromQueue = false,
    bool showSuccess = true,
  }) async {
    if (_env.storageDir.isEmpty) {
      return;
    }
    final isActiveTrack = _playback.activeTrack?.id == track.id;
    try {
      if (isActiveTrack) {
        await _playback.stop();
      }
      _downloadManager.removeFromDownloadedIndex(track.id);
      await widget.core.invoke({
        'op': 'delete_downloaded',
        'video_id': track.id,
        'storage_dir': _env.storageDir,
      });
      await _refreshDownloadedTracks();
      if (isActiveTrack || removeFromQueue) {
        await _playback.removeTrackFromQueueAndAdvance(track.id);
      }
      if (showSuccess) _showSnack('로컬 음원을 삭제했습니다.');
    } catch (e) {
      _showSnack('삭제 실패: ${e.toString().replaceFirst('Exception: ', '')}');
    }
  }

  Future<bool> _ensureStoragePermissionForDownload() async {
    final hasPermission = await _adapters.hasStoragePermission();
    if (!hasPermission) {
      if (mounted) {
        _showSnack('ReplicaMusic 폴더 저장을 위해 모든 파일 접근 권한을 허용해 주세요.');
      }
      await _adapters.openStoragePermissionSettings();
      return false;
    }
    return true;
  }

  bool _canAutoDownloadPlaylist(PlaylistItem playlist) =>
      playlist.isRemote && !_isHistoryPlaylist(playlist);

  Future<bool> _isAutomaticDownloadAllowed(String playlistId) async {
    if (!mounted || _webSession == null) return false;
    final mode = _autoDownloadByPlaylist[playlistId];
    if (mode == _PlaylistAutoDownload.always) return true;
    if (mode != _PlaylistAutoDownload.wifiOnly) return false;
    final onWifi = await _adapters.isWifiConnected();
    if (!mounted || _webSession == null) return false;
    final currentMode = _autoDownloadByPlaylist[playlistId];
    return currentMode == _PlaylistAutoDownload.always ||
        (currentMode == _PlaylistAutoDownload.wifiOnly && onWifi);
  }

  void _maybeAutoDownload(PlaylistItem playlist, List<TrackItem> tracks) {
    if (mounted &&
        _webSession != null &&
        _canAutoDownloadPlaylist(playlist) &&
        _autoDownloadByPlaylist.containsKey(playlist.id)) {
      unawaited(
        _downloadAllPlaylistTracks(
          playlist.copyWith(tracks: tracks),
          automatic: true,
        ),
      );
    }
  }

  Future<void> _downloadAllPlaylistTracks(
    PlaylistItem playlist, {
    bool automatic = false,
  }) async {
    if (_playlistDownloadProgress.containsKey(playlist.id) ||
        playlist.tracks.isEmpty) {
      return;
    }
    if (_env.storageDir.isEmpty) {
      if (!automatic) _showSnack('저장소 경로가 준비되지 않았습니다.');
      return;
    }
    final pending = playlist.tracks
        .where((t) => _downloadManager.resolveLocalPath(t) == null)
        .toList(growable: false);
    if (pending.isEmpty) {
      if (!automatic) _showSnack('모든 곡이 이미 다운로드되어 있습니다.');
      return;
    }
    if (automatic && !await _isAutomaticDownloadAllowed(playlist.id)) return;
    final permitted = automatic
        ? await _adapters.hasStoragePermission()
        : await _ensureStoragePermissionForDownload();
    if (!permitted || _playlistDownloadProgress.containsKey(playlist.id)) {
      return;
    }
    if (!mounted) {
      return;
    }
    _cancelledBulkPlaylists.remove(playlist.id);
    setState(() {
      _playlistDownloadProgress[playlist.id] = (done: 0, total: pending.length);
    });
    var succeeded = 0;
    var finished = 0;
    var nextIndex = 0;
    var consecutiveErrors = 0;
    var aborted = false;
    var abortedByError = false;
    const maxBulkConcurrency = 3;
    const maxConsecutiveErrors = 5;
    final workerCount = pending.length < maxBulkConcurrency
        ? pending.length
        : maxBulkConcurrency;
    try {
      await Future.wait(
        List<Future<void>>.generate(workerCount, (_) async {
          while (true) {
            if (!mounted ||
                aborted ||
                _cancelledBulkPlaylists.contains(playlist.id)) {
              return;
            }
            if (nextIndex >= pending.length ||
                (automatic &&
                    !await _isAutomaticDownloadAllowed(playlist.id))) {
              return;
            }
            if (!mounted ||
                aborted ||
                _cancelledBulkPlaylists.contains(playlist.id)) {
              return;
            }
            final idx = nextIndex++;
            if (idx >= pending.length) {
              return;
            }
            final track = pending[idx];
            try {
              final path = await _downloadManager.ensureLocalFile(
                track,
                allowNetwork: true,
                highPriority: false,
                isBulk: true,
              );
              if (path != null && path.isNotEmpty) {
                succeeded++;
                consecutiveErrors = 0;
              } else {
                aborted = true;
              }
            } catch (_) {
              consecutiveErrors++;
              if (consecutiveErrors >= maxConsecutiveErrors) {
                aborted = true;
                abortedByError = true;
              }
            } finally {
              finished++;
              if (mounted) {
                setState(() {
                  _playlistDownloadProgress[playlist.id] = (
                    done: finished,
                    total: pending.length,
                  );
                });
              }
            }
          }
        }),
      );
      final wasCancelled = _cancelledBulkPlaylists.remove(playlist.id);
      if (mounted && !automatic) {
        if (wasCancelled) {
          _showSnack('$succeeded / ${pending.length}곡 다운로드 후 취소했습니다.');
        } else if (abortedByError) {
          _showSnack(
            '연속 오류로 다운로드를 중단했습니다 ($succeeded / ${pending.length}곡 완료).',
          );
        } else {
          _showSnack('$succeeded / ${pending.length}곡 다운로드를 완료했습니다.');
        }
      }
    } finally {
      _cancelledBulkPlaylists.remove(playlist.id);
      if (mounted) {
        setState(() {
          _playlistDownloadProgress.remove(playlist.id);
        });
        if (_playlistDownloadProgress.isEmpty && succeeded > 0) {
          unawaited(_runStorageCleanup());
        }
      }
    }
  }

  Future<void> _removeTrackFromPlaylist(
    PlaylistItem playlist,
    TrackItem track,
  ) async {
    final gen = _sessionGeneration;
    if (!mounted || gen != _sessionGeneration) {
      return;
    }
    final isHistory = _isHistoryPlaylist(playlist);
    final newTs = isHistory ? 0 : nextPlaylistTimestamp(playlist.updatedAt);
    final newRemoteTitle = isHistory
        ? playlist.remoteTitle
        : buildVersionedRemoteTitle(playlist.remoteTitle, newTs);

    setState(() {
      _rawPlaylists = _rawPlaylists
          .map((pl) {
            if (pl.id != playlist.id) {
              return pl;
            }
            final remaining = pl.tracks
                .where((t) => t.id != track.id)
                .toList(growable: false);
            return pl.copyWith(
              remoteTitle: newRemoteTitle,
              updatedAt: newTs,
              tracks: remaining,
              thumbnail: remaining.isNotEmpty ? remaining.first.thumbnail : '',
            );
          })
          .toList(growable: false);
    });
    await _saveCachedPlaylists();
    _showSnack('재생 목록에서 "${track.title}"을(를) 삭제했습니다.');

    if (playlist.isRemote && _webSession != null) {
      _beginPlaylistSync(playlist.id);
      try {
        await widget.core.invoke({
          'op': 'remove_from_playlist',
          'playlist_id': playlist.id,
          'video_id': track.id,
          if (track.setVideoId != null) 'set_video_id': track.setVideoId,
          if (!isHistory) 'new_remote_title': newRemoteTitle,
          'session': _webSession,
        });
      } catch (_) {
        if (mounted && gen == _sessionGeneration) {
          setState(() {
            _rawPlaylists = _rawPlaylists
                .map(
                  (pl) => pl.id == playlist.id
                      ? pl.copyWith(hasPendingLocalEdit: true)
                      : pl,
                )
                .toList(growable: false);
          });
          await _saveCachedPlaylists();
        }
      } finally {
        _endPlaylistSync(playlist.id);
      }
    }
  }

  Future<PlaylistItem> _ensurePlaylistTracksLoaded(
    PlaylistItem playlist,
  ) async {
    if (playlist.tracks.isNotEmpty ||
        !playlist.isRemote ||
        _loadedRemotePlaylistIds.contains(playlist.id)) {
      return playlist;
    }
    await _loadPlaylistTracks(playlist);
    for (final item in _rawPlaylists) {
      if (item.id == playlist.id) {
        return item;
      }
    }
    return playlist;
  }

  Future<void> _playPlaylistFromStart(PlaylistItem playlist) async {
    final loaded = await _ensurePlaylistTracksLoaded(playlist);
    if (loaded.tracks.isEmpty) {
      _showSnack('재생할 곡이 없습니다.');
      return;
    }
    await _downloadAndPlay(loaded.tracks.first, queue: loaded.tracks);
  }

  Future<void> _playPlaylistShuffled(PlaylistItem playlist) async {
    final loaded = await _ensurePlaylistTracksLoaded(playlist);
    if (loaded.tracks.isEmpty) {
      _showSnack('재생할 곡이 없습니다.');
      return;
    }
    await _playback.playQueueShuffled(loaded.tracks);
  }

  Future<void> _deletePlaylist(PlaylistItem playlist) async {
    final title = _cachedDisplayPlaylistTitle(playlist.remoteTitle);
    final gen = _sessionGeneration;
    if (playlist.isRemote && _webSession != null) {
      _beginPlaylistSync(playlist.id);
      try {
        await widget.core.invoke({
          'op': 'delete_playlist',
          'playlist_id': playlist.id,
          'session': _webSession,
        });
      } catch (e) {
        if (mounted && gen == _sessionGeneration) {
          _showSnack(
            'YouTube 재생 목록 삭제 실패: ${e.toString().replaceFirst('Exception: ', '')}',
          );
        }
        return;
      } finally {
        _endPlaylistSync(playlist.id);
      }
    }
    if (!mounted || gen != _sessionGeneration) {
      return;
    }
    setState(() {
      _rawPlaylists = _rawPlaylists
          .where((pl) => pl.id != playlist.id)
          .toList(growable: false);
      if (_selectedPlaylistId == playlist.id) {
        _selectedPlaylistId = null;
      }
    });
    await _saveCachedPlaylists();
    _showSnack('"$title" 재생 목록을 삭제했습니다.');
  }

  Future<void> _handleTrackMenuAction(
    String action,
    TrackItem track, {
    required List<TrackItem> queue,
    PlaylistItem? playlist,
    bool fromNowPlaying = false,
  }) async {
    switch (action) {
      case 'play':
        await _downloadAndPlay(track, queue: queue);
        break;
      case 'play_next':
        await _playback.playNextInQueue(track);
        _showSnack('다음에 재생합니다.');
        break;
      case 'add_to_queue':
        await _playback.addToQueueEnd(track);
        _showSnack('현재 재생목록에 추가했습니다.');
        break;
      case 'remove_from_playlist':
        if (playlist != null) {
          await _removeTrackFromPlaylist(playlist, track);
        }
        break;
      case 'add_to_playlist':
        await _addTrackToPlaylistFlow(track, fromNowPlaying: fromNowPlaying);
        break;
      case 'delete':
        await _deleteDownloadedTrack(track);
        break;
    }
  }

  Future<String?> _showContextMenu(
    BuildContext anchorContext,
    List<({String value, String label, bool enabled})> items,
  ) async {
    final navState = _navigatorKey.currentState;
    final box = anchorContext.findRenderObject() as RenderBox?;
    if (navState == null || box == null || !box.hasSize) {
      return null;
    }
    final anchorPos = box.localToGlobal(Offset.zero);
    final anchorSize = box.size;
    final media = MediaQuery.of(anchorContext);
    final screen = media.size;
    const menuWidth = 200.0;
    const itemHeight = 48.0;
    final menuHeight = items.length * itemHeight + 16.0;

    final left = (anchorPos.dx + anchorSize.width - menuWidth).clamp(
      12.0,
      (screen.width - menuWidth - 12.0).clamp(12.0, screen.width),
    );
    var top = anchorPos.dy + anchorSize.height + 6.0;
    if (top + menuHeight > screen.height - media.padding.bottom - 16.0) {
      top = (anchorPos.dy - menuHeight - 6.0).clamp(
        media.padding.top + 12.0,
        screen.height - menuHeight - 12.0,
      );
    }

    return navState.push<String>(
      PageRouteBuilder<String>(
        opaque: false,
        barrierDismissible: false,
        transitionDuration: const Duration(milliseconds: 140),
        reverseTransitionDuration: const Duration(milliseconds: 100),
        pageBuilder: (routeContext, _, _) {
          final theme = Theme.of(routeContext);
          final isDark = theme.brightness == Brightness.dark;
          final bgColor = isDark
              ? const Color(0xFF242428)
              : const Color(0xFFFFFFFF);
          return Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => Navigator.of(routeContext).pop(),
                  onPanStart: (_) => Navigator.of(routeContext).pop(),
                ),
              ),
              Positioned(
                left: left,
                top: top,
                width: menuWidth,
                child: Material(
                  color: bgColor,
                  elevation: 10,
                  shadowColor: Colors.black.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(20),
                  clipBehavior: Clip.antiAlias,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final item in items)
                          InkWell(
                            onTap: item.enabled
                                ? () =>
                                      Navigator.of(routeContext).pop(item.value)
                                : null,
                            child: SizedBox(
                              height: itemHeight,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 22,
                                ),
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    item.label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w500,
                                      color: item.enabled
                                          ? theme.colorScheme.onSurface
                                          : theme.colorScheme.onSurfaceVariant
                                                .withValues(alpha: 0.4),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
        transitionsBuilder: (_, animation, _, child) {
          return FadeTransition(opacity: animation, child: child);
        },
      ),
    );
  }

  Widget _buildTrackContextMenuButton(
    BuildContext context,
    TrackItem track, {
    required List<TrackItem> queue,
    PlaylistItem? playlist,
  }) {
    final theme = Theme.of(context);
    return Builder(
      builder: (anchorContext) {
        return Tooltip(
          message: '더보기',
          child: InkWell(
            key: Key('track-more-${track.id}'),
            customBorder: const CircleBorder(),
            onTap: () async {
              final action = await _showContextMenu(anchorContext, [
                (value: 'play', label: '재생', enabled: true),
                (value: 'play_next', label: '다음에 재생', enabled: true),
                (value: 'add_to_queue', label: '현재 재생목록에 추가', enabled: true),
                (value: 'add_to_playlist', label: '재생 목록에 추가', enabled: true),
                if (playlist != null)
                  (
                    value: 'remove_from_playlist',
                    label: '재생 목록에서 삭제',
                    enabled: true,
                  ),
                (
                  value: 'delete',
                  label: '로컬 파일 삭제',
                  enabled: track.isDownloaded,
                ),
              ]);
              if (action != null && mounted) {
                await _handleTrackMenuAction(
                  action,
                  track,
                  queue: queue,
                  playlist: playlist,
                );
              }
            },
            child: SizedBox(
              width: 36,
              height: 36,
              child: Icon(
                Icons.more_vert,
                size: 22,
                color: theme.colorScheme.onSurface,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildPlaylistRowContextMenuButton(
    BuildContext context,
    PlaylistItem playlist,
  ) {
    final theme = Theme.of(context);
    final isAllSongs = playlist.id == _allSongsPlaylistId;
    return Builder(
      builder: (anchorContext) {
        return Tooltip(
          message: '더보기',
          child: InkWell(
            key: isAllSongs ? const Key('playlist-more-all-songs') : null,
            customBorder: const CircleBorder(),
            onTap: () async {
              final isSpecial = isAllSongs || _isHistoryPlaylist(playlist);
              final dl = _playlistDownloadProgress[playlist.id];
              final action = await _showContextMenu(anchorContext, [
                (value: 'play', label: '재생', enabled: true),
                (value: 'shuffle', label: '랜덤 재생', enabled: true),
                if (!isSpecial)
                  (
                    value: dl != null ? 'cancel_download_all' : 'download_all',
                    label: dl != null
                        ? '다운로드 취소 (${dl.done}/${dl.total})'
                        : '다운로드',
                    enabled: true,
                  ),
                if (!isSpecial)
                  (value: 'delete_playlist', label: '재생 목록 삭제', enabled: true),
              ]);
              if (action == null || !mounted) {
                return;
              }
              switch (action) {
                case 'play':
                  await _playPlaylistFromStart(playlist);
                  break;
                case 'shuffle':
                  await _playPlaylistShuffled(playlist);
                  break;
                case 'download_all':
                  final loaded = await _ensurePlaylistTracksLoaded(playlist);
                  if (mounted) {
                    await _downloadAllPlaylistTracks(loaded);
                  }
                  break;
                case 'cancel_download_all':
                  _cancelledBulkPlaylists.add(playlist.id);
                  _showSnack('다운로드 취소를 요청했습니다.');
                  break;
                case 'delete_playlist':
                  await _deletePlaylist(playlist);
                  break;
              }
            },
            child: SizedBox(
              width: 36,
              height: 36,
              child: Icon(
                Icons.more_vert,
                size: 22,
                color: theme.colorScheme.onSurface,
              ),
            ),
          ),
        );
      },
    );
  }

  Future<bool> _pushLocalPlaylistToRemote(
    PlaylistItem playlist,
    List<TrackItem> desiredTracks, {
    String? targetRemoteTitle,
    int? targetUpdatedAt,
  }) async {
    final session = _webSession;
    final gen = _sessionGeneration;
    if (session == null || !playlist.isRemote) {
      return false;
    }
    final isHistory = _isHistoryPlaylist(playlist);
    final resolvedTs = isHistory
        ? 0
        : (targetUpdatedAt != null && targetUpdatedAt > 0
              ? targetUpdatedAt
              : (playlist.updatedAt > 0
                    ? playlist.updatedAt
                    : nextPlaylistTimestamp(0)));
    final resolvedRemoteTitle = isHistory
        ? playlist.remoteTitle
        : (targetRemoteTitle ??
              buildVersionedRemoteTitle(playlist.remoteTitle, resolvedTs));
    _beginPlaylistSync(playlist.id);
    try {
      final data = await widget.core.invoke({
        'op': 'sync_playlist_tracks',
        'playlist_id': playlist.id,
        'video_ids': desiredTracks.map((t) => t.id).toList(growable: false),
        if (!isHistory) 'new_remote_title': resolvedRemoteTitle,
        'session': session,
      });
      if (!mounted || gen != _sessionGeneration || _webSession == null) {
        return false;
      }
      final rawList = (data['tracks'] as List<dynamic>?) ?? const [];
      final downloadedMap = {for (final t in _downloadedTracks) t.id: t};
      final syncedTracks = rawList
          .whereType<Map<String, dynamic>>()
          .map((item) {
            final parsed = TrackItem.fromCoreJson(item);
            final cached = downloadedMap[parsed.id];
            return cached != null
                ? parsed.copyWith(
                    filePath: cached.filePath,
                    bytes: cached.bytes,
                    isDownloaded: true,
                  )
                : parsed;
          })
          .toList(growable: false);
      final finalTracks = syncedTracks.isEmpty && desiredTracks.isNotEmpty
          ? desiredTracks
          : syncedTracks;
      _loadedRemotePlaylistIds.add(playlist.id);
      setState(() {
        _rawPlaylists = _rawPlaylists
            .map(
              (p) => p.id == playlist.id
                  ? p.copyWith(
                      remoteTitle: resolvedRemoteTitle,
                      updatedAt: resolvedTs,
                      tracks: finalTracks,
                      hasPendingLocalEdit: false,
                      thumbnail: finalTracks.isNotEmpty
                          ? finalTracks.first.thumbnail
                          : '',
                    )
                  : p,
            )
            .toList(growable: false);
      });
      await _saveCachedPlaylists();
      _maybeAutoDownload(playlist, finalTracks);
      return true;
    } catch (_) {
      return false;
    } finally {
      _endPlaylistSync(playlist.id);
    }
  }

  void _enterPlaylistEditMode(PlaylistItem playlist, TrackItem selectedTrack) {
    if (_isSavingPlaylistEdit || _isSavingPlaylistSettings) return;
    setState(() {
      _isEditingPlaylist = true;
      _editingTracks = List<TrackItem>.of(playlist.tracks);
      _selectedEditingTracks
        ..clear()
        ..add(selectedTrack);
    });
  }

  void _cancelPlaylistEditMode() {
    if (_isSavingPlaylistEdit) return;
    setState(() {
      _isEditingPlaylist = false;
      _editingTracks = const [];
      _selectedEditingTracks.clear();
    });
  }

  Future<void> _confirmPlaylistEditMode(PlaylistItem playlist) async {
    if (_isSavingPlaylistEdit) {
      return;
    }
    final edited = List<TrackItem>.unmodifiable(_editingTracks);
    final unchanged =
        edited.length == playlist.tracks.length &&
        List<bool>.generate(
          edited.length,
          (i) => edited[i].id == playlist.tracks[i].id,
        ).every((e) => e);
    if (unchanged) {
      _cancelPlaylistEditMode();
      return;
    }
    setState(() => _isSavingPlaylistEdit = true);
    try {
      if (!mounted) {
        return;
      }
      if (playlist.id == _allSongsPlaylistId) {
        final keptIds = edited.map((track) => track.id).toSet();
        final activeId = _playback.activeTrack?.id;
        final removed = playlist.tracks.where(
          (track) => !keptIds.contains(track.id),
        );
        for (final track in removed.where((track) => track.id != activeId)) {
          await _deleteDownloadedTrack(
            track,
            removeFromQueue: true,
            showSuccess: false,
          );
        }
        for (final track in removed.where((track) => track.id == activeId)) {
          await _deleteDownloadedTrack(
            track,
            removeFromQueue: true,
            showSuccess: false,
          );
        }
        if (mounted) {
          setState(() {
            _isEditingPlaylist = false;
            _editingTracks = const [];
            _selectedEditingTracks.clear();
          });
        }
        return;
      }
      final isHistory = _isHistoryPlaylist(playlist);
      final newTs = isHistory ? 0 : nextPlaylistTimestamp(playlist.updatedAt);
      final newRemoteTitle = isHistory
          ? playlist.remoteTitle
          : buildVersionedRemoteTitle(playlist.remoteTitle, newTs);
      setState(() {
        _rawPlaylists = _rawPlaylists
            .map(
              (p) => p.id == playlist.id
                  ? p.copyWith(
                      remoteTitle: newRemoteTitle,
                      updatedAt: newTs,
                      tracks: edited,
                      hasPendingLocalEdit: playlist.isRemote,
                      thumbnail: edited.isNotEmpty
                          ? edited.first.thumbnail
                          : '',
                    )
                  : p,
            )
            .toList(growable: false);
        _isEditingPlaylist = false;
        _editingTracks = const [];
        _selectedEditingTracks.clear();
      });
      await _saveCachedPlaylists();
      if (playlist.isRemote && _webSession != null) {
        await _pushLocalPlaylistToRemote(
          playlist.copyWith(remoteTitle: newRemoteTitle, updatedAt: newTs),
          edited,
          targetRemoteTitle: isHistory ? null : newRemoteTitle,
          targetUpdatedAt: isHistory ? null : newTs,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSavingPlaylistEdit = false);
      }
    }
  }

  CoverPalette _resolvePlaylistHeroPalette(
    String imageUrl,
    String? itemId,
    Color fallbackColor,
  ) {
    final trimmed = imageUrl.trim();
    if (!trimmed.startsWith('https://')) {
      return CoverPalette.fromBase(fallbackColor);
    }
    final key = (itemId != null && itemId.isNotEmpty) ? itemId : trimmed;
    final cached = ThumbnailCache.instance.lookupPaletteSync(key);
    if (cached != null) {
      return cached;
    }
    if (_pendingHeroPalettes.add(key)) {
      unawaited(
        ThumbnailCache.instance
            .extractPalette(url: trimmed, itemId: itemId, cacheKey: key)
            .then((palette) {
              _pendingHeroPalettes.remove(key);
              if (palette != null && mounted) {
                setState(() {});
              }
            }),
      );
    }
    return CoverPalette.fromBase(fallbackColor);
  }

  Future<void> _showPlaylistSettingsDialog(PlaylistItem playlist) async {
    final originalName = _displayTitleForPlaylist(playlist);
    final canRename =
        playlist.id != _allSongsPlaylistId && !_isHistoryPlaylist(playlist);
    final canAutoDownload = _canAutoDownloadPlaylist(playlist);
    final generation = _sessionGeneration;
    var name = originalName;
    var autoDownload =
        _autoDownloadByPlaylist[playlist.id] ?? _PlaylistAutoDownload.off;
    final confirmed = await _showPaneDialog<bool>(
      builder: (_) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          key: const Key('playlist-settings-dialog'),
          scrollable: true,
          title: const Text('재생목록 설정'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                key: const Key('playlist-settings-name'),
                initialValue: originalName,
                readOnly: !canRename,
                decoration: const InputDecoration(labelText: '재생목록 이름'),
                onChanged: (value) => update(() => name = value.trim()),
              ),
              const SizedBox(height: 16),
              const Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text('자동 다운로드'),
              ),
              RadioGroup<_PlaylistAutoDownload>(
                groupValue: autoDownload,
                onChanged: (value) {
                  if (value != null) update(() => autoDownload = value);
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final mode in _PlaylistAutoDownload.values)
                      RadioListTile<_PlaylistAutoDownload>(
                        key: ValueKey('playlist-auto-download-${mode.name}'),
                        value: mode,
                        enabled: canAutoDownload,
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(mode.label),
                      ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('취소'),
            ),
            FilledButton(
              key: const Key('playlist-settings-save'),
              onPressed: name.isEmpty
                  ? null
                  : () => Navigator.of(context).pop(true),
              child: const Text('저장'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted || generation != _sessionGeneration) {
      return;
    }
    final current = _rawPlaylists
        .where((item) => item.id == playlist.id)
        .firstOrNull;
    if (current == null) return;

    setState(() => _isSavingPlaylistSettings = true);
    try {
      if (canRename && name != originalName) {
        final formattedTitle = widget.core.toRemotePlaylistTitle(name);
        if (formattedTitle == null || isHistoryRemoteTitle(formattedTitle)) {
          _showSnack('사용할 수 없는 재생목록 이름입니다.');
          return;
        }
        final timestamp = nextPlaylistTimestamp(current.updatedAt);
        final remoteTitle = buildVersionedRemoteTitle(
          formattedTitle,
          timestamp,
        );
        final session = _webSession;
        final pushRename =
            current.isRemote && session != null && !current.hasPendingLocalEdit;
        if (pushRename) {
          await widget.core.invoke({
            'op': 'rename_playlist',
            'playlist_id': current.id,
            'new_remote_title': remoteTitle,
            'session': session,
          });
        }
        if (!mounted || generation != _sessionGeneration) return;
        setState(() {
          _rawPlaylists = [
            for (final item in _rawPlaylists)
              if (item.id == current.id)
                item.copyWith(
                  remoteTitle: remoteTitle,
                  updatedAt: timestamp,
                  hasPendingLocalEdit:
                      item.hasPendingLocalEdit ||
                      (item.isRemote && !pushRename),
                )
              else
                item,
          ];
        });
        unawaited(_saveCachedPlaylists());
      }
      if (canAutoDownload &&
          mounted &&
          generation == _sessionGeneration &&
          autoDownload !=
              (_autoDownloadByPlaylist[current.id] ??
                  _PlaylistAutoDownload.off)) {
        setState(() {
          if (autoDownload == _PlaylistAutoDownload.off) {
            _autoDownloadByPlaylist.remove(current.id);
          } else {
            _autoDownloadByPlaylist[current.id] = autoDownload;
          }
        });
        unawaited(_saveAppSettings());
        _maybeAutoDownload(current, current.tracks);
      }
    } catch (_) {
      if (mounted && generation == _sessionGeneration) {
        _showSnack('재생목록 설정을 저장하지 못했습니다.');
      }
    } finally {
      if (mounted) setState(() => _isSavingPlaylistSettings = false);
    }
  }

  Widget _buildPlaylistContextMenuButton(
    BuildContext context,
    PlaylistItem playlist,
  ) {
    if (_isOtherDeviceHistory(playlist)) {
      return const SizedBox.shrink();
    }
    final isAllSongs = playlist.id == _allSongsPlaylistId;
    final isHistory = _isHistoryPlaylist(playlist);
    return Builder(
      builder: (anchorContext) {
        return Tooltip(
          message: '더보기',
          child: GestureDetector(
            key: const Key('detail-more-button'),
            onTap: () async {
              final dl = _playlistDownloadProgress[playlist.id];
              final action = await _showContextMenu(anchorContext, [
                (
                  value: 'edit',
                  label: '편집',
                  enabled: !_isSavingPlaylistSettings,
                ),
                if (!isAllSongs && !isHistory) ...[
                  (
                    value: dl != null ? 'cancel_download_all' : 'download_all',
                    label: dl != null
                        ? '다운로드 취소 (${dl.done}/${dl.total})'
                        : '다운로드',
                    enabled: dl != null || playlist.tracks.isNotEmpty,
                  ),
                  (value: 'delete_playlist', label: '재생 목록 삭제', enabled: true),
                ],
              ]);
              if (action == null || !mounted) {
                return;
              }
              switch (action) {
                case 'edit':
                  await _showPlaylistSettingsDialog(playlist);
                  break;
                case 'download_all':
                  await _downloadAllPlaylistTracks(playlist);
                  break;
                case 'cancel_download_all':
                  _cancelledBulkPlaylists.add(playlist.id);
                  _showSnack('다운로드 취소를 요청했습니다.');
                  break;
                case 'delete_playlist':
                  await _deletePlaylist(playlist);
                  break;
              }
            },
            child: _DockCircleSurface(
              size: 42,
              child: const Icon(
                Icons.more_vert,
                size: 24,
                color: replicaAccentColor,
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _addTrackToPlaylistFlow(
    TrackItem track, {
    bool fromNowPlaying = false,
  }) async {
    final gen = _sessionGeneration;
    List<PlaylistItem> readEligiblePlaylists() => _visiblePlaylists
        .where((p) => !_isHistoryPlaylist(p))
        .toList(growable: false);

    var playlists = readEligiblePlaylists();
    final initialChecked = <String>{
      for (final pl in playlists)
        if (pl.tracks.any((t) => t.id == track.id)) pl.id,
    };
    final selectedIds = Set<String>.of(initialChecked);
    final userToggledIds = <String>{};
    var dialogOpen = true;
    void Function(VoidCallback)? dialogSetState;

    final unloadedRemote = playlists
        .where(
          (p) =>
              p.isRemote &&
              p.tracks.isEmpty &&
              !_loadedRemotePlaylistIds.contains(p.id),
        )
        .toList(growable: false);
    if (unloadedRemote.isNotEmpty && _webSession != null) {
      for (final pl in unloadedRemote) {
        unawaited(
          _loadPlaylistTracks(pl).then((_) {
            if (!mounted || !dialogOpen || gen != _sessionGeneration) {
              return;
            }
            final refreshed = readEligiblePlaylists();
            PlaylistItem? updatedPl;
            for (final item in refreshed) {
              if (item.id == pl.id) {
                updatedPl = item;
                break;
              }
            }
            if (updatedPl == null) {
              return;
            }
            final contains = updatedPl.tracks.any((t) => t.id == track.id);
            dialogSetState?.call(() {
              playlists = refreshed;
              if (contains) {
                initialChecked.add(pl.id);
                if (!userToggledIds.contains(pl.id)) {
                  selectedIds.add(pl.id);
                }
              }
            });
          }),
        );
      }
    }

    final confirmed = await _showPaneDialog<bool>(
      fromNowPlaying: fromNowPlaying,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            dialogSetState = setDialogState;
            final theme = Theme.of(dialogContext);
            final isDark = theme.brightness == Brightness.dark;
            final maxHeight = (MediaQuery.sizeOf(dialogContext).height * 0.68)
                .clamp(280.0, 520.0);
            final pillColor = isDark
                ? Colors.white.withValues(alpha: 0.10)
                : Colors.black.withValues(alpha: 0.06);
            return Dialog(
              key: const Key('add-to-playlist-dialog'),
              insetPadding: const EdgeInsets.symmetric(
                horizontal: 18,
                vertical: 24,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(22),
              ),
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 420,
                  maxHeight: maxHeight,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 18, 10, 6),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '저장 위치',
                              style: theme.textTheme.titleLarge?.copyWith(
                                fontSize: 20,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.3,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: '닫기',
                            onPressed: () =>
                                Navigator.of(dialogContext).pop(false),
                            icon: const Icon(Icons.close_rounded),
                          ),
                        ],
                      ),
                    ),
                    Flexible(
                      child: playlists.isEmpty
                          ? Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                                vertical: 28,
                              ),
                              child: Center(
                                child: Text(
                                  '저장할 재생목록이 없습니다.\n아래에서 새 재생목록을 만들어 주세요.',
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            )
                          : ListView.builder(
                              shrinkWrap: true,
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              itemCount: playlists.length,
                              itemBuilder: (_, index) {
                                final pl = playlists[index];
                                final checked = selectedIds.contains(pl.id);
                                return InkWell(
                                  key: Key('playlist-check-row-${pl.id}'),
                                  onTap: () {
                                    userToggledIds.add(pl.id);
                                    setDialogState(() {
                                      if (!selectedIds.remove(pl.id)) {
                                        selectedIds.add(pl.id);
                                      }
                                    });
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 20,
                                      vertical: 10,
                                    ),
                                    child: Row(
                                      children: [
                                        _CoverBox(
                                          color: pl.coverColor,
                                          size: 44,
                                          radius: 8,
                                          imageUrl:
                                              pl.tracks.isNotEmpty &&
                                                  pl
                                                      .tracks
                                                      .first
                                                      .thumbnail
                                                      .isNotEmpty
                                              ? pl.tracks.first.thumbnail
                                              : pl.thumbnail,
                                        ),
                                        const SizedBox(width: 14),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                _cachedDisplayPlaylistTitle(
                                                  pl.remoteTitle,
                                                ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: theme.textTheme.bodyLarge
                                                    ?.copyWith(
                                                      fontSize: 15.5,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                              ),
                                              const SizedBox(height: 2),
                                              Text(
                                                '${pl.tracks.length}곡 · ${pl.isRemote ? 'YouTube' : '로컬'}',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: theme.textTheme.bodySmall
                                                    ?.copyWith(
                                                      color: theme
                                                          .colorScheme
                                                          .onSurfaceVariant,
                                                    ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Icon(
                                          checked
                                              ? Icons.check_box_rounded
                                              : Icons
                                                    .check_box_outline_blank_rounded,
                                          key: Key('playlist-check-${pl.id}'),
                                          size: 24,
                                          color: checked
                                              ? replicaAccentColor
                                              : theme
                                                    .colorScheme
                                                    .onSurfaceVariant,
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
                      child: Material(
                        color: pillColor,
                        borderRadius: BorderRadius.circular(999),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          key: const Key('save-dialog-create-playlist'),
                          onTap: () async {
                            final beforeIds = playlists
                                .map((p) => p.id)
                                .toSet();
                            await _showCreatePlaylistDialog(
                              dialogContext,
                              fromNowPlaying: fromNowPlaying,
                            );
                            if (!dialogOpen) {
                              return;
                            }
                            final refreshed = readEligiblePlaylists();
                            final newlyCreated = refreshed
                                .where((p) => !beforeIds.contains(p.id))
                                .toList();
                            setDialogState(() {
                              playlists = refreshed;
                              for (final created in newlyCreated) {
                                userToggledIds.add(created.id);
                                selectedIds.add(created.id);
                              }
                            });
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.add_rounded,
                                  size: 20,
                                  color: theme.colorScheme.onSurface,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  '새 재생목록',
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: () =>
                                Navigator.of(dialogContext).pop(false),
                            child: const Text('취소'),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            key: const Key('save-dialog-confirm'),
                            style: FilledButton.styleFrom(
                              backgroundColor: replicaAccentColor,
                              foregroundColor: Colors.white,
                            ),
                            onPressed: () =>
                                Navigator.of(dialogContext).pop(true),
                            child: const Text('완료'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    dialogOpen = false;
    dialogSetState = null;

    if (confirmed != true || !mounted || gen != _sessionGeneration) {
      return;
    }

    final addedIds = selectedIds.difference(initialChecked);
    final removedIds = initialChecked.difference(selectedIds);
    if (addedIds.isEmpty && removedIds.isEmpty) {
      return;
    }

    final byId = {for (final pl in readEligiblePlaylists()) pl.id: pl};
    var addedCount = 0;
    var removedCount = 0;
    final versionUpdates = <String, ({int ts, String title})>{};

    for (final pid in {...addedIds, ...removedIds}) {
      final pl = byId[pid];
      if (pl == null) {
        continue;
      }
      final newTs = nextPlaylistTimestamp(pl.updatedAt);
      versionUpdates[pid] = (
        ts: newTs,
        title: buildVersionedRemoteTitle(pl.remoteTitle, newTs),
      );
    }

    setState(() {
      _rawPlaylists = _rawPlaylists
          .map((item) {
            final bumped = versionUpdates[item.id];
            if (addedIds.contains(item.id) &&
                !item.tracks.any((t) => t.id == track.id)) {
              addedCount++;
              return item.copyWith(
                remoteTitle: bumped?.title ?? item.remoteTitle,
                updatedAt: bumped?.ts ?? item.updatedAt,
                tracks: [...item.tracks, track],
                thumbnail: item.thumbnail.isNotEmpty
                    ? item.thumbnail
                    : track.thumbnail,
              );
            }
            if (removedIds.contains(item.id)) {
              removedCount++;
              final remaining = item.tracks
                  .where((t) => t.id != track.id)
                  .toList(growable: false);
              return item.copyWith(
                remoteTitle: bumped?.title ?? item.remoteTitle,
                updatedAt: bumped?.ts ?? item.updatedAt,
                tracks: remaining,
                thumbnail: remaining.isNotEmpty
                    ? remaining.first.thumbnail
                    : '',
              );
            }
            return item;
          })
          .toList(growable: false);
    });
    await _saveCachedPlaylists();
    if (mounted) {
      if (addedCount > 0 && removedCount == 0) {
        _showSnack('재생목록 $addedCount곳에 저장했습니다.');
      } else if (removedCount > 0 && addedCount == 0) {
        _showSnack('재생목록 $removedCount곳에서 제외했습니다.');
      } else {
        _showSnack('재생목록 저장 상태를 업데이트했습니다.');
      }
    }

    final syncTasks = <Future<void>>[];
    for (final pid in addedIds) {
      final pl = byId[pid];
      if (pl == null || !pl.isRemote || _webSession == null) {
        continue;
      }
      final bumped = versionUpdates[pid];
      syncTasks.add(() async {
        _beginPlaylistSync(pl.id);
        try {
          final res = await widget.core.invoke({
            'op': 'add_to_playlist',
            'playlist_id': pl.id,
            'video_id': track.id,
            if (bumped != null) 'new_remote_title': bumped.title,
            'session': _webSession,
          });
          final rawSvid = (res['set_video_id'] as String?)?.trim();
          if (rawSvid != null &&
              rawSvid.isNotEmpty &&
              mounted &&
              gen == _sessionGeneration) {
            setState(() {
              _rawPlaylists = _rawPlaylists
                  .map(
                    (item) => item.id == pl.id
                        ? item.copyWith(
                            tracks: item.tracks
                                .map(
                                  (t) => t.id == track.id
                                      ? t.copyWith(setVideoId: rawSvid)
                                      : t,
                                )
                                .toList(growable: false),
                          )
                        : item,
                  )
                  .toList(growable: false);
            });
          }
        } catch (_) {
          if (mounted && gen == _sessionGeneration) {
            setState(() {
              _rawPlaylists = _rawPlaylists
                  .map(
                    (item) => item.id == pl.id
                        ? item.copyWith(hasPendingLocalEdit: true)
                        : item,
                  )
                  .toList(growable: false);
            });
          }
        } finally {
          _endPlaylistSync(pl.id);
        }
      }());
    }
    for (final pid in removedIds) {
      final pl = byId[pid];
      if (pl == null || !pl.isRemote || _webSession == null) {
        continue;
      }
      final bumped = versionUpdates[pid];
      TrackItem? existingTrack;
      for (final t in pl.tracks) {
        if (t.id == track.id) {
          existingTrack = t;
          break;
        }
      }
      syncTasks.add(() async {
        _beginPlaylistSync(pl.id);
        try {
          await widget.core.invoke({
            'op': 'remove_from_playlist',
            'playlist_id': pl.id,
            'video_id': track.id,
            if (existingTrack?.setVideoId != null)
              'set_video_id': existingTrack!.setVideoId,
            if (bumped != null) 'new_remote_title': bumped.title,
            'session': _webSession,
          });
        } catch (_) {
          if (mounted && gen == _sessionGeneration) {
            setState(() {
              _rawPlaylists = _rawPlaylists
                  .map(
                    (item) => item.id == pl.id
                        ? item.copyWith(hasPendingLocalEdit: true)
                        : item,
                  )
                  .toList(growable: false);
            });
          }
        } finally {
          _endPlaylistSync(pl.id);
        }
      }());
    }
    if (syncTasks.isNotEmpty) {
      await Future.wait(syncTasks);
      if (mounted && gen == _sessionGeneration) {
        await _saveCachedPlaylists();
      }
    }
  }

  Future<void> _showCreatePlaylistDialog(
    BuildContext context, {
    bool fromNowPlaying = false,
  }) async {
    final gen = _sessionGeneration;
    final created = await _showPaneDialog<String>(
      fromNowPlaying: fromNowPlaying,
      builder: (_) => const _CreatePlaylistDialog(),
    );
    if (created == null ||
        created.trim().isEmpty ||
        !mounted ||
        gen != _sessionGeneration) {
      return;
    }
    final remoteTitle = widget.core.toRemotePlaylistTitle(created);
    if (remoteTitle == null) {
      _showSnack('올바른 재생목록 이름을 입력하세요.');
      return;
    }
    if (_webSession != null) {
      try {
        final data = await widget.core.invoke({
          'op': 'create_playlist',
          'title': created,
          'session': _webSession,
        });
        final item = PlaylistItem.fromCoreJson(
          (data['playlist'] as Map<String, dynamic>?) ?? const {},
        );
        if (!mounted || gen != _sessionGeneration) {
          return;
        }
        setState(() {
          _rawPlaylists = [item, ..._rawPlaylists];
        });
        await _saveCachedPlaylists();
        _showSnack(
          'YouTube에 "${widget.core.toDisplayPlaylistTitle(item.remoteTitle)}" 재생목록을 만들었습니다.',
        );
        return;
      } catch (e) {
        if (mounted && gen == _sessionGeneration) {
          _showSnack(
            '원격 생성 실패: ${e.toString().replaceFirst('Exception: ', '')}',
          );
        }
        return;
      }
    }
    final createdTs = nextPlaylistTimestamp(0);
    final versionedTitle = buildVersionedRemoteTitle(created, createdTs);
    final newItem = PlaylistItem(
      id: 'pl-${DateTime.now().microsecondsSinceEpoch}',
      remoteTitle: versionedTitle,
      owner: '로컬',
      description: '새로 만든 Replica 재생목록',
      coverColor: const Color(0xFF27272A),
      tracks: const [],
      updatedAt: createdTs,
    );
    setState(() {
      _rawPlaylists = [newItem, ..._rawPlaylists];
    });
    await _saveCachedPlaylists();
    _showSnack(
      '"${widget.core.toDisplayPlaylistTitle(newItem.remoteTitle)}" 재생목록을 만들었습니다.',
    );
  }

  Future<void> _checkForUpdates({required bool silentIfUpToDate}) async {
    if (_isCheckingUpdate || !widget.core.isNativeLoaded) {
      return;
    }
    setState(() => _isCheckingUpdate = true);
    UpdateInfo? update;
    try {
      final data = await widget.core.invoke({
        'op': 'check_update',
        'current_version': _env.version,
      });
      update = UpdateInfo.fromJson(
        (data['update'] as Map<String, dynamic>?) ?? const {},
      );
    } catch (e) {
      if (!silentIfUpToDate) {
        _showSnack(
          '업데이트 확인 실패: ${e.toString().replaceFirst('Exception: ', '')}',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isCheckingUpdate = false);
      }
    }
    if (!mounted || update == null) {
      return;
    }
    if (update.updateAvailable && update.assetUrl != null) {
      await _promptUpdateDialog(update);
    } else if (!silentIfUpToDate) {
      _showSnack('현재 최신 버전(v${update.currentVersion})을 사용 중입니다.');
    }
  }

  Future<void> _promptUpdateDialog(UpdateInfo update) async {
    final confirmed = await _showPaneDialog<bool>(
      fromNowPlaying: false,
      builder: (ctx) {
        return AlertDialog(
          key: const Key('update-available-dialog'),
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 24,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
          title: Text('새 버전 v${update.latestVersion} 출시'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '현재 버전 v${update.currentVersion} → v${update.latestVersion}',
                ),
                if (update.releaseNotes.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(update.releaseNotes),
                ],
                const SizedBox(height: 12),
                const Text('지금 업데이트를 다운로드하고 설치할까요?'),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('나중에'),
            ),
            FilledButton(
              key: const Key('update-confirm-button'),
              style: FilledButton.styleFrom(
                backgroundColor: replicaAccentColor,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('업데이트'),
            ),
          ],
        );
      },
    );
    if (confirmed == true) {
      await _performUpdateInstall(update);
    }
  }

  Future<void> _performUpdateInstall(UpdateInfo update) async {
    final assetUrl = update.assetUrl;
    if (assetUrl == null || _isUpdatingApp) {
      return;
    }
    if (_env.cacheDir.isEmpty) {
      _showSnack('업데이트 캐시 경로를 찾지 못했습니다.');
      return;
    }
    setState(() => _isUpdatingApp = true);
    final progressNotifier = ValueNotifier<UpdateDownloadProgress>(
      UpdateDownloadProgress(
        downloadedBytes: 0,
        totalBytes: update.assetSize ?? 0,
      ),
    );
    Timer? progressTimer;

    void stopProgressPolling() {
      progressTimer?.cancel();
      progressTimer = null;
    }

    String formatMb(int bytes) =>
        '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

    final dialogContext = _navigatorKey.currentContext;
    var progressDialogShown = false;
    var cancelled = false;

    void closeProgressDialog() {
      stopProgressPolling();
      if (progressDialogShown) {
        progressDialogShown = false;
        _navigatorKey.currentState?.maybePop();
      }
    }

    void cancelUpdate({required bool popDialog}) {
      if (cancelled) {
        return;
      }
      cancelled = true;
      stopProgressPolling();
      widget.core.cancelUpdateDownload();
      if (popDialog) {
        closeProgressDialog();
      } else {
        progressDialogShown = false;
      }
      if (mounted) {
        _showSnack('업데이트 다운로드를 취소했습니다.');
      }
    }

    if (dialogContext != null) {
      progressDialogShown = true;
      unawaited(
        _showPaneDialog<void>(
          fromNowPlaying: false,
          barrierDismissible: true,
          builder: (ctx) {
            final theme = Theme.of(ctx);
            return PopScope(
              canPop: true,
              onPopInvokedWithResult: (didPop, _) {
                if (didPop && progressDialogShown) {
                  cancelUpdate(popDialog: false);
                }
              },
              child: AlertDialog(
                key: const Key('update-progress-dialog'),
                insetPadding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 24,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(22),
                ),
                title: Text('v${update.latestVersion} 업데이트'),
                content: ValueListenableBuilder<UpdateDownloadProgress>(
                  valueListenable: progressNotifier,
                  builder: (_, progress, _) {
                    final effectiveTotal = progress.totalBytes > 0
                        ? progress.totalBytes
                        : (update.assetSize ?? 0);
                    final ratio = effectiveTotal > 0
                        ? (progress.downloadedBytes / effectiveTotal).clamp(
                            0.0,
                            1.0,
                          )
                        : 0.0;
                    final percent = (ratio * 100).floor();
                    final isVerifying =
                        effectiveTotal > 0 &&
                        progress.downloadedBytes >= effectiveTotal;
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isVerifying
                              ? '다운로드 완료 · 설치 파일을 준비하고 있습니다...'
                              : '업데이트 파일을 다운로드하고 있습니다...',
                        ),
                        const SizedBox(height: 16),
                        LinearProgressIndicator(
                          key: const Key('update-progress-bar'),
                          value: ratio,
                          minHeight: 6,
                          color: replicaAccentColor,
                          borderRadius: BorderRadius.circular(3),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              '$percent%',
                              key: const Key('update-progress-percent'),
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (effectiveTotal > 0)
                              Text(
                                '${formatMb(progress.downloadedBytes)} / ${formatMb(effectiveTotal)}',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                          ],
                        ),
                      ],
                    );
                  },
                ),
                actions: [
                  TextButton(
                    key: const Key('update-cancel-button'),
                    onPressed: () => cancelUpdate(popDialog: true),
                    child: const Text('취소'),
                  ),
                ],
              ),
            );
          },
        ),
      );
    }

    progressTimer = Timer.periodic(const Duration(milliseconds: 150), (_) {
      final latest = widget.core.readUpdateDownloadProgress();
      final total = latest.totalBytes > 0
          ? latest.totalBytes
          : (update.assetSize ?? 0);
      if (latest.downloadedBytes != progressNotifier.value.downloadedBytes ||
          total != progressNotifier.value.totalBytes) {
        progressNotifier.value = UpdateDownloadProgress(
          downloadedBytes: latest.downloadedBytes,
          totalBytes: total,
        );
      }
    });

    try {
      final data = await widget.core.invoke({
        'op': 'download_update',
        'asset_url': assetUrl,
        if (update.sha256 != null) 'sha256': update.sha256,
        'cache_dir': _env.cacheDir,
      });
      if (cancelled) {
        return;
      }
      final downloaded =
          (data['downloaded'] as Map<String, dynamic>?) ?? const {};
      final apkPath = downloaded['path'] as String?;
      if (apkPath == null || apkPath.isEmpty) {
        throw Exception('다운로드된 APK 경로가 없습니다.');
      }
      final canInstall = await _adapters.canInstallPackages();
      closeProgressDialog();
      if (!canInstall) {
        _showSnack('알 수 없는 앱 설치 권한을 허용한 뒤 다시 시도하세요.');
        await _adapters.openInstallPermissionSettings();
        return;
      }
      await _adapters.installApk(apkPath);
    } catch (e) {
      closeProgressDialog();
      if (!cancelled) {
        _showSnack('업데이트 실패: ${e.toString().replaceFirst('Exception: ', '')}');
      }
    } finally {
      closeProgressDialog();
      progressNotifier.dispose();
      if (mounted) {
        setState(() => _isUpdatingApp = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Replica',
      navigatorKey: _navigatorKey,
      scaffoldMessengerKey: _messengerKey,
      debugShowCheckedModeBanner: false,
      theme: buildReplicaLightTheme(),
      darkTheme: buildReplicaDarkTheme(),
      themeMode: _themeMode,
      home: LayoutBuilder(
        builder: (context, constraints) {
          final isWideLandscape =
              constraints.maxWidth >= 600 &&
              constraints.maxWidth > constraints.maxHeight;
          final isSplitMode =
              constraints.maxWidth > constraints.maxHeight &&
              (constraints.maxWidth / 2) < constraints.maxHeight;
          final visiblePlaylists = _visiblePlaylists;
          final detailPlaylist = _selectedPlaylist;
          final halfWidth = constraints.maxWidth / 2;
          const splitCenterGap = 2.0;
          final splitPaneWidth = (constraints.maxWidth - splitCenterGap) / 2;
          const nowPlayingSplitRadius = 5.0;

          final canExit =
              (isSplitMode || !_isNowPlayingOpen) &&
              !_isEditingPlaylist &&
              _selectedPlaylistId == null &&
              _tabIndex == 1;

          final mainWorkspaceContent = Column(
            children: [
              if (_isUpdatingApp)
                SafeArea(
                  bottom: false,
                  child: const LinearProgressIndicator(
                    minHeight: 2,
                    color: replicaAccentColor,
                  ),
                ),
              Expanded(
                child: Builder(
                  builder: (pageContext) {
                    final parentMedia = MediaQuery.of(pageContext);
                    final pageMedia = parentMedia.copyWith(
                      gestureSettings: const DeviceGestureSettings(
                        touchSlop: 38.0,
                      ),
                    );
                    return IndexedStack(
                      index: _tabIndex == 0 ? 0 : 1,
                      children: [
                        TickerMode(
                          enabled: _tabIndex == 0,
                          child: SafeArea(
                            bottom: false,
                            child: _buildSettingsPane(context),
                          ),
                        ),
                        TickerMode(
                          enabled: _tabIndex != 0,
                          child: MediaQuery(
                            data: pageMedia,
                            child: PageView(
                              key: const Key('main-tab-pageview'),
                              controller: _tabPageController,
                              physics: _isEditingPlaylist
                                  ? const NeverScrollableScrollPhysics()
                                  : const _IntentionalPageScrollPhysics(),
                              onPageChanged: (pageIdx) {
                                final newTab = pageIdx + 1;
                                if (newTab != 2) {
                                  FocusManager.instance.primaryFocus?.unfocus();
                                }
                                if (_tabIndex != 0 && _tabIndex != newTab) {
                                  setState(() => _tabIndex = newTab);
                                }
                              },
                              children: [
                                MediaQuery(
                                  data: parentMedia,
                                  child: detailPlaylist != null
                                      ? _buildPlaylistDetailPane(
                                          context,
                                          detailPlaylist,
                                        )
                                      : SafeArea(
                                          bottom: false,
                                          child: _buildLibraryPane(
                                            context,
                                            visiblePlaylists,
                                          ),
                                        ),
                                ),
                                MediaQuery(
                                  data: parentMedia,
                                  child: SafeArea(
                                    bottom: false,
                                    child: _buildSearchPane(context),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          );

          return PopScope(
            canPop: canExit,
            onPopInvokedWithResult: (didPop, _) {
              if (didPop) {
                return;
              }
              if (!isSplitMode && _isNowPlayingOpen) {
                _closeNowPlayingSheet();
              } else if (_tabIndex != 1) {
                _selectTab(1);
              } else if (_isEditingPlaylist) {
                _cancelPlaylistEditMode();
              } else if (_selectedPlaylistId != null) {
                setState(() => _selectedPlaylistId = null);
              }
            },
            child: Scaffold(
              resizeToAvoidBottomInset: false,
              body: isSplitMode
                  ? Stack(
                      children: [
                        AnimatedPositioned(
                          duration: const Duration(milliseconds: 280),
                          curve: Curves.easeOutCubic,
                          top: 0,
                          bottom: 0,
                          left: _nowPlayingOnRight
                              ? 0.0
                              : splitPaneWidth + splitCenterGap,
                          width: splitPaneWidth,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(
                              nowPlayingSplitRadius,
                            ),
                            child: ColoredBox(
                              color: Theme.of(context).scaffoldBackgroundColor,
                              child: Stack(
                                children: [
                                  Positioned.fill(child: mainWorkspaceContent),
                                  Positioned(
                                    left: 14,
                                    right: 14,
                                    bottom: 0,
                                    child: SafeArea(
                                      top: false,
                                      child: Padding(
                                        padding: const EdgeInsets.only(
                                          bottom: 10,
                                        ),
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            if (_toastMessage != null) ...[
                                              _buildFloatingToast(
                                                context,
                                                _toastMessage!,
                                              ),
                                              const SizedBox(height: 12),
                                            ],
                                            _slideDock(
                                              _isEditingPlaylist
                                                  ? _buildPlaylistEditDock()
                                                  : _buildBottomNavStrip(
                                                      context,
                                                      splitModeSwapEnabled:
                                                          true,
                                                    ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        AnimatedPositioned(
                          key: const Key('unfolded-now-playing-pane'),
                          duration: const Duration(milliseconds: 280),
                          curve: Curves.easeOutCubic,
                          top: 0,
                          bottom: 0,
                          left: _nowPlayingOnRight
                              ? splitPaneWidth + splitCenterGap
                              : 0.0,
                          width: splitPaneWidth,
                          child: GestureDetector(
                            behavior: HitTestBehavior.translucent,
                            onHorizontalDragEnd: (details) {
                              final v = details.primaryVelocity ?? 0;
                              if (_nowPlayingOnRight && v < -260) {
                                unawaited(_setNowPlayingOnRight(false));
                              } else if (!_nowPlayingOnRight && v > 260) {
                                unawaited(_setNowPlayingOnRight(true));
                              }
                            },
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(
                                nowPlayingSplitRadius,
                              ),
                              child: RepaintBoundary(
                                child: _buildNowPlayingWidget(
                                  context,
                                  allowDismiss: false,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    )
                  : AnimatedBuilder(
                      animation: _nowPlayingSheetController,
                      builder: (context, _) {
                        final nowPlayingT = Curves.easeOutCubic.transform(
                          _nowPlayingSheetController.value,
                        );
                        final isFullscreenNowPlaying =
                            _activeTrack != null && nowPlayingT > 0.001;

                        return Stack(
                          children: [
                            Positioned.fill(child: mainWorkspaceContent),
                            if (isWideLandscape) ...[
                              Positioned(
                                left: 14,
                                width: (halfWidth - 28).clamp(120.0, 800.0),
                                bottom: 0,
                                child: SafeArea(
                                  top: false,
                                  child: Padding(
                                    padding: const EdgeInsets.only(bottom: 10),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (_toastMessage != null) ...[
                                          _buildFloatingToast(
                                            context,
                                            _toastMessage!,
                                          ),
                                          const SizedBox(height: 12),
                                        ],
                                        _slideDock(
                                          _isEditingPlaylist
                                              ? _buildPlaylistEditDock()
                                              : _buildBottomNavStrip(context),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              Positioned(
                                left: halfWidth + 14,
                                width: (halfWidth - 28).clamp(120.0, 800.0),
                                bottom: 0,
                                child: SafeArea(
                                  top: false,
                                  child: Padding(
                                    padding: const EdgeInsets.only(bottom: 10),
                                    child: _slideDock(
                                      _isEditingPlaylist
                                          ? const SizedBox.shrink(
                                              key: Key('hidden-mini-player'),
                                            )
                                          : _buildMiniPlayerCard(context),
                                    ),
                                  ),
                                ),
                              ),
                            ] else
                              Positioned(
                                left: 14,
                                right: 14,
                                bottom: 0,
                                child: SafeArea(
                                  top: false,
                                  child: Padding(
                                    padding: const EdgeInsets.only(bottom: 10),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (_toastMessage != null) ...[
                                          _buildFloatingToast(
                                            context,
                                            _toastMessage!,
                                          ),
                                          const SizedBox(height: 12),
                                        ],
                                        _slideDock(
                                          _isEditingPlaylist
                                              ? _buildPlaylistEditDock()
                                              : Column(
                                                  key: const Key(
                                                    'workspace-playback-and-tabs',
                                                  ),
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    if (_activeTrack !=
                                                        null) ...[
                                                      _buildMiniPlayerCard(
                                                        context,
                                                      ),
                                                      const SizedBox(height: 5),
                                                    ],
                                                    _buildBottomNavStrip(
                                                      context,
                                                    ),
                                                  ],
                                                ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            if (isFullscreenNowPlaying)
                              Positioned.fill(
                                child: FractionalTranslation(
                                  key: const Key(
                                    'fullscreen-now-playing-overlay',
                                  ),
                                  translation: Offset(0, 1.0 - nowPlayingT),
                                  child: RepaintBoundary(
                                    child: _buildNowPlayingWidget(context),
                                  ),
                                ),
                              ),
                          ],
                        );
                      },
                    ),
            ),
          );
        },
      ),
    );
  }

  static const double _dockHeight = 62;

  double get _dockBottomPadding => _activeTrack != null ? 166 : 96;

  Widget _buildFloatingToast(BuildContext context, String message) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return IgnorePointer(
      child: Center(
        child: Container(
          key: const Key('floating-toast'),
          constraints: const BoxConstraints(maxWidth: 320),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xE63A3A40) : const Color(0xE05E5E64),
            borderRadius: BorderRadius.circular(999),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.22),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13.5,
              fontWeight: FontWeight.w500,
              height: 1.25,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomNavStrip(
    BuildContext context, {
    bool splitModeSwapEnabled = false,
  }) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final activePillColor = isDark
        ? Colors.white.withValues(alpha: 0.14)
        : Colors.black.withValues(alpha: 0.07);
    final inactiveColor = isDark
        ? Colors.white.withValues(alpha: 0.9)
        : theme.colorScheme.onSurface;

    return LayoutBuilder(
      builder: (context, constraints) {
        final totalWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 300.0;
        final capsuleWidth = (totalWidth - _dockHeight - 10).clamp(
          100.0,
          800.0,
        );
        final itemWidth = ((capsuleWidth - 8) / 2).clamp(48.0, 400.0);
        final settingsSelected = _tabIndex == 0;
        final settingsIconColor = settingsSelected
            ? replicaAccentColor
            : inactiveColor;

        final dockRow = SizedBox(
          key: const Key('bottom-nav-bar'),
          height: _dockHeight,
          child: Row(
            children: [
              _buildSettingsCircleDock(
                selected: settingsSelected,
                iconColor: settingsIconColor,
                activePillColor: activePillColor,
                isDark: isDark,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onHorizontalDragUpdate: splitModeSwapEnabled
                      ? null
                      : (details) {
                          if (_tabIndex == 0 ||
                              !_tabPageController.hasClients) {
                            return;
                          }
                          final pos = _tabPageController.position;
                          final deltaPages = details.delta.dx / itemWidth;
                          final nextPixels =
                              (pos.pixels + deltaPages * pos.viewportDimension)
                                  .clamp(
                                    pos.minScrollExtent,
                                    pos.maxScrollExtent,
                                  );
                          _tabPageController.jumpTo(nextPixels);
                        },
                  onHorizontalDragEnd: splitModeSwapEnabled
                      ? null
                      : (details) {
                          if (_tabIndex == 0) {
                            return;
                          }
                          final velocity = details.primaryVelocity ?? 0;
                          final currentPage = _dockPagePosition.value;
                          int targetPage;
                          if (velocity.abs() > 260) {
                            targetPage = velocity > 0 ? 1 : 0;
                          } else {
                            targetPage = currentPage.round().clamp(0, 1);
                          }
                          _selectTab(targetPage + 1);
                        },
                  child: _FloatingDockCapsule(
                    height: _dockHeight,
                    padding: const EdgeInsets.all(4),
                    child: ValueListenableBuilder<double>(
                      valueListenable: _dockPagePosition,
                      builder: (context, page, _) {
                        final clampedPage = page.clamp(0.0, 1.0);
                        final alignX = -1.0 + clampedPage * 2.0;
                        final showPill = _tabIndex != 0;
                        return Stack(
                          children: [
                            if (showPill)
                              Positioned.fill(
                                child: Align(
                                  alignment: Alignment(alignX, 0),
                                  child: FractionallySizedBox(
                                    widthFactor: 0.5,
                                    heightFactor: 1,
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        color: activePillColor,
                                        borderRadius: BorderRadius.circular(
                                          999,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            Row(
                              children: [
                                _buildNavIconItem(
                                  index: 1,
                                  page: showPill ? clampedPage + 1.0 : -1.0,
                                  inactiveColor: inactiveColor,
                                  icon: Icons.library_music_outlined,
                                  selectedIcon: Icons.library_music_rounded,
                                  label: '보관함',
                                ),
                                _buildNavIconItem(
                                  index: 2,
                                  page: showPill ? clampedPage + 1.0 : -1.0,
                                  inactiveColor: inactiveColor,
                                  icon: Icons.search_outlined,
                                  selectedIcon: Icons.search_rounded,
                                  label: '검색',
                                ),
                              ],
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ),
            ],
          ),
        );

        if (!splitModeSwapEnabled) {
          return dockRow;
        }
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragEnd: (details) {
            final v = details.primaryVelocity ?? 0;
            if (_nowPlayingOnRight && v > 260) {
              unawaited(_setNowPlayingOnRight(false));
            } else if (!_nowPlayingOnRight && v < -260) {
              unawaited(_setNowPlayingOnRight(true));
            }
          },
          child: dockRow,
        );
      },
    );
  }

  Widget _buildSettingsCircleDock({
    required bool selected,
    required Color iconColor,
    required Color activePillColor,
    required bool isDark,
  }) {
    final avatarUrl = _accountAvatarUrl?.trim() ?? '';
    final hasAvatar = _webSession != null && avatarUrl.startsWith('https://');
    final avatarDiameter = _dockHeight - 6;

    return Tooltip(
      message: '설정',
      child: _DockCircleSurface(
        size: _dockHeight,
        accentActive: selected,
        child: Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          child: InkWell(
            key: const Key('dock-settings-button'),
            customBorder: const CircleBorder(),
            onTap: () => _selectTab(0),
            child: Center(
              child: hasAvatar
                  ? ClipOval(
                      child: Image.network(
                        avatarUrl,
                        key: const Key('dock-settings-avatar'),
                        width: avatarDiameter,
                        height: avatarDiameter,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Icon(
                          selected
                              ? Icons.settings_rounded
                              : Icons.settings_outlined,
                          size: 28,
                          color: selected ? Colors.white : iconColor,
                        ),
                      ),
                    )
                  : Icon(
                      selected
                          ? Icons.settings_rounded
                          : Icons.settings_outlined,
                      size: 28,
                      color: selected ? Colors.white : iconColor,
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNavIconItem({
    required int index,
    required double page,
    required Color inactiveColor,
    required IconData icon,
    required IconData selectedIcon,
    required String label,
    Widget Function(bool selected, Color color)? customIconBuilder,
  }) {
    final focus = (1.0 - (page - index).abs()).clamp(0.0, 1.0);
    final selected = focus >= 0.5;
    final iconColor = Color.lerp(inactiveColor, replicaAccentColor, focus)!;
    return Expanded(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: () => _selectTab(index),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (customIconBuilder != null)
                customIconBuilder(selected, iconColor)
              else
                Icon(
                  selected ? selectedIcon : icon,
                  size: 24,
                  color: iconColor,
                ),
              const SizedBox(height: 2),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.1,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: iconColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTabHeader(
    BuildContext context,
    ThemeData theme,
    String title, {
    List<Widget> actions = const [],
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.headlineLarge?.copyWith(
                fontSize: 34,
                height: 1.15,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.6,
              ),
            ),
          ),
          for (var i = 0; i < actions.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            actions[i],
          ],
        ],
      ),
    );
  }

  Widget _buildMediaListRow(
    BuildContext context, {
    Key? key,
    required Color coverColor,
    required String? imageUrl,
    required String title,
    required String subtitle,
    bool? isDownloaded,
    bool highlighted = false,
    bool showDivider = false,
    Widget? leading,
    Widget? trailing,
    required VoidCallback onTap,
    VoidCallback? onLongPress,
  }) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final dividerColor = isDark
        ? Colors.white.withValues(alpha: 0.10)
        : Colors.black.withValues(alpha: 0.12);
    return SizedBox(
      key: key,
      height: 80,
      child: Stack(
        children: [
          Positioned.fill(
            child: InkWell(
              onTap: onTap,
              onLongPress: onLongPress,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    ?leading,
                    _CoverBox(
                      color: coverColor,
                      size: 56,
                      radius: 10,
                      imageUrl: imageUrl,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyLarge?.copyWith(
                              fontSize: 15.5,
                              fontWeight: highlighted
                                  ? FontWeight.w700
                                  : FontWeight.w600,
                              color: highlighted ? replicaAccentColor : null,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              if (isDownloaded != null) ...[
                                Icon(
                                  isDownloaded
                                      ? Icons.download_done_rounded
                                      : Icons.download_outlined,
                                  size: 14,
                                  color: highlighted
                                      ? replicaAccentColor
                                      : theme.colorScheme.onSurfaceVariant,
                                ),
                                const SizedBox(width: 4),
                              ],
                              Expanded(
                                child: Text(
                                  subtitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: highlighted
                                        ? replicaAccentColor
                                        : theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    if (trailing != null) ...[
                      const SizedBox(width: 4),
                      trailing,
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (showDivider)
            Positioned(
              left: leading == null ? 86 : 126,
              right: 16,
              bottom: 0,
              child: Divider(height: 0.6, thickness: 0.6, color: dividerColor),
            ),
        ],
      ),
    );
  }

  Widget _buildAppleSettingsGroup(
    ThemeData theme, {
    Key? key,
    required List<Widget> children,
  }) {
    final isDark = theme.brightness == Brightness.dark;
    final groupColor = isDark
        ? const Color(0xFF1C1C1E)
        : const Color(0xFFF2F2F7);
    final dividerColor = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.08);
    return Material(
      key: key,
      color: groupColor,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                thickness: 0.6,
                indent: 18,
                endIndent: 18,
                color: dividerColor,
              ),
            children[i],
          ],
        ],
      ),
    );
  }

  Widget _buildAppleSettingsSectionLabel(ThemeData theme, String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
      child: Text(
        label,
        style: theme.textTheme.bodySmall?.copyWith(
          fontSize: 13.5,
          fontWeight: FontWeight.w500,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _buildSettingsPane(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      key: const Key('settings-pane'),
      children: [
        _buildTabHeader(context, theme, '설정'),
        Expanded(
          child: ListView(
            padding: EdgeInsets.fromLTRB(16, 4, 16, _dockBottomPadding),
            children: [
              _buildAppleSettingsGroup(
                theme,
                key: const Key('settings-account-tile'),
                children: [
                  InkWell(
                    onTap: _webSession == null ? _handleAccountAction : null,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 16,
                      ),
                      child: Row(
                        children: [
                          if (_webSession != null) ...[
                            _buildAccountAvatar(theme),
                            const SizedBox(width: 12),
                          ],
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _webSession != null
                                      ? (_accountName ?? 'Google 계정')
                                      : '로그인',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodyLarge?.copyWith(
                                    fontSize: 16.5,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                if (_webSession != null) ...[
                                  const SizedBox(height: 3),
                                  Text(
                                    _accountHandle ?? 'YouTube .rm 재생목록과 동기화 중',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      fontSize: 13.5,
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          if (_webSession != null) ...[
                            TextButton(
                              onPressed: _isSyncingPlaylists
                                  ? null
                                  : () => _syncRemotePlaylists(silent: false),
                              child: const Text('동기화'),
                            ),
                            TextButton(
                              onPressed: _handleAccountAction,
                              child: const Text('로그아웃'),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              _buildAppleSettingsSectionLabel(theme, '앱 정보'),
              _buildAppleSettingsGroup(
                theme,
                key: const Key('settings-update-tile'),
                children: [
                  InkWell(
                    onTap: _isCheckingUpdate
                        ? null
                        : () => _checkForUpdates(silentIfUpToDate: false),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 16,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '업데이트 확인',
                                  style: theme.textTheme.bodyLarge?.copyWith(
                                    fontSize: 16.5,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  '현재 버전 v${_env.version}',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    fontSize: 13.5,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (_isCheckingUpdate)
                            const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: replicaAccentColor,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  InkWell(
                    key: const Key('settings-error-log-tile'),
                    onTap: _openErrorLogSheet,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 16,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '오류 로그 다운로드',
                                  style: theme.textTheme.bodyLarge?.copyWith(
                                    fontSize: 16.5,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  _errorLogCount > 0
                                      ? '저장된 오류 로그 $_errorLogCount건'
                                      : '저장된 오류 로그 없음',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    fontSize: 13.5,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Icon(
                            Icons.chevron_right_rounded,
                            size: 22,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              _buildAppleSettingsSectionLabel(theme, '디스플레이'),
              _buildAppleSettingsGroup(
                theme,
                key: const Key('settings-theme-selector'),
                children: [
                  _buildSettingsNavigationRow(
                    theme,
                    key: const Key('settings-theme-row'),
                    title: '테마',
                    subtitle: _themeModeLabel(_themeMode),
                    onTap: _openThemePickerDialog,
                  ),
                ],
              ),
              const SizedBox(height: 24),
              _buildAppleSettingsSectionLabel(theme, '저장소 관리'),
              _buildAppleSettingsGroup(
                theme,
                key: const Key('settings-storage-group'),
                children: [
                  _buildSettingsNavigationRow(
                    theme,
                    key: const Key('settings-audio-format-row'),
                    title: '다운로드 오디오 형식',
                    subtitle: _audioFormatLabel(_audioFormat),
                    onTap: _openAudioFormatPickerDialog,
                  ),
                  _buildSettingsNavigationRow(
                    theme,
                    key: const Key('settings-unused-days-row'),
                    title: '오래된 곡 자동 삭제',
                    subtitle: _unusedDaysLabel(_autoDeleteUnusedDays),
                    onTap: _openUnusedDaysPickerDialog,
                  ),
                  _buildSettingsNavigationRow(
                    theme,
                    key: const Key('settings-max-storage-row'),
                    title: '저장 용량 제한',
                    subtitle:
                        '${_maxStorageLabel(_maxStorageGb)} · 현재 ${_formatBytesLabel(_totalDownloadedBytes())}',
                    onTap: _openMaxStoragePickerDialog,
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _themeModeLabel(ThemeMode mode) => switch (mode) {
    ThemeMode.system => '기기 테마 사용',
    ThemeMode.light => '밝은 테마',
    ThemeMode.dark => '어두운 테마',
  };

  String _audioFormatLabel(String format) =>
      format == 'm4a' ? 'M4A (.m4a)' : 'Opus (.opus)';

  String _unusedDaysLabel(int days) => days <= 0 ? '사용 안 함' : '$days일 이상';

  String _maxStorageLabel(int gb) => gb <= 0 ? '제한 없음' : '$gb GB';

  Widget _buildRowProgressIndicator({Key? key, double? progress}) {
    return SizedBox(
      key: key,
      width: 36,
      height: 36,
      child: Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(
            value: progress?.clamp(0.0, 1.0),
            strokeWidth: 2.5,
            color: replicaAccentColor,
            backgroundColor: replicaAccentColor.withValues(alpha: 0.18),
          ),
        ),
      ),
    );
  }

  Widget _buildTrackDownloadProgressIndicator(String trackId) {
    return ValueListenableBuilder<Map<String, UpdateDownloadProgress>>(
      valueListenable: _downloadManager.downloadProgress,
      builder: (_, progressMap, _) {
        final progress = progressMap[trackId];
        final ratio = progress != null ? progress.ratio : 0.0;
        return _buildRowProgressIndicator(
          key: Key('track-downloading-$trackId'),
          progress: ratio,
        );
      },
    );
  }

  Widget _buildSettingsNavigationRow(
    ThemeData theme, {
    Key? key,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return InkWell(
      key: key,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontSize: 16.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 13.5,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              size: 22,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  Future<T?> _showSingleChoiceDialog<T>({
    Key? dialogKey,
    required String title,
    String? description,
    required List<({T value, String title, String? subtitle})> options,
    required T current,
  }) {
    return _showPaneDialog<T>(
      fromNowPlaying: false,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        final screenHeight = MediaQuery.sizeOf(ctx).height;
        final isShortViewport = screenHeight < 520;
        final maxHeight = isShortViewport
            ? (screenHeight - 32).clamp(220.0, 480.0)
            : (screenHeight * 0.65).clamp(220.0, 480.0);
        return Dialog(
          key: dialogKey,
          insetPadding: EdgeInsets.symmetric(
            horizontal: 18,
            vertical: isShortViewport ? 12 : 24,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 420, maxHeight: maxHeight),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 10, 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.3,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '닫기',
                        onPressed: () => Navigator.of(ctx).pop(),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ),
                if (description != null && description.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                    child: Text(
                      description,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 13,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    itemCount: options.length,
                    separatorBuilder: (_, _) =>
                        const Divider(height: 1, indent: 20, endIndent: 20),
                    itemBuilder: (_, index) {
                      final opt = options[index];
                      final selected = opt.value == current;
                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 2,
                        ),
                        title: Text(
                          opt.title,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            fontSize: 15.5,
                            fontWeight: selected
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                        ),
                        subtitle: opt.subtitle != null
                            ? Text(
                                opt.subtitle!,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              )
                            : null,
                        trailing: selected
                            ? const Icon(
                                Icons.check_rounded,
                                size: 20,
                                color: replicaAccentColor,
                              )
                            : null,
                        onTap: () => Navigator.of(ctx).pop(opt.value),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _openAudioFormatPickerDialog() async {
    final chosen = await _showSingleChoiceDialog<String>(
      dialogKey: const Key('audio-format-picker-dialog'),
      title: '다운로드 오디오 형식',
      description:
          '재인코딩 없이 YouTube 원본 음원을 저장합니다. 선택한 형식이 없으면 다른 형식으로 자동 저장합니다.',
      current: _audioFormat,
      options: const [
        (value: 'opus', title: 'Opus (.opus)', subtitle: '높은 음질과 효율적인 용량 (권장)'),
        (value: 'm4a', title: 'M4A (.m4a)', subtitle: 'AAC 원본 오디오, 폭넓은 기기 호환성'),
      ],
    );
    if (chosen != null) {
      await _setAudioFormat(chosen);
    }
  }

  Future<void> _openThemePickerDialog() async {
    final chosen = await _showSingleChoiceDialog<ThemeMode>(
      dialogKey: const Key('theme-picker-dialog'),
      title: '테마',
      current: _themeMode,
      options: const [
        (
          value: ThemeMode.system,
          title: '기기 테마 사용',
          subtitle: '시스템 라이트/다크 설정을 따릅니다.',
        ),
        (value: ThemeMode.light, title: '밝은 테마', subtitle: '항상 라이트 모드로 표시합니다.'),
        (value: ThemeMode.dark, title: '어두운 테마', subtitle: '항상 다크 모드로 표시합니다.'),
      ],
    );
    if (chosen != null) {
      await _setThemeMode(chosen);
    }
  }

  Future<void> _openUnusedDaysPickerDialog() async {
    final chosen = await _showSingleChoiceDialog<int>(
      dialogKey: const Key('unused-days-picker-dialog'),
      title: '오래된 곡 자동 삭제',
      description: '일정 기간 동안 듣지 않은 저장 음원을 자동으로 삭제합니다.',
      current: _autoDeleteUnusedDays,
      options: const [
        (value: 0, title: '사용 안 함', subtitle: null),
        (value: 7, title: '7일 이상', subtitle: null),
        (value: 14, title: '14일 이상', subtitle: null),
        (value: 30, title: '30일 이상', subtitle: null),
        (value: 60, title: '60일 이상', subtitle: null),
        (value: 90, title: '90일 이상', subtitle: null),
        (value: 180, title: '180일 이상', subtitle: null),
      ],
    );
    if (chosen != null) {
      await _setAutoDeleteUnusedDays(chosen);
    }
  }

  Future<void> _openMaxStoragePickerDialog() async {
    final chosen = await _showPaneDialog<int>(
      fromNowPlaying: false,
      builder: (_) => _MaxStorageDialog(initialGb: _maxStorageGb),
    );
    if (chosen != null) {
      await _setMaxStorageGb(chosen);
    }
  }

  Widget _buildAccountAvatar(ThemeData theme) {
    final fallback = CircleAvatar(
      radius: 20,
      backgroundColor: theme.colorScheme.surfaceContainer,
      child: Icon(
        _webSession != null ? Icons.account_circle : Icons.person_outline,
        size: 24,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
    final url = _accountAvatarUrl?.trim() ?? '';
    if (_webSession == null || !url.startsWith('https://')) {
      return fallback;
    }
    return ClipOval(
      child: SizedBox(
        width: 40,
        height: 40,
        child: Image.network(
          url,
          width: 40,
          height: 40,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => fallback,
        ),
      ),
    );
  }

  Widget _buildSearchPane(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    final listBottomPadding = keyboardInset > _dockBottomPadding
        ? keyboardInset + 16
        : _dockBottomPadding;
    final boxColor = isDark ? const Color(0xFF1C1C1E) : const Color(0xFFF2F2F7);
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.08);
    return Column(
      children: [
        _buildTabHeader(context, theme, '검색'),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: Container(
            height: 48,
            decoration: BoxDecoration(
              color: boxColor,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: borderColor, width: 0.8),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Icon(
                  Icons.search_rounded,
                  size: 21,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    key: const Key('search-input'),
                    controller: _searchController,
                    cursorColor: replicaAccentColor,
                    textInputAction: TextInputAction.search,
                    onSubmitted: _runSearch,
                    style: theme.textTheme.bodyLarge?.copyWith(fontSize: 16),
                    decoration: InputDecoration(
                      hintText: '아티스트, 노래 검색',
                      hintStyle: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        vertical: 12,
                        horizontal: 2,
                      ),
                    ),
                  ),
                ),
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _searchController,
                  builder: (_, value, _) {
                    if (value.text.isEmpty) {
                      return const SizedBox.shrink();
                    }
                    return Tooltip(
                      message: '검색어 지우기',
                      child: InkWell(
                        key: const Key('search-clear-button'),
                        customBorder: const CircleBorder(),
                        onTap: () {
                          _searchController.clear();
                          if (_searchError != null) {
                            setState(() => _searchError = null);
                          }
                        },
                        child: SizedBox(
                          width: 32,
                          height: 32,
                          child: Icon(
                            Icons.close_rounded,
                            size: 19,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
        if (_isSearching)
          const Padding(
            padding: EdgeInsets.all(24),
            child: CircularProgressIndicator(color: replicaAccentColor),
          )
        else if (_searchError != null)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              _searchError!,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          )
        else if (_searchResults.isEmpty)
          const Expanded(child: SizedBox.shrink())
        else
          Expanded(
            child: ListView.builder(
              controller: _searchScrollController,
              itemExtent: 80,
              cacheExtent: 600,
              padding: EdgeInsets.only(bottom: listBottomPadding),
              itemCount: _searchResults.length,
              itemBuilder: (context, index) {
                final track = _searchResults[index];
                final isCurrent = _activeTrack?.id == track.id;
                return _buildMediaListRow(
                  context,
                  coverColor: track.coverColor,
                  imageUrl: track.thumbnail,
                  title: track.title,
                  subtitle: '${track.artist} • ${track.duration}',
                  isDownloaded: track.isDownloaded,
                  highlighted: isCurrent,
                  showDivider: index < _searchResults.length - 1,
                  trailing: _isTrackDownloading(track.id)
                      ? _buildTrackDownloadProgressIndicator(track.id)
                      : _buildTrackContextMenuButton(
                          context,
                          track,
                          queue: _searchResults,
                        ),
                  onTap: () => _onTrackRowTap(track, queue: _searchResults),
                );
              },
            ),
          ),
      ],
    );
  }

  void _openPlaylistDetail(PlaylistItem playlist) {
    final isAllSongs = playlist.id == _allSongsPlaylistId;
    setState(() {
      _isEditingPlaylist = false;
      _editingTracks = const [];
      _selectedEditingTracks.clear();
      _selectedPlaylistId = playlist.id;
    });
    if (!isAllSongs && playlist.isRemote) {
      _loadPlaylistTracks(playlist);
    }
  }

  String _historySubtitle(PlaylistItem playlist) {
    final isCurrent = _isCurrentDeviceHistory(playlist);
    final role = isCurrent ? '이 기기' : '다른 기기';
    if (isCurrent || playlist.tracks.isNotEmpty) {
      return '$role · ${playlist.tracks.length}곡';
    }
    return role;
  }

  String? _playlistCoverUrl(PlaylistItem playlist) {
    if (playlist.tracks.isNotEmpty &&
        playlist.tracks.first.thumbnail.isNotEmpty) {
      return playlist.tracks.first.thumbnail;
    }
    return playlist.thumbnail.isNotEmpty ? playlist.thumbnail : null;
  }

  Future<void> _openAllHistoriesDialog(List<PlaylistItem> histories) async {
    await _showPaneDialog<void>(
      fromNowPlaying: false,
      builder: (dialogContext) {
        final theme = Theme.of(dialogContext);
        final maxHeight = (MediaQuery.sizeOf(dialogContext).height * 0.68)
            .clamp(240.0, 520.0);
        return Dialog(
          key: const Key('all-histories-dialog'),
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 18,
            vertical: 24,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 420, maxHeight: maxHeight),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 10, 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '기록',
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.3,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '닫기',
                        onPressed: () => Navigator.of(dialogContext).pop(),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    itemCount: histories.length,
                    separatorBuilder: (_, _) =>
                        const Divider(height: 1, indent: 82, endIndent: 20),
                    itemBuilder: (_, index) {
                      final pl = histories[index];
                      return InkWell(
                        key: Key('all-histories-item-${pl.id}'),
                        onTap: () {
                          Navigator.of(dialogContext).pop();
                          _openPlaylistDetail(pl);
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 10,
                          ),
                          child: Row(
                            children: [
                              _CoverBox(
                                color: pl.coverColor,
                                size: 48,
                                radius: 8,
                                imageUrl: _playlistCoverUrl(pl),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      _displayTitleForPlaylist(pl),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.bodyLarge
                                          ?.copyWith(
                                            fontSize: 15.5,
                                            fontWeight: FontWeight.w600,
                                          ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      _historySubtitle(pl),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            color: theme
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                              Icon(
                                Icons.chevron_right_rounded,
                                size: 20,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildHistoryShelf(
    BuildContext context,
    ThemeData theme,
    List<PlaylistItem> histories,
  ) {
    return Column(
      key: const Key('library-history-shelf'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 14, 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '기록',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.3,
                  ),
                ),
              ),
              InkWell(
                key: const Key('history-shelf-more-button'),
                borderRadius: BorderRadius.circular(8),
                onTap: () => unawaited(_openAllHistoriesDialog(histories)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Text(
                    '더보기',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 184,
          child: ListView.separated(
            key: const Key('history-shelf-list'),
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            itemCount: histories.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final pl = histories[index];
              final isCurrent = _isCurrentDeviceHistory(pl);
              final isSelected = _selectedPlaylistId == pl.id;
              return SizedBox(
                width: 128,
                child: InkWell(
                  key: Key(
                    isCurrent
                        ? 'playlist-tile-history'
                        : 'playlist-tile-history-${pl.id}',
                  ),
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => _openPlaylistDetail(pl),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _CoverBox(
                        color: pl.coverColor,
                        size: 128,
                        radius: 10,
                        imageUrl: _playlistCoverUrl(pl),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _displayTitleForPlaylist(pl),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                          color: isSelected ? replicaAccentColor : null,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _historySubtitle(pl),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: 12.5,
                          color: isSelected
                              ? replicaAccentColor
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _buildLibraryPane(BuildContext context, List<PlaylistItem> playlists) {
    final theme = Theme.of(context);
    PlaylistItem? currentDeviceHistory;
    final otherDeviceHistories = <PlaylistItem>[];
    final regularPlaylists = <PlaylistItem>[];
    for (final pl in playlists) {
      if (_isCurrentDeviceHistory(pl)) {
        currentDeviceHistory ??= pl;
      } else if (_isHistoryPlaylist(pl)) {
        otherDeviceHistories.add(pl);
      } else {
        regularPlaylists.add(pl);
      }
    }
    otherDeviceHistories.sort(
      (a, b) =>
          _displayTitleForPlaylist(a)
              .toLowerCase()
              .compareTo(_displayTitleForPlaylist(b).toLowerCase()),
    );
    final historyPlaylists = [?currentDeviceHistory, ...otherDeviceHistories];
    final displayPlaylists = [_allSongsPlaylist, ...regularPlaylists];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildTabHeader(
          context,
          theme,
          '보관함',
          actions: [
            _DockCircleButton(
              key: const Key('create-playlist-button'),
              tooltip: '새 재생목록',
              icon: Icons.add,
              iconColor: replicaAccentColor,
              size: 42,
              iconSize: 24,
              onPressed: () => _showCreatePlaylistDialog(context),
            ),
          ],
        ),
        Expanded(
          child: RefreshIndicator(
            key: const Key('library-refresh-indicator'),
            color: replicaAccentColor,
            onRefresh: _refreshLibrary,
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              controller: _libraryScrollController,
              cacheExtent: 600,
              slivers: [
                if (historyPlaylists.isNotEmpty)
                  SliverToBoxAdapter(
                    child: _buildHistoryShelf(context, theme, historyPlaylists),
                  ),
                SliverPadding(
                  padding: EdgeInsets.only(bottom: _dockBottomPadding),
                  sliver: SliverFixedExtentList.builder(
                    itemExtent: 80,
                    itemCount: displayPlaylists.length,
                    itemBuilder: (context, index) {
                      final playlist = displayPlaylists[index];
                      final isAllSongs = playlist.id == _allSongsPlaylistId;
                      final displayTitle = _displayTitleForPlaylist(playlist);
                      final isSelected = _selectedPlaylistId == playlist.id;
                      return _buildMediaListRow(
                        context,
                        key: Key(
                          isAllSongs
                              ? 'playlist-tile-all-songs'
                              : 'playlist-tile-${playlist.id}',
                        ),
                        coverColor: playlist.coverColor,
                        imageUrl: _playlistCoverUrl(playlist),
                        title: displayTitle,
                        subtitle: '${playlist.tracks.length} 곡',
                        highlighted: isSelected,
                        showDivider: index < displayPlaylists.length - 1,
                        trailing:
                            !isAllSongs &&
                                _playlistDownloadProgress.containsKey(
                                  playlist.id,
                                )
                            ? _buildRowProgressIndicator(
                                key: Key('playlist-downloading-${playlist.id}'),
                                progress: () {
                                  final p =
                                      _playlistDownloadProgress[playlist.id]!;
                                  return p.total > 0 ? p.done / p.total : null;
                                }(),
                              )
                            : !isAllSongs && _isPlaylistSyncing(playlist.id)
                            ? _buildRowProgressIndicator(
                                key: Key('playlist-syncing-${playlist.id}'),
                              )
                            : _buildPlaylistRowContextMenuButton(
                                context,
                                playlist,
                              ),
                        onTap: () => _openPlaylistDetail(playlist),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPlaylistEditTracks({required bool canReorder}) {
    Widget buildTrack(BuildContext context, int index) {
      final track = _editingTracks[index];
      final selected = _selectedEditingTracks.contains(track);

      return _buildMediaListRow(
        context,
        key: ObjectKey(track),
        coverColor: track.coverColor,
        imageUrl: track.thumbnail,
        title: track.title,
        subtitle: '${track.artist} • ${track.duration}',
        isDownloaded: track.isDownloaded,
        highlighted: _activeTrack?.id == track.id,
        showDivider: index < _editingTracks.length - 1,
        leading: Semantics(
          checked: selected,
          child: Padding(
            key: Key('edit-select-${track.id}'),
            padding: const EdgeInsets.only(right: 16),
            child: _playlistSelectionIcon(context, selected),
          ),
        ),
        trailing: canReorder
            ? ReorderableDragStartListener(
                index: index,
                enabled: !_isSavingPlaylistEdit,
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Icon(
                    Icons.drag_handle_rounded,
                    key: Key('edit-drag-${track.id}'),
                  ),
                ),
              )
            : null,
        onTap: () {
          if (_isSavingPlaylistEdit) return;
          setState(() {
            if (!_selectedEditingTracks.remove(track)) {
              _selectedEditingTracks.add(track);
            }
          });
        },
      );
    }

    if (!canReorder) {
      return SliverFixedExtentList.builder(
        itemExtent: 80,
        itemCount: _editingTracks.length,
        itemBuilder: buildTrack,
      );
    }
    return SliverReorderableList(
      itemCount: _editingTracks.length,
      itemBuilder: buildTrack,
      onReorder: (from, to) {
        setState(() {
          final track = _editingTracks.removeAt(from);
          _editingTracks.insert(from < to ? to - 1 : to, track);
        });
      },
    );
  }

  Widget _slideDock(Widget child) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 210),
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.bottomCenter,
        children: [
          for (final widget in previous) IgnorePointer(child: widget),
          ?current,
        ],
      ),
      transitionBuilder: (child, animation) => SlideTransition(
        position: animation.drive(
          Tween(begin: const Offset(0, 1.5), end: Offset.zero),
        ),
        child: child,
      ),
      child: child,
    );
  }

  bool get _allEditingTracksSelected =>
      _editingTracks.isNotEmpty &&
      _selectedEditingTracks.length == _editingTracks.length;

  void _toggleAllEditingTracks() {
    final allSelected = _allEditingTracksSelected;
    setState(() {
      _selectedEditingTracks.clear();
      if (!allSelected) _selectedEditingTracks.addAll(_editingTracks);
    });
  }

  Widget _playlistSelectionIcon(BuildContext context, bool selected) {
    return Icon(
      selected
          ? Icons.check_circle_rounded
          : Icons.radio_button_unchecked_rounded,
      color: selected
          ? replicaAccentColor
          : Theme.of(context).colorScheme.onSurfaceVariant,
    );
  }

  Future<void> _openAddTracksToPlaylistDialog(List<TrackItem> tracks) async {
    if (tracks.isEmpty) {
      return;
    }
    final gen = _sessionGeneration;
    List<PlaylistItem> readEligiblePlaylists() => _rawPlaylists
        .where((p) => !isHistoryRemoteTitle(p.remoteTitle))
        .toList(growable: false);

    var playlists = readEligiblePlaylists();
    final selectedIds = <String>{};

    final confirmed = await _showPaneDialog<bool>(
      fromNowPlaying: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final theme = Theme.of(context);
            final maxHeight = (MediaQuery.of(context).size.height * 0.62).clamp(
              260.0,
              460.0,
            );
            return Dialog(
              key: const Key('add-tracks-to-playlist-dialog'),
              insetPadding: const EdgeInsets.symmetric(
                horizontal: 18,
                vertical: 24,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(22),
              ),
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 420,
                  maxHeight: maxHeight,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 18, 10, 6),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '재생목록에 추가 (${tracks.length}곡)',
                              style: theme.textTheme.titleLarge?.copyWith(
                                fontSize: 19,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.3,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: '닫기',
                            onPressed: () =>
                                Navigator.of(dialogContext).pop(false),
                            icon: const Icon(Icons.close_rounded),
                          ),
                        ],
                      ),
                    ),
                    Flexible(
                      child: playlists.isEmpty
                          ? Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                                vertical: 28,
                              ),
                              child: Center(
                                child: Text(
                                  '저장할 재생목록이 없습니다.\n아래에서 새 재생목록을 만들어 주세요.',
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            )
                          : ListView.builder(
                              shrinkWrap: true,
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              itemCount: playlists.length,
                              itemBuilder: (_, index) {
                                final pl = playlists[index];
                                final checked = selectedIds.contains(pl.id);
                                return InkWell(
                                  key: Key('playlist-check-row-${pl.id}'),
                                  onTap: () {
                                    setDialogState(() {
                                      if (!selectedIds.remove(pl.id)) {
                                        selectedIds.add(pl.id);
                                      }
                                    });
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 8,
                                    ),
                                    child: Row(
                                      children: [
                                        _playlistSelectionIcon(
                                          context,
                                          checked,
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Text(
                                            _displayTitleForPlaylist(pl),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: theme.textTheme.bodyLarge
                                                ?.copyWith(
                                                  fontWeight: FontWeight.w600,
                                                ),
                                          ),
                                        ),
                                        Text(
                                          '${pl.tracks.length}곡',
                                          style: theme.textTheme.bodySmall
                                              ?.copyWith(
                                                color: theme
                                                    .colorScheme
                                                    .onSurfaceVariant,
                                              ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      child: Material(
                        color: theme.colorScheme.surfaceContainerHighest
                            .withValues(alpha: 0.45),
                        borderRadius: BorderRadius.circular(14),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onTap: () async {
                            final beforeIds = playlists
                                .map((p) => p.id)
                                .toSet();
                            await _showCreatePlaylistDialog(context);
                            if (!context.mounted) return;
                            final refreshed = readEligiblePlaylists();
                            final newlyCreated = refreshed
                                .where((p) => !beforeIds.contains(p.id))
                                .toList();
                            setDialogState(() {
                              playlists = refreshed;
                              for (final created in newlyCreated) {
                                selectedIds.add(created.id);
                              }
                            });
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.add_rounded,
                                  size: 20,
                                  color: theme.colorScheme.onSurface,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  '새 재생목록',
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: () =>
                                Navigator.of(dialogContext).pop(false),
                            child: const Text('취소'),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            key: const Key('save-dialog-confirm'),
                            style: FilledButton.styleFrom(
                              backgroundColor: replicaAccentColor,
                              foregroundColor: Colors.white,
                            ),
                            onPressed: selectedIds.isEmpty
                                ? null
                                : () => Navigator.of(dialogContext).pop(true),
                            child: const Text('추가'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    if (confirmed != true ||
        selectedIds.isEmpty ||
        !mounted ||
        gen != _sessionGeneration) {
      return;
    }

    final byId = {for (final pl in readEligiblePlaylists()) pl.id: pl};
    final addedPerPlaylist = <String, List<TrackItem>>{};
    final versionUpdates = <String, ({int ts, String title})>{};

    for (final pid in selectedIds) {
      final pl = byId[pid];
      if (pl == null) continue;
      final existingIds = pl.tracks.map((t) => t.id).toSet();
      final toAdd = tracks
          .where((t) => existingIds.add(t.id))
          .toList(growable: false);
      if (toAdd.isEmpty) continue;
      addedPerPlaylist[pid] = toAdd;
      final newTs = nextPlaylistTimestamp(pl.updatedAt);
      versionUpdates[pid] = (
        ts: newTs,
        title: buildVersionedRemoteTitle(pl.remoteTitle, newTs),
      );
    }

    if (addedPerPlaylist.isEmpty) {
      _showSnack('선택한 곡이 이미 재생목록에 있습니다.');
      return;
    }

    setState(() {
      _rawPlaylists = _rawPlaylists
          .map((item) {
            final toAdd = addedPerPlaylist[item.id];
            if (toAdd == null) return item;
            final bumped = versionUpdates[item.id];
            return item.copyWith(
              remoteTitle: bumped?.title ?? item.remoteTitle,
              updatedAt: bumped?.ts ?? item.updatedAt,
              tracks: [...item.tracks, ...toAdd],
              thumbnail: item.thumbnail.isNotEmpty
                  ? item.thumbnail
                  : toAdd.first.thumbnail,
            );
          })
          .toList(growable: false);
    });
    await _saveCachedPlaylists();
    if (mounted) {
      _showSnack('재생목록 ${addedPerPlaylist.length}곳에 추가했습니다.');
    }

    for (final entry in addedPerPlaylist.entries) {
      final pl = byId[entry.key];
      if (pl == null || !pl.isRemote || _webSession == null) continue;
      final bumped = versionUpdates[entry.key];
      unawaited(() async {
        _beginPlaylistSync(pl.id);
        try {
          for (var i = 0; i < entry.value.length; i++) {
            final track = entry.value[i];
            final isLast = i == entry.value.length - 1;
            await widget.core.invoke({
              'op': 'add_to_playlist',
              'playlist_id': pl.id,
              'video_id': track.id,
              if (isLast && bumped != null) 'new_remote_title': bumped.title,
              'session': _webSession,
            });
          }
        } catch (_) {
          if (mounted && gen == _sessionGeneration) {
            setState(() {
              _rawPlaylists = _rawPlaylists
                  .map(
                    (item) => item.id == pl.id
                        ? item.copyWith(hasPendingLocalEdit: true)
                        : item,
                  )
                  .toList(growable: false);
            });
            unawaited(_saveCachedPlaylists());
          }
        } finally {
          _endPlaylistSync(pl.id);
        }
      }());
    }
  }

  Widget _buildPlaylistEditDock() {
    final hasSelection =
        _selectedEditingTracks.isNotEmpty && !_isSavingPlaylistEdit;
    final canSelectAll = _editingTracks.isNotEmpty && !_isSavingPlaylistEdit;
    final allSelected = _allEditingTracksSelected;
    final theme = Theme.of(context);
    final selectColor = !canSelectAll
        ? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4)
        : (allSelected ? replicaAccentColor : theme.colorScheme.onSurface);
    return SizedBox(
      key: const Key('playlist-edit-dock'),
      height: _dockHeight,
      child: Row(
        children: [
          Semantics(
            container: true,
            label: '전체 선택',
            checked: allSelected,
            child: _DockCircleSurface(
              size: _dockHeight,
              child: Material(
                color: Colors.transparent,
                shape: const CircleBorder(),
                child: InkWell(
                  key: const Key('detail-edit-select-all'),
                  customBorder: const CircleBorder(),
                  onTap: canSelectAll ? _toggleAllEditingTracks : null,
                  child: SizedBox(
                    width: _dockHeight,
                    height: _dockHeight,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          allSelected
                              ? Icons.check_circle_rounded
                              : Icons.radio_button_unchecked_rounded,
                          size: 22,
                          color: selectColor,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '전체',
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                            height: 1.1,
                            color: selectColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _FloatingDockCapsule(
              height: _dockHeight,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  TextButton.icon(
                    key: const Key('playlist-edit-add-to-playlist'),
                    onPressed: hasSelection
                        ? () {
                            final selected = _editingTracks
                                .where(_selectedEditingTracks.contains)
                                .toList(growable: false);
                            unawaited(_openAddTracksToPlaylistDialog(selected));
                          }
                        : null,
                    icon: const Icon(Icons.playlist_add_rounded),
                    label: const Text('재생목록에 추가'),
                  ),
                  TextButton.icon(
                    key: const Key('playlist-edit-delete'),
                    onPressed: hasSelection
                        ? () {
                            setState(() {
                              _editingTracks.removeWhere(
                                _selectedEditingTracks.contains,
                              );
                              _selectedEditingTracks.clear();
                            });
                          }
                        : null,
                    icon: const Icon(Icons.delete_outline_rounded),
                    label: const Text('삭제'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlaylistDetailPane(BuildContext context, PlaylistItem playlist) {
    final isAllSongs = playlist.id == _allSongsPlaylistId;
    final media = MediaQuery.of(context);
    final topInset = media.padding.top;
    final displayTitle = _displayTitleForPlaylist(playlist);
    final heroTrack = playlist.tracks.isNotEmpty ? playlist.tracks.first : null;
    final heroImageUrl = (heroTrack != null && heroTrack.thumbnail.isNotEmpty)
        ? heroTrack.thumbnail
        : playlist.thumbnail;
    final heroItemId = (heroTrack != null && heroTrack.thumbnail.isNotEmpty)
        ? heroTrack.id
        : null;

    return LayoutBuilder(
      builder: (context, paneConstraints) {
        final paneWidth = paneConstraints.maxWidth.isFinite
            ? paneConstraints.maxWidth
            : media.size.width;
        final isWideHero = paneWidth >= 580;
        final squareSize = isWideHero
            ? (paneWidth / 2).clamp(280.0, 440.0)
            : paneWidth.clamp(240.0, 560.0);
        final heroHeight = squareSize;
        final heroDecodeHeight = (squareSize * media.devicePixelRatio)
            .round()
            .clamp(480, 1440);
        final heroPalette = _resolvePlaylistHeroPalette(
          heroImageUrl,
          heroItemId,
          playlist.coverColor,
        );

        Widget buildHeroInfoColumn({required bool centered}) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: centered
                ? CrossAxisAlignment.center
                : CrossAxisAlignment.start,
            children: [
              Text(
                displayTitle,
                key: const Key('detail-playlist-title'),
                textAlign: centered ? TextAlign.center : TextAlign.start,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: centered ? 24 : 28,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.4,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _isCurrentDeviceHistory(playlist)
                    ? '이 기기 · ${playlist.tracks.length}곡 · ${formatTotalTracksDuration(playlist.tracks)}'
                    : _isOtherDeviceHistory(playlist)
                    ? '다른 기기 · ${playlist.tracks.length}곡 · ${formatTotalTracksDuration(playlist.tracks)}'
                    : '${playlist.tracks.length}곡 · ${formatTotalTracksDuration(playlist.tracks)}',
                key: const Key('detail-playlist-summary'),
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.8),
                  fontSize: 13.5,
                  fontWeight: FontWeight.w500,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: 16),
              if (!_isEditingPlaylist)
                Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 46,
                        child: FilledButton.icon(
                          key: const Key('detail-play-button'),
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.white.withValues(
                              alpha: 0.22,
                            ),
                            disabledBackgroundColor: Colors.white.withValues(
                              alpha: 0.12,
                            ),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          onPressed: playlist.tracks.isEmpty
                              ? null
                              : () => _downloadAndPlay(
                                  playlist.tracks.first,
                                  queue: playlist.tracks,
                                ),
                          icon: const Icon(Icons.play_arrow_rounded, size: 22),
                          label: const Text(
                            '재생',
                            style: TextStyle(
                              fontSize: 15.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: SizedBox(
                        height: 46,
                        child: FilledButton.icon(
                          key: const Key('detail-shuffle-button'),
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.white.withValues(
                              alpha: 0.22,
                            ),
                            disabledBackgroundColor: Colors.white.withValues(
                              alpha: 0.12,
                            ),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          onPressed: playlist.tracks.isEmpty
                              ? null
                              : () => _playPlaylistShuffled(playlist),
                          icon: const Icon(Icons.shuffle_rounded, size: 20),
                          label: const Text(
                            '랜덤 재생',
                            style: TextStyle(
                              fontSize: 15.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              if (_playlistDownloadProgress[playlist.id] case final dl?) ...[
                const SizedBox(height: 10),
                Text(
                  '전체 다운로드 중 (${dl.done} / ${dl.total})',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.85),
                    fontSize: 12.5,
                  ),
                ),
              ],
            ],
          );
        }

        return Stack(
          children: [
            RefreshIndicator(
              color: replicaAccentColor,
              edgeOffset: topInset,
              onRefresh: () async {
                await _refreshDownloadedTracks();
                if (!isAllSongs) {
                  await _loadPlaylistTracks(playlist, forceRefresh: true);
                }
              },
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                controller: _detailScrollController,
                cacheExtent: 600,
                slivers: [
                  SliverToBoxAdapter(
                    child: RepaintBoundary(
                      child: SizedBox(
                        height: heroHeight,
                        child: isWideHero
                            ? Stack(
                                fit: StackFit.expand,
                                children: [
                                  DecoratedBox(
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        begin: Alignment.centerLeft,
                                        end: Alignment.centerRight,
                                        colors: [
                                          heroPalette.mainColor,
                                          heroPalette.mainColor,
                                          heroPalette.deepColor,
                                        ],
                                        stops: const [0.0, 0.50, 1.0],
                                      ),
                                    ),
                                  ),
                                  Positioned(
                                    top: 0,
                                    left: 0,
                                    width: squareSize,
                                    height: squareSize,
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        CachedCoverImage(
                                          imageUrl: heroImageUrl,
                                          itemId: heroItemId,
                                          highRes: true,
                                          decodeHeight: heroDecodeHeight,
                                          filterQuality: FilterQuality.medium,
                                          fit: BoxFit.cover,
                                          alignment: Alignment.center,
                                          fallback: Container(
                                            color: playlist.coverColor,
                                            alignment: Alignment.center,
                                            child: Icon(
                                              Icons.music_note,
                                              size: 88,
                                              color: Colors.white.withValues(
                                                alpha: 0.35,
                                              ),
                                            ),
                                          ),
                                        ),
                                        DecoratedBox(
                                          decoration: BoxDecoration(
                                            gradient: LinearGradient(
                                              begin: Alignment.centerLeft,
                                              end: Alignment.centerRight,
                                              colors: [
                                                Colors.transparent,
                                                heroPalette.mainColor
                                                    .withValues(alpha: 0.0),
                                                heroPalette.mainColor
                                                    .withValues(alpha: 0.55),
                                                heroPalette.mainColor
                                                    .withValues(alpha: 0.90),
                                                heroPalette.mainColor,
                                              ],
                                              stops: const [
                                                0.0,
                                                0.55,
                                                0.76,
                                                0.90,
                                                1.0,
                                              ],
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  DecoratedBox(
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        begin: Alignment.topCenter,
                                        end: Alignment.bottomCenter,
                                        colors: [
                                          Colors.transparent,
                                          Colors.transparent,
                                          Colors.black.withValues(alpha: 0.22),
                                        ],
                                        stops: const [0.0, 0.55, 1.0],
                                      ),
                                    ),
                                  ),
                                  Positioned(
                                    top: topInset + 56,
                                    left: squareSize + 18,
                                    right: 24,
                                    bottom: 20,
                                    child: Align(
                                      alignment: Alignment.bottomLeft,
                                      child: buildHeroInfoColumn(
                                        centered: false,
                                      ),
                                    ),
                                  ),
                                ],
                              )
                            : Stack(
                                fit: StackFit.expand,
                                children: [
                                  CachedCoverImage(
                                    imageUrl: heroImageUrl,
                                    itemId: heroItemId,
                                    highRes: true,
                                    decodeHeight: heroDecodeHeight,
                                    filterQuality: FilterQuality.medium,
                                    fit: BoxFit.cover,
                                    alignment: Alignment.center,
                                    fallback: Container(
                                      color: playlist.coverColor,
                                      alignment: Alignment.center,
                                      child: Icon(
                                        Icons.music_note,
                                        size: 88,
                                        color: Colors.white.withValues(
                                          alpha: 0.35,
                                        ),
                                      ),
                                    ),
                                  ),
                                  DecoratedBox(
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        begin: Alignment.topCenter,
                                        end: Alignment.bottomCenter,
                                        colors: [
                                          Colors.transparent,
                                          Colors.black.withValues(alpha: 0.0),
                                          Colors.black.withValues(alpha: 0.48),
                                          Colors.black.withValues(alpha: 0.75),
                                        ],
                                        stops: const [0.0, 0.50, 0.76, 1.0],
                                      ),
                                    ),
                                  ),
                                  Positioned(
                                    left: 16,
                                    right: 16,
                                    bottom: 18,
                                    child: buildHeroInfoColumn(centered: true),
                                  ),
                                ],
                              ),
                      ),
                    ),
                  ),
                  if (!isAllSongs &&
                      (_playlistDownloadProgress.containsKey(playlist.id) ||
                          _isPlaylistSyncing(playlist.id)))
                    SliverToBoxAdapter(
                      child: Builder(
                        builder: (context) {
                          final dl = _playlistDownloadProgress[playlist.id];
                          final ratio = (dl != null && dl.total > 0)
                              ? (dl.done / dl.total).clamp(0.0, 1.0)
                              : null;
                          final percent = ratio != null
                              ? (ratio * 100).floor()
                              : null;
                          return Column(
                            key: dl != null
                                ? const Key('detail-playlist-progress-bar')
                                : const Key('detail-playlist-sync-bar'),
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              LinearProgressIndicator(
                                value: ratio,
                                minHeight: 3,
                                color: replicaAccentColor,
                                backgroundColor: replicaAccentColor.withValues(
                                  alpha: 0.16,
                                ),
                              ),
                              if (dl != null && percent != null)
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    6,
                                    16,
                                    4,
                                  ),
                                  child: Text(
                                    '다운로드 중 ${dl.done}/${dl.total} ($percent%)',
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          fontSize: 12,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurfaceVariant,
                                        ),
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
                    ),
                  if (isAllSongs && !_isEditingPlaylist)
                    ...() {
                      final downloadedIds = playlist.tracks
                          .map((t) => t.id)
                          .toSet();
                      final activeDownloads = _downloadingTracks
                          .where((t) => !downloadedIds.contains(t.id))
                          .toList(growable: false);
                      if (activeDownloads.isEmpty) {
                        return const <Widget>[];
                      }
                      return <Widget>[
                        SliverToBoxAdapter(
                          child: Padding(
                            key: const Key('all-songs-downloading-header'),
                            padding: const EdgeInsets.fromLTRB(20, 14, 16, 4),
                            child: Text(
                              '다운로드 중 · ${activeDownloads.length}곡',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w700,
                                    color: replicaAccentColor,
                                  ),
                            ),
                          ),
                        ),
                        SliverFixedExtentList.builder(
                          itemExtent: 80,
                          itemCount: activeDownloads.length,
                          itemBuilder: (context, index) {
                            final track = activeDownloads[index];
                            return ValueListenableBuilder<
                              Map<String, UpdateDownloadProgress>
                            >(
                              valueListenable:
                                  _downloadManager.downloadProgress,
                              builder: (context, progressMap, _) {
                                final prog = progressMap[track.id];
                                final ratio = prog != null ? prog.ratio : 0.0;
                                final statusText =
                                    prog != null && prog.totalBytes > 0
                                    ? '${(ratio * 100).floor()}%'
                                    : '대기 중';
                                return _buildMediaListRow(
                                  context,
                                  key: Key(
                                    'downloading-track-tile-${track.id}',
                                  ),
                                  coverColor: track.coverColor,
                                  imageUrl: track.thumbnail,
                                  title: track.title,
                                  subtitle: '${track.artist} • $statusText',
                                  showDivider:
                                      index < activeDownloads.length - 1 ||
                                      playlist.tracks.isNotEmpty,
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      _buildRowProgressIndicator(
                                        key: Key(
                                          'track-downloading-${track.id}',
                                        ),
                                        progress: ratio,
                                      ),
                                      Tooltip(
                                        message: '다운로드 취소',
                                        child: InkWell(
                                          key: Key(
                                            'downloading-track-cancel-${track.id}',
                                          ),
                                          customBorder: const CircleBorder(),
                                          onTap: () => _downloadManager
                                              .cancelDownload(track.id),
                                          child: SizedBox(
                                            width: 32,
                                            height: 32,
                                            child: Icon(
                                              Icons.close_rounded,
                                              size: 18,
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .onSurfaceVariant,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  onTap: () => _downloadManager
                                      .promoteTrackDownload(track.id),
                                );
                              },
                            );
                          },
                        ),
                      ];
                    }(),
                  if (_isEditingPlaylist)
                    _buildPlaylistEditTracks(canReorder: !isAllSongs)
                  else if (playlist.tracks.isEmpty &&
                      (!isAllSongs || _downloadingTracks.isEmpty))
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            isAllSongs
                                ? '다운로드된 곡이 없습니다.\n하단 검색 탭에서 곡을 찾아 재생하세요.'
                                : '아직 추가된 곡이 없습니다. 검색에서 곡을 추가하세요.',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    )
                  else
                    SliverFixedExtentList.builder(
                      itemExtent: 80,
                      itemCount: playlist.tracks.length,
                      itemBuilder: (context, index) {
                        final track = playlist.tracks[index];
                        final isCurrent = _activeTrack?.id == track.id;
                        return _buildMediaListRow(
                          context,
                          key: Key('track-tile-${track.id}'),
                          coverColor: track.coverColor,
                          imageUrl: track.thumbnail,
                          title: track.title,
                          subtitle: '${track.artist} • ${track.duration}',
                          isDownloaded: track.isDownloaded,
                          highlighted: isCurrent,
                          showDivider: index < playlist.tracks.length - 1,
                          trailing: _isTrackDownloading(track.id)
                              ? _buildTrackDownloadProgressIndicator(track.id)
                              : _buildTrackContextMenuButton(
                                  context,
                                  track,
                                  queue: playlist.tracks,
                                  playlist:
                                      (isAllSongs ||
                                          _isOtherDeviceHistory(playlist))
                                      ? null
                                      : playlist,
                                ),
                          onTap: () =>
                              _onTrackRowTap(track, queue: playlist.tracks),
                          onLongPress: _isOtherDeviceHistory(playlist)
                              ? null
                              : () => _enterPlaylistEditMode(playlist, track),
                        );
                      },
                    ),
                  SliverToBoxAdapter(
                    child: SizedBox(
                      height: _isEditingPlaylist ? 96 : _dockBottomPadding,
                    ),
                  ),
                ],
              ),
            ),
            Positioned(
              top: topInset + 12,
              left: 16,
              right: 16,
              child: Semantics(
                explicitChildNodes: true,
                container: true,
                child: Row(
                  children: [
                    const Spacer(),
                    if (_isEditingPlaylist)
                      _DockCircleButton(
                        key: const Key('detail-edit-confirm'),
                        tooltip: '확정',
                        icon: Icons.check_rounded,
                        iconColor: replicaAccentColor,
                        size: 42,
                        iconSize: 24,
                        onPressed: _isSavingPlaylistEdit
                            ? null
                            : () =>
                                  unawaited(_confirmPlaylistEditMode(playlist)),
                      )
                    else
                      _buildPlaylistContextMenuButton(context, playlist),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildMiniPlayerCard(BuildContext context) {
    final track = _activeTrack;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final iconColor = isDark ? Colors.white : theme.colorScheme.onSurface;
    final disabledColor = theme.colorScheme.onSurfaceVariant.withValues(
      alpha: 0.35,
    );
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragEnd: (details) {
        if ((details.primaryVelocity ?? 0) < -220 && track != null) {
          _openNowPlayingSheet();
        }
      },
      child: _FloatingDockCapsule(
        key: const Key('mini-player'),
        height: _dockHeight,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            key: const Key('mini-player-open-sheet'),
            borderRadius: BorderRadius.circular(999),
            onTap: track != null ? _openNowPlayingSheet : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                children: [
                  if (track != null)
                    _CoverBox(
                      color: track.coverColor,
                      size: 40,
                      radius: 10,
                      imageUrl: track.thumbnail,
                    )
                  else
                    Container(
                      key: const Key('mini-player-empty-cover'),
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.08)
                            : Colors.black.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      alignment: Alignment.center,
                      child: Icon(
                        Icons.music_note_rounded,
                        size: 20,
                        color: theme.colorScheme.onSurfaceVariant.withValues(
                          alpha: 0.65,
                        ),
                      ),
                    ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: track != null
                        ? Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                track.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontSize: 14.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              Text(
                                _isDownloadingTrack
                                    ? '${track.artist} • 다운로드 중...'
                                    : track.artist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  fontSize: 12.5,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          )
                        : Text(
                            '재생 중인 곡 없음',
                            key: const Key('mini-player-empty-label'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                  ),
                  CossIconButton(
                    key: const Key('mini-player-previous'),
                    tooltip: '이전 곡',
                    size: 40,
                    iconSize: 28,
                    iconColor: track != null && _hasPreviousTrack
                        ? iconColor
                        : disabledColor,
                    icon: Icons.fast_rewind_rounded,
                    onPressed: track != null && _hasPreviousTrack
                        ? _skipToPreviousTrack
                        : null,
                  ),
                  CossIconButton(
                    key: const Key('mini-player-toggle'),
                    tooltip: _isPlaying ? '일시정지' : '재생',
                    size: 44,
                    iconSize: 32,
                    iconColor: track != null ? iconColor : disabledColor,
                    icon: track != null && _isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    onPressed: track != null ? _togglePlayback : null,
                  ),
                  CossIconButton(
                    key: const Key('mini-player-next'),
                    tooltip: '다음 곡',
                    size: 40,
                    iconSize: 28,
                    iconColor: track != null && _hasNextTrack
                        ? iconColor
                        : disabledColor,
                    icon: Icons.fast_forward_rounded,
                    onPressed: track != null && _hasNextTrack
                        ? _skipToNextTrack
                        : null,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _IntentionalPageScrollPhysics extends PageScrollPhysics {
  const _IntentionalPageScrollPhysics({super.parent});

  @override
  _IntentionalPageScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return _IntentionalPageScrollPhysics(parent: buildParent(ancestor));
  }

  @override
  double get minFlingVelocity => 520.0;

  @override
  double get minFlingDistance => 36.0;
}

class _DockCircleSurface extends StatelessWidget {
  const _DockCircleSurface({
    required this.size,
    required this.child,
    this.accentActive = false,
  });

  final double size;
  final Widget child;
  final bool accentActive;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.36 : 0.11),
            blurRadius: 16,
            spreadRadius: -2,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: ClipOval(
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: accentActive
                  ? LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        replicaAccentColor.withValues(alpha: 0.96),
                        replicaAccentColor.withValues(alpha: 0.88),
                      ],
                    )
                  : LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: isDark
                          ? const [Color(0xBA26262C), Color(0xAD18181D)]
                          : const [Color(0xC9FFFFFF), Color(0xB3F4F4F8)],
                    ),
              border: Border.all(
                color: accentActive
                    ? replicaAccentColor
                    : (isDark
                          ? Colors.white.withValues(alpha: 0.18)
                          : Colors.black.withValues(alpha: 0.08)),
                width: 0.9,
              ),
            ),
            alignment: Alignment.center,
            child: child,
          ),
        ),
      ),
    );
  }
}

class _DockCircleButton extends StatelessWidget {
  const _DockCircleButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.iconColor,
    this.size = 42,
    this.iconSize = 22,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final Color? iconColor;
  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final button = _DockCircleSurface(
      size: size,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: SizedBox(
            width: size,
            height: size,
            child: Icon(
              icon,
              size: iconSize,
              color: onPressed == null
                  ? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4)
                  : (iconColor ?? replicaAccentColor),
            ),
          ),
        ),
      ),
    );
    if (tooltip == null) {
      return button;
    }
    return Tooltip(message: tooltip!, child: button);
  }
}

class _FloatingDockCapsule extends StatelessWidget {
  const _FloatingDockCapsule({
    super.key,
    required this.height,
    required this.child,
    this.padding = EdgeInsets.zero,
  });

  final double height;
  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final radius = BorderRadius.circular(999);

    return Container(
      height: height,
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.38 : 0.11),
            blurRadius: 20,
            spreadRadius: -2,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              borderRadius: radius,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: isDark
                    ? const [Color(0xBA26262C), Color(0xAD18181D)]
                    : const [Color(0xC9FFFFFF), Color(0xB3F4F4F8)],
              ),
              border: Border.all(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.18)
                    : Colors.black.withValues(alpha: 0.08),
                width: 0.9,
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

class _MaxStorageDialog extends StatefulWidget {
  const _MaxStorageDialog({required this.initialGb});

  final int initialGb;

  @override
  State<_MaxStorageDialog> createState() => _MaxStorageDialogState();
}

class _MaxStorageDialogState extends State<_MaxStorageDialog> {
  late final TextEditingController _controller;
  late bool _useLimit;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _useLimit = widget.initialGb > 0;
    _controller = TextEditingController(
      text: widget.initialGb > 0 ? '${widget.initialGb}' : '',
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      key: const Key('max-storage-picker-dialog'),
      insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 10, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '저장 용량 제한',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.3,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '닫기',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                '저장 용량을 초과하면 가장 오랫동안 듣지 않은 곡부터 삭제합니다.',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 13,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 20,
                vertical: 2,
              ),
              title: Text(
                '제한 없음',
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontSize: 15.5,
                  fontWeight: !_useLimit ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
              trailing: !_useLimit
                  ? const Icon(
                      Icons.check_rounded,
                      size: 20,
                      color: replicaAccentColor,
                    )
                  : null,
              onTap: () => Navigator.of(context).pop(0),
            ),
            const Divider(height: 1, indent: 20, endIndent: 20),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    key: const Key('max-storage-gb-input'),
                    controller: _controller,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: '용량 직접 입력',
                      hintText: '예: 5',
                      suffixText: 'GB',
                      errorText: _errorText,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    onChanged: (_) {
                      setState(() {
                        _useLimit = true;
                        _errorText = null;
                      });
                    },
                  ),
                  const SizedBox(height: 14),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('취소'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        key: const Key('max-storage-confirm-button'),
                        style: FilledButton.styleFrom(
                          backgroundColor: replicaAccentColor,
                          foregroundColor: Colors.white,
                        ),
                        onPressed: () {
                          final parsed = int.tryParse(_controller.text.trim());
                          if (parsed == null || parsed <= 0) {
                            setState(() {
                              _errorText = '1 이상의 숫자를 입력하세요.';
                            });
                            return;
                          }
                          Navigator.of(context).pop(parsed);
                        },
                        child: const Text('적용'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CreatePlaylistDialog extends StatefulWidget {
  const _CreatePlaylistDialog();

  @override
  State<_CreatePlaylistDialog> createState() => _CreatePlaylistDialogState();
}

class _CreatePlaylistDialogState extends State<_CreatePlaylistDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('새 재생목록'),
      content: TextField(
        key: const Key('create-playlist-input'),
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(
          hintText: '재생목록 이름 입력',
          helperText: 'YouTube 저장 시 전용 접미사가 자동 관리됩니다.',
          filled: true,
          fillColor: theme.colorScheme.surfaceContainer,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: theme.colorScheme.outline),
          ),
        ),
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          key: const Key('create-playlist-confirm'),
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('만들기'),
        ),
      ],
    );
  }
}

class _CoverBox extends StatelessWidget {
  const _CoverBox({
    required this.color,
    required this.size,
    this.radius = 8,
    this.imageUrl,
  });

  final Color color;
  final double size;
  final double radius;
  final String? imageUrl;

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(radius),
      ),
      alignment: Alignment.center,
      child: Icon(
        Icons.music_note,
        color: Colors.white.withValues(alpha: 0.9),
        size: size * 0.45,
      ),
    );
    final url = imageUrl?.trim() ?? '';
    if (!url.startsWith('https://')) {
      return fallback;
    }
    final decodeHeight = (size * MediaQuery.devicePixelRatioOf(context))
        .round()
        .clamp(64, 240);
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: size,
        height: size,
        child: SizedBox.expand(
          child: CachedCoverImage(
            imageUrl: url,
            fallback: fallback,
            decodeHeight: decodeHeight,
            filterQuality: FilterQuality.low,
            fit: BoxFit.cover,
          ),
        ),
      ),
    );
  }
}
