import 'package:flutter/material.dart';

class TrackItem {
  const TrackItem({
    required this.id,
    required this.title,
    required this.artist,
    required this.duration,
    required this.coverColor,
    this.thumbnail = '',
    this.filePath,
    this.setVideoId,
    this.bytes = 0,
    this.isDownloaded = false,
  });

  final String id;
  final String title;
  final String artist;
  final String duration;
  final Color coverColor;
  final String thumbnail;
  final String? filePath;
  final String? setVideoId;
  final int bytes;
  final bool isDownloaded;

  TrackItem copyWith({
    String? filePath,
    String? setVideoId,
    int? bytes,
    bool? isDownloaded,
  }) {
    return TrackItem(
      id: id,
      title: title,
      artist: artist,
      duration: duration,
      coverColor: coverColor,
      thumbnail: thumbnail,
      filePath: filePath ?? this.filePath,
      setVideoId: setVideoId ?? this.setVideoId,
      bytes: bytes ?? this.bytes,
      isDownloaded: isDownloaded ?? this.isDownloaded,
    );
  }

  Map<String, dynamic> toCoreJson() => {
    'video_id': id,
    'title': title,
    'artist': artist,
    'duration': duration,
    'thumbnail': thumbnail,
    if (filePath != null) 'file_path': filePath,
    if (setVideoId != null) 'set_video_id': setVideoId,
    if (bytes > 0) 'bytes': bytes,
  };

  factory TrackItem.fromCoreJson(
    Map<String, dynamic> json, {
    bool isDownloaded = false,
  }) {
    final id = (json['video_id'] as String?) ?? '';
    return TrackItem(
      id: id,
      title: (json['title'] as String?) ?? '제목 없음',
      artist: (json['artist'] as String?) ?? 'YouTube',
      duration: (json['duration'] as String?) ?? '',
      thumbnail: (json['thumbnail'] as String?) ?? '',
      filePath: json['file_path'] as String?,
      setVideoId: json['set_video_id'] as String?,
      bytes: (json['bytes'] as num?)?.toInt() ?? 0,
      isDownloaded: isDownloaded || (json['file_path'] as String?) != null,
      coverColor: colorFromId(id),
    );
  }
}

class PlaylistItem {
  const PlaylistItem({
    required this.id,
    required this.remoteTitle,
    required this.owner,
    required this.description,
    required this.coverColor,
    required this.tracks,
    this.thumbnail = '',
    this.isRemote = false,
    this.hasPendingLocalEdit = false,
    this.updatedAt = 0,
  });

  final String id;
  final String remoteTitle;
  final String owner;
  final String description;
  final Color coverColor;
  final List<TrackItem> tracks;
  final String thumbnail;
  final bool isRemote;
  final bool hasPendingLocalEdit;
  final int updatedAt;

