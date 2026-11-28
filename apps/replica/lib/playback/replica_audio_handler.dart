import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/library_models.dart';
import '../ui/now_playing_sheet.dart';
import 'download_manager.dart';
import 'playback_persistence.dart';

abstract class AudioEngineBackend {
  Stream<bool> get playingStream;
  Stream<Duration> get positionStream;
  Stream<Duration?> get durationStream;
  Stream<void> get completedStream;
  Stream<Object> get errorStream;

  Future<void> initialize();
  Future<Duration?> loadFile(String path, {Duration? initialPosition});
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> stop();
  Future<void> dispose();
}

class YMusicPlayerBackend implements AudioEngineBackend {
  static const _channel = MethodChannel('io.replicamedia.replica/player');

  final StreamController<bool> _playingController =
      StreamController<bool>.broadcast();
  final StreamController<Duration> _positionController =
      StreamController<Duration>.broadcast();
  final StreamController<Duration?> _durationController =
      StreamController<Duration?>.broadcast();
  final StreamController<void> _completedController =
      StreamController<void>.broadcast();
  final StreamController<Object> _errorController =
      StreamController<Object>.broadcast();

  StreamSubscription<AudioInterruptionEvent>? _interruptionSub;
  StreamSubscription<void>? _becomingNoisySub;
  bool _initialized = false;
  bool _playing = false;
  bool _resumeAfterInterruption = false;

  @override
  Stream<bool> get playingStream => _playingController.stream;

  @override
  Stream<Duration> get positionStream => _positionController.stream;

  @override
  Stream<Duration?> get durationStream => _durationController.stream;

  @override
  Stream<void> get completedStream => _completedController.stream;

  @override
  Stream<Object> get errorStream => _errorController.stream;

  @override
  Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'playing':
          final value = call.arguments == true;
          _playing = value;
          _playingController.add(value);
          break;
        case 'position':
          final ms = (call.arguments as num?)?.toInt() ?? 0;
          _positionController.add(Duration(milliseconds: ms));
          break;
        case 'duration':
          final ms = (call.arguments as num?)?.toInt() ?? 0;
          if (ms > 0) {
            _durationController.add(Duration(milliseconds: ms));
          }
          break;
        case 'completed':
          _completedController.add(null);
          break;
        case 'error':
          _errorController.add(
            Exception(call.arguments?.toString() ?? '재생 오류'),
          );
          break;
      }
    });
    try {
      await _channel.invokeMethod<bool>('init');
    } catch (_) {}
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
      _interruptionSub = session.interruptionEventStream.listen((event) {
        if (event.begin) {
          switch (event.type) {
            case AudioInterruptionType.duck:
              break;
            case AudioInterruptionType.pause:
            case AudioInterruptionType.unknown:
              if (_playing) {
                _resumeAfterInterruption = true;
                unawaited(pause());
              }
              break;
          }
        } else {
          switch (event.type) {
            case AudioInterruptionType.duck:
              break;
            case AudioInterruptionType.pause:
              if (_resumeAfterInterruption) {
                _resumeAfterInterruption = false;
                unawaited(play());
              }
              break;
            case AudioInterruptionType.unknown:
              _resumeAfterInterruption = false;
              break;
          }
        }
      });
      _becomingNoisySub = session.becomingNoisyEventStream.listen((_) {
        _resumeAfterInterruption = false;
        if (_playing) {
          unawaited(pause());
        }
      });
    } catch (_) {}
  }

  @override
  Future<Duration?> loadFile(String path, {Duration? initialPosition}) async {
    await initialize();
    await _channel.invokeMethod<void>('loadFile', {
      'path': path,
      'initialPositionMs': initialPosition?.inMilliseconds ?? 0,
    });
    return null;
  }

  @override
  Future<void> play() async {
    await initialize();
    try {
      final session = await AudioSession.instance;
      await session.setActive(true);
    } catch (_) {}
    await _channel.invokeMethod<bool>('play');
  }

  @override
  Future<void> pause() async {
    _resumeAfterInterruption = false;
    await _channel.invokeMethod<bool>('pause');
  }

  @override
  Future<void> seek(Duration position) async {
    await _channel.invokeMethod<bool>('seek', {
      'positionMs': position.inMilliseconds,
    });
  }

  @override
  Future<void> stop() async {
    _resumeAfterInterruption = false;
    await _channel.invokeMethod<bool>('stop');
  }

  @override
  Future<void> dispose() async {
    _channel.setMethodCallHandler(null);
    await _interruptionSub?.cancel();
    await _becomingNoisySub?.cancel();
    await _playingController.close();
    await _positionController.close();
    await _durationController.close();
    await _completedController.close();
    await _errorController.close();
  }
}

