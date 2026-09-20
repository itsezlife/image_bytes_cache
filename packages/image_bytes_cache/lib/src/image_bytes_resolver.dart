// ignore_for_file: one_member_abstracts

import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:image_bytes_cache/src/cache/cache_middleware.dart';
import 'package:image_bytes_cache/src/cache/middlewares/skip_cache_middleware.dart';
import 'package:image_bytes_cache/src/http/http_bytes_client.dart';
import 'package:image_bytes_cache/src/http/middlewares/conditional_middleware.dart';
import 'package:image_bytes_cache/src/image_bytes_cache.dart';
import 'package:image_bytes_cache/src/image_bytes_diagnostics.dart';
import 'package:image_bytes_cache/src/image_http_cache_freshness.dart';
import 'package:meta/meta.dart';

/// Arguments for [IImageBytesResolver.resolve].
@immutable
final class ImageBytesRequest {
  const ImageBytesRequest({
    required this.url,
    this.headers,
    this.cacheKey,
    this.skipCache = false,
    this.onBytesProgress,
  });

  /// Absolute or [Uri.base]-relative URL.
  ///
  /// The ladder resolves this with [Uri.base.resolve] for both the network GET
  /// and the default [ImageCacheKey] (when [cacheKey] is null), so relative and
  /// absolute forms of the same resource share one durable identity.
  final String url;

  /// Sent on the network hop.
  ///
  /// When [cacheKey] is null, folded into the default [ImageCacheKey] via
  /// [ImageCacheKey.fromUrl]. When [cacheKey] is set, still sent on the wire
  /// but not folded into identity. See [cacheKey].
  final Map<String, String>? headers;

  /// When set, the entire durable and coalesce identity for this resolve.
  ///
  /// Null builds identity with [ImageCacheKey.fromUrl] from the canonical URL
  /// and [headers]. Non-null: [headers] still go on the GET, but they do not
  /// change the key. The ladder copies this into
  /// [HttpBytesContext.identityOverride] so in-flight coalesce matches the
  /// durable slot.
  ///
  /// If you vary `Authorization` (or other representation headers) across
  /// users, omit this field so headers participate, or mint a distinct key per
  /// tenant. One shared override across tenants shares one cache slot. When
  /// this field is set and request headers include `Authorization`, the ladder
  /// reports [ImageBytesLogOp.cacheKeyAuthorization] at debug level (silent
  /// by default). Bearer-injected tokens are not checked here.
  final ImageCacheKey? cacheKey;

  /// When true, durable read misses and write is a no-op for this resolve.
  ///
  /// HTTP still runs. Requires a [MiddlewareImageBytesCache] whose chain
  /// includes [SkipCacheMiddleware] (or middleware that honors
  /// [CacheContext.skipCache]). Plain [IImageBytesCache] stores ignore the
  /// flag. Not part of [ImageCacheKey] identity.
  final bool skipCache;

  /// Optional sink for honest HTTP body progress on a network fetch.
  ///
  /// Forwarded to [HttpBytesClient.send] only when the ladder actually
  /// fetches. A durable non-empty fresh cache hit returns bytes without
  /// invoking this callback. Silence is not "0%"; do not invent mid-download
  /// percents. Resolve remains a single [Future] of the full body; this is not
  /// a streaming resolve API. Does not participate in [ImageCacheKey] identity
  /// or in-flight coalesce.
  final ImageBytesProgressCallback? onBytesProgress;
}

/// Looks up bytes in a cache, then fetches, then write-through.
abstract interface class IImageBytesResolver {
  /// Resolves [request] to bytes.
  ///
  /// Empty cached payloads count as a miss so a bad empty write cannot poison
  /// the ladder. Fresh hits return without a network hop. Stale hits with
  /// validators issue a conditional GET when the client stack includes
  /// [HttpBytesConditionalMiddleware]; 304 reuses cached bytes and refreshes
  /// meta. After a network hit, persistence runs off the critical path; a
  /// durable write failure is reported via [ImageBytesDiagnostics] and does
  /// not fail this future.
  ///
  /// Uses [HttpBytesClient.send] with [HttpBytesRequest]. Typed
  /// [HttpBytesException] failures propagate. When
  /// [ImageBytesRequest.onBytesProgress] is set, the ladder forwards it on a
  /// network fetch only. Fresh cache hits do not synthesize progress events.
  Future<Uint8List> resolve(ImageBytesRequest request);
}

