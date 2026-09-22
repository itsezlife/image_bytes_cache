import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_bytes_cache/src/cache/cache_middleware.dart';
import 'package:image_bytes_cache/src/cache/middlewares/skip_cache_middleware.dart';
import 'package:image_bytes_cache/src/http/http_bytes_client.dart';
import 'package:image_bytes_cache/src/http/middlewares/conditional_middleware.dart';
import 'package:image_bytes_cache/src/http/middlewares/timeout_middleware.dart';
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

    test('explicit cacheKey coalesces concurrent GETs despite different Authorization', () async {
      var hits = 0;
      final release = Completer<void>();
      final body = Uint8List.fromList([2, 2]);
      final client = HttpBytesClient(
        client: MockClient((_) async {
          hits++;
          await release.future;
          return http.Response.bytes(body, 200);
        }),
      );
      addTearDown(client.close);

      final resolver = ImageBytesResolver(
        cache: MemoryImageBytesCache(),
        client: client,
      );
      const key = ImageCacheKey('host_override_key');
      const url = 'https://cdn.example.com/a.svg';

      final a = resolver.resolve(
        const ImageBytesRequest(
          url: url,
          headers: {'Authorization': 'Bearer a'},
          cacheKey: key,
        ),
      );
      final b = resolver.resolve(
        const ImageBytesRequest(
          url: url,
          headers: {'Authorization': 'Bearer b'},
          cacheKey: key,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      release.complete();

      final results = await (a, b).wait;
      expect(results.$1, body);
      expect(results.$2, body);
      expect(hits, 1);
    });

    test('cacheKey + Authorization reports debug diagnostic', () async {
      final body = Uint8List.fromList([1]);
      final client = HttpBytesClient(
        client: MockClient((_) async => http.Response.bytes(body, 200)),
      );
      addTearDown(client.close);

      final events = <ImageBytesLogEvent>[];
      final resolver = ImageBytesResolver(
        cache: MemoryImageBytesCache(),
        client: client,
        diagnostics: ImageBytesDiagnostics.onEvent(events.add),
      );

      await resolver.resolve(
        const ImageBytesRequest(
          url: 'https://cdn.example.com/diag.svg',
          headers: {'Authorization': 'Bearer x'},
          cacheKey: ImageCacheKey('override'),
        ),
      );

      expect(
        events,
        contains(
          isA<ImageBytesLogEvent>()
              .having((e) => e.op, 'op', ImageBytesLogOp.cacheKeyAuthorization)
              .having((e) => e.level, 'level', ImageBytesLogLevel.debug),
        ),
      );
    });

    test('skipCache seeds SkipCacheMiddleware — miss and no write-through', () async {
      final inner = MemoryImageBytesCache();
      const url = 'https://cdn.example.com/skip.svg';
      final key = ImageCacheKey.fromUrl(url);
      await inner.write(key, Uint8List.fromList([1, 2, 3]));

      final cache = MiddlewareImageBytesCache(
        inner: inner,
        middlewares: <CacheMiddleware>[const SkipCacheMiddleware()],
      );
      var hits = 0;
      final client = HttpBytesClient(
        client: MockClient((_) async {
          hits++;
          return http.Response.bytes(Uint8List.fromList([9]), 200);
        }),
      );
      addTearDown(client.close);

      final resolver = ImageBytesResolver(cache: cache, client: client);
      final bytes = await resolver.resolve(
        const ImageBytesRequest(url: url, skipCache: true),
      );
      await Future<void>.delayed(Duration.zero);

      expect(bytes, Uint8List.fromList([9]));
      expect(hits, 1);
      expect(await inner.read(key), Uint8List.fromList([1, 2, 3]));
    });

    test('typed HttpBytesException from send propagates', () async {
      final client = HttpBytesClient(
        client: MockClient((_) async => http.Response('gone', 404)),
      );
      addTearDown(client.close);

      final resolver = ImageBytesResolver(
        cache: MemoryImageBytesCache(),
        client: client,
      );

      await expectLater(
        resolver.resolve(
          const ImageBytesRequest(url: 'https://cdn.example.com/missing.svg'),
        ),
        throwsA(
          isA<HttpBytesException$Request>().having(
            (e) => e.statusCode,
            'statusCode',
            404,
          ),
        ),
      );
    });
  });

  group('ImageBytesResolver freshness + revalidation', () {
    HttpBytesClient revalidatingClient(MockClientHandler handler) {
      final client = HttpBytesClient(
        client: MockClient(handler),
        middlewares: <HttpBytesMiddleware>[
          const HttpBytesTimeoutMiddleware(),
          const HttpBytesConditionalMiddleware(),
        ],
      );
      addTearDown(client.close);
      return client;
    }

    test('fresh max-age hit skips network', () async {
      var hits = 0;
      final now = DateTime.utc(2024, 6, 1, 12);
      final cache = MemoryImageBytesCache(clock: () => now);
      const url = 'https://cdn.example.com/fresh.svg';
      final key = ImageCacheKey.fromUrl(url);
      final body = Uint8List.fromList([1, 2, 3]);
      await cache.write(
        key,
        body,
        httpCacheMeta: ImageHttpCacheMeta(
          etag: '"v1"',
          cacheControl: 'max-age=3600',
          lastValidatedAt: now.subtract(const Duration(minutes: 5)),
        ),
      );

      final resolver = ImageBytesResolver(
        cache: cache,
        client: revalidatingClient((_) async {
          hits++;
          return http.Response.bytes(Uint8List.fromList([9]), 200);
        }),
        clock: () => now,
      );

      expect(await resolver.resolve(const ImageBytesRequest(url: url)), body);
      expect(hits, 0);
    });

    test('stale with ETag issues conditional GET; 304 reuses bytes and refreshes meta', () async {
      var hits = 0;
      http.BaseRequest? seen;
      final events = <ImageBytesLogEvent>[];
      final now = DateTime.utc(2024, 6, 1, 12);
      final cache = MemoryImageBytesCache(clock: () => now);
      const url = 'https://cdn.example.com/revalidate.svg';
      final key = ImageCacheKey.fromUrl(url);
      final body = Uint8List.fromList([4, 5, 6]);
      await cache.write(
        key,
        body,
        httpCacheMeta: const ImageHttpCacheMeta(
          etag: '"v1"',
          cacheControl: 'max-age=60',
        ),
      );
      // Advance past max-age via lastValidatedAt in the past.
      await cache.write(
        key,
        body,
        httpCacheMeta: ImageHttpCacheMeta(
          etag: '"v1"',
          cacheControl: 'max-age=60',
          lastValidatedAt: now.subtract(const Duration(minutes: 5)),
        ),
      );

      final resolver = ImageBytesResolver(
        cache: cache,
        client: revalidatingClient((request) async {
          hits++;
          seen = request;
          return http.Response.bytes(
            Uint8List(0),
            304,
            headers: {'etag': '"v1"', 'cache-control': 'max-age=120'},
          );
        }),
        diagnostics: ImageBytesDiagnostics.onEvent(events.add),
        clock: () => now,
      );

      expect(await resolver.resolve(const ImageBytesRequest(url: url)), body);
      expect(hits, 1);
      expect(seen!.headers['if-none-match'], '"v1"');
      expect(events, hasLength(1));
      expect(events.single.op, ImageBytesLogOp.resolveRevalidated);
      expect(events.single.level, ImageBytesLogLevel.debug);
      await Future<void>.delayed(Duration.zero);

      final rich = await cache.readRich(key);
      expect(rich?.bytes, body);
      expect(rich?.httpCacheMeta?.etag, '"v1"');
      expect(rich?.httpCacheMeta?.cacheControl, 'max-age=120');
      expect(rich?.httpCacheMeta?.lastValidatedAt, now);
    });

    test('stale with ETag on 200 replaces bytes and write-through meta', () async {
      var hits = 0;
      final now = DateTime.utc(2024, 6, 1, 12);
      final cache = MemoryImageBytesCache(clock: () => now);
      const url = 'https://cdn.example.com/replace.svg';
      final key = ImageCacheKey.fromUrl(url);
      await cache.write(
        key,
        Uint8List.fromList([1]),
        httpCacheMeta: ImageHttpCacheMeta(
          etag: '"old"',
          lastValidatedAt: now.subtract(const Duration(days: 1)),
        ),
      );
      final next = Uint8List.fromList([2, 2]);

      final resolver = ImageBytesResolver(
        cache: cache,
        client: revalidatingClient((request) async {
          hits++;
          expect(request.headers['if-none-match'], '"old"');
          return http.Response.bytes(
            next,
            200,
            headers: {'etag': '"new"', 'cache-control': 'max-age=30'},
          );
        }),
        clock: () => now,
      );

      expect(await resolver.resolve(const ImageBytesRequest(url: url)), next);
      expect(hits, 1);
      await Future<void>.delayed(Duration.zero);

      final rich = await cache.readRich(key);
      expect(rich?.bytes, next);
      expect(rich?.httpCacheMeta?.etag, '"new"');
      expect(rich?.httpCacheMeta?.cacheControl, 'max-age=30');
    });

    test('stale without validators / miss uses unconditional GET', () async {
      final seen = <String?>[];
      final events = <ImageBytesLogEvent>[];
      final now = DateTime.utc(2024, 6, 1, 12);
      final cache = MemoryImageBytesCache(clock: () => now);
      const staleUrl = 'https://cdn.example.com/no-validators.svg';
      final staleKey = ImageCacheKey.fromUrl(staleUrl);
      await cache.write(
        staleKey,
        Uint8List.fromList([1]),
        httpCacheMeta: ImageHttpCacheMeta(
          cacheControl: 'max-age=1',
          lastValidatedAt: now.subtract(const Duration(hours: 1)),
        ),
      );

      final client = revalidatingClient((request) async {
        seen.add(request.headers['if-none-match']);
        return http.Response.bytes(
          Uint8List.fromList([9]),
          200,
          headers: {'etag': '"v1"', 'cache-control': 'max-age=60'},
        );
      });
      final resolver = ImageBytesResolver(
        cache: cache,
        client: client,
        diagnostics: ImageBytesDiagnostics.onEvent(events.add),
        clock: () => now,
      );

      expect(
        await resolver.resolve(const ImageBytesRequest(url: staleUrl)),
        Uint8List.fromList([9]),
      );
      expect(events, hasLength(1));
      expect(events.single.op, ImageBytesLogOp.resolveUnconditional);
      expect(events.single.level, ImageBytesLogLevel.debug);
      events.clear();

      expect(
        await resolver.resolve(
          const ImageBytesRequest(url: 'https://cdn.example.com/miss.svg'),
        ),
        Uint8List.fromList([9]),
      );
      // Cold miss stays quiet: unconditional is only useful when we already
      // held bytes and still full-fetched.
      expect(events, isEmpty);
      expect(seen, [null, null]);
      await Future<void>.delayed(Duration.zero);
      expect(
        (await cache.readRich(ImageCacheKey.fromUrl('https://cdn.example.com/miss.svg')))?.httpCacheMeta?.etag,
        '"v1"',
      );
    });

    test('validators without Cache-Control revalidate on every use', () async {
      var hits = 0;
      final now = DateTime.utc(2024, 6, 1, 12);
      final cache = MemoryImageBytesCache(clock: () => now);
      const url = 'https://cdn.example.com/etag-only.svg';
      final key = ImageCacheKey.fromUrl(url);
      final body = Uint8List.fromList([7]);
      await cache.write(
        key,
        body,
        httpCacheMeta: const ImageHttpCacheMeta(etag: '"always"'),
      );

      final resolver = ImageBytesResolver(
        cache: cache,
        client: revalidatingClient((request) async {
          hits++;
          expect(request.headers['if-none-match'], '"always"');
          return http.Response.bytes(Uint8List(0), 304, headers: {'etag': '"always"'});
        }),
        clock: () => now,
      );

      expect(await resolver.resolve(const ImageBytesRequest(url: url)), body);
      expect(hits, 1);
    });

    test('stale Last-Modified issues If-Modified-Since; 304 reuses bytes', () async {
      var hits = 0;
      http.BaseRequest? seen;
      final now = DateTime.utc(2024, 6, 1, 12);
      const lastModified = 'Wed, 21 Oct 2015 07:28:00 GMT';
      final cache = MemoryImageBytesCache(clock: () => now);
      const url = 'https://cdn.example.com/last-mod.svg';
      final key = ImageCacheKey.fromUrl(url);
      final body = Uint8List.fromList([2, 2]);
      await cache.write(
        key,
        body,
        httpCacheMeta: ImageHttpCacheMeta(
          lastModified: lastModified,
          lastValidatedAt: now.subtract(const Duration(days: 1)),
        ),
      );

      final resolver = ImageBytesResolver(
        cache: cache,
        client: revalidatingClient((request) async {
          hits++;
          seen = request;
          return http.Response.bytes(Uint8List(0), 304, headers: {'last-modified': lastModified});
        }),
        clock: () => now,
      );

      expect(await resolver.resolve(const ImageBytesRequest(url: url)), body);
      expect(hits, 1);
      expect(seen!.headers['if-modified-since'], lastModified);
      expect(seen!.headers.containsKey('if-none-match'), isFalse);
    });

    test('immutable keeps network quiet until retention', () async {
      var hits = 0;
      final now = DateTime.utc(2024, 6, 1, 12);
      final cache = MemoryImageBytesCache(clock: () => now);
      const url = 'https://cdn.example.com/immutable.svg';
      final body = Uint8List.fromList([8, 8]);
      await cache.write(
        ImageCacheKey.fromUrl(url),
        body,
        httpCacheMeta: ImageHttpCacheMeta(
          etag: '"static"',
          cacheControl: 'public, max-age=0, immutable',
          lastValidatedAt: now.subtract(const Duration(days: 40)),
        ),
      );

      final resolver = ImageBytesResolver(
        cache: cache,
        client: revalidatingClient((_) async {
          hits++;
          return http.Response.bytes(Uint8List.fromList([1]), 200);
        }),
        clock: () => now,
      );

      expect(await resolver.resolve(const ImageBytesRequest(url: url)), body);
      expect(hits, 0);
    });

    test('412 precondition failure falls back to one unconditional GET', () async {
      var hits = 0;
      final events = <ImageBytesLogEvent>[];
      final now = DateTime.utc(2024, 6, 1, 12);
      final cache = MemoryImageBytesCache(clock: () => now);
      const url = 'https://cdn.example.com/precondition.svg';
      final key = ImageCacheKey.fromUrl(url);
      await cache.write(
        key,
        Uint8List.fromList([1]),
        httpCacheMeta: ImageHttpCacheMeta(
          etag: '"stale"',
          lastValidatedAt: now.subtract(const Duration(days: 1)),
        ),
      );
      final next = Uint8List.fromList([3, 3, 3]);

      final resolver = ImageBytesResolver(
        cache: cache,
        client: revalidatingClient((request) async {
          hits++;
          if (request.headers.containsKey('if-none-match')) {
            return http.Response('precondition failed', 412);
          }
          return http.Response.bytes(
            next,
            200,
            headers: {'etag': '"ok"', 'cache-control': 'max-age=10'},
          );
        }),
        diagnostics: ImageBytesDiagnostics.onEvent(events.add),
        clock: () => now,
      );

      expect(await resolver.resolve(const ImageBytesRequest(url: url)), next);
      expect(hits, 2);
      expect(events, hasLength(1));
      expect(events.single.op, ImageBytesLogOp.resolveUnconditional);
      expect(events.single.level, ImageBytesLogLevel.debug);
      expect(events.single.message, isNot(contains('without a conditional path')));
      await Future<void>.delayed(Duration.zero);
      expect((await cache.readRich(key))?.httpCacheMeta?.etag, '"ok"');
    });
  });

  group('ImageBytesResolver stale-on-network-error', () {
    const url = 'https://cdn.example.com/stale-fallback.svg';
    final body = Uint8List.fromList([4, 4, 4]);
    final now = DateTime.utc(2024, 6, 1, 12);

    Future<MemoryImageBytesCache> seededCache({ImageHttpCacheMeta? meta}) async {
      final cache = MemoryImageBytesCache(clock: () => now);
      await cache.write(
        ImageCacheKey.fromUrl(url),
        body,
        httpCacheMeta:
            meta ??
            ImageHttpCacheMeta(
              etag: '"v1"',
              lastValidatedAt: now.subtract(const Duration(days: 1)),
            ),
      );
      return cache;
    }

    HttpBytesClient clientThrowing(HttpBytesException error) {
      final client = HttpBytesClient(
        client: MockClient((_) async => http.Response.bytes(Uint8List.fromList([9]), 200)),
        middlewares: <HttpBytesMiddleware>[
          (_) =>
              (request, context) async => throw error,
        ],
      );
      addTearDown(client.close);
      return client;
    }

    HttpBytesClient clientWithHandler(MockClientHandler handler) {
      final client = HttpBytesClient(
        client: MockClient(handler),
        middlewares: <HttpBytesMiddleware>[
          const HttpBytesTimeoutMiddleware(),
          const HttpBytesConditionalMiddleware(),
        ],
      );
      addTearDown(client.close);
      return client;
    }

    test(r'non-empty cache + $Network returns cached bytes and reports stale_used', () async {
      final events = <ImageBytesLogEvent>[];
      final cache = await seededCache();
      final resolver = ImageBytesResolver(
        cache: cache,
        client: clientThrowing(
          const HttpBytesException$Network(
            code: 'network_error',
            message: 'down',
            statusCode: 0,
          ),
        ),
        diagnostics: ImageBytesDiagnostics.onEvent(events.add),
        clock: () => now,
      );

      expect(await resolver.resolve(const ImageBytesRequest(url: url)), body);
      expect(events, hasLength(1));
      expect(events.single.op, ImageBytesLogOp.resolveStaleUsed);
      expect(events.single.level, ImageBytesLogLevel.warning);
      expect(events.single.message, contains('stale'));
    });

    test(r'non-empty cache + $Timeout returns cached bytes', () async {
      final cache = await seededCache();
      final resolver = ImageBytesResolver(
        cache: cache,
        client: clientThrowing(
          const HttpBytesException$Timeout(
            code: 'timeout',
            message: 'connect timed out',
            statusCode: 0,
            duration: Duration(milliseconds: 20),
          ),
        ),
        clock: () => now,
      );

      expect(await resolver.resolve(const ImageBytesRequest(url: url)), body);
    });

    test(r'exhausted $Server with cached bytes returns cached bytes', () async {
      final cache = await seededCache();
      final resolver = ImageBytesResolver(
        cache: cache,
        client: clientWithHandler((_) async => http.Response('boom', 503)),
        clock: () => now,
      );

      expect(await resolver.resolve(const ImageBytesRequest(url: url)), body);
    });

    test(r'$Cancelled with cached bytes propagates failure', () async {
      final cache = await seededCache();
      final resolver = ImageBytesResolver(
        cache: cache,
        client: clientThrowing(const HttpBytesException$Cancelled()),
        clock: () => now,
      );

      await expectLater(
        resolver.resolve(const ImageBytesRequest(url: url)),
        throwsA(isA<HttpBytesException$Cancelled>()),
      );
    });

    test(r'$Authentication with cached bytes propagates failure', () async {
      final cache = await seededCache();
      final resolver = ImageBytesResolver(
        cache: cache,
        client: clientWithHandler((_) async => http.Response('nope', 401)),
        clock: () => now,
      );

      await expectLater(
        resolver.resolve(const ImageBytesRequest(url: url)),
        throwsA(isA<HttpBytesException$Authentication>()),
      );
    });

    test('definitive 404 with cached bytes propagates failure', () async {
      final cache = await seededCache();
      final resolver = ImageBytesResolver(
        cache: cache,
        client: clientWithHandler((_) async => http.Response('gone', 404)),
        clock: () => now,
      );

      await expectLater(
        resolver.resolve(const ImageBytesRequest(url: url)),
        throwsA(
          isA<HttpBytesException$Request>().having((e) => e.statusCode, 'statusCode', 404),
        ),
      );
    });

    test(r'missing cache + $Network propagates failure', () async {
      final resolver = ImageBytesResolver(
        cache: MemoryImageBytesCache(clock: () => now),
        client: clientThrowing(
          const HttpBytesException$Network(
            code: 'network_error',
            message: 'down',
            statusCode: 0,
          ),
        ),
        clock: () => now,
      );

      await expectLater(
        resolver.resolve(const ImageBytesRequest(url: url)),
        throwsA(isA<HttpBytesException$Network>()),
      );
    });

    test(r'empty cached payload + $Network propagates failure', () async {
      final resolver = ImageBytesResolver(
        cache: _StickyEmptyImageBytesCache(),
        client: clientThrowing(
          const HttpBytesException$Network(
            code: 'network_error',
            message: 'down',
            statusCode: 0,
          ),
        ),
        clock: () => now,
      );

      await expectLater(
        resolver.resolve(const ImageBytesRequest(url: url)),
        throwsA(isA<HttpBytesException$Network>()),
      );
    });

    test('silent diagnostics emits nothing when stale is used', () async {
      final events = <ImageBytesLogEvent>[];
      ImageBytesDiagnostics.current = ImageBytesDiagnostics.onEvent(events.add);
      addTearDown(() {
        ImageBytesDiagnostics.current = const ImageBytesDiagnostics.silent();
      });

      final cache = await seededCache();
      final resolver = ImageBytesResolver(
        cache: cache,
        client: clientThrowing(
          const HttpBytesException$Network(
            code: 'network_error',
            message: 'down',
            statusCode: 0,
          ),
        ),
        diagnostics: const ImageBytesDiagnostics.silent(),
        clock: () => now,
      );

      expect(await resolver.resolve(const ImageBytesRequest(url: url)), body);
      expect(events, isEmpty);
    });

    test(r'stale without validators + $Network still returns cached bytes', () async {
      final cache = await seededCache(
        meta: ImageHttpCacheMeta(
          cacheControl: 'max-age=1',
          lastValidatedAt: now.subtract(const Duration(hours: 1)),
        ),
      );
      final resolver = ImageBytesResolver(
        cache: cache,
        client: clientThrowing(
          const HttpBytesException$Network(
            code: 'network_error',
            message: 'down',
            statusCode: 0,
          ),
        ),
        clock: () => now,
      );

      expect(await resolver.resolve(const ImageBytesRequest(url: url)), body);
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
  Future<void> write(
    ImageCacheKey key,
    Uint8List bytes, {
    ImageHttpCacheMeta? httpCacheMeta,
  }) async {}

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
  Future<void> write(
    ImageCacheKey key,
    Uint8List bytes, {
    ImageHttpCacheMeta? httpCacheMeta,
  }) async {
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
  Future<void> write(
    ImageCacheKey key,
    Uint8List bytes, {
    ImageHttpCacheMeta? httpCacheMeta,
  }) async {
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