class NoopAudioEngineBackend implements AudioEngineBackend {
  final StreamController<bool> _playing = StreamController<bool>.broadcast();
  final StreamController<Duration> _position =
      StreamController<Duration>.broadcast();
  final StreamController<Duration?> _duration =
      StreamController<Duration?>.broadcast();
  final StreamController<void> _completed = StreamController<void>.broadcast();
  final StreamController<Object> _error = StreamController<Object>.broadcast();

  @override
  Stream<bool> get playingStream => _playing.stream;

  @override
  Stream<Duration> get positionStream => _position.stream;

  @override
  Stream<Duration?> get durationStream => _duration.stream;

  @override
  Stream<void> get completedStream => _completed.stream;

  @override
  Stream<Object> get errorStream => _error.stream;

  @override
  Future<void> initialize() async {}

  @override
  Future<Duration?> loadFile(String path, {Duration? initialPosition}) async {
    if (initialPosition != null) {
      _position.add(initialPosition);
    }
    return const Duration(minutes: 3);
  }

  @override
  Future<void> play() async => _playing.add(true);

  @override
  Future<void> pause() async => _playing.add(false);

  @override
  Future<void> seek(Duration position) async => _position.add(position);

  @override
  Future<void> stop() async => _playing.add(false);

  @override
  Future<void> dispose() async {
    await _playing.close();
    await _position.close();
    await _duration.close();
    await _completed.close();
    await _error.close();
  }
}

class ReplicaAudioServiceHandler extends BaseAudioHandler with SeekHandler {
  Future<void> Function()? onPlay;
  Future<void> Function()? onPause;
  Future<void> Function()? onStop;
  Future<void> Function(Duration position)? onSeek;
  Future<void> Function()? onSkipNext;
  Future<void> Function()? onSkipPrevious;

  void updateNowPlaying({
    required TrackItem track,
    required int durationMs,
    String? localArtPath,
  }) {
    Uri? artUri;
    if (localArtPath != null && localArtPath.isNotEmpty) {
      artUri = Uri.file(localArtPath);
    } else if (track.thumbnail.trim().startsWith('https://')) {
      artUri = Uri.tryParse(track.thumbnail.trim());
    }
    mediaItem.add(
      MediaItem(
        id: track.id,
        title: track.title,
        artist: track.artist,
        duration: durationMs > 0 ? Duration(milliseconds: durationMs) : null,
        artUri: artUri,
      ),
    );
  }

  void updateTransportState({
    required bool playing,
    required bool loading,
    required int positionMs,
    required bool hasQueueControls,
  }) {
    final controls = <MediaControl>[
      if (hasQueueControls) MediaControl.skipToPrevious,
      playing ? MediaControl.pause : MediaControl.play,
      if (hasQueueControls) MediaControl.skipToNext,
    ];
    final compactIndices = hasQueueControls ? const [0, 1, 2] : const [0];
    playbackState.add(
      playbackState.value.copyWith(
        controls: controls,
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        androidCompactActionIndices: compactIndices,
        processingState: loading
            ? AudioProcessingState.loading
            : AudioProcessingState.ready,
        playing: playing,
        updatePosition: Duration(milliseconds: positionMs),
        speed: playing ? 1.0 : 0.0,
      ),
    );
  }

  @override
  Future<void> play() async => await onPlay?.call();

  @override
  Future<void> pause() async => await onPause?.call();

  @override
  Future<void> stop() async {
    await onStop?.call();
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) async => await onSeek?.call(position);

  @override
  Future<void> skipToNext() async => await onSkipNext?.call();

  @override
  Future<void> skipToPrevious() async => await onSkipPrevious?.call();
}

class ReplicaPlaybackController {
  ReplicaPlaybackController({
    required this.downloadManager,
    required this.persistence,
    AudioEngineBackend? engine,
    this.serviceHandler,
    this.onMessage,
    this.onError,
    this.onTrackUpdated,
    this.onTrackPlayed,
  }) : _engine = engine ?? _defaultEngine();

