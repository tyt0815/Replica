import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

class CoverPalette {
  const CoverPalette({
    required this.mainColor,
    required this.deepColor,
    required this.glowColor,
  });

  final Color mainColor;
  final Color deepColor;
  final Color glowColor;

  static CoverPalette fromBase(Color base) {
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
    return CoverPalette(
      mainColor: mainColor,
      deepColor: deepColor,
      glowColor: glowColor,
    );
  }
}

class ThumbnailCache {
  ThumbnailCache._();

  static final ThumbnailCache instance = ThumbnailCache._();

  static const int _maxMemoryEntries = 256;
  static const int _maxConcurrentDownloads = 6;
  static const int _maxDiskCacheBytes = 60 * 1024 * 1024;
  static const int _maxDiskCacheFiles = 400;
  static const int _maxSingleImageBytes = 6 * 1024 * 1024;

  String _cacheDir = '';
  String _storageDir = '';
  final Map<String, File> _memoryIndex = {};
  final Set<String> _knownDiskPaths = {};
  bool _diskIndexReady = false;
  final Map<String, Future<File?>> _inFlight = {};
  final Map<String, CoverPalette> _paletteCache = {};
  HttpClient? _sharedHttpClient;
  int _activeDownloads = 0;
  final List<Completer<void>> _downloadWaiters = [];
  bool _pruningDiskCache = false;
  int _writesSincePrune = 0;

  bool get isConfigured => _cacheDir.isNotEmpty;

  HttpClient _httpClient() {
    return _sharedHttpClient ??= (HttpClient()
      ..connectionTimeout = const Duration(seconds: 6)
      ..idleTimeout = const Duration(seconds: 30)
      ..maxConnectionsPerHost = _maxConcurrentDownloads);
  }

  void _rememberFile(String key, File file) {
    _memoryIndex.remove(key);
    _memoryIndex[key] = file;
    while (_memoryIndex.length > _maxMemoryEntries) {
      _memoryIndex.remove(_memoryIndex.keys.first);
    }
  }

  void _rememberPalette(String key, CoverPalette palette) {
    _paletteCache.remove(key);
    _paletteCache[key] = palette;
    while (_paletteCache.length > _maxMemoryEntries) {
      _paletteCache.remove(_paletteCache.keys.first);
    }
  }

  Future<void> _acquireDownloadSlot() async {
    if (_activeDownloads < _maxConcurrentDownloads) {
      _activeDownloads += 1;
      return;
    }
    final waiter = Completer<void>();
    _downloadWaiters.add(waiter);
    await waiter.future;
  }

  void _releaseDownloadSlot() {
    if (_downloadWaiters.isNotEmpty) {
      final next = _downloadWaiters.removeAt(0);
      if (!next.isCompleted) {
        next.complete();
      }
      return;
    }
    _activeDownloads = (_activeDownloads - 1).clamp(0, _maxConcurrentDownloads);
  }

  CoverPalette? lookupPaletteSync(String key) => _paletteCache[key];

