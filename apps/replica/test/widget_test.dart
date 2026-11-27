import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:replica/core/platform_adapters.dart';
import 'package:replica/core/replica_music_core.dart';
import 'package:replica/models/library_models.dart';
import 'package:replica/playback/replica_audio_handler.dart';
import 'package:replica/ui/replica_music_app.dart';

class _FakeMediaAdapters extends PlatformAdapters {
  final List<String> sharedSubjects = [];
  final List<String> sharedPaths = [];

  @override
  Future<AppEnvironmentInfo> loadEnvironment({
    String fallbackVersion = '0.1.0',
  }) async {
    return AppEnvironmentInfo(
      version: fallbackVersion,
      cacheDir: Directory.systemTemp.path,
      storageDir: 'C:\\temp\\storage',
    );
  }

  @override
  Future<Map<String, dynamic>?> readWebSession() async => null;

  @override
  Future<bool> shareTextFile({
    required String path,
    String? subject,
    String? text,
  }) async {
    sharedPaths.add(path);
    if (subject != null) {
      sharedSubjects.add(subject);
    }
    return true;
  }
}

class _FakeAudioEngine implements AudioEngineBackend {
  final List<String> loadedPaths = [];
  final List<Duration> seekCalls = [];
  final StreamController<bool> _playing = StreamController<bool>.broadcast();
  final StreamController<Duration> _position =
      StreamController<Duration>.broadcast();
  final StreamController<Duration?> _duration =
      StreamController<Duration?>.broadcast();
  final StreamController<void> _completed = StreamController<void>.broadcast();
  final StreamController<Object> _error = StreamController<Object>.broadcast();

  void emitPlaying(bool value) => _playing.add(value);
  void emitPosition(Duration value) => _position.add(value);
  void emitCompleted() => _completed.add(null);

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
    loadedPaths.add(path);
    _duration.add(const Duration(seconds: 200));
    _position.add(initialPosition ?? Duration.zero);
    return const Duration(seconds: 200);
  }

  @override
  Future<void> play() async => _playing.add(true);

  @override
  Future<void> pause() async => _playing.add(false);

  @override
  Future<void> seek(Duration position) async {
    seekCalls.add(position);
    _position.add(position);
  }

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

class _FakeMediaCore extends _FakeUpdateCore {
  @override
  Future<Map<String, dynamic>> invoke(Map<String, dynamic> request) async {
    if (request['op'] == 'list_downloaded') {
      return {
        'tracks': [
          {
            'video_id': 'track-1',
            'title': 'First Track',
            'artist': 'Artist One',
            'duration': '3:20',
            'thumbnail': '',
            'file_path': 'C:\\temp\\storage\\track-1.m4a',
          },
          {
            'video_id': 'track-2',
            'title': 'Second Track',
            'artist': 'Artist Two',
            'duration': '4:10',
            'thumbnail': '',
            'file_path': 'C:\\temp\\storage\\track-2.m4a',
          },
        ],
      };
    }
    return super.invoke(request);
  }
}

class _FakeUpdateCore implements ReplicaMusicCoreBridge {
  UpdateDownloadProgress mockProgress = const UpdateDownloadProgress(
    downloadedBytes: 0,
    totalBytes: 0,
  );
  Map<String, UpdateDownloadProgress> mockTrackProgress = const {};
  Completer<Map<String, dynamic>>? downloadCompleter;
  bool cancelCalled = false;

  @override
  String get coreVersion => '0.16.1';

  @override
  bool get isNativeLoaded => true;

  @override
  UpdateDownloadProgress readUpdateDownloadProgress() => mockProgress;

  @override
  Map<String, UpdateDownloadProgress> readTrackDownloadProgress() =>
      mockTrackProgress;

  @override
  void cancelUpdateDownload() {
    cancelCalled = true;
    if (downloadCompleter != null && !downloadCompleter!.isCompleted) {
      downloadCompleter!.completeError(Exception('cancelled'));
    }
  }

  @override
  void cancelTrackDownload(String videoId) {}

  @override
  void promoteTrackDownload(String videoId) {}

  @override
  bool isReplicaPlaylist(String rawTitle) =>
      rawTitle.trim().endsWith('.rm') && rawTitle.trim().length > 3;

  @override
  String toDisplayPlaylistTitle(String rawTitle) =>
      stripPlaylistTimestampAndSuffix(rawTitle);

  @override
  String? toRemotePlaylistTitle(String displayTitle) =>
      displayTitle.trim().isEmpty ? null : '${displayTitle.trim()}.rm';

  @override
  Future<Map<String, dynamic>> invoke(Map<String, dynamic> request) async {
    switch (request['op']) {
      case 'check_update':
        return {
          'update': {
            'update_available': true,
            'current_version': '0.16.1',
            'latest_version': '0.16.2',
            'tag_name': 'v0.16.2',
            'release_notes': '테스트용 신규 릴리스',
            'asset_name': 'ReplicaMusic-0.16.2.apk',
            'asset_size': 40 * 1024 * 1024,
            'asset_url': 'https://github.com/tyt0815/ReplicaMusic/releases/download/v0.16.2/ReplicaMusic-0.16.2.apk',
          },
        };
      case 'download_update':
        return downloadCompleter?.future ??
            Future.value({
              'downloaded': {
                'path': 'C:\\temp\\cache\\update\\ReplicaMusic-0.16.2.apk',
              },
            });
      case 'list_error_reports':
        return {
          'reports': [
            {
              'id': 'err-1',
              'fingerprint': 'fp-old',
              'title': 'Older Error',
              'body': 'older details',
              'created_at_ms': 1700000000000,
            },
            {
              'id': 'err-2',
              'fingerprint': 'fp-new',
              'title': 'Newest Error',
              'body': 'newest details',
              'created_at_ms': 1800000000000,
            },
          ],
        };
      case 'list_downloaded':
        return {'tracks': <dynamic>[]};
      default:
        return <String, dynamic>{};
    }
  }
}