  static const int restartThresholdMs = 3000;

  static AudioEngineBackend _defaultEngine() {
    if (Platform.isAndroid) {
      return YMusicPlayerBackend();
    }
    return NoopAudioEngineBackend();
  }

  final DownloadManager downloadManager;
  final PlaybackPersistence persistence;
  final AudioEngineBackend _engine;
  final ReplicaAudioServiceHandler? serviceHandler;
  final void Function(String message)? onMessage;
  final void Function(String source, String message, String? stackTrace)?
  onError;
  final void Function(TrackItem updated)? onTrackUpdated;
  final void Function(TrackItem track)? onTrackPlayed;

  final ValueNotifier<PlaybackSnapshot?> snapshot =
      ValueNotifier<PlaybackSnapshot?>(null);

  List<TrackItem> _queue = const [];
  int _queueIndex = -1;
  TrackItem? _activeTrack;
  bool _isPlaying = false;
  bool _isLoading = false;
  int _positionMs = 0;
  int _durationMs = 0;
  int _requestSeq = 0;
  String? _loadingTrackId;
  String? _prefetchingTrackId;
  bool _hasLoadedCurrentTrack = false;
  bool _shuffleEnabled = false;
  PlaybackRepeatMode _repeatMode = PlaybackRepeatMode.all;
  final Set<int> _shuffleRemaining = {};
  final List<int> _shuffleHistory = [];
  final List<String> _upNextTrackIds = [];
  final Random _random = Random();
  Timer? _prefetchTimer;

  StreamSubscription<bool>? _playingSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration?>? _durationSub;
  StreamSubscription<void>? _completedSub;
  StreamSubscription<Object>? _errorSub;

  TrackItem? get activeTrack => _activeTrack;
  List<TrackItem> get queue => _queue;
  int get queueIndex => _queueIndex;
  bool get isPlaying => _isPlaying;
  bool get isLoading => _isLoading;
  bool get shuffleEnabled => _shuffleEnabled;
  PlaybackRepeatMode get repeatMode => _repeatMode;
  bool get hasPrevious => _activeTrack != null;
  bool get hasNext => _queue.length > 1 && _queueIndex >= 0;

  Future<void> initialize() async {
    await _engine.initialize();
    _playingSub = _engine.playingStream.listen((playing) {
      if (_isPlaying != playing) {
        _isPlaying = playing;
        _emitState();
      }
    });
    _positionSub = _engine.positionStream.listen((pos) {
      final ms = pos.inMilliseconds;
      if ((ms - _positionMs).abs() >= 200 || ms == 0) {
        _positionMs = ms;
        _emitState(syncSystem: false);
        _schedulePersist();
      }
    });
    _durationSub = _engine.durationStream.listen((dur) {
      final ms = dur?.inMilliseconds ?? 0;
      if (ms > 0 && ms != _durationMs) {
        _durationMs = ms;
        _emitState();
      }
    });
    _completedSub = _engine.completedStream.listen((_) {
      unawaited(_handleTrackCompleted());
    });
    _errorSub = _engine.errorStream.listen((error) {
      onError?.call('AudioEngine', error.toString(), null);
    });

    final handler = serviceHandler;
    if (handler != null) {
      handler.onPlay = resume;
      handler.onPause = pause;
      handler.onStop = stop;
      handler.onSeek = (pos) => seek(pos.inMilliseconds);
      handler.onSkipNext = skipToNext;
      handler.onSkipPrevious = skipToPrevious;
    }
  }

  void restorePersistedState() {
    if (_activeTrack != null) {
      return;
    }
    final restored = persistence.load();
    if (restored == null || restored.currentTrack == null) {
      return;
    }
    final resolvedQueue = restored.queue
        .map((t) {
          final local = downloadManager.resolveLocalPath(t);
          return local != null
              ? t.copyWith(filePath: local, isDownloaded: true)
              : t;
        })
        .toList(growable: false);
    _queue = List<TrackItem>.unmodifiable(resolvedQueue);
    _queueIndex = restored.queueIndex;
    _activeTrack = _queue[_queueIndex];
    _positionMs = restored.positionMs;
    _isPlaying = false;
    _isLoading = false;
    _hasLoadedCurrentTrack = false;
    _emitState();
  }