/// Default ladder: [IImageBytesCache] then [HttpBytesClient].
///
/// ## Resolve order
///
/// 1. Rich cache read (skip context when [ImageBytesRequest.skipCache] is set
///    on a [MiddlewareImageBytesCache]). Empty bytes count as a miss.
/// 2. Fresh hit: return bytes. No network. No progress events.
/// 3. Stale hit with validators: conditional GET (seeds
///    [HttpBytesContext.etag] / [HttpBytesContext.lastModified]).
/// 4. Stale without validators, or miss: unconditional GET.
/// 5. 304: return cached bytes; soft meta refresh.
/// 6. 200: return new bytes; soft write-through of bytes + response meta.
/// 7. 412 after a conditional: one unconditional GET, then same as 200 / fail.
///
/// Freshness is [ImageHttpCacheFreshness], not [ImageBytesRetention].
/// Conditional headers reach the wire only when the client includes
/// [HttpBytesConditionalMiddleware]. Without it, seeded validators are ignored
/// and the GET stays unconditional. Recommended stack (outermost first):
/// Logger, Retry, Timeout, Bearer, Conditional.
///
/// [ImageBytesRequest.cacheKey] sets durable identity and
/// [HttpBytesContext.identityOverride] (coalesce). [ImageBytesRequest.skipCache]
/// seeds [CacheContext.skipCache] on a middleware store. Network goes through
/// [HttpBytesClient.send]; typed failures are [HttpBytesException].
///
/// [ImageBytesResolver.shared] does not snapshot the process-wide cache or
/// client. Each [resolve] reads [ImageBytesCache.shared] and
/// [HttpBytesClient.shared] (or their `debugShared` overrides) so configure
/// after first paint still enables durable caching, and
/// [ImageBytesCache.resetShared] / configure replacement cannot leave this
/// ladder permanently bound to NoOp or a closed previous store.
final class ImageBytesResolver implements IImageBytesResolver {
  /// Injected wiring for tests and hosts that own their own ladder instances.
  ///
  /// [clock] defaults to UTC now. Pass a fixed clock when testing freshness.
  ImageBytesResolver({
    required IImageBytesCache cache,
    required HttpBytesClient client,
    ImageBytesDiagnostics? diagnostics,
    DateTime Function()? clock,
  }) : _cacheOf = (() => cache),
       _clientOf = (() => client),
       _diagnostics = diagnostics,
       _clock = clock ?? _defaultClock;

  /// Process-wide ladder that re-reads shared cache/client on every resolve.
  ImageBytesResolver._liveShared({ImageBytesDiagnostics? diagnostics})
    : _cacheOf = ImageBytesCache.shared,
      _clientOf = HttpBytesClient.shared,
      _diagnostics = diagnostics,
      _clock = _defaultClock;

  /// Process-wide default when nothing is injected.
  ///
  /// Returns one shared instance, but that instance looks up the current
  /// [ImageBytesCache.shared] / [HttpBytesClient.shared] on each [resolve]
  /// rather than capturing them once at first call.
  factory ImageBytesResolver.shared() {
    _$ensureResetSharedCleanup();
    return debugShared ?? (_shared ??= ImageBytesResolver._liveShared());
  }

  static ImageBytesResolver? _shared;

  /// Test override for [ImageBytesResolver.shared]. Set to `null` to clear.
  @visibleForTesting
  static ImageBytesResolver? debugShared;

  /// Clears the memoized [shared] instance and [debugShared].
  ///
  /// Registered via [ImageBytesCache.addAfterResetShared] so test re-bootstrap
  /// cannot keep a stale override without the store facade importing this
  /// library. Live wiring already re-reads the cache; this only drops the
  /// resolver singleton / debug override.
  @internal
  static void resetShared() {
    debugShared = null;
    _shared = null;
  }

  static var _$resetSharedCleanupInstalled = false;

  static void _$ensureResetSharedCleanup() {
    if (_$resetSharedCleanupInstalled) return;
    _$resetSharedCleanupInstalled = true;
    ImageBytesCache.addAfterResetShared(resetShared);
  }

  final IImageBytesCache Function() _cacheOf;
  final HttpBytesClient Function() _clientOf;
  final ImageBytesDiagnostics? _diagnostics;
  final DateTime Function() _clock;

  ImageBytesDiagnostics get _effectiveDiagnostics => _diagnostics ?? ImageBytesDiagnostics.current;

