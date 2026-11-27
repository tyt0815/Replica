import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/library_models.dart';

class PersistedPlaybackState {
  const PersistedPlaybackState({
    required this.queue,
    required this.queueIndex,
    required this.positionMs,
  });

  final List<TrackItem> queue;
  final int queueIndex;
  final int positionMs;

  TrackItem? get currentTrack =>
      queueIndex >= 0 && queueIndex < queue.length ? queue[queueIndex] : null;
}

class PlaybackPersistence {
  PlaybackPersistence({required this.getDataDir});

  final String Function() getDataDir;
  Timer? _saveTimer;
  Future<void> _writeChain = Future<void>.value();

  File? _file() {
    final dir = getDataDir();
    if (dir.isEmpty) {
      return null;
    }
    return File('$dir${Platform.pathSeparator}playback_state.json');
  }

  PersistedPlaybackState? load() {
    final file = _file();
    if (file == null || !file.existsSync()) {
      return null;
    }
    try {
      final raw = jsonDecode(file.readAsStringSync());
      if (raw is! Map<String, dynamic>) {
        return null;
      }
      final rawQueue = (raw['queue'] as List<dynamic>?) ?? const [];
      final queue = rawQueue
          .whereType<Map<String, dynamic>>()
          .map(TrackItem.fromCoreJson)
          .where((t) => t.id.isNotEmpty)
          .toList(growable: false);
      if (queue.isEmpty) {
        return null;
      }
      final index = ((raw['queue_index'] as num?)?.toInt() ?? 0).clamp(
        0,
        queue.length - 1,
      );
      final positionMs = ((raw['position_ms'] as num?)?.toInt() ?? 0).clamp(
        0,
        86400000,
      );
      return PersistedPlaybackState(
        queue: queue,
        queueIndex: index,
        positionMs: positionMs,
      );
    } catch (_) {
      return null;
    }
  }

  void scheduleSave(PersistedPlaybackState state) {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 1200), () {
      unawaited(saveNow(state));
    });
  }

  Future<void> saveNow(PersistedPlaybackState state) {
    _saveTimer?.cancel();
    final file = _file();
    if (file == null || state.queue.isEmpty) {
      return Future<void>.value();
    }
    final payload = jsonEncode({
      'queue': state.queue.map((t) => t.toCoreJson()).toList(),
      'queue_index': state.queueIndex,
      'position_ms': state.positionMs,
    });
    _writeChain = _writeChain
        .then((_) async {
          try {
            await file.parent.create(recursive: true);
            final tmp = File(
              '${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
            );
            await tmp.writeAsString(payload);
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
    return _writeChain;
  }

  void dispose() {
    _saveTimer?.cancel();
  }
}
