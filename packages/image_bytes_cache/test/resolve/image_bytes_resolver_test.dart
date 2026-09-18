import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_bytes_cache/src/http_bytes_fetcher.dart';
import 'package:image_bytes_cache/src/image_bytes_cache.dart';
import 'package:image_bytes_cache/src/image_bytes_diagnostics.dart';
import 'package:image_bytes_cache/src/image_bytes_resolver.dart';
import 'package:test/test.dart';

void main() {
  group('ImageBytesResolver.resolve', () {
    test('network miss fetches once and write-through to cache', () async {
      var hits = 0;
      final body = Uint8List.fromList([7, 8, 9]);
      final fetcher = HttpBytesFetcher(
        client: MockClient((_) async {
          hits++;
          return http.Response.bytes(body, 200);
        }),
      );
      addTearDown(fetcher.close);

      final cache = MemoryImageBytesCache();
      final resolver = ImageBytesResolver(cache: cache, fetcher: fetcher);

      final bytes = await resolver.resolve(
        const ImageBytesRequest(url: 'https://cdn.example.com/a.svg'),
      );

      expect(bytes, body);
      expect(hits, 1);
      expect(
        await cache.read(ImageCacheKey.fromUrl('https://cdn.example.com/a.svg')),
        body,
      );
    });

    test('cache hit skips HTTP', () async {
      var hits = 0;
      final fetcher = HttpBytesFetcher(
        client: MockClient((_) async {
          hits++;
          return http.Response.bytes(Uint8List.fromList([1]), 200);
        }),
      );
      addTearDown(fetcher.close);

      final cache = MemoryImageBytesCache();
      const url = 'https://cdn.example.com/cached.svg';
      final key = ImageCacheKey.fromUrl(url);
      await cache.write(key, Uint8List.fromList([4, 5, 6]));

      final resolver = ImageBytesResolver(cache: cache, fetcher: fetcher);
      final bytes = await resolver.resolve(const ImageBytesRequest(url: url));

      expect(bytes, Uint8List.fromList([4, 5, 6]));
      expect(hits, 0);
    });

    test('write-through failure still returns network bytes and reports', () async {
      final body = Uint8List.fromList([1, 2, 3]);
      final fetcher = HttpBytesFetcher(
        client: MockClient((_) async => http.Response.bytes(body, 200)),
      );
      addTearDown(fetcher.close);

      final events = <ImageBytesLogEvent>[];
      final resolver = ImageBytesResolver(
        cache: const _ThrowingWriteImageBytesCache(),
        fetcher: fetcher,
        diagnostics: ImageBytesDiagnostics.onEvent(events.add),
      );

      final bytes = await resolver.resolve(
        const ImageBytesRequest(url: 'https://cdn.example.com/fail-write.svg'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(bytes, body);
      expect(events, hasLength(1));
      expect(events.single.op, ImageBytesLogOp.writeThrough);
      expect(events.single.level, ImageBytesLogLevel.error);
      expect(events.single.message, contains('write-through failed'));
    });

    test('silent diagnostics emits nothing on write-through failure', () async {
      final body = Uint8List.fromList([9]);
      final fetcher = HttpBytesFetcher(
        client: MockClient((_) async => http.Response.bytes(body, 200)),
      );
      addTearDown(fetcher.close);

      final events = <ImageBytesLogEvent>[];
      ImageBytesDiagnostics.current = ImageBytesDiagnostics.onEvent(events.add);
      addTearDown(ImageBytesCache.resetShared);

      final resolver = ImageBytesResolver(
        cache: const _ThrowingWriteImageBytesCache(),
        fetcher: fetcher,
        diagnostics: const ImageBytesDiagnostics.silent(),
      );

      expect(
        await resolver.resolve(
          const ImageBytesRequest(url: 'https://cdn.example.com/silent.svg'),
        ),
        body,
      );
      await Future<void>.delayed(Duration.zero);
      expect(events, isEmpty);
    });
  });
}

/// Always misses; [write] always throws (simulates durable store failure).
final class _ThrowingWriteImageBytesCache implements IImageBytesCache {
  const _ThrowingWriteImageBytesCache();

  @override
  Future<Uint8List?> read(ImageCacheKey key) async => null;

  @override
  Future<void> write(ImageCacheKey key, Uint8List bytes) async {
    throw StateError('simulated durable write failure');
  }

  @override
  Future<void> evict(ImageCacheKey key) async {}

  @override
  Future<ImageBytesPruneReport> prune() async => const ImageBytesPruneReport(evictedKeys: [], freedBytes: 0);

  @override
  Future<void> close() async {}
}