  @override
  Future<Uint8List> resolve(ImageBytesRequest request) async {
    final key = request.cacheKey ?? ImageCacheKey.fromUrl(request.url, headers: request.headers);
    final cache = _cacheOf();
    final client = _clientOf();
    final now = _clock();

    // Override wins for durable + coalesce while Authorization still rides
    // the wire. Without distinct keys per tenant, hosts can share one slot
    // across users. Silent when diagnostics are silent (default).
    // Only checks Authorization on the request map. Bearer-injected tokens
    // are not visible here.
    if (request.cacheKey case final _? when _hasAuthorizationHeader(request.headers)) {
      _effectiveDiagnostics.report(
        ImageBytesLogEvent(
          level: ImageBytesLogLevel.debug,
          message:
              'ImageBytesRequest.cacheKey override coexists with Authorization; '
              'override wins for durable and coalesce identity. Mint distinct '
              'keys per tenant. key=${key.value}',
          op: ImageBytesLogOp.cacheKeyAuthorization,
        ),
      );
    }

    final cacheContext = switch (request.skipCache) {
      true => CacheContext.empty()..skipCache = true,
      false => null,
    };

    final hit = await _readRich(cache, key, cacheContext);
    if (hit case final cached? when cached.bytes.isNotEmpty) {
      final fresh = ImageHttpCacheFreshness.isFresh(
        cached.httpCacheMeta,
        now: now,
        writtenAt: cached.writtenAt,
      );
      if (fresh) return cached.bytes;

      if (ImageHttpCacheFreshness.hasValidators(cached.httpCacheMeta)) {
        return _revalidate(
          request: request,
          key: key,
          cache: cache,
          client: client,
          cacheContext: cacheContext,
          cached: cached,
          now: now,
        );
      }
      // Stale without validators → unconditional GET below.
    }

    return _fetchAndStore(
      request: request,
      key: key,
      cache: cache,
      client: client,
      cacheContext: cacheContext,
      now: now,
    );
  }

  /// Conditional GET for a stale hit that still has validators.
  ///
  /// Seeds [HttpBytesContext.etag] / [HttpBytesContext.lastModified] for
  /// [HttpBytesConditionalMiddleware]. On 304, returns cached bytes and soft
  /// meta refresh. On 412, retries once without validators. On 200,
  /// write-through new bytes and meta.
  Future<Uint8List> _revalidate({
    required ImageBytesRequest request,
    required ImageCacheKey key,
    required IImageBytesCache cache,
    required HttpBytesClient client,
    required CacheContext? cacheContext,
    required ImageBytesRichHit cached,
    required DateTime now,
  }) async {
    final httpContext = _seedHttpContext(request);
    final meta = cached.httpCacheMeta;
    if (meta?.etag case final etag? when etag.trim().isNotEmpty) {
      httpContext.etag = etag;
    }
    if (meta?.lastModified case final lm? when lm.trim().isNotEmpty) {
      httpContext.lastModified = lm;
    }

    try {
      final response = await _send(client, request, httpContext);
      if (response.statusCode == 304) {
        final refreshed = ImageHttpCacheFreshness.afterNotModified(
          cached.httpCacheMeta,
          headers: response.headers,
          validatedAt: now,
        );
        unawaited(_softWrite(cache, key, cached.bytes, cacheContext, refreshed));
        return cached.bytes;
      }

      final bytes = await response.toBytes();
      final nextMeta = ImageHttpCacheFreshness.fromResponseHeaders(
        response.headers,
        validatedAt: now,
      );
      unawaited(_softWrite(cache, key, bytes, cacheContext, nextMeta));
      return bytes;
    } on HttpBytesException$Request catch (error) {
      // 412 Precondition Failed: one unconditional GET.
      if (error.statusCode != 412) rethrow;
      return _fetchAndStore(
        request: request,
        key: key,
        cache: cache,
        client: client,
        cacheContext: cacheContext,
        now: now,
      );
    }
  }

  /// Unconditional GET + soft write-through of bytes and response meta.
  Future<Uint8List> _fetchAndStore({
    required ImageBytesRequest request,
    required ImageCacheKey key,
    required IImageBytesCache cache,
    required HttpBytesClient client,
    required CacheContext? cacheContext,
    required DateTime now,
  }) async {
    final httpContext = _seedHttpContext(request);
    final response = await _send(client, request, httpContext);
    final bytes = await response.toBytes();
    final meta = ImageHttpCacheFreshness.fromResponseHeaders(
      response.headers,
      validatedAt: now,
    );
    unawaited(_softWrite(cache, key, bytes, cacheContext, meta));
    return bytes;
  }