  void _resetShufflePool({required int currentIndex}) {
    _shuffleRemaining
      ..clear()
      ..addAll(List<int>.generate(_queue.length, (i) => i));
    _shuffleRemaining.remove(currentIndex);
  }

  int? _pickNextShuffleIndex({required bool allowRefill}) {
    if (_queue.length <= 1) {
      return null;
    }
    _shuffleRemaining.remove(_queueIndex);
    if (_shuffleRemaining.isEmpty) {
      if (!allowRefill) {
        return null;
      }
      _resetShufflePool(currentIndex: _queueIndex);
    }
    if (_shuffleRemaining.isEmpty) {
      return null;
    }
    final list = _shuffleRemaining.toList(growable: false);
    final chosen = list[_random.nextInt(list.length)];
    _shuffleRemaining.remove(chosen);
    return chosen;
  }

  void toggleShuffle() {
    _shuffleEnabled = !_shuffleEnabled;
    _shuffleHistory.clear();
    if (_shuffleEnabled && _queue.isNotEmpty) {
      _resetShufflePool(currentIndex: _queueIndex);
    } else {
      _shuffleRemaining.clear();
    }
    _emitState();
  }

  void cycleRepeatMode() {
    switch (_repeatMode) {
      case PlaybackRepeatMode.off:
        _repeatMode = PlaybackRepeatMode.one;
        break;
      case PlaybackRepeatMode.one:
        _repeatMode = PlaybackRepeatMode.all;
        break;
      case PlaybackRepeatMode.all:
        _repeatMode = PlaybackRepeatMode.off;
        break;
    }
    _emitState();
  }

  Future<void> playQueueShuffled(List<TrackItem> tracks) async {
    if (tracks.isEmpty) {
      return;
    }
    _shuffleEnabled = true;
    _shuffleHistory.clear();
    final startIndex = _random.nextInt(tracks.length);
    await playTrack(tracks[startIndex], queue: tracks, resetShufflePool: true);
  }

