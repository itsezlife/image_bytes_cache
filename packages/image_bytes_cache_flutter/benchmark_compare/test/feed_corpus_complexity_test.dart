import 'package:flutter_test/flutter_test.dart';
import 'package:image_bytes_cache_benchmark_compare/feed_corpus.dart';
import 'package:image_bytes_cache_benchmark_compare/profile_matrix.dart';

void main() {
  group('ordinary vs complicated feed corpus', () {
    test('ordinary keeps few unique URLs and only small bodies', () {
      final urls = feedUrls(
        length: 48,
        complexity: FeedComplexity.ordinary,
      );
      expect(urls.toSet(), hasLength(feedOrdinaryUniqueSlots));
      for (final url in urls) {
        final bytes = feedPayloadForUrl(url);
        expect(bytes, isNotNull);
        expect(bytes!.length, lessThan(64 * 1024));
      }
    });

    test('complicated has many distinct keys under the same list length', () {
      final ordinary = feedUrls(
        length: 48,
        complexity: FeedComplexity.ordinary,
      );
      final complicated = feedUrls(
        length: 48,
        complexity: FeedComplexity.complicated,
      );
      expect(
        complicated.toSet().length,
        greaterThan(ordinary.toSet().length),
      );
      expect(
        complicated.toSet().length,
        greaterThanOrEqualTo(feedComplicatedMinUniqueKeys),
      );
    });

    test('complicated mixes under and over the 64 KiB cut', () {
      final urls = feedUrls(
        length: 48,
        complexity: FeedComplexity.complicated,
      );
      var under = 0;
      var over = 0;
      for (final url in urls.toSet()) {
        final bytes = feedPayloadForUrl(url)!;
        if (bytes.length < 64 * 1024) {
          under++;
        } else {
          over++;
        }
      }
      expect(under, greaterThan(0));
      expect(over, greaterThan(0));
    });

    test('complicated includes in-view coalesce bursts (consecutive dupes)', () {
      final urls = feedUrls(
        length: 48,
        complexity: FeedComplexity.complicated,
      );
      var foundBurst = false;
      for (var i = 0; i < urls.length - 2; i++) {
        if (urls[i] == urls[i + 1] && urls[i] == urls[i + 2]) {
          foundBurst = true;
          break;
        }
      }
      expect(foundBurst, isTrue);
    });

    test('ordinary has no three-in-a-row coalesce burst', () {
      final urls = feedUrls(
        length: 48,
        complexity: FeedComplexity.ordinary,
      );
      for (var i = 0; i < urls.length - 2; i++) {
        expect(
          urls[i] == urls[i + 1] && urls[i] == urls[i + 2],
          isFalse,
        );
      }
    });
  });
}
