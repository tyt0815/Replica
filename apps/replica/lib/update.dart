import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:pub_semver/pub_semver.dart';

const repository = 'tyt0815/Replica';
const _maxBytes = 256 * 1024 * 1024;

class AppRelease {
  const AppRelease(this.version, this.uri, this.bytes, this.digest);
  final Version version;
  final Uri uri;
  final int bytes;
  final String digest;

  static AppRelease? newer(Map<String, dynamic> data, Version installed) {
    if (data['draft'] == true || data['prerelease'] == true) return null;
    final tag = data['tag_name'] as String;
    if (!RegExp(r'^v\d+\.\d+\.\d+$').hasMatch(tag)) {
      throw const FormatException('지원하지 않는 릴리스 버전입니다.');
    }
    final version = Version.parse(tag.substring(1));
    if (version <= installed) return null;
    final name = 'Replica-$version-release.apk';
    final asset = (data['assets'] as List)
        .where((a) => a['name'] == name)
        .single;
    final uri = Uri.https(
      'github.com',
      '/$repository/releases/download/$tag/$name',
    );
    final digest = asset['digest'];
    final size = asset['size'];
    if (asset['browser_download_url'] != uri.toString() ||
        digest is! String ||
        !RegExp(r'^sha256:[a-f0-9]{64}$').hasMatch(digest) ||
        size is! int ||
        size < 1 ||
        size > _maxBytes) {
      throw const FormatException('릴리스 APK 정보를 확인할 수 없습니다.');
    }
    return AppRelease(version, uri, size, digest.substring(7));
  }
}

Future<AppRelease?> latestRelease(http.Client client, Version installed) async {
  final response = await client
      .get(
        Uri.https('api.github.com', '/repos/$repository/releases/latest'),
        headers: {'Accept': 'application/vnd.github+json'},
      )
      .timeout(const Duration(seconds: 12));
  if (response.statusCode == 404) return null;
  if (response.statusCode != 200) {
    throw HttpException('GitHub 응답 ${response.statusCode}');
  }
  return AppRelease.newer(
    jsonDecode(utf8.decode(response.bodyBytes)),
    installed,
  );
}

Future<File> downloadRelease(
  http.Client client,
  AppRelease release,
  Directory directory,
  void Function(double) progress,
) async {
  final file = File('${directory.path}/Replica-${release.version}.apk');
  final partial = File(
    '${file.path}.${DateTime.now().microsecondsSinceEpoch}.part',
  );
  try {
    final response = await client
        .send(http.Request('GET', release.uri))
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw HttpException('다운로드 응답 ${response.statusCode}');
    }
    final sink = partial.openWrite();
    var count = 0;
    try {
      await sink.addStream(
        response.stream.timeout(const Duration(seconds: 30)).map((chunk) {
          count += chunk.length;
          if (count > release.bytes) {
            throw const FormatException('APK 크기가 일치하지 않습니다.');
          }
          progress(count / release.bytes);
          return chunk;
        }),
      );
    } finally {
      await sink.close();
    }
    if (count != release.bytes ||
        (await sha256.bind(partial.openRead()).first).toString() !=
            release.digest) {
      throw const FormatException('APK 무결성 검사에 실패했습니다.');
    }
    return await partial.rename(file.path);
  } finally {
    if (await partial.exists()) await partial.delete();
  }
}
