import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

class Track {
  const Track(this.id, this.title, this.artist, this.thumbnail);

  final String id;
  final String title;
  final String artist;
  final String thumbnail;
}

Future<List<Track>> searchVideos(String query) async {
  final response = await http
      .get(
        Uri.https('www.youtube.com', '/results', {
          'search_query': query,
          'hl': 'ko',
        }),
        headers: {
          'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/131.0.0.0 Safari/537.36',
        },
      )
      .timeout(const Duration(seconds: 20));
  if (response.statusCode != 200) {
    throw StateError('검색 서버 응답 오류 (${response.statusCode})');
  }
  final html = utf8.decode(response.bodyBytes);
  final start = RegExp(r'var ytInitialData\s*=\s*').firstMatch(html)?.end;
  final end = start == null ? -1 : html.indexOf('</script>', start);
  if (start == null || end < start) {
    throw const FormatException('검색 페이지에서 결과를 찾을 수 없습니다.');
  }
  final data = html
      .substring(start, end)
      .trimRight()
      .replaceFirst(RegExp(r';$'), '');
  final result = await const MethodChannel('replica/search')
      .invokeMethod<String>('parse', data);
  final rows = jsonDecode(result!) as List;
  return rows
      .map((r) => Track(r['id'], r['title'], r['artist'], r['thumbnail']))
      .toList();
}
