import 'dart:typed_data';

import 'package:image_bytes_cache/src/image_bytes_cache.dart';
import 'package:test/test.dart';

void main() {
  group('MemoryImageBytesCache', () {
    test('write then read returns the same bytes', () async {
      final cache = MemoryImageBytesCache();
      const key = ImageCacheKey('logo');
      final bytes = Uint8List.fromList([1, 2, 3]);

      await cache.write(key, bytes);

      expect(await cache.read(key), bytes);
    });

    test('read miss returns null', () async {
      final cache = MemoryImageBytesCache();

      expect(await cache.read(const ImageCacheKey('missing')), isNull);
    });

    test('TTL: read after maxAge returns null and evicts', () async {
      var now = DateTime.utc(2024, 1, 1, 12);
      final cache = MemoryImageBytesCache(
        retention: const ImageBytesRetention.maxAge(Duration(hours: 1)),
        clock: () => now,
      );
      const key = ImageCacheKey('logo');
      await cache.write(key, Uint8List.fromList([1]));

      now = now.add(const Duration(hours: 2));

      expect(await cache.read(key), isNull);
      expect(await cache.read(key), isNull);
    });

    test('TTL: read within maxAge still hits', () async {
      var now = DateTime.utc(2024, 1, 1, 12);
      final cache = MemoryImageBytesCache(
        retention: const ImageBytesRetention.maxAge(Duration(hours: 1)),
        clock: () => now,
      );
      const key = ImageCacheKey('logo');
      final bytes = Uint8List.fromList([9]);
      await cache.write(key, bytes);

      now = now.add(const Duration(minutes: 30));

      expect(await cache.read(key), bytes);
    });

    test('maxEntries: write evicts oldest accessed', () async {
      var now = DateTime.utc(2024, 1, 1);
      final cache = MemoryImageBytesCache(
        retention: const ImageBytesRetention.maxEntries(2),
        clock: () => now,
      );

      await cache.write(const ImageCacheKey('a'), Uint8List.fromList([1]));
      now = now.add(const Duration(seconds: 1));
      await cache.write(const ImageCacheKey('b'), Uint8List.fromList([2]));
      now = now.add(const Duration(seconds: 1));
      // Touch a so b becomes oldest.
      await cache.read(const ImageCacheKey('a'));
      now = now.add(const Duration(seconds: 1));
      await cache.write(const ImageCacheKey('c'), Uint8List.fromList([3]));

      expect(await cache.read(const ImageCacheKey('a')), Uint8List.fromList([1]));
      expect(await cache.read(const ImageCacheKey('b')), isNull);
      expect(await cache.read(const ImageCacheKey('c')), Uint8List.fromList([3]));
    });

    test('prune removes expired and reports keys', () async {
      var now = DateTime.utc(2024, 6, 1);
      final cache = MemoryImageBytesCache(
        retention: const ImageBytesRetention.maxAge(Duration(days: 1)),
        clock: () => now,
      );
      await cache.write(const ImageCacheKey('old'), Uint8List.fromList([1]));
      now = now.add(const Duration(days: 2));
      await cache.write(const ImageCacheKey('fresh'), Uint8List.fromList([2]));

      final report = await cache.prune();

      expect(report.evictedKeys, [const ImageCacheKey('old')]);
      expect(await cache.read(const ImageCacheKey('old')), isNull);
      expect(await cache.read(const ImageCacheKey('fresh')), Uint8List.fromList([2]));
    });

    test('evict removes a single key', () async {
      final cache = MemoryImageBytesCache();
      const key = ImageCacheKey('logo');
      await cache.write(key, Uint8List.fromList([1]));

      await cache.evict(key);

      expect(await cache.read(key), isNull);
    });

    test('empty write is not retained as capacity waste', () async {
      final cache = MemoryImageBytesCache(
        retention: const ImageBytesRetention.maxEntries(1),
      );
      const emptyKey = ImageCacheKey('empty');
      const keepKey = ImageCacheKey('keep');

      await cache.write(emptyKey, Uint8List(0));
      expect(await cache.read(emptyKey), isNull);

      await cache.write(keepKey, Uint8List.fromList([1]));
      expect(await cache.read(keepKey), Uint8List.fromList([1]));
    });

    test('empty write evicts a previously stored payload for the same key', () async {
      final cache = MemoryImageBytesCache();
      const key = ImageCacheKey('logo');
      await cache.write(key, Uint8List.fromList([1, 2]));

      await cache.write(key, Uint8List(0));

      expect(await cache.read(key), isNull);
    });
  });

  group('NoOpImageBytesCache', () {
    test('read always returns null and write succeeds', () async {
      const cache = NoOpImageBytesCache();
      const key = ImageCacheKey('logo');

      await cache.write(key, Uint8List.fromList([1]));

      expect(await cache.read(key), isNull);
      expect(
        await cache.prune(),
        const ImageBytesPruneReport(evictedKeys: [], freedBytes: 0),
      );
    });
  });

  group('ImageCacheKey.fromUrl', () {
    test('produces safe key with host path and hash', () {
      final key = ImageCacheKey.fromUrl(
        'https://cdn.example.com/icons/logo.svg',
      );
      expect(key.value, contains('cdn_example_com'));
      expect(key.value, contains('logo'));
      expect(key.value, isNot(contains('/')));
      expect(key.value, isNot(contains(r'\')));
    });

    test('strips path traversal and reserved characters', () {
      final key = ImageCacheKey.fromUrl(
        'https://cdn.example.com/../../etc/passwd?x=1',
      );
      expect(key.value, isNot(contains('..')));
      expect(key.value, isNot(contains('/')));
    });

    test('different query strings yield different keys', () {
      final a = ImageCacheKey.fromUrl('https://x.test/a.svg?v=1');
      final b = ImageCacheKey.fromUrl('https://x.test/a.svg?v=2');
      expect(a, isNot(equals(b)));
    });

    test('different headers yield different keys', () {
      final a = ImageCacheKey.fromUrl(
        'https://x.test/a.svg',
        headers: const {'Authorization': 'a'},
      );
      final b = ImageCacheKey.fromUrl(
        'https://x.test/a.svg',
        headers: const {'Authorization': 'b'},
      );
      expect(a, isNot(equals(b)));
    });

    test('header key casing does not change identity', () {
      final a = ImageCacheKey.fromUrl(
        'https://x.test/a.svg',
        headers: const {'Authorization': 'token'},
      );
      final b = ImageCacheKey.fromUrl(
        'https://x.test/a.svg',
        headers: const {'authorization': 'token'},
      );
      expect(a, equals(b));
    });

    test('header key order does not change identity', () {
      final a = ImageCacheKey.fromUrl(
        'https://x.test/a.svg',
        headers: const {'a': '1', 'b': '2'},
      );
      final b = ImageCacheKey.fromUrl(
        'https://x.test/a.svg',
        headers: const {'b': '2', 'a': '1'},
      );
      expect(a, equals(b));
    });

    test('same basename under different paths yields different keys', () {
      final a = ImageCacheKey.fromUrl('https://x.test/foo/logo.svg');
      final b = ImageCacheKey.fromUrl('https://x.test/bar/logo.svg');
      expect(a, isNot(equals(b)));
    });

    test('long basename stays within length cap and remains distinct', () {
      final longName = '${'a' * 200}.svg';
      final a = ImageCacheKey.fromUrl('https://cdn.example.com/icons/$longName');
      final b = ImageCacheKey.fromUrl('https://cdn.example.com/other/$longName');
      expect(a.value.length, lessThanOrEqualTo(180));
      expect(b.value.length, lessThanOrEqualTo(180));
      expect(a, isNot(equals(b)));
    });

    test('relative and absolute Uri.base equivalents share one key', () {
      const relative = 'icons/logo.svg';
      final absolute = Uri.base.resolve(relative).toString();
      expect(ImageCacheKey.fromUrl(relative), equals(ImageCacheKey.fromUrl(absolute)));
    });

    test('URL containing |… without headers differs from clean URL plus those headers', () {
      final poisoned = ImageCacheKey.fromUrl(
        'https://cdn.example.com/a.svg|authorization=Bearer x',
      );
      final clean = ImageCacheKey.fromUrl(
        'https://cdn.example.com/a.svg',
        headers: const {'Authorization': 'Bearer x'},
      );
      expect(poisoned, isNot(equals(clean)));
    });

    test('pipe inside a header value cannot forge another URL+headers fingerprint', () {
      final withPipeInValue = ImageCacheKey.fromUrl(
        'https://cdn.example.com/a.svg',
        headers: const {'authorization': 'Bearer x|foo=bar'},
      );
      final withPipeInUrl = ImageCacheKey.fromUrl(
        'https://cdn.example.com/a.svg|authorization=Bearer x',
        headers: const {'foo': 'bar'},
      );
      expect(withPipeInValue, isNot(equals(withPipeInUrl)));
      // Same host/basename would still collide if fingerprint material used a
      // raw `url|headers` join — assert the trailing fingerprint segments differ.
      expect(
        withPipeInValue.value.substring(withPipeInValue.value.length - 12),
        isNot(equals(withPipeInUrl.value.substring(withPipeInUrl.value.length - 12))),
      );
    });
  });

  group('ImageBytesRetention.standard', () {
    test('includes maxAge, maxEntries, and maxBytes', () {
      final limits = ImageBytesRetention.standard.limits;
      expect(limits.maxAge, const Duration(days: 14));
      expect(limits.maxEntries, 500);
      expect(limits.maxBytes, 50 * 1024 * 1024);
    });
  });

  group('ImageBytesRetention capacity invariants', () {
    test('rejects non-positive maxEntries', () {
      expect(
        () => ImageBytesRetention.maxEntries(0),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => ImageBytesRetention.maxEntries(-1),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => ImageBytesRetention.compound(maxEntries: 0),
        throwsA(isA<AssertionError>()),
      );
    });

    test('rejects non-positive maxBytes', () {
      expect(
        () => ImageBytesRetention.maxBytes(0),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => ImageBytesRetention.maxBytes(-1),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => ImageBytesRetention.compound(maxBytes: 0),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('close', () {
    test('MemoryImageBytesCache close is idempotent', () async {
      final cache = MemoryImageBytesCache();
      await cache.close();
      await cache.close();
      await cache.write(const ImageCacheKey('logo'), Uint8List.fromList([1]));
      expect(
        await cache.read(const ImageCacheKey('logo')),
        Uint8List.fromList([1]),
      );
    });

    test('NoOpImageBytesCache close is idempotent', () async {
      const cache = NoOpImageBytesCache();
      await cache.close();
      await cache.close();
      expect(await cache.read(const ImageCacheKey('logo')), isNull);
    });
  });

  group('ImageBytesCache.configure', () {
    tearDown(() async {
      await ImageBytesCache.resetShared();
    });

    test('closes the previous shared instance before replace', () async {
      final first = _ClosableProbeCache();
      final second = _ClosableProbeCache();

      await ImageBytesCache.configure(first);
      expect(identical(ImageBytesCache.shared(), first), isTrue);

      first.onClose = () {
        expect(
          identical(ImageBytesCache.shared(), first),
          isTrue,
          reason: 'previous must still be shared until close finishes',
        );
      };

      await ImageBytesCache.configure(second);
      expect(identical(ImageBytesCache.shared(), second), isTrue);
      expect(first.closeCount, 1);
      expect(second.closeCount, 0);
    });

    test('resetShared closes then clears', () async {
      final probe = _ClosableProbeCache();
      await ImageBytesCache.configure(probe);
      probe.onClose = () {
        expect(
          identical(ImageBytesCache.shared(), probe),
          isTrue,
          reason: 'shared must stay until close finishes',
        );
      };

      await ImageBytesCache.resetShared();
      expect(probe.closeCount, 1);
      expect(ImageBytesCache.shared(), isA<NoOpImageBytesCache>());
    });
  });
}

final class _ClosableProbeCache implements IImageBytesCache {
  int closeCount = 0;
  void Function()? onClose;

  @override
  Future<Uint8List?> read(ImageCacheKey key) async => null;

  @override
  Future<void> write(ImageCacheKey key, Uint8List bytes, {ImageHttpCacheMeta? httpCacheMeta}) async {}

  @override
  Future<void> evict(ImageCacheKey key) async {}

  @override
  Future<ImageBytesPruneReport> prune() async => const ImageBytesPruneReport(evictedKeys: [], freedBytes: 0);

  @override
  Future<void> close() async {
    closeCount++;
    onClose?.call();
  }
}
