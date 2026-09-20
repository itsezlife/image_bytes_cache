import 'dart:typed_data';

import 'package:image_bytes_cache/image_bytes_cache.dart';
import 'package:test/test.dart';

void main() {
  group('MiddlewareImageBytesCache', () {
    test('forwards write then read through an empty chain to Memory', () async {
      final inner = MemoryImageBytesCache();
      final cache = MiddlewareImageBytesCache(inner: inner);
      const key = ImageCacheKey('logo');
      final bytes = Uint8List.fromList([1, 2, 3]);

      await cache.write(key, bytes);

      expect(await cache.read(key), bytes);
      expect(await inner.read(key), bytes);
    });

    test('public read unwraps a rich hit to Uint8List?', () async {
      final inner = MemoryImageBytesCache();
      final cache = MiddlewareImageBytesCache(
        inner: inner,
        middlewares: <CacheMiddleware>[
          (innerHandler) => (operation, context) async {
            final result = await innerHandler(operation, context);
            return switch (result) {
              CacheOperationResult$Read(:final hit?) => CacheOperationResult$Read(
                CacheReadHit(
                  bytes: hit.bytes,
                  writtenAt: hit.writtenAt,
                  accessedAt: hit.accessedAt,
                  httpCacheMeta: const ImageHttpCacheMeta(etag: '"abc"'),
                ),
              ),
              _ => result,
            };
          },
        ],
      );
      const key = ImageCacheKey('logo');
      final bytes = Uint8List.fromList([9]);
      await cache.write(key, bytes);

      expect(await cache.read(key), bytes);

      final rich = await cache.execute(const CacheOperation$Read(ImageCacheKey('logo')));
      expect(
        rich,
        isA<CacheOperationResult$Read>().having(
          (r) => r.hit?.httpCacheMeta?.etag,
          'etag',
          '"abc"',
        ),
      );
    });

    test('forwards evict, prune, and close to the inner store', () async {
      final inner = MemoryImageBytesCache(
        retention: const ImageBytesRetention.maxAge(Duration(hours: 1)),
      );
      final cache = MiddlewareImageBytesCache(inner: inner);
      const key = ImageCacheKey('logo');
      await cache.write(key, Uint8List.fromList([1]));

      await cache.evict(key);
      expect(await inner.read(key), isNull);

      await cache.write(key, Uint8List.fromList([2]));
      final report = await cache.prune();
      expect(report.evictedKeys, isEmpty);

      await cache.close();
      // Memory stays usable after close; forwarding must not throw.
      expect(await cache.read(key), Uint8List.fromList([2]));
    });

    test('middleware list is outermost-first (same fold as HTTP)', () async {
      final order = <String>[];
      CacheMiddleware named(String label) => (innerHandler) {
        return (operation, context) async {
          order.add('$label:before');
          final result = await innerHandler(operation, context);
          order.add('$label:after');
          return result;
        };
      };

      final cache = MiddlewareImageBytesCache(
        inner: MemoryImageBytesCache(),
        middlewares: <CacheMiddleware>[named('outer'), named('inner')],
      );
      await cache.write(const ImageCacheKey('k'), Uint8List.fromList([1]));

      expect(order, <String>[
        'outer:before',
        'inner:before',
        'inner:after',
        'outer:after',
      ]);
    });

    test('CacheOperation sealed set has no reclaim variant', () {
      // Exhaustiveness: adding CacheOperation$Reclaim would break this switch.
      String kind(CacheOperation op) => switch (op) {
        CacheOperation$Read() => 'read',
        CacheOperation$Write() => 'write',
        CacheOperation$Evict() => 'evict',
        CacheOperation$Prune() => 'prune',
        CacheOperation$Close() => 'close',
      };

      expect(kind(const CacheOperation$Read(ImageCacheKey('k'))), 'read');
      expect(
        kind(CacheOperation$Write(const ImageCacheKey('k'), Uint8List(0))),
        'write',
      );
      expect(kind(const CacheOperation$Evict(ImageCacheKey('k'))), 'evict');
      expect(kind(const CacheOperation$Prune()), 'prune');
      expect(kind(const CacheOperation$Close()), 'close');
    });

    test('execute passes CacheContext through the chain', () async {
      Object? seen;
      final cache = MiddlewareImageBytesCache(
        inner: MemoryImageBytesCache(),
        middlewares: <CacheMiddleware>[
          (innerHandler) => (operation, context) async {
            seen = context['probe'];
            return innerHandler(operation, context);
          },
        ],
      );
      final context = CacheContext.empty()..['probe'] = true;

      await cache.execute(
        const CacheOperation$Read(ImageCacheKey('missing')),
        context,
      );

      expect(seen, isTrue);
    });
  });
}