  Future<void> playTrack(
    TrackItem track, {
    List<TrackItem>? queue,
    int initialPositionMs = 0,
    int recoveryHops = 0,
    bool resetShufflePool = false,
  }) async {
    final seq = ++_requestSeq;
    _prefetchTimer?.cancel();
    final prevPrefetchId = _prefetchingTrackId;
    if (prevPrefetchId != null && prevPrefetchId != track.id) {
      downloadManager.cancelPlaybackDownload(prevPrefetchId);
      _prefetchingTrackId = null;
    }
    final prevLoadingId = _loadingTrackId;
    if (prevLoadingId != null && prevLoadingId != track.id) {
      downloadManager.cancelPlaybackDownload(prevLoadingId);
      _loadingTrackId = null;
    }

    final isNewQueue =
        queue != null &&
        queue.isNotEmpty &&
        !identical(queue, _queue) &&
        (queue.length != _queue.length ||
            !List<bool>.generate(
              queue.length,
              (i) => queue[i].id == _queue[i].id,
            ).every((e) => e));

    final resolvedQueue = queue != null && queue.isNotEmpty
        ? List<TrackItem>.unmodifiable(queue)
        : (_queue.any((t) => t.id == track.id)
              ? _queue
              : List<TrackItem>.unmodifiable([track]));
    final resolvedIndex = resolvedQueue.indexWhere((t) => t.id == track.id);

    _queue = resolvedQueue;
    _queueIndex = resolvedIndex >= 0 ? resolvedIndex : 0;
    if (isNewQueue || resetShufflePool) {
      _shuffleHistory.clear();
      _upNextTrackIds.clear();
      if (_shuffleEnabled) {
        _resetShufflePool(currentIndex: _queueIndex);
      }
    } else if (_shuffleEnabled) {
      _shuffleRemaining.remove(_queueIndex);
    }
    _upNextTrackIds.remove(track.id);
    _activeTrack = track;
    final cachedLocal = downloadManager.resolveLocalPath(track);
    _isLoading = true;
    _isPlaying = false;
    _durationMs = 0;
    _positionMs = initialPositionMs;
    _hasLoadedCurrentTrack = false;
    _emitState();

    try {
      await _engine.stop();
      if (seq != _requestSeq) return;
      String? filePath = cachedLocal;
      if (filePath == null) {
        _loadingTrackId = track.id;
        try {
          filePath = await downloadManager.ensureLocalFile(track);
        } finally {
          if (_loadingTrackId == track.id) {
            _loadingTrackId = null;
          }
        }
      }
      if (seq != _requestSeq) {
        return;
      }
      if (filePath == null || filePath.isEmpty) {
        _isLoading = false;
        _isPlaying = false;
        _emitState();
        return;
      }

      Duration? loadedDuration;
      try {
        loadedDuration = await _engine.loadFile(
          filePath,
          initialPosition: initialPositionMs > 0
              ? Duration(milliseconds: initialPositionMs)
              : null,
        );
      } catch (decodeErr) {
        if (seq != _requestSeq) {
          return;
        }
        await downloadManager.invalidateLocalFile(track.id);
        _loadingTrackId = track.id;
        String? redownloaded;
        try {
          redownloaded = await downloadManager.ensureLocalFile(track);
        } finally {
          if (_loadingTrackId == track.id) {
            _loadingTrackId = null;
          }
        }
        if (seq != _requestSeq) {
          return;
        }
        if (redownloaded == null || redownloaded.isEmpty) {
          rethrow;
        }
        filePath = redownloaded;
        loadedDuration = await _engine.loadFile(
          filePath,
          initialPosition: initialPositionMs > 0
              ? Duration(milliseconds: initialPositionMs)
              : null,
        );
        onError?.call(
          'AudioDecodeRecovery',
          '손상된 로컬 음원을 재다운로드해 복구했습니다: ${track.title} ($decodeErr)',
          null,
        );
      }

      if (seq != _requestSeq) {
        return;
      }

      final updated = track.copyWith(filePath: filePath, isDownloaded: true);
      _activeTrack = updated;
      _queue = _queue
          .map((t) => t.id == updated.id ? updated : t)
          .toList(growable: false);
      _durationMs = loadedDuration?.inMilliseconds ?? _durationMs;
      _positionMs = initialPositionMs;
      _isLoading = false;
      _hasLoadedCurrentTrack = true;
      onTrackUpdated?.call(updated);

      await _engine.play();
      if (seq != _requestSeq) {
        return;
      }
      _isPlaying = true;
      _emitState();
      onTrackPlayed?.call(updated);
      _persistNow();
      _scheduleNextTrackPrefetch();
    } catch (e, st) {
      if (seq != _requestSeq) {
        return;
      }
      onError?.call('Playback', e.toString(), st.toString());

      final nextLocalIndex = _findNextDownloadedIndex(fromIndex: _queueIndex);
      if (nextLocalIndex != null &&
          recoveryHops < _queue.length - 1 &&
          _queue.length > 1) {
        onMessage?.call('오프라인이거나 재생할 수 없어 다음 다운로드 곡으로 이동합니다.');
        await playTrack(
          _queue[nextLocalIndex],
          queue: _queue,
          recoveryHops: recoveryHops + 1,
        );
        return;
      }

      _isLoading = false;
      _isPlaying = false;
      _emitState();
      onMessage?.call(
        '재생 준비 실패: ${e.toString().replaceFirst('Exception: ', '')}',
      );
    }
  }

  int? _findNextDownloadedIndex({required int fromIndex}) {
    if (_queue.length <= 1 || fromIndex < 0) {
      return null;
    }
    for (var step = 1; step < _queue.length; step++) {
      final candidate = (fromIndex + step) % _queue.length;
      if (downloadManager.resolveLocalPath(_queue[candidate]) != null) {
        return candidate;
      }
    }
    return null;
  }

  void _scheduleNextTrackPrefetch() {
    _prefetchTimer?.cancel();
    if (_shuffleEnabled || _queue.length <= 1 || _queueIndex < 0) {
      return;
    }
    final nextIndex = (_queueIndex + 1) % _queue.length;
    final nextTrack = _queue[nextIndex];
    _prefetchTimer = Timer(const Duration(milliseconds: 1500), () {
      _prefetchingTrackId = nextTrack.id;
      downloadManager.prefetchTrack(nextTrack);
    });
  }

