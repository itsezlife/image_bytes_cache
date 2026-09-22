import 'package:image_bytes_cache/src/image_bytes_cache.dart';
import 'package:image_bytes_cache/src/image_http_cache_freshness.dart';
import 'package:test/test.dart';

void main() {
  group('ImageHttpCacheFreshness.isFresh', () {
    final now = DateTime.utc(2024, 6, 1, 12);

    test('null / empty meta is fresh (pre-ETag retain until retention)', () {
      expect(ImageHttpCacheFreshness.isFresh(null, now: now), isTrue);
      expect(
        ImageHttpCacheFreshness.isFresh(const ImageHttpCacheMeta(), now: now),
        isTrue,
      );
    });

    test('validators without Cache-Control / Expires are stale', () {
      expect(
        ImageHttpCacheFreshness.isFresh(
          const ImageHttpCacheMeta(etag: '"v1"'),
          now: now,
        ),
        isFalse,
      );
      expect(
        ImageHttpCacheFreshness.isFresh(
          const ImageHttpCacheMeta(lastModified: 'Wed, 21 Oct 2015 07:28:00 GMT'),
          now: now,
        ),
        isFalse,
      );
    });

    test('max-age still within lifetime is fresh', () {
      final meta = ImageHttpCacheMeta(
        etag: '"v1"',
        cacheControl: 'max-age=3600',
        lastValidatedAt: now.subtract(const Duration(minutes: 10)),
      );
      expect(ImageHttpCacheFreshness.isFresh(meta, now: now), isTrue);
    });

    test('max-age past lifetime is stale', () {
      final meta = ImageHttpCacheMeta(
        etag: '"v1"',
        cacheControl: 'max-age=60',
        lastValidatedAt: now.subtract(const Duration(minutes: 5)),
      );
      expect(ImageHttpCacheFreshness.isFresh(meta, now: now), isFalse);
    });

    test('Age header counts toward current age', () {
      final meta = ImageHttpCacheMeta(
        etag: '"v1"',
        cacheControl: 'max-age=120',
        age: const Duration(seconds: 100),
        lastValidatedAt: now,
      );
      expect(ImageHttpCacheFreshness.isFresh(meta, now: now), isTrue);

      final stale = ImageHttpCacheMeta(
        etag: '"v1"',
        cacheControl: 'max-age=120',
        age: const Duration(seconds: 150),
        lastValidatedAt: now,
      );
      expect(ImageHttpCacheFreshness.isFresh(stale, now: now), isFalse);
    });

    test('Expires in the future is fresh; past is stale', () {
      final fresh = ImageHttpCacheMeta(
        etag: '"v1"',
        expires: now.add(const Duration(hours: 1)),
        date: now.subtract(const Duration(minutes: 1)),
        lastValidatedAt: now.subtract(const Duration(minutes: 1)),
      );
      expect(ImageHttpCacheFreshness.isFresh(fresh, now: now), isTrue);

      final stale = ImageHttpCacheMeta(
        etag: '"v1"',
        expires: now.subtract(const Duration(minutes: 1)),
        date: now.subtract(const Duration(hours: 1)),
        lastValidatedAt: now.subtract(const Duration(hours: 1)),
      );
      expect(ImageHttpCacheFreshness.isFresh(stale, now: now), isFalse);
    });

    test('Expires-only meta uses absolute wall time', () {
      expect(
        ImageHttpCacheFreshness.isFresh(
          ImageHttpCacheMeta(expires: now.add(const Duration(hours: 1))),
          now: now,
        ),
        isTrue,
      );
      expect(
        ImageHttpCacheFreshness.isFresh(
          ImageHttpCacheMeta(expires: now.subtract(const Duration(minutes: 1))),
          now: now,
        ),
        isFalse,
      );
    });

    test('no-cache and must-revalidate are always stale', () {
      expect(
        ImageHttpCacheFreshness.isFresh(
          const ImageHttpCacheMeta(etag: '"v1"', cacheControl: 'no-cache'),
          now: now,
        ),
        isFalse,
      );
      expect(
        ImageHttpCacheFreshness.isFresh(
          const ImageHttpCacheMeta(etag: '"v1"', cacheControl: 'max-age=3600, must-revalidate'),
          now: now,
        ),
        isFalse,
      );
    });

    test('immutable is fresh even with validators', () {
      expect(
        ImageHttpCacheFreshness.isFresh(
          ImageHttpCacheMeta(
            etag: '"static"',
            cacheControl: 'public, max-age=0, immutable',
            lastValidatedAt: now.subtract(const Duration(days: 30)),
          ),
          now: now,
        ),
        isTrue,
      );
    });
  });

  group('ImageHttpCacheFreshness.fromResponseHeaders', () {
    test('captures validators and freshness fields', () {
      final validatedAt = DateTime.utc(2024, 6, 1, 12);
      final meta = ImageHttpCacheFreshness.fromResponseHeaders(
        {
          'ETag': '"abc"',
          'Last-Modified': 'Wed, 21 Oct 2015 07:28:00 GMT',
          'Cache-Control': 'max-age=60',
          'Date': 'Sat, 01 Jun 2024 12:00:00 GMT',
          'Age': '12',
        },
        validatedAt: validatedAt,
      );

      expect(meta?.etag, '"abc"');
      expect(meta?.lastModified, 'Wed, 21 Oct 2015 07:28:00 GMT');
      expect(meta?.cacheControl, 'max-age=60');
      expect(meta?.date, DateTime.utc(2024, 6, 1, 12));
      expect(meta?.age, const Duration(seconds: 12));
      expect(meta?.lastValidatedAt, validatedAt);
    });

    test('empty headers yield null', () {
      expect(
        ImageHttpCacheFreshness.fromResponseHeaders(
          const {},
          validatedAt: DateTime.utc(2024, 1, 1),
        ),
        isNull,
      );
    });
  });

  group('ImageHttpCacheFreshness.afterNotModified', () {
    test('keeps prior etag when 304 omits it and bumps lastValidatedAt', () {
      const prior = ImageHttpCacheMeta(
        etag: '"old"',
        cacheControl: 'max-age=60',
      );
      final validatedAt = DateTime.utc(2024, 6, 2);
      final next = ImageHttpCacheFreshness.afterNotModified(
        prior,
        headers: const {'cache-control': 'max-age=120'},
        validatedAt: validatedAt,
      );

      expect(next.etag, '"old"');
      expect(next.cacheControl, 'max-age=120');
      expect(next.lastValidatedAt, validatedAt);
    });
  });
}