  PlaylistItem copyWith({
    String? remoteTitle,
    List<TrackItem>? tracks,
    String? description,
    String? thumbnail,
    bool? hasPendingLocalEdit,
    int? updatedAt,
  }) {
    return PlaylistItem(
      id: id,
      remoteTitle: remoteTitle ?? this.remoteTitle,
      owner: owner,
      description: description ?? this.description,
      coverColor: coverColor,
      tracks: tracks ?? this.tracks,
      thumbnail: thumbnail ?? this.thumbnail,
      isRemote: isRemote,
      hasPendingLocalEdit: hasPendingLocalEdit ?? this.hasPendingLocalEdit,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toCacheJson() => {
    'id': id,
    'remote_title': remoteTitle,
    'owner': owner,
    'description': description,
    'thumbnail': thumbnail,
    'is_remote': isRemote,
    'has_pending_local_edit': hasPendingLocalEdit,
    'updated_at': updatedAt,
    'tracks': tracks.map((t) => t.toCoreJson()).toList(growable: false),
  };

  factory PlaylistItem.fromCacheJson(Map<String, dynamic> json) {
    final id = (json['id'] as String?) ?? '';
    final remoteTitle = (json['remote_title'] as String?) ?? '';
    final rawTracks = (json['tracks'] as List<dynamic>?) ?? const [];
    final parsedTs =
        (json['updated_at'] as num?)?.toInt() ??
        parsePlaylistTimestamp(remoteTitle);
    return PlaylistItem(
      id: id,
      remoteTitle: remoteTitle,
      owner: (json['owner'] as String?) ?? 'YouTube',
      description: (json['description'] as String?) ?? '',
      thumbnail: (json['thumbnail'] as String?) ?? '',
      coverColor: colorFromId(id),
      isRemote: json['is_remote'] == true,
      hasPendingLocalEdit: json['has_pending_local_edit'] == true,
      updatedAt: parsedTs,
      tracks: rawTracks
          .whereType<Map<String, dynamic>>()
          .map(TrackItem.fromCoreJson)
          .toList(growable: false),
    );
  }

  factory PlaylistItem.fromCoreJson(Map<String, dynamic> json) {
    final id = (json['id'] as String?) ?? '';
    final remoteTitle = (json['remote_title'] as String?) ?? '';
    final parsedTs =
        (json['updated_at'] as num?)?.toInt() ??
        parsePlaylistTimestamp(remoteTitle);
    return PlaylistItem(
      id: id,
      remoteTitle: remoteTitle,
      owner: 'YouTube',
      description: (json['subtitle'] as String?) ?? 'YouTube 재생목록',
      thumbnail: (json['thumbnail'] as String?) ?? '',
      coverColor: colorFromId(id),
      tracks: const [],
      isRemote: true,
      updatedAt: parsedTs,
    );
  }
}

class UpdateInfo {
  const UpdateInfo({
    required this.updateAvailable,
    required this.currentVersion,
    required this.latestVersion,
    required this.tagName,
    required this.releaseNotes,
    this.assetName,
    this.assetUrl,
    this.assetSize,
    this.sha256,
  });

  final bool updateAvailable;
  final String currentVersion;
  final String latestVersion;
  final String tagName;
  final String releaseNotes;
  final String? assetName;
  final String? assetUrl;
  final int? assetSize;
  final String? sha256;

  factory UpdateInfo.fromJson(Map<String, dynamic> json) {
    return UpdateInfo(
      updateAvailable: json['update_available'] == true,
      currentVersion: (json['current_version'] as String?) ?? '0.1.0',
      latestVersion: (json['latest_version'] as String?) ?? '0.1.0',
      tagName: (json['tag_name'] as String?) ?? '',
      releaseNotes: (json['release_notes'] as String?) ?? '',
      assetName: json['asset_name'] as String?,
      assetUrl: json['asset_url'] as String?,
      assetSize: (json['asset_size'] as num?)?.toInt(),
      sha256: json['sha256'] as String?,
    );
  }
}

Color colorFromId(String id) {
  const palette = <Color>[
    Color(0xFFFF4D2E),
    Color(0xFF2B4C7E),
    Color(0xFF5A2A48),
    Color(0xFF1F4E5F),
    Color(0xFF6B3A2E),
    Color(0xFF2E5E4E),
  ];
  if (id.isEmpty) {
    return palette.first;
  }
  final hash = id.codeUnits.fold<int>(0, (acc, code) => acc + code);
  return palette[hash % palette.length];
}

List<PlaylistItem> initialLocalPlaylists() => const [];

int parseTrackDurationSeconds(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    return 0;
  }
  final parts = trimmed.split(':');
  if (parts.length < 2 || parts.length > 3) {
    return 0;
  }
  var total = 0;
  for (final part in parts) {
    final value = int.tryParse(part.trim());
    if (value == null || value < 0) {
      return 0;
    }
    total = total * 60 + value;
  }
  return total;
}

String formatTotalTracksDuration(Iterable<TrackItem> tracks) {
  var totalSeconds = 0;
  for (final track in tracks) {
    totalSeconds += parseTrackDurationSeconds(track.duration);
  }
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  final hh = hours.toString().padLeft(2, '0');
  final mm = minutes.toString().padLeft(2, '0');
  final ss = seconds.toString().padLeft(2, '0');
  return '$hh:$mm:$ss';
}

const String replicaPlaylistSuffix = '.rm';
const String historyTitlePrefix = 'history.';
const String legacyHistoryTitle = 'history.rm';

String sanitizeDeviceName(String raw) {
  final buffer = StringBuffer();
  var prevSpace = false;
  var count = 0;
  for (final rune in raw.trim().runes) {
    if (rune == 0x2E || rune < 0x20 || rune == 0x7F) {
      if (!prevSpace && buffer.isNotEmpty) {
        buffer.write(' ');
        prevSpace = true;
      }
      continue;
    }
    final ch = String.fromCharCode(rune);
    if (ch.trim().isEmpty) {
      if (!prevSpace && buffer.isNotEmpty) {
        buffer.write(' ');
        prevSpace = true;
      }
      continue;
    }
    buffer.write(ch);
    prevSpace = false;
    count++;
    if (count >= 40) {
      break;
    }
  }
  final cleaned = buffer.toString().trim();
  return cleaned.isEmpty ? 'Device' : cleaned;
}

bool isHistoryRemoteTitle(String rawTitle) {
  final trimmed = rawTitle.trim();
  if (!trimmed.endsWith(replicaPlaylistSuffix) ||
      trimmed.length <= replicaPlaylistSuffix.length) {
    return false;
  }
  final lower = trimmed.toLowerCase();
  if (lower == legacyHistoryTitle) {
    return true;
  }
  if (lower.startsWith(historyTitlePrefix)) {
    final device = lower.substring(
      historyTitlePrefix.length,
      lower.length - replicaPlaylistSuffix.length,
    );
    return device.trim().isNotEmpty;
  }
  return false;
}

String? extractHistoryDeviceName(String rawTitle) {
  final trimmed = rawTitle.trim();
  if (!trimmed.endsWith(replicaPlaylistSuffix) ||
      trimmed.length <= replicaPlaylistSuffix.length) {
    return null;
  }
  final stem = trimmed
      .substring(0, trimmed.length - replicaPlaylistSuffix.length)
      .trimRight();
  if (stem.length > historyTitlePrefix.length &&
      stem.substring(0, historyTitlePrefix.length).toLowerCase() ==
          historyTitlePrefix) {
    final device = stem.substring(historyTitlePrefix.length).trim();
    return device.isEmpty ? null : device;
  }
  return null;
}

String buildHistoryRemoteTitle(String deviceName) =>
    'History.${sanitizeDeviceName(deviceName)}$replicaPlaylistSuffix';

int parsePlaylistTimestamp(String rawTitle) {
  final trimmed = rawTitle.trim();
  if (!trimmed.endsWith(replicaPlaylistSuffix) ||
      trimmed.length <= replicaPlaylistSuffix.length ||
      isHistoryRemoteTitle(trimmed)) {
    return 0;
  }
  final stem = trimmed
      .substring(0, trimmed.length - replicaPlaylistSuffix.length)
      .trimRight();
  final dotIdx = stem.lastIndexOf('.');
  if (dotIdx <= 0) {
    return 0;
  }
  final base = stem.substring(0, dotIdx).trim();
  final tsStr = stem.substring(dotIdx + 1).trim();
  if (base.isEmpty || tsStr.length < 10 || tsStr.length > 13) {
    return 0;
  }
  for (final code in tsStr.codeUnits) {
    if (code < 0x30 || code > 0x39) {
      return 0;
    }
  }
  return int.tryParse(tsStr) ?? 0;
}

String stripPlaylistTimestampAndSuffix(String rawTitle) {
  final trimmed = rawTitle.trim();
  final device = extractHistoryDeviceName(trimmed);
  if (device != null) {
    return device;
  }
  final stem = trimmed.endsWith(replicaPlaylistSuffix)
      ? trimmed
            .substring(0, trimmed.length - replicaPlaylistSuffix.length)
            .trimRight()
      : trimmed;
  final dotIdx = stem.lastIndexOf('.');
  if (dotIdx > 0) {
    final base = stem.substring(0, dotIdx).trim();
    final tsStr = stem.substring(dotIdx + 1).trim();
    if (base.isNotEmpty &&
        tsStr.length >= 10 &&
        tsStr.length <= 13 &&
        tsStr.codeUnits.every((c) => c >= 0x30 && c <= 0x39)) {
      return base;
    }
  }
  return stem;
}

String buildVersionedRemoteTitle(String rawOrDisplayTitle, int unixSeconds) {
  final clean = stripPlaylistTimestampAndSuffix(rawOrDisplayTitle);
  if (clean.isEmpty) {
    return rawOrDisplayTitle;
  }
  if (unixSeconds > 0) {
    return '$clean.$unixSeconds$replicaPlaylistSuffix';
  }
  return '$clean$replicaPlaylistSuffix';
}

int nextPlaylistTimestamp(int currentTimestamp) {
  final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return nowSec > currentTimestamp ? nowSec : currentTimestamp + 1;
}