  int? _popUpNextIndex() {
    while (_upNextTrackIds.isNotEmpty) {
      final nextId = _upNextTrackIds.removeAt(0);
      final idx = _queue.indexWhere((t) => t.id == nextId);
      if (idx >= 0 && idx != _queueIndex) {
        return idx;
      }
    }
    return null;
  }

  void _remapShuffleIndices(
    List<TrackItem> oldQueue,
    List<TrackItem> newQueue, {
    int? includeNewIndex,
  }) {
    if (!_shuffleEnabled) {
      return;
    }
    final remainingIds = <String>{
      for (final idx in _shuffleRemaining)
        if (idx >= 0 && idx < oldQueue.length) oldQueue[idx].id,
    };
    final historyIds = <String>[
      for (final idx in _shuffleHistory)
        if (idx >= 0 && idx < oldQueue.length) oldQueue[idx].id,
    ];
    final idToNewIdx = <String, int>{
      for (var i = 0; i < newQueue.length; i++) newQueue[i].id: i,
    };
    _shuffleRemaining
      ..clear()
      ..addAll(remainingIds.map((id) => idToNewIdx[id]).whereType<int>());
    if (includeNewIndex != null &&
        includeNewIndex >= 0 &&
        includeNewIndex < newQueue.length) {
      _shuffleRemaining.add(includeNewIndex);
    }
    _shuffleRemaining.remove(_queueIndex);
    _shuffleHistory
      ..clear()
      ..addAll(historyIds.map((id) => idToNewIdx[id]).whereType<int>());
  }

  Future<void> playNextInQueue(TrackItem track) async {
    if (_activeTrack == null || _queue.isEmpty || _queueIndex < 0) {
      await playTrack(track, queue: [track]);
      return;
    }
    if (track.id == _activeTrack!.id) {
      return;
    }
    final localPath = downloadManager.resolveLocalPath(track);
    final resolvedTrack = localPath != null
        ? track.copyWith(filePath: localPath, isDownloaded: true)
        : track;
    final oldQueue = _queue;
    final nextQueue = oldQueue
        .where((t) => t.id != resolvedTrack.id)
        .toList(growable: true);
    var activeIdx = nextQueue.indexWhere((t) => t.id == _activeTrack!.id);
    if (activeIdx < 0) {
      activeIdx = 0;
    }
    final insertIdx = (activeIdx + 1).clamp(0, nextQueue.length);
    nextQueue.insert(insertIdx, resolvedTrack);
    _queue = List<TrackItem>.unmodifiable(nextQueue);
    _queueIndex = activeIdx;
    _upNextTrackIds.remove(resolvedTrack.id);
    _upNextTrackIds.insert(0, resolvedTrack.id);
    _remapShuffleIndices(oldQueue, _queue, includeNewIndex: insertIdx);
    _emitState();
    _persistNow();
    _scheduleNextTrackPrefetch();
  }

  Future<void> addToQueueEnd(TrackItem track) async {
    if (_activeTrack == null || _queue.isEmpty || _queueIndex < 0) {
      await playTrack(track, queue: [track]);
      return;
    }
    if (track.id == _activeTrack!.id) {
      return;
    }
    final localPath = downloadManager.resolveLocalPath(track);
    final resolvedTrack = localPath != null
        ? track.copyWith(filePath: localPath, isDownloaded: true)
        : track;
    final oldQueue = _queue;
    final nextQueue = oldQueue
        .where((t) => t.id != resolvedTrack.id)
        .toList(growable: true);
    nextQueue.add(resolvedTrack);
    final activeIdx = nextQueue.indexWhere((t) => t.id == _activeTrack!.id);
    _queue = List<TrackItem>.unmodifiable(nextQueue);
    _queueIndex = activeIdx >= 0 ? activeIdx : 0;
    _remapShuffleIndices(oldQueue, _queue, includeNewIndex: _queue.length - 1);
    _emitState();
    _persistNow();
    _scheduleNextTrackPrefetch();
  }