void main() {
  test(
    'formatTotalTracksDuration computes hh:mm:ss across m:ss and h:mm:ss',
    () {
      const sampleTracks = [
        TrackItem(
          id: 'a',
          title: 'A',
          artist: 'Artist',
          duration: '3:20',
          coverColor: Colors.red,
        ),
        TrackItem(
          id: 'b',
          title: 'B',
          artist: 'Artist',
          duration: '1:02:45',
          coverColor: Colors.blue,
        ),
        TrackItem(
          id: 'c',
          title: 'C',
          artist: 'Artist',
          duration: 'LIVE',
          coverColor: Colors.green,
        ),
      ];
      expect(formatTotalTracksDuration(const []), '00:00:00');
      expect(formatTotalTracksDuration(sampleTracks), '01:06:05');
    },
  );

  test('Versioned playlist timestamp and per-device history helpers parse titles accurately', () {
    expect(parsePlaylistTimestamp('Drive.1795747025.rm'), 1795747025);
    expect(parsePlaylistTimestamp('Drive.rm'), 0);
    expect(parsePlaylistTimestamp('Ver 2.0.1795747025.rm'), 1795747025);
    expect(parsePlaylistTimestamp('History.OO의 폴드8.rm'), 0);

    expect(stripPlaylistTimestampAndSuffix('Drive.1795747025.rm'), 'Drive');
    expect(stripPlaylistTimestampAndSuffix('Ver 2.0.1795747025.rm'), 'Ver 2.0');
    expect(stripPlaylistTimestampAndSuffix('History.OO의 폴드8.rm'), 'OO의 폴드8');

    expect(
      buildVersionedRemoteTitle('Drive.1700000000.rm', 1795747025),
      'Drive.1795747025.rm',
    );
    expect(sanitizeDeviceName('OO의.폴드8'), 'OO의 폴드8');
    expect(buildHistoryRemoteTitle('OO의 폴드8'), 'History.OO의 폴드8.rm');
    expect(isHistoryRemoteTitle('History.OO의 폴드8.rm'), isTrue);
    expect(isHistoryRemoteTitle('History.rm'), isTrue);
    expect(isHistoryRemoteTitle('Drive.1795747025.rm'), isFalse);
    expect(extractHistoryDeviceName('History.OO의 폴드8.rm'), 'OO의 폴드8');
    expect(extractHistoryDeviceName('History.rm'), isNull);
  });

  test('Backend bridge returns 0.4.0 and enforces .rm rules', () {
    final core = NativeReplicaMusicCore.openOrFallback();
    expect(core.coreVersion, '0.4.0');
    expect(core.isReplicaPlaylist('Chill.rm'), isTrue);
    expect(core.isReplicaPlaylist('Chill'), isFalse);
    expect(core.toRemotePlaylistTitle('Chill'), 'Chill.rm');
    expect(core.toDisplayPlaylistTitle('Chill.rm'), 'Chill');
    expect(core.toDisplayPlaylistTitle('Drive.1795747025.rm'), 'Drive');
    expect(core.toDisplayPlaylistTitle('History.OO의 폴드8.rm'), 'OO의 폴드8');
  });

  testWidgets(
    'App startup does not check updates and Settings manual check prompts when newer release exists',
    (tester) async {
      await tester.pumpWidget(ReplicaMusicApp(core: _FakeUpdateCore()));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('update-available-dialog')), findsNothing);

      await tester.tap(find.byKey(const Key('dock-settings-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('업데이트 확인'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('update-available-dialog')), findsOneWidget);
      expect(find.text('새 버전 v0.16.2 출시'), findsOneWidget);
      expect(find.byKey(const Key('update-confirm-button')), findsOneWidget);
      final updateRect = tester.getRect(
        find.byKey(const Key('update-available-dialog')),
      );
      expect(updateRect.center.dx, lessThan(400));
    },
  );

  testWidgets(
    'Update download dialog renders determinate percent progress bar',
    (tester) async {
      final core = _FakeUpdateCore();
      final completer = Completer<Map<String, dynamic>>();
      core.downloadCompleter = completer;

      await tester.pumpWidget(
        ReplicaMusicApp(core: core, adapters: _FakeMediaAdapters()),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('dock-settings-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('업데이트 확인'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('update-confirm-button')));
      await tester.pump();

      expect(find.byKey(const Key('update-progress-dialog')), findsOneWidget);
      expect(find.text('0%'), findsOneWidget);

      core.mockProgress = const UpdateDownloadProgress(
        downloadedBytes: 20 * 1024 * 1024,
        totalBytes: 40 * 1024 * 1024,
      );
      await tester.pump(const Duration(milliseconds: 200));

      final indicator = tester.widget<LinearProgressIndicator>(
        find.byKey(const Key('update-progress-bar')),
      );
      expect(indicator.value, closeTo(0.5, 0.01));
      expect(find.text('50%'), findsOneWidget);

      await tester.tap(find.byKey(const Key('update-cancel-button')));
      await tester.pumpAndSettle();

      expect(core.cancelCalled, isTrue);
      expect(find.byKey(const Key('update-progress-dialog')), findsNothing);
      expect(find.byKey(const Key('floating-toast')), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    },
  );

  testWidgets(
    'Library places add button in header and hides .rm suffix on creation',
    (tester) async {
      final core = NativeReplicaMusicCore.openOrFallback();
      await tester.pumpWidget(ReplicaMusicApp(core: core));
      await tester.pumpAndSettle();

      expect(find.text('보관함'), findsWidgets);
      expect(find.byKey(const Key('playlist-tile-all-songs')), findsOneWidget);
      expect(find.byKey(const Key('playlist-more-all-songs')), findsOneWidget);
      expect(find.text('저장된 곡'), findsOneWidget);

      await tester.tap(find.byKey(const Key('playlist-more-all-songs')));
      await tester.pumpAndSettle();
      expect(find.text('재생'), findsOneWidget);
      expect(find.text('랜덤 재생'), findsOneWidget);
      expect(find.text('다운로드'), findsNothing);
      expect(find.text('재생 목록 삭제'), findsNothing);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('header-more-button')), findsNothing);
      expect(find.byKey(const Key('create-playlist-button')), findsOneWidget);
      expect(
        find.byKey(const Key('library-refresh-indicator')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('create-playlist-button')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('create-playlist-input')),
        'Morning Walk',
      );
      await tester.tap(find.byKey(const Key('create-playlist-confirm')));
      await tester.pumpAndSettle();

      expect(find.text('Morning Walk'), findsWidgets);
      expect(find.text('Morning Walk.rm'), findsNothing);
    },
  );

  testWidgets(
    'Bottom dock has Settings, Library, and Search tabs in order and supports swiping',
    (tester) async {
      final core = NativeReplicaMusicCore.openOrFallback();
      await tester.pumpWidget(ReplicaMusicApp(core: core));
      await tester.pumpAndSettle();

      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
      expect(scaffold.resizeToAvoidBottomInset, isFalse);

      final navBar = find.byKey(const Key('bottom-nav-bar'));
      final setX = tester
          .getCenter(
            find.descendant(
              of: navBar,
              matching: find.byKey(const Key('dock-settings-button')),
            ),
          )
          .dx;
      final libX = tester
          .getCenter(find.descendant(of: navBar, matching: find.text('보관함')))
          .dx;
      final searchX = tester
          .getCenter(find.descendant(of: navBar, matching: find.text('검색')))
          .dx;
      expect(setX, lessThan(libX));
      expect(libX, lessThan(searchX));

      await tester.fling(
        find.byKey(const Key('main-tab-pageview')),
        const Offset(400, 0),
        1000,
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('library-refresh-indicator')),
        findsOneWidget,
      );

      await tester.fling(
        find.byKey(const Key('main-tab-pageview')),
        const Offset(-400, 0),
        1000,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('search-input')), findsOneWidget);

      await tester.tap(find.byKey(const Key('dock-settings-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('settings-pane')), findsOneWidget);
      expect(find.byKey(const Key('settings-account-tile')), findsOneWidget);
      expect(find.byKey(const Key('settings-update-tile')), findsOneWidget);
      expect(find.byKey(const Key('settings-error-log-tile')), findsOneWidget);
      expect(find.byKey(const Key('settings-theme-selector')), findsOneWidget);
      final accountY = tester
          .getTopLeft(find.byKey(const Key('settings-account-tile')))
          .dy;
      final appInfoY = tester
          .getTopLeft(find.byKey(const Key('settings-update-tile')))
          .dy;
      final themeY = tester
          .getTopLeft(find.byKey(const Key('settings-theme-selector')))
          .dy;
      expect(accountY, lessThan(appInfoY));
      expect(appInfoY, lessThan(themeY));

      MaterialApp readApp() =>
          tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(readApp().themeMode, ThemeMode.system);

      await tester.ensureVisible(find.byKey(const Key('settings-theme-row')));
      await tester.tap(find.byKey(const Key('settings-theme-row')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('theme-picker-dialog')), findsOneWidget);
      await tester.tap(find.text('밝은 테마'));
      await tester.pumpAndSettle();
      expect(readApp().themeMode, ThemeMode.light);

      await tester.tap(find.byKey(const Key('settings-theme-row')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('어두운 테마'));
      await tester.pumpAndSettle();
      expect(readApp().themeMode, ThemeMode.dark);

      expect(find.byKey(const Key('settings-history-max-row')), findsNothing);
      expect(find.byKey(const Key('settings-sync-policy-row')), findsNothing);

      await tester.ensureVisible(
        find.byKey(const Key('settings-unused-days-row')),
      );
      expect(find.byKey(const Key('settings-unused-days-row')), findsOneWidget);
      expect(find.byKey(const Key('settings-max-storage-row')), findsOneWidget);

      await tester.tap(find.byKey(const Key('settings-max-storage-row')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('max-storage-picker-dialog')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const Key('max-storage-gb-input')),
        '8',
      );
      await tester.tap(find.byKey(const Key('max-storage-confirm-button')));
      await tester.pumpAndSettle();
      expect(find.textContaining('8 GB'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.search_outlined));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('search-input')), findsOneWidget);
      expect(find.byKey(const Key('search-clear-button')), findsNothing);
      await tester.enterText(find.byKey(const Key('search-input')), 'hello');
      await tester.pump();
      expect(find.byKey(const Key('search-clear-button')), findsOneWidget);
      await tester.tap(find.byKey(const Key('search-clear-button')));
      await tester.pump();
      expect(find.byKey(const Key('search-clear-button')), findsNothing);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('search-input')))
            .controller
            ?.text,
        isEmpty,
      );

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('library-refresh-indicator')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'Fold 8 four screen states render single-column layout and side-by-side landscape docks',
    (tester) async {
      final adapters = _FakeMediaAdapters();
      const foldStates = <(String, Size, bool)>[
        ('cover-portrait', Size(360, 840), false),
        ('cover-landscape', Size(840, 360), true),
        ('unfolded-portrait', Size(710, 840), false),
        ('unfolded-landscape', Size(840, 710), true),
      ];

      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      tester.view.physicalSize = const Size(840, 710);
      await tester.pumpWidget(
        ReplicaMusicApp(
          core: _FakeMediaCore(),
          adapters: adapters,
          audioEngine: _FakeAudioEngine(),
          fileExistsOverride: (_) => true,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('unfolded-now-playing-pane')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('now-playing-empty-pane')), findsOneWidget);
      expect(find.byKey(const Key('mini-player')), findsNothing);
      final initialRightPane = tester.getRect(
        find.byKey(const Key('unfolded-now-playing-pane')),
      );
      expect(initialRightPane.left, greaterThan(400));

      await tester.fling(
        find.byKey(const Key('unfolded-now-playing-pane')),
        const Offset(-260, 0),
        900,
      );
      await tester.pumpAndSettle();
      final swappedLeftPane = tester.getRect(
        find.byKey(const Key('unfolded-now-playing-pane')),
      );
      expect(swappedLeftPane.left, lessThan(20));

      await tester.fling(
        find.byKey(const Key('bottom-nav-bar')),
        const Offset(-260, 0),
        900,
      );
      await tester.pumpAndSettle();
      final swappedBackRightPane = tester.getRect(
        find.byKey(const Key('unfolded-now-playing-pane')),
      );
      expect(swappedBackRightPane.left, greaterThan(400));

      tester.view.physicalSize = foldStates.first.$2;
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('playlist-tile-all-songs')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('First Track'));
      await tester.pumpAndSettle();

      for (final (label, size, expectSideBySide) in foldStates) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final navRect = tester.getRect(find.byKey(const Key('bottom-nav-bar')));
        expect(navRect.height, 62);
        if (label == 'unfolded-landscape') {
          expect(
            find.byKey(const Key('unfolded-now-playing-pane')),
            findsOneWidget,
          );
          expect(find.byKey(const Key('now-playing-sheet')), findsOneWidget);
          expect(find.byKey(const Key('mini-player')), findsNothing);
          final coverRect = tester.getRect(
            find.byKey(const Key('now-playing-cover')),
          );
          final paneRect = tester.getRect(
            find.byKey(const Key('unfolded-now-playing-pane')),
          );
          expect(coverRect.width, closeTo(paneRect.width, 0.5));
          expect(coverRect.height, closeTo(coverRect.width, 0.5));
          expect(coverRect.top, closeTo(paneRect.top, 0.5));
        } else {
          expect(
            find.byKey(const Key('unfolded-now-playing-pane')),
            findsNothing,
          );
          final playerRect = tester.getRect(
            find.byKey(const Key('mini-player')),
          );
          expect(navRect.height, playerRect.height);
          if (expectSideBySide) {
            expect(navRect.top, playerRect.top);
            expect(navRect.right, lessThan(playerRect.left));
          } else {
            expect(playerRect.bottom, lessThan(navRect.top));
          }
          await tester.tap(find.byKey(const Key('mini-player-open-sheet')));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final coverRect = tester.getRect(
            find.byKey(const Key('now-playing-cover')),
          );
          expect(coverRect.width, closeTo(coverRect.height, 0.5));
          expect(coverRect.top, closeTo(0.0, 0.5));
          expect(coverRect.left, closeTo(0.0, 0.5));
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
        }
        expect(find.byType(NavigationRail), findsNothing);
      }

      tester.view.physicalSize = foldStates.first.$2;
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('mini-player-open-sheet')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('now-playing-sheet')), findsOneWidget);
      expect(find.byKey(const Key('now-playing-title')), findsOneWidget);

      for (final (label, size, _) in foldStates) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('now-playing-sheet')), findsOneWidget);
        if (label == 'unfolded-landscape') {
          expect(
            find.byKey(const Key('unfolded-now-playing-pane')),
            findsOneWidget,
          );
        } else {
          expect(
            find.byKey(const Key('unfolded-now-playing-pane')),
            findsNothing,
          );
        }
      }
    },
  );

  testWidgets(
    'Playback handles circular queue, smart previous restart, and media controls',
    (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(360, 840);
      addTearDown(tester.view.reset);

      final adapters = _FakeMediaAdapters();
      final engine = _FakeAudioEngine();
      final handler = ReplicaAudioServiceHandler();
      await tester.pumpWidget(
        ReplicaMusicApp(
          core: _FakeMediaCore(),
          adapters: adapters,
          audioEngine: engine,
          audioServiceHandler: handler,
          fileExistsOverride: (_) => true,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('playlist-tile-all-songs')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('detail-playlist-summary')), findsOneWidget);
      expect(find.text('2곡 · 00:07:30'), findsOneWidget);

      await tester.tap(find.text('First Track'));
      await tester.pumpAndSettle();

      expect(engine.loadedPaths.length, 1);
      expect(engine.loadedPaths.last, contains('track-1.m4a'));
      expect(handler.mediaItem.value?.title, 'First Track');
      expect(handler.mediaItem.value?.artist, 'Artist One');
      expect(find.byKey(const Key('mini-player')), findsOneWidget);
      expect(find.byKey(const Key('playback-progress-bar')), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const Key('mini-player-toggle')),
          matching: find.byIcon(Icons.pause_rounded),
        ),
        findsOneWidget,
      );

      engine.emitPlaying(false);
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byKey(const Key('mini-player-toggle')),
          matching: find.byIcon(Icons.play_arrow_rounded),
        ),
        findsOneWidget,
      );

      await handler.skipToNext();
      await tester.pumpAndSettle();

      expect(engine.loadedPaths.length, 2);
      expect(engine.loadedPaths.last, contains('track-2.m4a'));
      expect(handler.mediaItem.value?.title, 'Second Track');

      engine.emitPosition(const Duration(seconds: 12));
      await tester.pump();
      await handler.skipToPrevious();
      await tester.pumpAndSettle();

      expect(engine.loadedPaths.length, 2);
      expect(engine.seekCalls.last, Duration.zero);
      expect(handler.mediaItem.value?.title, 'Second Track');

      await handler.skipToPrevious();
      await tester.pumpAndSettle();

      expect(engine.loadedPaths.length, 3);
      expect(engine.loadedPaths.last, contains('track-1.m4a'));

      engine.emitCompleted();
      await tester.pumpAndSettle();

      expect(engine.loadedPaths.length, 4);
      expect(engine.loadedPaths.last, contains('track-2.m4a'));

      await tester.fling(
        find.byKey(const Key('mini-player')),
        const Offset(0, -240),
        800,
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('now-playing-sheet')), findsOneWidget);
      expect(
        find.byKey(const Key('now-playing-shuffle-button')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('now-playing-repeat-button')),
        findsOneWidget,
      );
      expect(find.text('다운로드됨'), findsNothing);
      expect(
        find.byKey(const Key('now-playing-scroll-queue-indicator')),
        findsNothing,
      );
      expect(find.byKey(const Key('now-playing-queue-header')), findsOneWidget);
      expect(find.text('현재 재생목록'), findsOneWidget);
      expect(
        find.byKey(const Key('now-playing-queue-summary')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('now-playing-queue-summary')))
            .data,
        '2곡 · 00:07:30',
      );
      final queueHeaderRect = tester.getRect(
        find.byKey(const Key('now-playing-queue-header')),
      );
      expect(queueHeaderRect.top, lessThan(840));
      expect(queueHeaderRect.bottom, lessThan(840));
      final firstQueueItemRect = tester.getRect(
        find.byKey(const Key('now-playing-queue-item-0')),
      );
      expect(firstQueueItemRect.top, lessThan(840));
      expect(firstQueueItemRect.bottom, greaterThan(840));

      await tester.tap(find.byKey(const Key('now-playing-repeat-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('now-playing-shuffle-button')));
      await tester.pumpAndSettle();

      engine.emitCompleted();
      await tester.pumpAndSettle();
      expect(engine.loadedPaths.length, 5);
      expect(engine.loadedPaths.last, contains('track-1.m4a'));
    },
  );

  testWidgets(
    'Settings error log sheet lists logs newest-first and shares selected log',
    (tester) async {
      final adapters = _FakeMediaAdapters();
      await tester.pumpWidget(
        ReplicaMusicApp(core: _FakeUpdateCore(), adapters: adapters),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('dock-settings-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('settings-error-log-tile')), findsOneWidget);
      expect(find.text('오류 로그 다운로드'), findsOneWidget);
      expect(find.text('오류 로그 GitHub 보고'), findsNothing);

      await tester.tap(find.byKey(const Key('settings-error-log-tile')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('error-log-sheet')), findsOneWidget);
      final dialogRect = tester.getRect(
        find.byKey(const Key('error-log-sheet')),
      );
      expect(dialogRect.center.dx, lessThan(400));
      final newestY = tester.getTopLeft(find.text('Newest Error')).dy;
      final olderY = tester.getTopLeft(find.text('Older Error')).dy;
      expect(newestY, lessThan(olderY));

      await tester.tap(find.byKey(const Key('error-log-share-0')));
      await tester.pumpAndSettle();

      expect(adapters.sharedSubjects, ['Newest Error']);
      expect(adapters.sharedPaths.first, endsWith('.txt'));
    },
  );

  testWidgets(
    'History shelf shows per-device histories at top and records local-first',
    (tester) async {
      final adapters = _FakeLoggedInAdapters();
      final core = _FakeHistoryCore();
      final engine = _FakeAudioEngine();
      final handler = ReplicaAudioServiceHandler();

      await tester.pumpWidget(
        ReplicaMusicApp(
          core: core,
          adapters: adapters,
          audioEngine: engine,
          audioServiceHandler: handler,
          fileExistsOverride: (_) => true,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('library-history-shelf')), findsOneWidget);
      expect(
        find.byKey(const Key('history-shelf-more-button')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('playlist-tile-history')), findsOneWidget);
      expect(
        find.byKey(const Key('playlist-tile-history-PL_HISTORY_OTHER')),
        findsOneWidget,
      );
      expect(find.text('MyFold8'), findsOneWidget);
      expect(find.text('OfficePC'), findsOneWidget);
      expect(find.text('Drive'), findsOneWidget);
      expect(find.text('Drive.1700000000.rm'), findsNothing);

      final historyShelfY = tester
          .getTopLeft(find.byKey(const Key('library-history-shelf')))
          .dy;
      final allSongsY = tester
          .getTopLeft(find.byKey(const Key('playlist-tile-all-songs')))
          .dy;
      expect(historyShelfY, lessThan(allSongsY));

      final currentDeviceX = tester
          .getTopLeft(find.byKey(const Key('playlist-tile-history')))
          .dx;
      final otherDeviceX = tester
          .getTopLeft(
            find.byKey(const Key('playlist-tile-history-PL_HISTORY_OTHER')),
          )
          .dx;
      expect(currentDeviceX, lessThan(otherDeviceX));

      await tester.tap(find.byKey(const Key('history-shelf-more-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('all-histories-dialog')), findsOneWidget);
      expect(
        find.byKey(const Key('all-histories-item-PL_HISTORY_REMOTE')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('all-histories-item-PL_HISTORY_OTHER')),
        findsOneWidget,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('playlist-tile-all-songs')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('First Track'));
      await tester.pumpAndSettle();

      await handler.skipToNext();
      await tester.pumpAndSettle();

      await handler.skipToPrevious();
      await tester.pumpAndSettle();

      expect(core.historyRequests.length, 3);
      expect(core.historyRequests[0]['playlist_id'], 'PL_HISTORY_REMOTE');
      expect(core.historyRequests[0]['video_id'], 'track-1');
      expect(core.historyRequests[0]['playlist_loaded'], isFalse);
      expect(core.historyRequests[0]['existing_set_video_id'], isNull);
      expect(core.historyRequests[0]['max_tracks'], 100);

      expect(core.historyRequests[1]['video_id'], 'track-2');
      expect(core.historyRequests[1]['playlist_loaded'], isTrue);
      expect(core.historyRequests[1]['existing_set_video_id'], isNull);

      expect(core.historyRequests[2]['video_id'], 'track-1');
      expect(core.historyRequests[2]['playlist_loaded'], isTrue);
      expect(core.historyRequests[2]['existing_set_video_id'], 'svid-track-1');

      await tester.tap(find.byKey(const Key('detail-back-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('playlist-tile-history')));
      await tester.pumpAndSettle();
      expect(core.playlistTrackFetchCount, 0);
      expect(find.byKey(const Key('detail-more-button')), findsOneWidget);

      await tester.tap(find.byKey(const Key('detail-back-button')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('playlist-tile-history-PL_HISTORY_OTHER')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('detail-more-button')), findsNothing);
      expect(core.playlistTrackFetchCount, 1);
    },
  );

  testWidgets('Track menu supports play-next insertion and add-to-queue end', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(360, 840);
    addTearDown(tester.view.reset);

    final adapters = _FakeLoggedInAdapters();
    final core = _FakeThreeTrackCore();
    final engine = _FakeAudioEngine();
    final handler = ReplicaAudioServiceHandler();

    await tester.pumpWidget(
      ReplicaMusicApp(
        core: core,
        adapters: adapters,
        audioEngine: engine,
        audioServiceHandler: handler,
        fileExistsOverride: (_) => true,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('playlist-tile-all-songs')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('First Track'));
    await tester.pumpAndSettle();
    expect(engine.loadedPaths.last, contains('track-1.m4a'));

    await tester.ensureVisible(find.byKey(const Key('track-more-track-3')));
    await tester.tap(find.byKey(const Key('track-more-track-3')));
    await tester.pumpAndSettle();
    expect(find.text('다음에 재생'), findsOneWidget);
    expect(find.text('현재 재생목록에 추가'), findsOneWidget);
    await tester.tap(find.text('다음에 재생'));
    await tester.pumpAndSettle();

    await handler.skipToNext();
    await tester.pumpAndSettle();
    expect(engine.loadedPaths.last, contains('track-3.m4a'));

    await tester.ensureVisible(find.byKey(const Key('track-more-track-1')));
    await tester.tap(find.byKey(const Key('track-more-track-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('현재 재생목록에 추가'));
    await tester.pumpAndSettle();

    await handler.skipToNext();
    await tester.pumpAndSettle();
    expect(engine.loadedPaths.last, contains('track-2.m4a'));

    await handler.skipToNext();
    await tester.pumpAndSettle();
    expect(engine.loadedPaths.last, contains('track-1.m4a'));
  });

  testWidgets(
    'Tapping undownloaded track downloads only with determinate progress and shows in Saved Songs',
    (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(360, 840);
      addTearDown(tester.view.reset);

      final adapters = _FakeMediaAdapters();
      final core = _FakeDownloadFlowCore();
      final engine = _FakeAudioEngine();
      final downloadCompleter = Completer<Map<String, dynamic>>();
      core.trackDownloadCompleter = downloadCompleter;

      await tester.pumpWidget(
        ReplicaMusicApp(
          core: core,
          adapters: adapters,
          audioEngine: engine,
          fileExistsOverride: (path) =>
              path.contains('track-1') ||
              path.contains('track-2') ||
              path.contains('new-track-1'),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.search_outlined));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('search-input')), 'demo');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      expect(find.text('Undownloaded Song'), findsOneWidget);
      await tester.tap(find.text('Undownloaded Song'));
      await tester.pump();

      expect(engine.loadedPaths, isEmpty);
      expect(
        find.byKey(const Key('track-downloading-new-track-1')),
        findsOneWidget,
      );
      final initialIndicator = tester.widget<CircularProgressIndicator>(
        find.descendant(
          of: find.byKey(const Key('track-downloading-new-track-1')),
          matching: find.byType(CircularProgressIndicator),
        ),
      );
      expect(initialIndicator.value, closeTo(0.0, 0.01));

      core.mockTrackProgress = {
        'new-track-1': const UpdateDownloadProgress(
          downloadedBytes: 600,
          totalBytes: 1000,
        ),
      };
      await tester.pump(const Duration(milliseconds: 200));

      final midIndicator = tester.widget<CircularProgressIndicator>(
        find.descendant(
          of: find.byKey(const Key('track-downloading-new-track-1')),
          matching: find.byType(CircularProgressIndicator),
        ),
      );
      expect(midIndicator.value, closeTo(0.6, 0.01));

      await tester.tap(find.text('보관함'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('playlist-tile-all-songs')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('all-songs-downloading-header')),
        findsOneWidget,
      );
      expect(find.text('다운로드 중 · 1곡'), findsOneWidget);
      expect(
        find.byKey(const Key('downloading-track-tile-new-track-1')),
        findsOneWidget,
      );
      expect(find.text('New Artist • 60%'), findsOneWidget);

      final downloadingY = tester
          .getTopLeft(
            find.byKey(const Key('downloading-track-tile-new-track-1')),
          )
          .dy;
      final firstTrackY = tester.getTopLeft(find.text('First Track')).dy;
      expect(downloadingY, lessThan(firstTrackY));

      downloadCompleter.complete({
        'downloaded': {
          'video_id': 'new-track-1',
          'title': 'Undownloaded Song',
          'artist': 'New Artist',
          'duration': '3:30',
          'thumbnail': '',
          'file_path': 'C:\\temp\\storage\\new-track-1.m4a',
          'bytes': 1000,
        },
      });
      await tester.pumpAndSettle();

      expect(engine.loadedPaths, isEmpty);
      expect(
        find.byKey(const Key('all-songs-downloading-header')),
        findsNothing,
      );
      expect(find.text('Undownloaded Song'), findsOneWidget);
      expect(core.downloadRequests.last['format'], 'opus');
    },
  );

  testWidgets(
    'Settings audio format switches between Opus and M4A and stays intact across Fold 8 states',
    (tester) async {
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      const foldStates = <(String, Size)>[
        ('cover-portrait', Size(360, 840)),
        ('cover-landscape', Size(840, 360)),
        ('unfolded-portrait', Size(710, 840)),
        ('unfolded-landscape', Size(840, 710)),
      ];

      final adapters = _FakeMediaAdapters();
      final core = _FakeDownloadFlowCore();
      final engine = _FakeAudioEngine();
      tester.view.physicalSize = foldStates.first.$2;

      await tester.pumpWidget(
        ReplicaMusicApp(
          core: core,
          adapters: adapters,
          audioEngine: engine,
          fileExistsOverride: (path) =>
              path.endsWith('.opus') || path.endsWith('.m4a'),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('dock-settings-button')));
      await tester.pumpAndSettle();

      for (final (_, size) in foldStates) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final settingsScrollable = find
            .descendant(
              of: find.byKey(const Key('settings-pane')),
              matching: find.byType(Scrollable),
            )
            .first;
        await tester.scrollUntilVisible(
          find.byKey(const Key('settings-audio-format-row')),
          140,
          scrollable: settingsScrollable,
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          find.byKey(const Key('settings-audio-format-row')),
          findsOneWidget,
        );
        expect(find.text('Opus (.opus)'), findsOneWidget);
      }

      tester.view.physicalSize = foldStates[1].$2;
      await tester.pumpAndSettle();
      final landscapeScrollable = find
          .descendant(
            of: find.byKey(const Key('settings-pane')),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.byKey(const Key('settings-audio-format-row')),
        140,
        scrollable: landscapeScrollable,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings-audio-format-row')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const Key('audio-format-picker-dialog')),
        findsOneWidget,
      );

      await tester.tap(find.text('M4A (.m4a)'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('audio-format-picker-dialog')), findsNothing);
      expect(find.text('M4A (.m4a)'), findsOneWidget);

      tester.view.physicalSize = foldStates.first.$2;
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.search_outlined));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('search-input')), 'demo');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Undownloaded Song'));
      await tester.pumpAndSettle();

      expect(core.downloadRequests.length, 1);
      expect(core.downloadRequests.last['format'], 'm4a');
    },
  );
}

class _FakeDownloadFlowCore extends _FakeMediaCore {
  Completer<Map<String, dynamic>>? trackDownloadCompleter;
  final List<Map<String, dynamic>> downloadRequests = [];

  @override
  Future<Map<String, dynamic>> invoke(Map<String, dynamic> request) async {
    switch (request['op']) {
      case 'search':
        return {
          'tracks': [
            {
              'video_id': 'new-track-1',
              'title': 'Undownloaded Song',
              'artist': 'New Artist',
              'duration': '3:30',
              'thumbnail': '',
            },
          ],
        };
      case 'download_track':
        downloadRequests.add(Map<String, dynamic>.of(request));
        return trackDownloadCompleter?.future ??
            Future.value({
              'downloaded': {
                'video_id': 'new-track-1',
                'title': 'Undownloaded Song',
                'artist': 'New Artist',
                'duration': '3:30',
                'thumbnail': '',
                'file_path': request['format'] == 'opus'
                    ? 'C:\\temp\\storage\\new-track-1.opus'
                    : 'C:\\temp\\storage\\new-track-1.m4a',
                'extension': request['format'] == 'opus' ? 'opus' : 'm4a',
                'bytes': 1000,
              },
            });
      default:
        return super.invoke(request);
    }
  }
}

class _FakeThreeTrackCore extends _FakeHistoryCore {
  @override
  Future<Map<String, dynamic>> invoke(Map<String, dynamic> request) async {
    if (request['op'] == 'list_downloaded') {
      return {
        'tracks': [
          {
            'video_id': 'track-1',
            'title': 'First Track',
            'artist': 'Artist One',
            'duration': '3:20',
            'thumbnail': '',
            'file_path': 'C:\\temp\\storage\\track-1.m4a',
          },
          {
            'video_id': 'track-2',
            'title': 'Second Track',
            'artist': 'Artist Two',
            'duration': '4:10',
            'thumbnail': '',
            'file_path': 'C:\\temp\\storage\\track-2.m4a',
          },
          {
            'video_id': 'track-3',
            'title': 'Third Track',
            'artist': 'Artist Three',
            'duration': '2:45',
            'thumbnail': '',
            'file_path': 'C:\\temp\\storage\\track-3.m4a',
          },
        ],
      };
    }
    return super.invoke(request);
  }
}

class _FakeLoggedInAdapters extends _FakeMediaAdapters {
  @override
  Future<AppEnvironmentInfo> loadEnvironment({
    String fallbackVersion = '0.1.0',
  }) async {
    return AppEnvironmentInfo(
      version: fallbackVersion,
      cacheDir: '',
      storageDir: 'C:\\temp\\storage',
      deviceName: 'MyFold8',
    );
  }

  @override
  Future<Map<String, dynamic>?> readWebSession() async => {
    'cookie': 'SAPISID=test; SID=test',
    'origin': 'https://www.youtube.com',
  };
}

class _FakeHistoryCore extends _FakeMediaCore {
  final List<Map<String, dynamic>> historyRequests = [];
  int playlistTrackFetchCount = 0;

  @override
  Future<Map<String, dynamic>> invoke(Map<String, dynamic> request) async {
    switch (request['op']) {
      case 'playlist_tracks':
        playlistTrackFetchCount++;
        return {'tracks': <dynamic>[]};
      case 'list_playlists':
        return {
          'playlists': [
            {
              'id': 'PL_HISTORY_REMOTE',
              'remote_title': 'History.MyFold8.rm',
              'subtitle': 'YouTube 재생목록',
              'thumbnail': '',
              'updated_at': 0,
            },
            {
              'id': 'PL_HISTORY_OTHER',
              'remote_title': 'History.OfficePC.rm',
              'subtitle': 'YouTube 재생목록',
              'thumbnail': '',
              'updated_at': 0,
            },
            {
              'id': 'PL_DRIVE',
              'remote_title': 'Drive.1700000000.rm',
              'subtitle': 'YouTube 재생목록',
              'thumbnail': '',
              'updated_at': 1700000000,
            },
          ],
        };
      case 'record_history_track':
        historyRequests.add(Map<String, dynamic>.of(request));
        final videoId = request['video_id'] as String;
        final svid = 'svid-$videoId';
        if (request['playlist_loaded'] == false) {
          return {
            'set_video_id': svid,
            'tracks': [
              {
                'video_id': videoId,
                'title': videoId == 'track-1' ? 'First Track' : 'Second Track',
                'artist': 'Artist',
                'duration': '3:20',
                'thumbnail': '',
                'set_video_id': svid,
              },
            ],
          };
        }
        return {'set_video_id': svid, 'tracks': null};
      default:
        return super.invoke(request);
    }
  }
}
