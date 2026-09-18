import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_bytes_cache_benchmark_compare/feed_corpus.dart';
import 'package:image_bytes_cache_benchmark_compare/profile_matrix.dart';

void main() {
  group('feed_corpus', () {
    test('feed URLs stay on bench.invalid and cycle unique slots', () {
      final urls = feedUrls(
        length: 8,
        contentMode: FeedContentMode.mixed,
      );
      expect(urls, hasLength(8));
      expect(urls.toSet(), hasLength(feedOrdinaryUniqueSlots));
      for (final url in urls) {
        expect(url, startsWith('https://bench.invalid/feed/'));
        expect(url, endsWith('.svg'));
      }
    });

    test('prose mode repeats one identical payload URL', () {
      final urls = feedUrls(
        length: 5,
        contentMode: FeedContentMode.prose,
      );
      expect(urls.toSet(), <String>{feedProseUrl()});
    });

    test('SVG payloads are well-formed UTF-8 and resolve by URL', () {
      final bytes = feedSvgBytes(slot: 2, minBytes: 512);
      final text = utf8.decode(bytes);
      expect(text, contains('<svg'));
      expect(text, contains('</svg>'));
      expect(bytes.length, greaterThanOrEqualTo(512));

      final fromUrl = feedPayloadForUrl(feedUrl(slot: 2));
      expect(fromUrl, isNotNull);
      if (fromUrl case final Uint8List resolved) {
        expect(utf8.decode(resolved), contains('<svg'));
      }
    });
  });
}
