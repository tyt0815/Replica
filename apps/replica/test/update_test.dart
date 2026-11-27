import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:replica/update.dart';

void main() {
  final body = utf8.encode('test apk');
  final digest = sha256.convert(body).toString();
  const name = 'Replica-0.2.0-release.apk';
  final asset = {
    'name': name,
    'size': body.length,
    'digest': 'sha256:$digest',
    'browser_download_url':
        'https://github.com/tyt0815/Replica/releases/download/v0.2.0/$name',
  };
  final metadata = {
    'tag_name': 'v0.2.0',
    'assets': [asset],
  };
  final older = Version.parse('0.1.0');
  test('현재 버전과 시험 릴리스는 업데이트에서 제외한다', () {
    expect(AppRelease.newer(metadata, Version.parse('0.2.0')), isNull);
    expect(AppRelease.newer({...metadata, 'prerelease': true}, older), isNull);
  });
  test('다른 저장소의 APK는 거부한다', () {
    expect(
      () => AppRelease.newer({
        ...metadata,
        'assets': [
          {...asset, 'browser_download_url': 'https://example.org/test.apk'},
        ],
      }, older),
      throwsFormatException,
    );
  });
  test('GitHub 최신 릴리스에서 받은 크기와 SHA-256을 확인한다', () async {
    final client = MockClient(
      (req) async => req.url.host == 'api.github.com'
          ? http.Response(jsonEncode(metadata), 200)
          : http.Response.bytes(body, 200),
    );
    addTearDown(client.close);
    final dir = await Directory.systemTemp.createTemp();
    addTearDown(() => dir.delete(recursive: true));
    final release = (await latestRelease(client, older))!;
    final apk = await downloadRelease(client, release, dir, (_) {});
    expect(await apk.readAsBytes(), body);
    final bad = AppRelease(
      release.version,
      release.uri,
      release.bytes,
      '0' * 64,
    );
    await expectLater(
      downloadRelease(client, bad, dir, (_) {}),
      throwsFormatException,
    );
    expect(await dir.list().length, 1);
    expect(await apk.readAsBytes(), body);
  });
}
