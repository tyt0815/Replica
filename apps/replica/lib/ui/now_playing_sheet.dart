import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../core/thumbnail_cache.dart';
import '../models/library_models.dart';

enum PlaybackRepeatMode { off, one, all }

class PlaybackSnapshot {
  const PlaybackSnapshot({
    required this.track,
    required this.isPlaying,
    required this.isDownloading,
    required this.positionMs,
    required this.durationMs,
    required this.queue,
    required this.queueIndex,
    this.shuffleEnabled = false,
    this.repeatMode = PlaybackRepeatMode.all,
  });

  final TrackItem track;
  final bool isPlaying;
  final bool isDownloading;
  final int positionMs;
  final int durationMs;
  final List<TrackItem> queue;
  final int queueIndex;
  final bool shuffleEnabled;
  final PlaybackRepeatMode repeatMode;
}

class _CoverPalette {
  const _CoverPalette({
    required this.mainColor,
    required this.deepColor,
    required this.glowColor,
  });

  final Color mainColor;
  final Color deepColor;
  final Color glowColor;
}

class NowPlayingSheet extends StatefulWidget {
  const NowPlayingSheet({
    super.key,
    required this.stateListenable,
    required this.onTogglePlay,
    required this.onSkipPrevious,
    required this.onSkipNext,
    required this.onSeek,
    required this.onToggleShuffle,
    required this.onCycleRepeat,
    required this.onSelectQueueTrack,
    required this.onOpenTrackMenu,
    this.onGetVolume,
    this.onSetVolume,
    this.volumeStream,
    this.onClose,
    this.allowDismiss = true,
  });

  final ValueNotifier<PlaybackSnapshot?> stateListenable;
  final VoidCallback onTogglePlay;
  final VoidCallback onSkipPrevious;
  final VoidCallback onSkipNext;
  final ValueChanged<int> onSeek;
  final VoidCallback onToggleShuffle;
  final VoidCallback onCycleRepeat;
  final ValueChanged<TrackItem> onSelectQueueTrack;
  final void Function(BuildContext anchorContext, TrackItem track)
  onOpenTrackMenu;
  final Future<double> Function()? onGetVolume;
  final Future<void> Function(double)? onSetVolume;
  final Stream<double>? volumeStream;
  final VoidCallback? onClose;
  final bool allowDismiss;

  @override
  State<NowPlayingSheet> createState() => _NowPlayingSheetState();
}

class _NowPlayingSheetState extends State<NowPlayingSheet> {
  static final Map<String, _CoverPalette> _paletteCache = {};

  final ScrollController _scrollController = ScrollController();
  bool _dragStartedAtTop = false;
  double _topPullDistance = 0;
  _CoverPalette _palette = _buildPaletteFromBase(const Color(0xFF3A141A));
  String _lastColorSource = '';
  TrackItem? _currentTrack;
  bool _isPlaying = false;
  bool _isDownloading = false;
  bool _shuffleEnabled = false;
  PlaybackRepeatMode _repeatMode = PlaybackRepeatMode.all;
  int _queueLength = 0;

  @override
  void initState() {
    super.initState();
    widget.stateListenable.addListener(_onSnapshotChanged);
    _applySnapshot(widget.stateListenable.value, notify: false);
  }

  @override
  void dispose() {
    widget.stateListenable.removeListener(_onSnapshotChanged);
    _scrollController.dispose();
    super.dispose();
  }