  Future<void> _handleTrackCompleted() async {
    _positionMs = 0;
    if (_repeatMode == PlaybackRepeatMode.one && _activeTrack != null) {
      await seek(0);
      await resume();
      return;
    }
    final upNextIdx = _popUpNextIndex();
    if (upNextIdx != null) {
      if (_shuffleEnabled && _queueIndex >= 0) {
        _shuffleHistory.add(_queueIndex);
      }
      await playTrack(_queue[upNextIdx], queue: _queue);
      return;
    }
    if (_shuffleEnabled && _queue.length > 1) {
      final nextIndex = _pickNextShuffleIndex(
        allowRefill: _repeatMode == PlaybackRepeatMode.all,
      );
      if (nextIndex != null) {
        if (_queueIndex >= 0) {
          _shuffleHistory.add(_queueIndex);
        }
        await playTrack(_queue[nextIndex], queue: _queue);
        return;
      }
      _isPlaying = false;
      _emitState();
      _persistNow();
      return;
    }
    if (_queue.length > 1 && _queueIndex >= 0) {
      if (_queueIndex < _queue.length - 1) {
        await playTrack(_queue[_queueIndex + 1], queue: _queue);
        return;
      }
      if (_repeatMode == PlaybackRepeatMode.all) {
        await playTrack(_queue.first, queue: _queue);
        return;
      }
    }
    _isPlaying = false;
    _emitState();
    _persistNow();
  }

  Future<void> togglePlayPause() async {
    if (_activeTrack == null || _isLoading) {
      return;
    }
    if (_isPlaying) {
      await pause();
    } else {
      await resume();
    }
  }

  Future<void> pause() async {
    await _engine.pause();
    _isPlaying = false;
    _emitState();
    _persistNow();
  }

  Future<void> resume() async {
    final track = _activeTrack;
    if (track == null || _isLoading) {
      return;
    }
    final localPath = downloadManager.resolveLocalPath(track);
    if (!_hasLoadedCurrentTrack || localPath == null) {
      _hasLoadedCurrentTrack = false;
      await playTrack(track, queue: _queue, initialPositionMs: _positionMs);
      return;
    }
    try {
      await _engine.play();
      _isPlaying = true;
      _emitState();
    } catch (_) {
      _hasLoadedCurrentTrack = false;
      await playTrack(track, queue: _queue, initialPositionMs: _positionMs);
    }
  }

  Future<void> seek(int positionMs) async {
    final clamped = _durationMs > 0
        ? positionMs.clamp(0, _durationMs)
        : positionMs.clamp(0, 86400000);
    _positionMs = clamped;
    _emitState();
    await _engine.seek(Duration(milliseconds: clamped));
    _persistNow();
  }

  Future<void> skipToNext() async {
    if (!hasNext) {
      return;
    }
    final upNextIdx = _popUpNextIndex();
    if (upNextIdx != null) {
      if (_shuffleEnabled && _queueIndex >= 0) {
        _shuffleHistory.add(_queueIndex);
      }
      await playTrack(_queue[upNextIdx], queue: _queue);
      return;
    }
    if (_shuffleEnabled) {
      final nextIndex = _pickNextShuffleIndex(allowRefill: true);
      if (nextIndex != null) {
        if (_queueIndex >= 0) {
          _shuffleHistory.add(_queueIndex);
        }
        await playTrack(_queue[nextIndex], queue: _queue);
        return;
      }
    }
    final nextIndex = (_queueIndex + 1) % _queue.length;
    await playTrack(_queue[nextIndex], queue: _queue);
  }

  Future<void> skipToPrevious() async {
    if (_activeTrack == null) {
      return;
    }
    if (_positionMs > restartThresholdMs || _queue.length <= 1) {
      await seek(0);
      if (!_isPlaying && _hasLoadedCurrentTrack) {
        await resume();
      }
      return;
    }
    if (_shuffleEnabled && _shuffleHistory.isNotEmpty) {
      final prevIndex = _shuffleHistory.removeLast().clamp(
        0,
        _queue.length - 1,
      );
      await playTrack(_queue[prevIndex], queue: _queue);
      return;
    }
    final prevIndex = (_queueIndex - 1 + _queue.length) % _queue.length;
    await playTrack(_queue[prevIndex], queue: _queue);
  }

  void _cancelPendingPlayback() {
    _requestSeq++;
    _prefetchTimer?.cancel();
    final prefetchId = _prefetchingTrackId;
    if (prefetchId != null) {
      downloadManager.cancelPlaybackDownload(prefetchId);
      _prefetchingTrackId = null;
    }
    final loadingId = _loadingTrackId;
    if (loadingId != null) {
      downloadManager.cancelPlaybackDownload(loadingId);
      _loadingTrackId = null;
    }
  }

