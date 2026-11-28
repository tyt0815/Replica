import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

class AppEnvironmentInfo {
  const AppEnvironmentInfo({
    required this.version,
    required this.cacheDir,
    required this.storageDir,
    this.dataDir = '',
    this.deviceName = 'Device',
  });

  final String version;
  final String cacheDir;
  final String storageDir;
  final String dataDir;
  final String deviceName;

  String get effectiveDataDir => dataDir.isNotEmpty ? dataDir : storageDir;
}

class PlatformAdapters {
  PlatformAdapters({
    this.updateChannel = const MethodChannel('com.tyt0815.replicamusic/update'),
    this.accountChannel = const MethodChannel(
      'com.tyt0815.replicamusic/account',
    ),
    this.volumeChannel = const MethodChannel('com.tyt0815.replicamusic/volume'),
  }) {
    if (Platform.isAndroid) {
      volumeChannel.setMethodCallHandler((call) async {
        if (call.method == 'changed' && call.arguments is num) {
          final v = (call.arguments as num).toDouble().clamp(0.0, 1.0);
          _volumeChanges.add(v);
        }
      });
    }
  }

  final MethodChannel updateChannel;
  final MethodChannel accountChannel;
  final MethodChannel volumeChannel;
  final StreamController<double> _volumeChanges =
      StreamController<double>.broadcast();
  double _fallbackVolume = 0.7;

  Stream<double> get mediaVolumeStream => _volumeChanges.stream;

  Future<bool> isWifiConnected() async {
    if (!Platform.isAndroid) return false;
    try {
      return await updateChannel.invokeMethod<bool>('is_wifi_connected') ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<double> getMediaVolume() async {
    if (!Platform.isAndroid) {
      return _fallbackVolume;
    }
    try {
      final result = await volumeChannel.invokeMethod<num>('get');
      return result?.toDouble().clamp(0.0, 1.0) ?? _fallbackVolume;
    } catch (_) {
      return _fallbackVolume;
    }
  }

  Future<void> setMediaVolume(double volume) async {
    final clamped = volume.clamp(0.0, 1.0);
    _fallbackVolume = clamped;
    if (!Platform.isAndroid) {
      _volumeChanges.add(clamped);
      return;
    }
    try {
      await volumeChannel.invokeMethod<num>('set', {'volume': clamped});
    } catch (_) {}
  }

  Future<AppEnvironmentInfo> loadEnvironment({
    String fallbackVersion = '0.1.0',
  }) async {
    if (Platform.isAndroid) {
      try {
        final result = await updateChannel.invokeMapMethod<String, dynamic>(
          'info',
        );
        if (result != null) {
          final rawDevice = (result['device_name'] as String?)?.trim() ?? '';
          return AppEnvironmentInfo(
            version: (result['version'] as String?) ?? fallbackVersion,
            cacheDir: (result['cache_dir'] as String?) ?? '',
            storageDir: (result['storage_dir'] as String?) ?? '',
            dataDir: (result['data_dir'] as String?) ?? '',
            deviceName: rawDevice.isNotEmpty ? rawDevice : 'Android',
          );
        }
      } catch (_) {}
    }
    try {
      final sep = Platform.pathSeparator;
      final base =
          Platform.environment['LOCALAPPDATA'] ??
          Platform.environment['HOME'] ??
          Directory.systemTemp.path;
      final host = Platform.localHostname.trim();
      return AppEnvironmentInfo(
        version: fallbackVersion,
        cacheDir: '${Directory.systemTemp.path}${sep}replica_music_cache',
        storageDir: '$base${sep}ReplicaMusic',
        dataDir: '$base${sep}ReplicaMusic$sep.data',
        deviceName: host.isNotEmpty ? host : 'Desktop',
      );
    } catch (_) {
      return AppEnvironmentInfo(
        version: fallbackVersion,
        cacheDir: '',
        storageDir: '',
        dataDir: '',
        deviceName: 'Device',
      );
    }
  }

  Future<bool> hasStoragePermission() async {
    if (!Platform.isAndroid) {
      return true;
    }
    try {
      return await updateChannel.invokeMethod<bool>('has_storage_permission') ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<void> openStoragePermissionSettings() async {
    if (!Platform.isAndroid) {
      return;
    }
    await updateChannel.invokeMethod<bool>('open_storage_permission_settings');
  }

  Future<bool> canInstallPackages() async {
    if (!Platform.isAndroid) {
      return false;
    }
    try {
      return await updateChannel.invokeMethod<bool>('can_install_packages') ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<void> openInstallPermissionSettings() async {
    if (!Platform.isAndroid) {
      return;
    }
    await updateChannel.invokeMethod<bool>('open_install_permission_settings');
  }

  Future<void> installApk(String path) async {
    if (!Platform.isAndroid) {
      throw Exception('APK 자동 설치는 Android에서만 지원합니다.');
    }
    await updateChannel.invokeMethod<bool>('install_apk', {'path': path});
  }

  Future<Map<String, dynamic>?> readWebSession() async {
    if (!Platform.isAndroid) {
      return null;
    }
    try {
      final raw = await accountChannel.invokeMapMethod<String, dynamic>(
        'session',
      );
      return raw;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> loginWebSession() async {
    if (!Platform.isAndroid) {
      throw Exception('현재 버전에서는 Android에서 Google 로그인을 지원합니다.');
    }
    final raw = await accountChannel.invokeMapMethod<String, dynamic>('login');
    return raw;
  }

  Future<void> logoutWebSession() async {
    if (!Platform.isAndroid) {
      return;
    }
    await accountChannel.invokeMethod<bool>('logout');
  }

  Future<void> openExternalUrl(String url) async {
    if (Platform.isAndroid) {
      await updateChannel.invokeMethod<bool>('open_url', {'url': url});
    }
  }

  Future<bool> shareTextFile({
    required String path,
    String? subject,
    String? text,
  }) async {
    if (Platform.isAndroid) {
      final result = await updateChannel.invokeMethod<bool>('share_file', {
        'path': path,
        if (subject != null && subject.isNotEmpty) 'subject': subject,
        if (text != null && text.isNotEmpty) 'text': text,
      });
      return result == true;
    }
    if (text != null && text.isNotEmpty) {
      await Clipboard.setData(ClipboardData(text: text));
    }
    return false;
  }
}