  Future<CoverPalette?> extractPalette({
    required String url,
    String? itemId,
    required String cacheKey,
  }) async {
    final existing = _paletteCache[cacheKey];
    if (existing != null) {
      return existing;
    }
    if (!url.trim().startsWith('https://')) {
      return null;
    }
    final cachedFile = await fetchAndCache(
      url.trim(),
      itemId: itemId,
      highRes: false,
    );
    if (cachedFile == null) {
      return null;
    }
    ui.Codec? codec;
    ui.Image? image;
    try {
      final bytes = await cachedFile.readAsBytes();
      codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: 48,
        targetHeight: 48,
      );
      final frame = await codec.getNextFrame();
      image = frame.image;
      final byteData = await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      if (byteData == null) {
        return null;
      }
      final rgba = byteData.buffer.asUint8List();
      final width = image.width;
      final height = image.height;
      final stepX = (width / 16).ceil().clamp(1, 8);
      final stepY = (height / 16).ceil().clamp(1, 8);

      double sumR = 0;
      double sumG = 0;
      double sumB = 0;
      double totalWeight = 0;

      for (var y = 0; y < height; y += stepY) {
        for (var x = 0; x < width; x += stepX) {
          final offset = (y * width + x) * 4;
          if (offset + 3 >= rgba.length) {
            continue;
          }
          final r = rgba[offset];
          final g = rgba[offset + 1];
          final b = rgba[offset + 2];
          final a = rgba[offset + 3];
          if (a < 180) {
            continue;
          }
          final hsl = HSLColor.fromColor(Color.fromARGB(255, r, g, b));
          final satWeight = 0.30 + hsl.saturation * 2.1;
          final lightWeight = (hsl.lightness < 0.06 || hsl.lightness > 0.90)
              ? 0.25
              : 1.0;
          final weight = satWeight * lightWeight;
          sumR += r * weight;
          sumG += g * weight;
          sumB += b * weight;
          totalWeight += weight;
        }
      }

      if (totalWeight <= 0) {
        return null;
      }
      final avg = Color.fromARGB(
        255,
        (sumR / totalWeight).round().clamp(0, 255),
        (sumG / totalWeight).round().clamp(0, 255),
        (sumB / totalWeight).round().clamp(0, 255),
      );
      final palette = CoverPalette.fromBase(avg);
      _rememberPalette(cacheKey, palette);
      return palette;
    } catch (_) {
      return null;
    } finally {
      image?.dispose();
      codec?.dispose();
    }
  }

  void configure({required String cacheDir, required String storageDir}) {
    final changed = _cacheDir != cacheDir || _storageDir != storageDir;
    _cacheDir = cacheDir;
    _storageDir = storageDir;
    if (changed) {
      _knownDiskPaths.clear();
      _diskIndexReady = false;
    }
    if (cacheDir.isNotEmpty) {
      unawaited(_pruneDiskCache());
    }
  }

  Future<void> _pruneDiskCache() async {
    if (_pruningDiskCache || _cacheDir.isEmpty) {
      return;
    }
    _pruningDiskCache = true;
    try {
      final now = DateTime.now();
      final scannedPaths = <String>{};
      final dir = Directory('$_cacheDir${Platform.pathSeparator}thumbnails');
      final entries = <({File file, int bytes, DateTime modified})>[];
      var totalBytes = 0;
      if (await dir.exists()) {
        await for (final entity in dir.list(followLinks: false)) {
          if (entity is! File) {
            continue;
          }
          final path = entity.path;
          if (path.endsWith('.tmp')) {
            try {
              final stat = await entity.stat();
              if (now.difference(stat.modified).inMinutes >= 5) {
                await entity.delete();
              }
            } catch (_) {}
            continue;
          }
          if (path.endsWith('.png')) {
            try {
              await entity.delete();
              _memoryIndex.removeWhere((_, f) => f.path == path);
            } catch (_) {}
            continue;
          }
          try {
            final stat = await entity.stat();
            if (stat.size >= 512) {
              scannedPaths.add(path);
              totalBytes += stat.size;
              entries.add((
                file: entity,
                bytes: stat.size,
                modified: stat.modified,
              ));
            }
          } catch (_) {}
        }
      }
      if (totalBytes > _maxDiskCacheBytes ||
          entries.length > _maxDiskCacheFiles) {
        entries.sort((a, b) => a.modified.compareTo(b.modified));
        var count = entries.length;
        for (final entry in entries) {
          if (totalBytes <= (_maxDiskCacheBytes * 3 ~/ 4) &&
              count <= (_maxDiskCacheFiles * 3 ~/ 4)) {
            break;
          }
          try {
            await entry.file.delete();
            scannedPaths.remove(entry.file.path);
            _memoryIndex.removeWhere((_, f) => f.path == entry.file.path);
            totalBytes -= entry.bytes;
            count -= 1;
          } catch (_) {}
        }
      }
      if (_storageDir.isNotEmpty) {
        final metaDir = Directory('$_storageDir${Platform.pathSeparator}.meta');
        if (await metaDir.exists()) {
          await for (final entity in metaDir.list(followLinks: false)) {
            if (entity is File && entity.path.endsWith('.jpg')) {
              scannedPaths.add(entity.path);
            }
          }
        }
      }
      _knownDiskPaths
        ..clear()
        ..addAll(scannedPaths);
      _diskIndexReady = true;
    } catch (_) {
    } finally {
      _pruningDiskCache = false;
    }
  }

  static List<String> candidateUrls(String rawUrl, {bool highRes = false}) {
    final trimmed = rawUrl.trim();
    if (!trimmed.startsWith('https://')) {
      return const [];
    }
    final out = <String>[];

    final ytimgMatch = RegExp(
      r'^https://i\d?\.ytimg\.com/vi(?:_webp)?/([A-Za-z0-9_-]{11})/',
    ).firstMatch(trimmed);
    if (ytimgMatch != null) {
      final videoId = ytimgMatch.group(1)!;
      if (highRes) {
        out.add('https://i.ytimg.com/vi/$videoId/maxresdefault.jpg');
        out.add('https://i.ytimg.com/vi/$videoId/hq720.jpg');
        out.add('https://i.ytimg.com/vi/$videoId/mqdefault.jpg');
        out.add('https://i.ytimg.com/vi/$videoId/sddefault.jpg');
      } else {
        out.add('https://i.ytimg.com/vi/$videoId/hq720.jpg');
        out.add('https://i.ytimg.com/vi/$videoId/mqdefault.jpg');
        out.add('https://i.ytimg.com/vi/$videoId/maxresdefault.jpg');
      }
      if (!out.contains(trimmed)) {
        out.add(trimmed);
      }
      return out;
    }

    if (trimmed.contains('googleusercontent.com') ||
        trimmed.contains('ggpht.com')) {
      final sizeParam = highRes ? '=w1080-h1080-l90-rj' : '=w544-h544-l90-rj';
      final eqIndex = trimmed.indexOf('=');
      if (eqIndex > 0) {
        final upgraded = '${trimmed.substring(0, eqIndex)}$sizeParam';
        out.add(upgraded);
      }
      if (!out.contains(trimmed)) {
        out.add(trimmed);
      }
      return out;
    }

    return [trimmed];
  }

  String _cacheKey(String url, {String? itemId, required bool highRes}) {
    final tier = highRes ? 'sqhd' : 'sqsd';
    if (itemId != null && itemId.isNotEmpty) {
      final safeId = itemId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
      return '${safeId}_$tier';
    }
    var hash = 0x811c9dc5;
    for (final byte in utf8.encode(url)) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return 'u_${hash.toRadixString(16)}_$tier';
  }

  File? _targetCacheFile(String key) {
    if (_cacheDir.isEmpty) {
      return null;
    }
    return File(
      '$_cacheDir${Platform.pathSeparator}thumbnails${Platform.pathSeparator}$key.jpg',
    );
  }

  File? _metaTrackFile(String? itemId) {
    if (_storageDir.isEmpty || itemId == null || itemId.isEmpty) {
      return null;
    }
    return File(
      '$_storageDir${Platform.pathSeparator}.meta${Platform.pathSeparator}$itemId.jpg',
    );
  }

  bool _hasLocalImage(File file) {
    if (_diskIndexReady) {
      return _knownDiskPaths.contains(file.path);
    }
    return _isValidLocalImage(file);
  }

  File? lookupSync(String url, {String? itemId, bool highRes = false}) {
    final key = _cacheKey(url, itemId: itemId, highRes: highRes);
    final mem = _memoryIndex[key];
    if (mem != null) {
      return mem;
    }
    final hdKey = _cacheKey(url, itemId: itemId, highRes: true);
    final hdMem = _memoryIndex[hdKey];
    if (hdMem != null) {
      return hdMem;
    }

    final hdFile = _targetCacheFile(hdKey);
    if (hdFile != null && _hasLocalImage(hdFile)) {
      _rememberFile(hdKey, hdFile);
      _rememberFile(key, hdFile);
      return hdFile;
    }

    final cacheFile = _targetCacheFile(key);
    if (cacheFile != null && _hasLocalImage(cacheFile)) {
      _rememberFile(key, cacheFile);
      return cacheFile;
    }

    if (!highRes) {
      final metaFile = _metaTrackFile(itemId);
      if (metaFile != null && _hasLocalImage(metaFile)) {
        _rememberFile(key, metaFile);
        return metaFile;
      }
    }
    return null;
  }

  static bool _isValidLocalImage(File file) {
    try {
      return file.existsSync() && file.lengthSync() >= 512;
    } catch (_) {
      return false;
    }
  }

  Future<File?> fetchAndCache(
    String url, {
    String? itemId,
    bool highRes = false,
  }) async {
    final existing = lookupSync(url, itemId: itemId, highRes: highRes);
    if (existing != null) {
      return existing;
    }
    final key = _cacheKey(url, itemId: itemId, highRes: highRes);
    final inFlight = _inFlight[key];
    if (inFlight != null) {
      return inFlight;
    }
    final target = _targetCacheFile(key);
    if (target == null) {
      return null;
    }
    final candidates = candidateUrls(url, highRes: highRes);
    if (candidates.isEmpty) {
      return null;
    }

    final future = _downloadFirstValid(
      candidates,
      target,
      key,
      highRes: highRes,
    );
    _inFlight[key] = future;
    try {
      return await future;
    } finally {
      if (identical(_inFlight[key], future)) {
        _inFlight.remove(key);
      }
    }
  }

  Future<File?> _downloadFirstValid(
    List<String> candidates,
    File target,
    String key, {
    required bool highRes,
  }) async {
    await _acquireDownloadSlot();
    final client = _httpClient();
    try {
      await target.parent.create(recursive: true);
      for (final candidate in candidates) {
        try {
          final req = await client.getUrl(Uri.parse(candidate));
          req.headers.set(HttpHeaders.userAgentHeader, 'Mozilla/5.0');
          final resp = await req.close().timeout(const Duration(seconds: 8));
          if (resp.statusCode != HttpStatus.ok) {
            await resp.drain<void>();
            continue;
          }
          final builder = BytesBuilder(copy: false);
          var oversized = false;
          await for (final chunk in resp.timeout(const Duration(seconds: 8))) {
            builder.add(chunk);
            if (builder.length > _maxSingleImageBytes) {
              oversized = true;
              break;
            }
          }
          if (oversized) {
            continue;
          }
          final bytes = builder.takeBytes();
          if (bytes.length < 1500) {
            continue;
          }
          final tmp = File(
            '${target.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
          );
          await tmp.writeAsBytes(bytes, flush: true);
          try {
            await tmp.rename(target.path);
          } catch (_) {
            if (target.existsSync()) {
              await target.delete();
            }
            await tmp.rename(target.path);
          }
          _knownDiskPaths.add(target.path);
          _rememberFile(key, target);
          _writesSincePrune += 1;
          if (_writesSincePrune >= 40) {
            _writesSincePrune = 0;
            unawaited(_pruneDiskCache());
          }
          return target;
        } catch (_) {}
      }
    } catch (_) {
    } finally {
      _releaseDownloadSlot();
    }
    return null;
  }
}