  Future<void> pauseForVideo() async {
    _cancelPendingPlayback();
    if (_activeTrack == null) return;
    if (_isLoading) {
      await _engine.stop();
      _isLoading = false;
      _hasLoadedCurrentTrack = false;
    }
    await pause();
  }

  Future<void> stop() async {
    _cancelPendingPlayback();
    await _engine.stop();
    _isPlaying = false;
    _isLoading = false;
    _hasLoadedCurrentTrack = false;
    _upNextTrackIds.clear();
    _emitState();
    _persistNow();
  }

  Future<void> removeTrackFromQueueAndAdvance(String trackId) async {
    _upNextTrackIds.remove(trackId);
    final wasActive = _activeTrack?.id == trackId;
    final inQueue = _queue.any((t) => t.id == trackId);
    if (!wasActive && !inQueue) {
      return;
    }

    if (wasActive) {
      _cancelPendingPlayback();
      await _engine.stop();
      _isPlaying = false;
      _isLoading = false;
      _hasLoadedCurrentTrack = false;
    }

    final remaining = _queue
        .where((t) => t.id != trackId)
        .toList(growable: false);

    if (remaining.isEmpty) {
      _queue = const [];
      _queueIndex = -1;
      _activeTrack = null;
      _positionMs = 0;
      _durationMs = 0;
      _shuffleRemaining.clear();
      _shuffleHistory.clear();
      _emitState();
      return;
    }

    if (!wasActive) {
      _queue = List<TrackItem>.unmodifiable(remaining);
      _queueIndex = _queue.indexWhere((t) => t.id == _activeTrack?.id);
      if (_shuffleEnabled) {
        _shuffleHistory.clear();
        _resetShufflePool(currentIndex: _queueIndex);
      }
      _emitState();
      _persistNow();
      return;
    }

    final nextIndex = _shuffleEnabled
        ? _random.nextInt(remaining.length)
        : (_queueIndex >= 0 && _queueIndex < remaining.length
              ? _queueIndex
              : 0);
    await playTrack(
      remaining[nextIndex],
      queue: remaining,
      resetShufflePool: _shuffleEnabled,
    );
  }

  void _emitState({bool syncSystem = true}) {
    final track = _activeTrack;
    if (track == null) {
      snapshot.value = null;
      return;
    }
    snapshot.value = PlaybackSnapshot(
      track: track,
      isPlaying: _isPlaying,
      isDownloading: _isLoading,
      positionMs: _positionMs,
      durationMs: _durationMs,
      queue: _queue,
      queueIndex: _queueIndex,
      shuffleEnabled: _shuffleEnabled,
      repeatMode: _repeatMode,
    );
    if (syncSystem) {
      final handler = serviceHandler;
      if (handler != null) {
        handler.updateNowPlaying(
          track: track,
          durationMs: _durationMs,
          localArtPath: downloadManager.resolveLocalThumbnailPath(track.id),
        );
        handler.updateTransportState(
          playing: _isPlaying,
          loading: _isLoading,
          positionMs: _positionMs,
          hasQueueControls: _queue.length > 1 || _activeTrack != null,
        );
      }
    }
  }

  void _schedulePersist() {
    if (_queue.isEmpty || _queueIndex < 0) {
      return;
    }
    persistence.scheduleSave(
      PersistedPlaybackState(
        queue: _queue,
        queueIndex: _queueIndex,
        positionMs: _positionMs,
      ),
    );
  }

  void _persistNow() {
    if (_queue.isEmpty || _queueIndex < 0) {
      return;
    }
    unawaited(
      persistence.saveNow(
        PersistedPlaybackState(
          queue: _queue,
          queueIndex: _queueIndex,
          positionMs: _positionMs,
        ),
      ),
    );
  }

  Future<void> dispose() async {
    _prefetchTimer?.cancel();
    persistence.dispose();
    await _playingSub?.cancel();
    await _positionSub?.cancel();
    await _durationSub?.cancel();
    await _completedSub?.cancel();
    await _errorSub?.cancel();
    snapshot.dispose();
    await _engine.dispose();
  }
}
