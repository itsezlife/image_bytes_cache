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
        expect(url, endsWith('.png'));
      }
    });

    test('prose mode repeats one identical payload URL', () {
      final urls = feedUrls(
        length: 5,
        contentMode: FeedContentMode.prose,
      );
      expect(urls.toSet(), <String>{feedProseUrl()});
    });

    test('PNG payloads carry signature, meet minBytes, resolve by URL', () {
      final bytes = feedPngBytes(slot: 2, minBytes: feedSmallMinBytes);
      expect(isPngSignature(bytes), isTrue);
      expect(bytes.length, greaterThanOrEqualTo(feedSmallMinBytes));

      final fromUrl = feedPayloadForUrl(feedUrl(slot: 2));
      expect(fromUrl, isNotNull);
      if (fromUrl case final Uint8List resolved) {
        expect(isPngSignature(resolved), isTrue);
      }
    });

    test('large PNG meets the 64 KiB cut with PNG signature', () {
      final large = feedPngBytes(slot: 1, minBytes: feedLargeMinBytes);
      expect(isPngSignature(large), isTrue);
      expect(large.length, greaterThanOrEqualTo(feedLargeMinBytes));
    });
  });
}