class CachedCoverImage extends StatefulWidget {
  const CachedCoverImage({
    super.key,
    required this.imageUrl,
    required this.fallback,
    this.itemId,
    this.highRes = false,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.decodeHeight,
    this.filterQuality = FilterQuality.low,
  });

  final String? imageUrl;
  final Widget fallback;
  final String? itemId;
  final bool highRes;
  final BoxFit fit;
  final Alignment alignment;
  final int? decodeHeight;
  final FilterQuality filterQuality;

  @override
  State<CachedCoverImage> createState() => _CachedCoverImageState();
}

class _CachedCoverImageState extends State<CachedCoverImage> {
  File? _localFile;
  String _activeUrl = '';
  bool _fallbackToNetwork = false;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant CachedCoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl ||
        oldWidget.itemId != widget.itemId ||
        oldWidget.highRes != widget.highRes) {
      _resolve();
    }
  }

  void _resolve() {
    final url = widget.imageUrl?.trim() ?? '';
    _activeUrl = url;
    _fallbackToNetwork = false;
    if (!url.startsWith('https://')) {
      _localFile = null;
      return;
    }
    final cached = ThumbnailCache.instance.lookupSync(
      url,
      itemId: widget.itemId,
      highRes: widget.highRes,
    );
    _localFile = cached;
    if (cached == null) {
      unawaited(
        ThumbnailCache.instance
            .fetchAndCache(url, itemId: widget.itemId, highRes: widget.highRes)
            .then((file) {
              if (!mounted || _activeUrl != url) {
                return;
              }
              if (file != null) {
                setState(() => _localFile = file);
              } else if (!ThumbnailCache.instance.isConfigured) {
                setState(() => _fallbackToNetwork = true);
              }
            }),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final file = _localFile;
    if (file != null) {
      return Image.file(
        file,
        fit: widget.fit,
        alignment: widget.alignment,
        cacheHeight: widget.decodeHeight,
        filterQuality: widget.filterQuality,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => widget.fallback,
      );
    }
    final url = _activeUrl;
    if (!_fallbackToNetwork || !url.startsWith('https://')) {
      return widget.fallback;
    }
    return Image.network(
      url,
      fit: widget.fit,
      alignment: widget.alignment,
      cacheHeight: widget.decodeHeight,
      filterQuality: widget.filterQuality,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => widget.fallback,
    );
  }
}