  void _closeSheet() {
    if (!mounted || !widget.allowDismiss) {
      return;
    }
    final onClose = widget.onClose;
    if (onClose != null) {
      onClose();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  void _onSnapshotChanged() {
    final snapshot = widget.stateListenable.value;
    if (snapshot == null) {
      _closeSheet();
      return;
    }
    _applySnapshot(snapshot, notify: true);
  }

  void _applySnapshot(PlaybackSnapshot? snapshot, {required bool notify}) {
    if (snapshot == null) {
      return;
    }
    final track = snapshot.track;
    final structuralChanged =
        _currentTrack?.id != track.id ||
        _currentTrack?.thumbnail != track.thumbnail ||
        _currentTrack?.isDownloaded != track.isDownloaded ||
        _isPlaying != snapshot.isPlaying ||
        _isDownloading != snapshot.isDownloading ||
        _shuffleEnabled != snapshot.shuffleEnabled ||
        _repeatMode != snapshot.repeatMode ||
        _queueLength != snapshot.queue.length;

    _currentTrack = track;
    _isPlaying = snapshot.isPlaying;
    _isDownloading = snapshot.isDownloading;
    _shuffleEnabled = snapshot.shuffleEnabled;
    _repeatMode = snapshot.repeatMode;
    _queueLength = snapshot.queue.length;

    _syncColorFromTrack(track, notify: notify);
    if (notify && structuralChanged && mounted) {
      setState(() {});
    }
  }

  void _syncColorFromTrack(TrackItem track, {required bool notify}) {
    final key = track.thumbnail.trim().isNotEmpty
        ? track.thumbnail.trim()
        : track.id;
    if (key == _lastColorSource) {
      return;
    }
    _lastColorSource = key;
    final cached = _paletteCache[key];
    if (cached != null) {
      _palette = cached;
      if (notify && mounted) {
        setState(() {});
      }
      return;
    }
    _palette = _buildPaletteFromBase(track.coverColor);
    if (notify && mounted) {
      setState(() {});
    }
    if (track.thumbnail.trim().startsWith('https://')) {
      unawaited(_extractPalette(track.thumbnail.trim(), track.id, key));
    }
  }

  Future<void> _extractPalette(
    String url,
    String trackId,
    String cacheKey,
  ) async {
    final cachedFile = await ThumbnailCache.instance.fetchAndCache(
      url,
      itemId: trackId,
      highRes: false,
    );
    if (!mounted) {
      return;
    }
    final completer = Completer<ui.Image?>();
    final ImageProvider baseProvider = cachedFile != null
        ? FileImage(cachedFile)
        : NetworkImage(url);
    final provider = ResizeImage(
      baseProvider,
      width: 48,
      height: 48,
      allowUpscaling: false,
    );
    final stream = provider.resolve(
      const ImageConfiguration(size: Size(48, 48)),
    );
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        if (!completer.isCompleted) {
          completer.complete(info.image);
        }
        stream.removeListener(listener);
      },
      onError: (_, _) {
        if (!completer.isCompleted) {
          completer.complete(null);
        }
        stream.removeListener(listener);
      },
    );
    stream.addListener(listener);
    final image = await completer.future.timeout(
      const Duration(seconds: 4),
      onTimeout: () {
        stream.removeListener(listener);
        return null;
      },
    );
    if (image == null || !mounted) {
      return;
    }
    try {
      final byteData = await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      if (byteData == null) {
        return;
      }
      final bytes = byteData.buffer.asUint8List();
      final width = image.width;
      final height = image.height;
      final stepX = (width / 16).ceil().clamp(1, 8);
      final stepY = (height / 16).ceil().clamp(1, 8);

      double sumR = 0;
      double sumG = 0;
      double sumB = 0;
      double totalWeight = 0;

      for (var y = 0; y < height; y += stepY) {
        final isLowerBand = y >= (height * 0.55);
        final bandWeight = isLowerBand ? 2.2 : 1.0;
        for (var x = 0; x < width; x += stepX) {
          final offset = (y * width + x) * 4;
          if (offset + 3 >= bytes.length) {
            continue;
          }
          final r = bytes[offset];
          final g = bytes[offset + 1];
          final b = bytes[offset + 2];
          final a = bytes[offset + 3];
          if (a < 180) {
            continue;
          }
          final hsl = HSLColor.fromColor(Color.fromARGB(255, r, g, b));
          final satWeight = 0.30 + hsl.saturation * 2.1;
          final lightWeight = (hsl.lightness < 0.06 || hsl.lightness > 0.90)
              ? 0.25
              : 1.0;
          final weight = bandWeight * satWeight * lightWeight;
          sumR += r * weight;
          sumG += g * weight;
          sumB += b * weight;
          totalWeight += weight;
        }
      }

      if (totalWeight <= 0) {
        return;
      }
      final avg = Color.fromARGB(
        255,
        (sumR / totalWeight).round().clamp(0, 255),
        (sumG / totalWeight).round().clamp(0, 255),
        (sumB / totalWeight).round().clamp(0, 255),
      );
      final extracted = _buildPaletteFromBase(avg);
      _paletteCache[cacheKey] = extracted;
      if (mounted && _lastColorSource == cacheKey) {
        setState(() => _palette = extracted);
      }
    } catch (_) {}
  }

