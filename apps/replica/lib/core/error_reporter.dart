import 'dart:async';
import 'dart:io';

import 'replica_music_core.dart';

class ErrorReporter {
  ErrorReporter({required this.core});

  final ReplicaMusicCoreBridge core;

  String _dataDir = '';
  String _appVersion = '0.16.1';
  int _logCount = 0;

  int get logCount => _logCount;

  Future<void> initialize({
    required String dataDir,
    required String appVersion,
  }) async {
    _dataDir = dataDir;
    _appVersion = appVersion;
    await _ingestNativePlaybackLog();
    await refreshLogCount();
  }

  Future<void> _ingestNativePlaybackLog() async {
    if (_dataDir.isEmpty) {
      return;
    }
    final logFile = File(
      '$_dataDir${Platform.pathSeparator}playback_error.log',
    );
    if (!logFile.existsSync()) {
      return;
    }
    try {
      final content = (await logFile.readAsString()).trim();
      if (content.isEmpty) {
        return;
      }
      final tail = content.length > 6000
          ? content.substring(content.length - 6000)
          : content;
      await reportError(
        source: 'Android MediaPlaybackService',
        message: '네이티브 오디오 재생 오류 로그 감지',
        stackTrace: tail,
      );
      await logFile.writeAsString('');
    } catch (_) {}
  }

  Future<void> reportError({
    required String source,
    required String message,
    String? stackTrace,
  }) async {
    if (_dataDir.isEmpty || !core.isNativeLoaded) {
      return;
    }
    final cleanMsg = message.trim();
    if (cleanMsg.isEmpty) {
      return;
    }
    final shortSummary = cleanMsg.split('\n').first;
    final title =
        '$source: ${shortSummary.length > 80 ? '${shortSummary.substring(0, 80)}...' : shortSummary}';
    final bodyBuffer = StringBuffer()
      ..writeln('### 환경 정보')
      ..writeln('- App Version: v$_appVersion')
      ..writeln(
        '- OS: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      )
      ..writeln('- Source: $source')
      ..writeln('- Timestamp: ${DateTime.now().toIso8601String()}')
      ..writeln()
      ..writeln('### 오류 내용')
      ..writeln(cleanMsg);
    final trace = stackTrace?.trim() ?? '';
    if (trace.isNotEmpty) {
      bodyBuffer
        ..writeln()
        ..writeln('### 스택 트레이스 / 로그')
        ..writeln(trace.length > 7000 ? trace.substring(0, 7000) : trace);
    }
    final fingerprint = '$source|$shortSummary';
    try {
      final data = await core.invoke({
        'op': 'enqueue_error_report',
        'data_dir': _dataDir,
        'title': title,
        'body': bodyBuffer.toString(),
        'fingerprint': fingerprint,
      });
      _logCount = (data['pending'] as num?)?.toInt() ?? _logCount;
    } catch (_) {}
  }

  Future<int> refreshLogCount() async {
    if (_dataDir.isEmpty || !core.isNativeLoaded) {
      return 0;
    }
    try {
      final data = await core.invoke({
        'op': 'list_error_reports',
        'data_dir': _dataDir,
      });
      final reports = (data['reports'] as List<dynamic>?) ?? const [];
      _logCount = reports.length;
      return _logCount;
    } catch (_) {
      return _logCount;
    }
  }

  Future<List<Map<String, dynamic>>> listLogs() async {
    if (_dataDir.isEmpty || !core.isNativeLoaded) {
      return const [];
    }
    try {
      final data = await core.invoke({
        'op': 'list_error_reports',
        'data_dir': _dataDir,
      });
      final raw = (data['reports'] as List<dynamic>?) ?? const [];
      final list = raw.whereType<Map<String, dynamic>>().toList(growable: true);
      list.sort((a, b) {
        final ta = (a['created_at_ms'] as num?)?.toInt() ?? 0;
        final tb = (b['created_at_ms'] as num?)?.toInt() ?? 0;
        return tb.compareTo(ta);
      });
      _logCount = list.length;
      return List<Map<String, dynamic>>.unmodifiable(list);
    } catch (_) {
      return const [];
    }
  }

  Future<void> clearLogs() async {
    if (_dataDir.isEmpty || !core.isNativeLoaded) {
      return;
    }
    try {
      await core.invoke({'op': 'clear_error_reports', 'data_dir': _dataDir});
      _logCount = 0;
    } catch (_) {}
  }

  Future<File> writeLogShareFile({
    required String cacheDir,
    required Map<String, dynamic> report,
  }) async {
    final sep = Platform.pathSeparator;
    final dir = Directory('$cacheDir${sep}logs');
    dir.createSync(recursive: true);
    final createdMs =
        (report['created_at_ms'] as num?)?.toInt() ??
        DateTime.now().millisecondsSinceEpoch;
    final dt = DateTime.fromMillisecondsSinceEpoch(createdMs);
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp =
        '${dt.year}${two(dt.month)}${two(dt.day)}-${two(dt.hour)}${two(dt.minute)}${two(dt.second)}';
    final file = File('${dir.path}${sep}replica-music-error-$stamp.txt');
    final title = (report['title'] as String?)?.trim() ?? 'Replica 오류 로그';
    final body = (report['body'] as String?)?.trim() ?? '';
    final content = '$title\n\n$body\n';
    file.writeAsStringSync(content);
    return file;
  }
}
