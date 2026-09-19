import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_bytes_cache/src/http/http_bytes_client.dart';
import 'package:image_bytes_cache/src/image_bytes_cache.dart';
import 'package:image_bytes_cache/src/image_bytes_diagnostics.dart';
import 'package:image_bytes_cache/src/image_bytes_resolver.dart';
import 'package:test/test.dart';

void main() {
  group('ImageBytesResolver.resolve', () {
    test('network miss fetches once and write-through to cache', () async {
      var hits = 0;
      final body = Uint8List.fromList([7, 8, 9]);
      final client = HttpBytesClient(
        client: MockClient((_) async {
          hits++;
          return http.Response.bytes(body, 200);
        }),
      );
      addTearDown(client.close);

      final cache = MemoryImageBytesCache();
      final resolver = ImageBytesResolver(cache: cache, client: client);

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
      final client = HttpBytesClient(
        client: MockClient((_) async {
          hits++;
          return http.Response.bytes(Uint8List.fromList([1]), 200);
        }),
      );
      addTearDown(client.close);

      final cache = MemoryImageBytesCache();
      const url = 'https://cdn.example.com/cached.svg';
      final key = ImageCacheKey.fromUrl(url);
      await cache.write(key, Uint8List.fromList([4, 5, 6]));

      final resolver = ImageBytesResolver(cache: cache, client: client);
      final bytes = await resolver.resolve(const ImageBytesRequest(url: url));

      expect(bytes, Uint8List.fromList([4, 5, 6]));
      expect(hits, 0);
    });

    test('network miss forwards onBytesProgress from the request', () async {
      final reports = <(int cumulative, int? total)>[];
      final client = HttpBytesClient(
        client: _ResolverChunkedBodyClient(
          chunks: [
            [1, 2, 3],
            [4],
          ],
          contentLength: 4,
        ),
      );
      addTearDown(client.close);

      final resolver = ImageBytesResolver(
        cache: MemoryImageBytesCache(),
        client: client,
      );

      final bytes = await resolver.resolve(
        ImageBytesRequest(
          url: 'https://cdn.example.com/progress.svg',
          onBytesProgress: (cumulative, total) => reports.add((cumulative, total)),
        ),
      );

      expect(bytes, Uint8List.fromList([1, 2, 3, 4]));
      expect(reports, [(3, 4), (4, 4)]);
    });

    test('durable cache hit does not synthesize mid-download progress', () async {
      var hits = 0;
      final reports = <(int cumulative, int? total)>[];
      final client = HttpBytesClient(
        client: MockClient((_) async {
          hits++;
          return http.Response.bytes(Uint8List.fromList([1]), 200);
        }),
      );
      addTearDown(client.close);

      final cache = MemoryImageBytesCache();
      const url = 'https://cdn.example.com/warm.svg';
      await cache.write(ImageCacheKey.fromUrl(url), Uint8List.fromList([9, 9]));

      final resolver = ImageBytesResolver(cache: cache, client: client);
      final bytes = await resolver.resolve(
        ImageBytesRequest(
          url: url,
          onBytesProgress: (cumulative, total) => reports.add((cumulative, total)),
        ),
      );

      expect(bytes, Uint8List.fromList([9, 9]));
      expect(hits, 0);
      expect(reports, isEmpty);
    });

    test('empty cached payload counts as miss and fetches network', () async {
      var hits = 0;
      final body = Uint8List.fromList([8, 8]);
      final client = HttpBytesClient(
        client: MockClient((_) async {
          hits++;
          return http.Response.bytes(body, 200);
        }),
      );
      addTearDown(client.close);

      final cache = _StickyEmptyImageBytesCache();
      const url = 'https://cdn.example.com/empty-cached.svg';
      final resolver = ImageBytesResolver(cache: cache, client: client);

      expect(await resolver.resolve(const ImageBytesRequest(url: url)), body);
      expect(hits, 1);
    });

    test('write-through failure still returns network bytes and reports', () async {
      final body = Uint8List.fromList([1, 2, 3]);
      final client = HttpBytesClient(
        client: MockClient((_) async => http.Response.bytes(body, 200)),
      );
      addTearDown(client.close);

      final events = <ImageBytesLogEvent>[];
      final resolver = ImageBytesResolver(
        cache: const _ThrowingWriteImageBytesCache(),
        client: client,
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

    test('index commit failure on write-through still returns network bytes', () async {
      final body = Uint8List.fromList([5, 5]);
      final client = HttpBytesClient(
        client: MockClient((_) async => http.Response.bytes(body, 200)),
      );
      addTearDown(client.close);

      final index = _CommitFailingIndex();
      final blobs = _MapBlobStore();
      final cache = IndexedImageBytesCache(
        index: index,
        blobs: blobs,
        retention: const ImageBytesRetention.unlimited(),
      );
      final events = <ImageBytesLogEvent>[];
      final resolver = ImageBytesResolver(
        cache: cache,
        client: client,
        diagnostics: ImageBytesDiagnostics.onEvent(events.add),
      );
      const url = 'https://cdn.example.com/commit-fail.svg';

      final bytes = await resolver.resolve(const ImageBytesRequest(url: url));
      await Future<void>.delayed(Duration.zero);

      expect(bytes, body);
      expect(events, hasLength(1));
      expect(events.single.op, ImageBytesLogOp.writeThrough);
      // No optimistic RAM hit after the failed commit.
      expect(await cache.read(ImageCacheKey.fromUrl(url)), isNull);
    });

    test('throwing onEvent during write-through catch is not an unhandled async error', () async {
      final body = Uint8List.fromList([4, 4, 4]);
      final client = HttpBytesClient(
        client: MockClient((_) async => http.Response.bytes(body, 200)),
      );
      addTearDown(client.close);

      final errors = <Object>[];
      await runZonedGuarded(
        () async {
          final resolver = ImageBytesResolver(
            cache: const _ThrowingWriteImageBytesCache(),
            client: client,
            diagnostics: ImageBytesDiagnostics.onEvent((_) {
              throw StateError('host diagnostics blew up');
            }),
          );

          expect(
            await resolver.resolve(
              const ImageBytesRequest(url: 'https://cdn.example.com/diag-throw.svg'),
            ),
            body,
          );
          // Let the unawaited write-through catch + report run.
          await Future<void>.delayed(Duration.zero);
          await Future<void>.delayed(Duration.zero);
        },
        (error, _) => errors.add(error),
      );

      expect(
        errors,
        isEmpty,
        reason: 'throwing onEvent must not escape as an unhandled async error',
      );
    });

    test('silent diagnostics emits nothing on write-through failure', () async {
      final body = Uint8List.fromList([9]);
      final client = HttpBytesClient(
        client: MockClient((_) async => http.Response.bytes(body, 200)),
      );
      addTearDown(client.close);

      final events = <ImageBytesLogEvent>[];
      ImageBytesDiagnostics.current = ImageBytesDiagnostics.onEvent(events.add);
      addTearDown(ImageBytesCache.resetShared);

      final resolver = ImageBytesResolver(
        cache: const _ThrowingWriteImageBytesCache(),
        client: client,
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

    test('relative and absolute Uri.base equivalents share one durable key', () async {
      var hits = 0;
      final body = Uint8List.fromList([3, 3, 3]);
      final client = HttpBytesClient(
        client: MockClient((_) async {
          hits++;
          return http.Response.bytes(body, 200);
        }),
      );
      addTearDown(client.close);

      final cache = MemoryImageBytesCache();
      final resolver = ImageBytesResolver(cache: cache, client: client);

      const relative = 'icons/shared.svg';
      final absolute = Uri.base.resolve(relative).toString();

      expect(await resolver.resolve(const ImageBytesRequest(url: relative)), body);
      await Future<void>.delayed(Duration.zero);

      expect(await resolver.resolve(ImageBytesRequest(url: absolute)), body);
      expect(hits, 1);
      expect(await cache.read(ImageCacheKey.fromUrl(relative)), body);
      expect(await cache.read(ImageCacheKey.fromUrl(absolute)), body);
    });

    test('explicit cacheKey is full identity — headers do not change the key', () async {
      var hits = 0;
      final body = Uint8List.fromList([2, 2]);
      final client = HttpBytesClient(
        client: MockClient((request) async {
          hits++;
          expect(request.headers['authorization'], isNotNull);
          return http.Response.bytes(body, 200);
        }),
      );
      addTearDown(client.close);

      final cache = MemoryImageBytesCache();
      final resolver = ImageBytesResolver(cache: cache, client: client);
      const key = ImageCacheKey('host_override_key');

      await resolver.resolve(
        const ImageBytesRequest(
          url: 'https://cdn.example.com/a.svg',
          headers: {'Authorization': 'Bearer a'},
          cacheKey: key,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(await cache.read(key), body);

      // Different Authorization still on the wire for a miss path, but the
      // durable slot is the explicit key — a warm hit must not key on headers.
      expect(
        await resolver.resolve(
          const ImageBytesRequest(
            url: 'https://cdn.example.com/a.svg',
            headers: {'Authorization': 'Bearer b'},
            cacheKey: key,
          ),
        ),
        body,
      );
      expect(hits, 1);
    });
  });

  group('ImageBytesResolver.shared live wiring', () {
    tearDown(() async {
      await ImageBytesCache.resetShared();
      HttpBytesClient.debugShared = null;
      ImageBytesResolver.debugShared = null;
    });

    test('resolve after prior shared call then configure hits the configured store', () async {
      final body = Uint8List.fromList([3, 2, 1]);
      HttpBytesClient.debugShared = HttpBytesClient(
        client: MockClient((_) async => http.Response.bytes(body, 200)),
      );

      // Bootstrap race: paint may call shared() before configure.
      final sharedBeforeConfigure = ImageBytesResolver.shared();
      await sharedBeforeConfigure.resolve(
        const ImageBytesRequest(url: 'https://cdn.example.com/pre-configure.svg'),
      );

      final store = MemoryImageBytesCache();
      await ImageBytesCache.configure(store);

      await ImageBytesResolver.shared().resolve(
        const ImageBytesRequest(url: 'https://cdn.example.com/after-configure.svg'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(
        await store.read(ImageCacheKey.fromUrl('https://cdn.example.com/after-configure.svg')),
        body,
        reason: 'shared resolve must use the configured store, not a snapped NoOp',
      );
    });

    test('configure replacement does not leave shared resolve on a closed previous cache', () async {
      final body = Uint8List.fromList([9, 8, 7]);
      HttpBytesClient.debugShared = HttpBytesClient(
        client: MockClient((_) async => http.Response.bytes(body, 200)),
      );

      final first = _CloseRejectingImageBytesCache();
      await ImageBytesCache.configure(first);
      await ImageBytesResolver.shared().resolve(
        const ImageBytesRequest(url: 'https://cdn.example.com/first.svg'),
      );
      await Future<void>.delayed(Duration.zero);

      final second = MemoryImageBytesCache();
      await ImageBytesCache.configure(second);
      expect(first.closed, isTrue, reason: 'configure must close the previous store');

      // Would throw if shared resolve still held the closed previous cache.
      await ImageBytesResolver.shared().resolve(
        const ImageBytesRequest(url: 'https://cdn.example.com/second.svg'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(
        await second.read(ImageCacheKey.fromUrl('https://cdn.example.com/second.svg')),
        body,
      );
    });

    test('resetShared clears shared wiring so later configure is visible', () async {
      final body = Uint8List.fromList([5]);
      HttpBytesClient.debugShared = HttpBytesClient(
        client: MockClient((_) async => http.Response.bytes(body, 200)),
      );

      final first = MemoryImageBytesCache();
      await ImageBytesCache.configure(first);
      await ImageBytesResolver.shared().resolve(
        const ImageBytesRequest(url: 'https://cdn.example.com/before-reset.svg'),
      );

      await ImageBytesCache.resetShared();

      // resetShared clears client debugShared too; re-install a mock for the
      // post-reset resolve (no public internet in this suite).
      HttpBytesClient.debugShared = HttpBytesClient(
        client: MockClient((_) async => http.Response.bytes(body, 200)),
      );

      final second = MemoryImageBytesCache();
      await ImageBytesCache.configure(second);
      await ImageBytesResolver.shared().resolve(
        const ImageBytesRequest(url: 'https://cdn.example.com/after-reset.svg'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(
        await second.read(ImageCacheKey.fromUrl('https://cdn.example.com/after-reset.svg')),
        body,
      );
    });

    test('HttpBytesClient.configure is visible to shared resolve without injecting a resolver', () async {
      final body = Uint8List.fromList([4, 5, 6]);
      await ImageBytesCache.configure(MemoryImageBytesCache());
      await HttpBytesClient.configure(
        HttpBytesClient(
          client: MockClient((_) async => http.Response.bytes(body, 200)),
        ),
      );

      final bytes = await ImageBytesResolver.shared().resolve(
        const ImageBytesRequest(url: 'https://cdn.example.com/configured-client.svg'),
      );

      expect(bytes, body);
    });
  });
}

/// Always "hits" with an empty payload (legacy sticky empty durable row).
final class _StickyEmptyImageBytesCache implements IImageBytesCache {
  @override
  Future<Uint8List?> read(ImageCacheKey key) async => Uint8List(0);

  @override
  Future<void> write(ImageCacheKey key, Uint8List bytes) async {}

  @override
  Future<void> evict(ImageCacheKey key) async {}

  @override
  Future<ImageBytesPruneReport> prune() async => const ImageBytesPruneReport(evictedKeys: [], freedBytes: 0);

  @override
  Future<void> close() async {}
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

/// Durable-like store: ops throw after [close] (Memory/NoOp stay usable).
final class _CloseRejectingImageBytesCache implements IImageBytesCache {
  bool closed = false;
  final Map<ImageCacheKey, Uint8List> _entries = {};

  void _ensureOpen() {
    if (closed) {
      throw StateError('cache is closed');
    }
  }

  @override
  Future<Uint8List?> read(ImageCacheKey key) async {
    _ensureOpen();
    return _entries[key];
  }

  @override
  Future<void> write(ImageCacheKey key, Uint8List bytes) async {
    _ensureOpen();
    _entries[key] = bytes;
  }

  @override
  Future<void> evict(ImageCacheKey key) async {
    _ensureOpen();
    _entries.remove(key);
  }

  @override
  Future<ImageBytesPruneReport> prune() async {
    _ensureOpen();
    return const ImageBytesPruneReport(evictedKeys: [], freedBytes: 0);
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

/// RAM index whose [commit] always throws (simulates durable meta failure).
final class _CommitFailingIndex implements IImageBytesIndex {
  final Map<String, ImageBytesRecord> records = {};

  @override
  Future<ImageBytesRecord?> get(ImageCacheKey key) async => records[key.value];

  @override
  Future<void> put(ImageBytesRecord record) async {
    records[record.key.value] = record;
  }

  @override
  Future<void> delete(ImageCacheKey key) async {
    records.remove(key.value);
  }

  @override
  Future<Iterable<ImageBytesRecord>> values() async => records.values;

  @override
  Future<void> commit() async {
    throw StateError('simulated durable index commit failure');
  }
}

final class _MapBlobStore implements IImageBytesBlobStore {
  final Map<String, Uint8List> store = {};

  @override
  Future<Uint8List?> read(ImageCacheKey key, {int? knownByteLength}) async => store[key.value];

  @override
  Future<void> write(ImageCacheKey key, Uint8List bytes) async {
    store[key.value] = bytes;
  }

  @override
  Future<void> delete(ImageCacheKey key) async {
    store.remove(key.value);
  }
}

/// Streams body chunks so resolver progress forwarding can be observed.
final class _ResolverChunkedBodyClient extends http.BaseClient {
  _ResolverChunkedBodyClient({
    required this.chunks,
    this.contentLength,
  });

  final List<List<int>> chunks;
  final int? contentLength;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      Stream.fromIterable(chunks),
      200,
      contentLength: contentLength,
      request: request,
    );
  }
}