  static _CoverPalette _buildPaletteFromBase(Color base) {
    final hsl = HSLColor.fromColor(base);
    final sat = (hsl.saturation * 1.12).clamp(0.18, 0.74);
    final mainLightness = hsl.lightness.clamp(0.18, 0.30);
    final mainColor = hsl
        .withSaturation(sat)
        .withLightness(mainLightness)
        .toColor();
    final deepColor = hsl
        .withSaturation((sat * 0.92).clamp(0.12, 0.68))
        .withLightness((mainLightness * 0.56).clamp(0.08, 0.17))
        .toColor();
    final glowColor = hsl
        .withSaturation((sat * 1.05).clamp(0.20, 0.78))
        .withLightness((mainLightness * 1.28).clamp(0.22, 0.38))
        .toColor();
    return _CoverPalette(
      mainColor: mainColor,
      deepColor: deepColor,
      glowColor: glowColor,
    );
  }

  @override
  Widget build(BuildContext context) {
    final track = _currentTrack;
    if (track == null) {
      return const SizedBox.shrink();
    }
    final palette = _palette;
    final snapshot = widget.stateListenable.value;
    final queue = snapshot?.queue ?? const <TrackItem>[];
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return Material(
      color: palette.deepColor,
      child: LayoutBuilder(
        key: const Key('now-playing-sheet'),
        builder: (context, constraints) {
          final isLandscape =
              constraints.maxWidth > constraints.maxHeight &&
              constraints.maxWidth >= 560;
          final paneWidth = constraints.maxWidth > 0
              ? constraints.maxWidth
              : 380.0;
          final paneHeight = constraints.maxHeight > 0
              ? constraints.maxHeight
              : 800.0;
          final queuePeekHeight = queue.isNotEmpty
              ? ((isLandscape && paneHeight < 460) ? 44.0 : 76.0) + bottomInset
              : 0.0;
          final playerHeight = (paneHeight - queuePeekHeight).clamp(
            260.0,
            paneHeight,
          );
          final coverSize = isLandscape
              ? playerHeight.clamp(200.0, paneWidth * 0.50)
              : paneWidth.clamp(240.0, playerHeight);
          final backdropTransitionStart = isLandscape
              ? (coverSize / paneWidth).clamp(0.42, 0.80)
              : (coverSize / paneHeight).clamp(0.48, 0.92);

          return Stack(
            fit: StackFit.expand,
            children: [
              RepaintBoundary(
                child: _buildAmbientAcrylicBackdrop(
                  palette,
                  isLandscape: isLandscape,
                  transitionStart: backdropTransitionStart,
                ),
              ),
              NotificationListener<ScrollNotification>(
                onNotification: (notification) {
                  if (notification is ScrollStartNotification) {
                    _dragStartedAtTop =
                        notification.dragDetails != null &&
                        _scrollController.hasClients &&
                        _scrollController.offset <= 0.5;
                    _topPullDistance = 0;
                    return false;
                  }
                  if (notification is ScrollUpdateNotification) {
                    if (notification.metrics.pixels > 2.0) {
                      _dragStartedAtTop = false;
                      _topPullDistance = 0;
                    }
                    return false;
                  }
                  if (notification is OverscrollNotification) {
                    if (_dragStartedAtTop &&
                        notification.dragDetails != null &&
                        notification.overscroll < 0) {
                      _topPullDistance += -notification.overscroll;
                      if (_topPullDistance >= 56) {
                        _dragStartedAtTop = false;
                        _topPullDistance = 0;
                        _closeSheet();
                        return true;
                      }
                    }
                    return false;
                  }
                  if (notification is ScrollEndNotification) {
                    _dragStartedAtTop = false;
                    _topPullDistance = 0;
                  }
                  return false;
                },
                child: CustomScrollView(
                  controller: _scrollController,
                  physics: const ClampingScrollPhysics(),
                  slivers: [
                    SliverToBoxAdapter(
                      child: SizedBox(
                        height: playerHeight,
                        child: isLandscape
                            ? _buildLandscapePlayer(
                                context,
                                track,
                                palette,
                                paneWidth: paneWidth,
                                paneHeight: playerHeight,
                                squareSize: coverSize,
                                hasQueueBelow: queue.isNotEmpty,
                              )
                            : _buildPortraitPlayer(
                                context,
                                track,
                                palette,
                                paneWidth: paneWidth,
                                paneHeight: playerHeight,
                                coverHeight: coverSize,
                                hasQueueBelow: queue.isNotEmpty,
                              ),
                      ),
                    ),
                    if (queue.isNotEmpty) ...[
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(24, 10, 24, 8),
                          child: Row(
                            children: [
                              const Expanded(
                                child: Text(
                                  '음악 재생목록',
                                  key: Key('now-playing-queue-header'),
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 18,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              Text(
                                '${queue.length}곡 · ${formatTotalTracksDuration(queue)}',
                                key: const Key('now-playing-queue-summary'),
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.65),
                                  fontSize: 13.5,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      SliverFixedExtentList.builder(
                        itemExtent: 64,
                        itemCount: queue.length,
                        itemBuilder: (context, index) {
                          final item = queue[index];
                          final isCurrent = item.id == track.id;
                          return Padding(
                            key: Key('now-playing-queue-item-$index'),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 2,
                            ),
                            child: Material(
                              color: isCurrent
                                  ? Colors.white.withValues(alpha: 0.14)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(14),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(14),
                                onTap: () => widget.onSelectQueueTrack(item),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                  ),
                                  child: Row(
                                    children: [
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(8),
                                        child: SizedBox(
                                          width: 44,
                                          height: 44,
                                          child: _buildArtworkImage(
                                            item,
                                            fit: BoxFit.cover,
                                            highRes: false,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              item.title,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                color: Colors.white,
                                                fontSize: 15,
                                                fontWeight: isCurrent
                                                    ? FontWeight.w700
                                                    : FontWeight.w500,
                                              ),
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              item.artist,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                color: Colors.white.withValues(
                                                  alpha: 0.68,
                                                ),
                                                fontSize: 12.5,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      if (isCurrent)
                                        const Icon(
                                          Icons.graphic_eq_rounded,
                                          color: Colors.white,
                                          size: 20,
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                      SliverToBoxAdapter(
                        child: SizedBox(height: bottomInset + 28),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildAmbientAcrylicBackdrop(
    _CoverPalette palette, {
    required bool isLandscape,
    required double transitionStart,
  }) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: isLandscape ? Alignment.centerLeft : Alignment.topCenter,
          end: isLandscape ? Alignment.centerRight : Alignment.bottomCenter,
          colors: [palette.mainColor, palette.mainColor, palette.deepColor],
          stops: [0.0, transitionStart, 1.0],
        ),
      ),
    );
  }

  Widget _buildPortraitPlayer(
    BuildContext context,
    TrackItem track,
    _CoverPalette palette, {
    required double paneWidth,
    required double paneHeight,
    required double coverHeight,
    required bool hasQueueBelow,
  }) {
    final media = MediaQuery.of(context);
    final topInset = media.padding.top;
    final bottomInset = hasQueueBelow ? 0.0 : media.padding.bottom;
    final remainingHeight = (paneHeight - coverHeight - bottomInset).clamp(
      0.0,
      paneHeight,
    );
    final useCompactControls = remainingHeight < 340;
    final decodeHeight = (coverHeight * media.devicePixelRatio).round().clamp(
      480,
      1440,
    );

    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned(
          key: const Key('now-playing-cover'),
          top: 0,
          left: 0,
          right: 0,
          height: coverHeight,
          child: RepaintBoundary(
            child: Stack(
              fit: StackFit.expand,
              children: [
                _buildArtworkImage(
                  track,
                  fit: BoxFit.cover,
                  alignment: Alignment.center,
                  highRes: true,
                  decodeHeight: decodeHeight,
                ),
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        palette.mainColor.withValues(alpha: 0.0),
                        palette.mainColor.withValues(alpha: 0.45),
                        palette.mainColor.withValues(alpha: 0.88),
                        palette.mainColor,
                      ],
                      stops: const [0.0, 0.60, 0.75, 0.88, 1.0],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Column(
          children: [
            SizedBox(height: topInset + 8),
            const Spacer(),
            Padding(
              padding: EdgeInsets.fromLTRB(
                24,
                useCompactControls ? 4 : 8,
                24,
                0,
              ),
              child: _buildFloatingAcrylicControls(
                context,
                track,
                compact: useCompactControls,
              ),
            ),
            SizedBox(
              height: hasQueueBelow
                  ? (useCompactControls ? 10 : 16)
                  : (useCompactControls ? 16 : 24) + bottomInset,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildLandscapePlayer(
    BuildContext context,
    TrackItem track,
    _CoverPalette palette, {
    required double paneWidth,
    required double paneHeight,
    required double squareSize,
    required bool hasQueueBelow,
  }) {
    final media = MediaQuery.of(context);
    final topInset = media.padding.top;
    final bottomInset = hasQueueBelow ? 0.0 : media.padding.bottom;
    final isCompactHeight = paneHeight < 460;
    final decodeHeight = (squareSize * media.devicePixelRatio).round().clamp(
      480,
      1440,
    );

    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned(
          key: const Key('now-playing-cover'),
          top: 0,
          left: 0,
          width: squareSize,
          height: squareSize,
          child: RepaintBoundary(
            child: Stack(
              fit: StackFit.expand,
              children: [
                _buildArtworkImage(
                  track,
                  fit: BoxFit.cover,
                  alignment: Alignment.center,
                  highRes: true,
                  decodeHeight: decodeHeight,
                ),
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: [
                        Colors.transparent,
                        palette.mainColor.withValues(alpha: 0.0),
                        palette.mainColor.withValues(alpha: 0.45),
                        palette.mainColor.withValues(alpha: 0.88),
                        palette.mainColor,
                      ],
                      stops: const [0.0, 0.60, 0.75, 0.88, 1.0],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Positioned(
          top: topInset + 10,
          left: squareSize + 12,
          right: 24,
          bottom: hasQueueBelow ? 6 : bottomInset + 10,
          child: Center(
            child: _buildFloatingAcrylicControls(
              context,
              track,
              compact: isCompactHeight,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFloatingAcrylicControls(
    BuildContext context,
    TrackItem track, {
    required bool compact,
  }) {
    final hasQueueNav = _queueLength > 1;
    final repeatIcon = _repeatMode == PlaybackRepeatMode.one
        ? Icons.repeat_one_rounded
        : Icons.repeat_rounded;
    final repeatActive = _repeatMode != PlaybackRepeatMode.off;
    final repeatTooltip = switch (_repeatMode) {
      PlaybackRepeatMode.off => '반복 없음',
      PlaybackRepeatMode.one => '한 곡 반복',
      PlaybackRepeatMode.all => '음악 재생목록 반복',
    };

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    track.title,
                    key: const Key('now-playing-title'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: compact ? 19 : 22,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.35,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    track.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.72),
                      fontSize: compact ? 15 : 17,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Builder(
              builder: (anchorContext) => _AcrylicGlassCircleButton(
                key: const Key('now-playing-more-button'),
                tooltip: '더보기',
                icon: Icons.more_horiz_rounded,
                onTap: () => widget.onOpenTrackMenu(anchorContext, track),
              ),
            ),
          ],
        ),
        SizedBox(height: compact ? 14 : 22),
        _NowPlayingSeekBar(
          stateListenable: widget.stateListenable,
          onSeek: widget.onSeek,
        ),
        SizedBox(height: compact ? 6 : 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _TransportToggleIcon(
              key: const Key('now-playing-shuffle-button'),
              tooltip: _shuffleEnabled ? '셔플 켜짐' : '셔플 꺼짐',
              icon: Icons.shuffle_rounded,
              active: _shuffleEnabled,
              size: compact ? 25 : 28,
              onPressed: widget.onToggleShuffle,
            ),
            IconButton(
              key: const Key('now-playing-previous'),
              tooltip: '이전 곡',
              iconSize: compact ? 38 : 44,
              color: Colors.white,
              icon: const Icon(Icons.fast_rewind_rounded),
              onPressed: widget.onSkipPrevious,
            ),
            IconButton(
              key: const Key('now-playing-toggle'),
              tooltip: _isPlaying ? '일시정지' : '재생',
              iconSize: compact ? 52 : 62,
              color: Colors.white,
              icon: Icon(
                _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
              ),
              onPressed: widget.onTogglePlay,
            ),
            IconButton(
              key: const Key('now-playing-next'),
              tooltip: '다음 곡',
              iconSize: compact ? 38 : 44,
              color: hasQueueNav
                  ? Colors.white
                  : Colors.white.withValues(alpha: 0.35),
              icon: const Icon(Icons.fast_forward_rounded),
              onPressed: hasQueueNav ? widget.onSkipNext : null,
            ),
            _TransportToggleIcon(
              key: const Key('now-playing-repeat-button'),
              tooltip: repeatTooltip,
              icon: repeatIcon,
              active: repeatActive,
              size: compact ? 25 : 28,
              onPressed: widget.onCycleRepeat,
            ),
          ],
        ),
        SizedBox(height: compact ? 8 : 20),
        _NowPlayingVolumeSlider(
          onGetVolume: widget.onGetVolume,
          onSetVolume: widget.onSetVolume,
          volumeStream: widget.volumeStream,
        ),
      ],
    );
  }

  Widget _buildArtworkImage(
    TrackItem track, {
    required BoxFit fit,
    required bool highRes,
    Alignment alignment = Alignment.center,
    int? decodeHeight,
  }) {
    final fallback = Container(
      color: track.coverColor,
      alignment: Alignment.center,
      child: Icon(
        Icons.music_note_rounded,
        color: Colors.white.withValues(alpha: 0.42),
        size: highRes ? 72 : 22,
      ),
    );
    return CachedCoverImage(
      imageUrl: track.thumbnail,
      itemId: track.id,
      highRes: highRes,
      fit: fit,
      alignment: alignment,
      decodeHeight: decodeHeight,
      filterQuality: highRes ? FilterQuality.medium : FilterQuality.low,
      fallback: fallback,
    );
  }
}

class _TransportToggleIcon extends StatelessWidget {
  const _TransportToggleIcon({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.active,
    required this.size,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final bool active;
  final double size;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        radius: 24,
        onTap: onPressed,
        child: SizedBox(
          width: 48,
          height: 48,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: size,
                color: active
                    ? Colors.white
                    : Colors.white.withValues(alpha: 0.42),
              ),
              const SizedBox(height: 3),
              Container(
                width: 5,
                height: 5,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: active ? Colors.white : Colors.transparent,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NowPlayingSeekBar extends StatefulWidget {
  const _NowPlayingSeekBar({
    required this.stateListenable,
    required this.onSeek,
  });

  final ValueNotifier<PlaybackSnapshot?> stateListenable;
  final ValueChanged<int> onSeek;

  @override
  State<_NowPlayingSeekBar> createState() => _NowPlayingSeekBarState();
}

class _NowPlayingSeekBarState extends State<_NowPlayingSeekBar> {
  double? _dragRatio;

  static String _formatMs(int ms, {bool negative = false}) {
    final totalSeconds = (ms / 1000).floor().clamp(0, 359999);
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    final formatted = '$minutes:${seconds.toString().padLeft(2, '0')}';
    return negative ? '-$formatted' : formatted;
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ValueListenableBuilder<PlaybackSnapshot?>(
        valueListenable: widget.stateListenable,
        builder: (context, snapshot, _) {
          if (snapshot == null) {
            return const SizedBox.shrink();
          }
          final track = snapshot.track;
          final durationMs = snapshot.durationMs;
          final effectiveRatio =
              _dragRatio ??
              (durationMs > 0
                  ? (snapshot.positionMs / durationMs).clamp(0.0, 1.0)
                  : 0.0);
          final displayPositionMs = durationMs > 0
              ? (effectiveRatio * durationMs).round()
              : snapshot.positionMs;
          final remainingMs = (durationMs - displayPositionMs).clamp(
            0,
            durationMs,
          );

          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: _dragRatio != null ? 8 : 6,
                  activeTrackColor: Colors.white.withValues(alpha: 0.90),
                  inactiveTrackColor: Colors.white.withValues(alpha: 0.24),
                  thumbColor: Colors.white,
                  overlayColor: Colors.white.withValues(alpha: 0.14),
                  thumbShape: RoundSliderThumbShape(
                    enabledThumbRadius: _dragRatio != null ? 6 : 0,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 14,
                  ),
                  trackShape: const RoundedRectSliderTrackShape(),
                ),
                child: Slider(
                  key: const Key('now-playing-slider'),
                  value: effectiveRatio.clamp(0.0, 1.0),
                  onChanged: durationMs > 0
                      ? (v) => setState(() => _dragRatio = v)
                      : null,
                  onChangeEnd: durationMs > 0
                      ? (v) {
                          setState(() => _dragRatio = null);
                          widget.onSeek((v * durationMs).round());
                        }
                      : null,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _formatMs(displayPositionMs),
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.62),
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    if (snapshot.isDownloading)
                      Text(
                        '다운로드 중...',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.72),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    Text(
                      durationMs > 0
                          ? _formatMs(remainingMs, negative: true)
                          : track.duration,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.62),
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _AcrylicGlassCircleButton extends StatelessWidget {
  const _AcrylicGlassCircleButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.white.withValues(alpha: 0.24),
                  Colors.white.withValues(alpha: 0.12),
                ],
              ),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.26),
                width: 0.8,
              ),
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: 22, color: Colors.white),
          ),
        ),
      ),
    );
  }
}

class _NowPlayingVolumeSlider extends StatefulWidget {
  const _NowPlayingVolumeSlider({
    this.onGetVolume,
    this.onSetVolume,
    this.volumeStream,
  });

  final Future<double> Function()? onGetVolume;
  final Future<void> Function(double)? onSetVolume;
  final Stream<double>? volumeStream;

  @override
  State<_NowPlayingVolumeSlider> createState() =>
      _NowPlayingVolumeSliderState();
}

class _NowPlayingVolumeSliderState extends State<_NowPlayingVolumeSlider> {
  double _volume = 0.7;
  bool _dragging = false;
  bool _pushInFlight = false;
  double? _pendingPushVolume;
  DateTime _ignoreExternalUntil = DateTime.fromMillisecondsSinceEpoch(0);
  StreamSubscription<double>? _volumeSub;

  @override
  void initState() {
    super.initState();
    _loadInitialVolume();
    _volumeSub = widget.volumeStream?.listen((v) {
      if (_dragging || DateTime.now().isBefore(_ignoreExternalUntil)) {
        return;
      }
      if (mounted) {
        setState(() => _volume = v.clamp(0.0, 1.0));
      }
    });
  }

  Future<void> _loadInitialVolume() async {
    final getter = widget.onGetVolume;
    if (getter == null) {
      return;
    }
    try {
      final v = await getter();
      if (mounted && !_dragging) {
        setState(() => _volume = v.clamp(0.0, 1.0));
      }
    } catch (_) {}
  }

  void _pushVolume(double value) {
    final setter = widget.onSetVolume;
    if (setter == null) {
      return;
    }
    _pendingPushVolume = value;
    if (_pushInFlight) {
      return;
    }
    unawaited(_drainVolumePush(setter));
  }

  Future<void> _drainVolumePush(Future<void> Function(double) setter) async {
    _pushInFlight = true;
    try {
      while (_pendingPushVolume != null) {
        final next = _pendingPushVolume!;
        _pendingPushVolume = null;
        try {
          await setter(next);
        } catch (_) {}
      }
    } finally {
      _pushInFlight = false;
    }
  }

  @override
  void dispose() {
    _volumeSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          _volume <= 0.01
              ? Icons.volume_off_rounded
              : Icons.volume_down_rounded,
          size: 18,
          color: Colors.white.withValues(alpha: 0.65),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: _dragging ? 6.5 : 4.5,
              activeTrackColor: Colors.white.withValues(alpha: 0.86),
              inactiveTrackColor: Colors.white.withValues(alpha: 0.24),
              thumbColor: Colors.white,
              overlayColor: Colors.white.withValues(alpha: 0.14),
              thumbShape: RoundSliderThumbShape(
                enabledThumbRadius: _dragging ? 6 : 0,
              ),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
              trackShape: const RoundedRectSliderTrackShape(),
            ),
            child: Slider(
              key: const Key('now-playing-volume-slider'),
              value: _volume.clamp(0.0, 1.0),
              onChangeStart: (_) => setState(() => _dragging = true),
              onChanged: (v) {
                setState(() => _volume = v);
                _pushVolume(v);
              },
              onChangeEnd: (v) {
                _ignoreExternalUntil = DateTime.now().add(
                  const Duration(milliseconds: 220),
                );
                setState(() {
                  _dragging = false;
                  _volume = v;
                });
                _pushVolume(v);
              },
            ),
          ),
        ),
        const SizedBox(width: 6),
        Icon(
          Icons.volume_up_rounded,
          size: 18,
          color: Colors.white.withValues(alpha: 0.65),
        ),
      ],
    );
  }
}
