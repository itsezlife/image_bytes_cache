import 'package:flutter_test/flutter_test.dart';
import 'package:image_bytes_cache/image_bytes_cache.dart';
import 'package:image_bytes_cache_flutter/image_bytes_cache_flutter.dart';

void main() {
  group('ImageFadeSkip', () {
    test('bitmask combines and contains', () {
      final both = ImageFadeSkip.imageCache | ImageFadeSkip.bytesCache;
      expect(both.contains(ImageFadeSkip.imageCache), isTrue);
      expect(both.contains(ImageFadeSkip.bytesCache), isTrue);
      expect(ImageFadeSkip.imageCache.contains(ImageFadeSkip.bytesCache), isFalse);
      expect(ImageFadeSkip.all, both);
    });
  });

  group('ImageFadePolicy.shouldSkip', () {
    test('standard skips sync imageCache hits', () {
      expect(
        ImageFadePolicy.standard.shouldSkip(
          wasSynchronouslyLoaded: true,
          origin: ImageBytesOrigin.network,
        ),
        isTrue,
      );
    });

    test('standard skips bytesCache when origin is cache', () {
      expect(
        ImageFadePolicy.standard.shouldSkip(
          wasSynchronouslyLoaded: false,
          origin: ImageBytesOrigin.cache,
        ),
        isTrue,
      );
    });

    test('standard does not skip for bytesCache when origin is absent', () {
      expect(
        ImageFadePolicy.standard.shouldSkip(
          wasSynchronouslyLoaded: false,
          origin: null,
        ),
        isFalse,
      );
    });

    test('standard does not skip async network origin', () {
      expect(
        ImageFadePolicy.standard.shouldSkip(
          wasSynchronouslyLoaded: false,
          origin: ImageBytesOrigin.network,
        ),
        isFalse,
      );
    });

    test('always never skips', () {
      expect(
        ImageFadePolicy.always.shouldSkip(
          wasSynchronouslyLoaded: true,
          origin: ImageBytesOrigin.cache,
        ),
        isFalse,
      );
    });

    test('never always skips', () {
      expect(
        ImageFadePolicy.never.shouldSkip(
          wasSynchronouslyLoaded: false,
          origin: ImageBytesOrigin.network,
        ),
        isTrue,
      );
    });

    test('custom mask honors only declared bits', () {
      const policy = ImageFadePolicy(ImageFadeSkip.imageCache);
      expect(
        policy.shouldSkip(
          wasSynchronouslyLoaded: false,
          origin: ImageBytesOrigin.cache,
        ),
        isFalse,
      );
      expect(
        policy.shouldSkip(
          wasSynchronouslyLoaded: true,
          origin: ImageBytesOrigin.cache,
        ),
        isTrue,
      );
    });
  });
}