  HttpBytesContext _seedHttpContext(ImageBytesRequest request) {
    final httpContext = HttpBytesContext.empty();
    if (request.cacheKey case final override?) {
      httpContext.identityOverride = override;
    }
    return httpContext;
  }

  Future<HttpBytesResponse> _send(
    HttpBytesClient client,
    ImageBytesRequest request,
    HttpBytesContext httpContext,
  ) async {
    final url = Uri.base.resolve(request.url);
    final httpRequest = http.Request('GET', url);
    if (request.headers case final h?) {
      httpRequest.headers.addAll(h);
    }
    return client.send(
      HttpBytesRequest(httpRequest),
      context: httpContext,
      onBytesProgress: request.onBytesProgress,
    );
  }

  /// Soft write-through. Failures report; they never fail [resolve].
  Future<void> _softWrite(
    IImageBytesCache cache,
    ImageCacheKey key,
    Uint8List bytes,
    CacheContext? cacheContext,
    ImageHttpCacheMeta? httpCacheMeta,
  ) => _write(cache, key, bytes, cacheContext, httpCacheMeta: httpCacheMeta).catchError((
    Object error,
    StackTrace stackTrace,
  ) {
    _effectiveDiagnostics.report(
      ImageBytesLogEvent(
        level: ImageBytesLogLevel.error,
        message: 'ImageBytesResolver write-through failed for ${key.value}: $error',
        op: ImageBytesLogOp.writeThrough,
        stackTrace: stackTrace,
      ),
    );
  });

  /// Rich durable read (bytes + HTTP meta). Falls back to bytes-only stores.
  Future<ImageBytesRichHit?> _readRich(
    IImageBytesCache cache,
    ImageCacheKey key,
    CacheContext? context,
  ) async {
    Future<ImageBytesRichHit?> fromPlain() async {
      if (cache case final IImageBytesRichCache rich) {
        return rich.readRich(key);
      }
      return switch (await cache.read(key)) {
        final bytes? when bytes.isNotEmpty => ImageBytesRichHit(bytes: bytes),
        _ => null,
      };
    }

    switch (context) {
      case null:
        return fromPlain();
      case final ctx:
        if (cache case final MiddlewareImageBytesCache mw) {
          final result = await mw.execute(CacheOperation$Read(key), ctx);
          return switch (result) {
            CacheOperationResult$Read(:final hit?) => ImageBytesRichHit(
              bytes: hit.bytes,
              writtenAt: hit.writtenAt,
              accessedAt: hit.accessedAt,
              httpCacheMeta: hit.httpCacheMeta,
            ),
            CacheOperationResult$Read() => null,
            _ => throw StateError(
              'Cache middleware returned ${result.runtimeType} for read; '
              'expected CacheOperationResult.Read',
            ),
          };
        }
        // Plain store: skipCache has no effect without middleware that honors it.
        return fromPlain();
    }
  }

  /// Durable write-through. Same context story as [_readRich].
  Future<void> _write(
    IImageBytesCache cache,
    ImageCacheKey key,
    Uint8List bytes,
    CacheContext? context, {
    ImageHttpCacheMeta? httpCacheMeta,
  }) async {
    switch (context) {
      case null:
        await cache.write(key, bytes, httpCacheMeta: httpCacheMeta);
      case final ctx:
        if (cache case final MiddlewareImageBytesCache mw) {
          final result = await mw.execute(
            CacheOperation$Write(key, bytes, httpCacheMeta: httpCacheMeta),
            ctx,
          );
          switch (result) {
            case CacheOperationResult$Write():
              return;
            case _:
              throw StateError(
                'Cache middleware returned ${result.runtimeType} for write; '
                'expected CacheOperationResult.Write',
              );
          }
        }
        await cache.write(key, bytes, httpCacheMeta: httpCacheMeta);
    }
  }

  static bool _hasAuthorizationHeader(Map<String, String>? headers) {
    switch (headers) {
      case null || Map(isEmpty: true):
        return false;
      case final map:
        for (final key in map.keys) {
          if (key.toLowerCase() == 'authorization') return true;
        }
        return false;
    }
  }
}

DateTime _defaultClock() => DateTime.now().toUtc();
