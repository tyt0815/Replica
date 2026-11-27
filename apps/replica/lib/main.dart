import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import 'core/replica_music_core.dart';
import 'playback/replica_audio_handler.dart';
import 'theme/replica_music_theme.dart';
import 'ui/replica_music_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  ReplicaAudioServiceHandler? audioServiceHandler;
  if (Platform.isAndroid) {
    try {
      audioServiceHandler = await AudioService.init(
        builder: () => ReplicaAudioServiceHandler(),
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'io.replicamedia.replica.playback',
          androidNotificationChannelName: '음악 재생',
          androidNotificationOngoing: false,
          androidStopForegroundOnPause: false,
          androidNotificationIcon: 'drawable/ic_notification_music',
          notificationColor: replicaAccentColor,
        ),
      );
    } catch (_) {}
  }
  runApp(
    ReplicaMusicApp(
      core: NativeReplicaMusicCore.openOrFallback(),
      audioServiceHandler: audioServiceHandler,
    ),
  );
}
