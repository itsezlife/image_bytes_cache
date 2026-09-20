// ignore_for_file: one_member_abstracts

import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:image_bytes_cache/src/cache/cache_middleware.dart';
import 'package:image_bytes_cache/src/cache/middlewares/skip_cache_middleware.dart';
import 'package:image_bytes_cache/src/http/http_bytes_client.dart';
import 'package:image_bytes_cache/src/image_bytes_cache.dart';
import 'package:image_bytes_cache/src/image_bytes_diagnostics.dart';
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

  /// Optional sink for honest HTTP body progress on a network miss.
  ///
  /// Forwarded to [HttpBytesClient.send] only when the ladder actually
  /// fetches. A durable non-empty cache hit returns bytes without invoking this
  /// callback. Silence is not "0%"; do not invent mid-download percents.
  /// Resolve remains a single [Future] of the full body; this is not a
  /// streaming resolve API. Does not participate in [ImageCacheKey] identity
  /// or in-flight coalesce.
  final ImageBytesProgressCallback? onBytesProgress;
}

/// Looks up bytes in a cache, then fetches, then write-through.
abstract interface class IImageBytesResolver {
  /// Resolves [request] to bytes.
  ///
  /// Empty cached payloads count as a miss so a bad empty write cannot poison
  /// the ladder. After a network hit, persistence runs off the critical path;
  /// a durable write failure is reported via [ImageBytesDiagnostics] and does
  /// not fail this future.
  ///
  /// Uses [HttpBytesClient.send] with [HttpBytesRequest]. Typed
  /// [HttpBytesException] failures propagate. When
  /// [ImageBytesRequest.onBytesProgress] is set, the ladder forwards it on a
  /// network miss only. Cache hits do not synthesize progress events.
  Future<Uint8List> resolve(ImageBytesRequest request);
}

/// Default ladder: [IImageBytesCache] then [HttpBytesClient].
///
/// Order: cache read → network on miss → fire-and-forget write-through.
/// Callers that already hold bytes from a successful GET should keep painting;
/// storage bugs surface through [ImageBytesDiagnostics] (default silent), not
/// by failing [resolve].
///
/// [ImageBytesRequest.cacheKey] sets durable identity and
/// [HttpBytesContext.identityOverride] (coalesce). [ImageBytesRequest.skipCache]
/// seeds [CacheContext.skipCache] when the store is a [MiddlewareImageBytesCache].
/// Network goes through [HttpBytesClient.send]; typed failures are
/// [HttpBytesException].
///
/// [ImageBytesResolver.shared] does not snapshot the process-wide cache or
/// client. Each [resolve] reads [ImageBytesCache.shared] and
/// [HttpBytesClient.shared] (or their `debugShared` overrides) so configure
/// after first paint still enables durable caching, and [ImageBytesCache.resetShared]
/// / configure replacement cannot leave this ladder permanently bound to NoOp
/// or a closed previous store.
final class ImageBytesResolver implements IImageBytesResolver {
  /// Injected wiring for tests and hosts that own their own ladder instances.
  ImageBytesResolver({
    required IImageBytesCache cache,
    required HttpBytesClient client,
    ImageBytesDiagnostics? diagnostics,
  }) : _cacheOf = (() => cache),
       _clientOf = (() => client),
       _diagnostics = diagnostics;

  /// Process-wide ladder that re-reads shared cache/client on every resolve.
  ImageBytesResolver._liveShared({ImageBytesDiagnostics? diagnostics})
    : _cacheOf = ImageBytesCache.shared,
      _clientOf = HttpBytesClient.shared,
      _diagnostics = diagnostics;

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

  ImageBytesDiagnostics get _effectiveDiagnostics => _diagnostics ?? ImageBytesDiagnostics.current;

  @override
  Future<Uint8List> resolve(ImageBytesRequest request) async {
    final key = request.cacheKey ?? ImageCacheKey.fromUrl(request.url, headers: request.headers);
    final cache = _cacheOf();
    final client = _clientOf();

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
              'override wins for durable and coalesce identity — mint distinct '
              'keys per tenant. key=${key.value}',
          op: ImageBytesLogOp.cacheKeyAuthorization,
        ),
      );
    }

    final cacheContext = switch (request.skipCache) {
      true => CacheContext.empty()..skipCache = true,
      false => null,
    };

    final cached = await _read(cache, key, cacheContext);
    if (cached case final bytes? when bytes.isNotEmpty) {
      return bytes;
    }

    final url = Uri.base.resolve(request.url);
    final httpRequest = http.Request('GET', url);
    if (request.headers case final h?) {
      httpRequest.headers.addAll(h);
    }

    final httpContext = HttpBytesContext.empty();
    if (request.cacheKey case final override?) {
      httpContext.identityOverride = override;
    }

    // send → typed HttpBytesException. Ladder owns identity/context seeding.
    final response = await client.send(
      HttpBytesRequest(httpRequest),
      context: httpContext,
      onBytesProgress: request.onBytesProgress,
    );
    final bytes = await response.toBytes();

    // Persist off the critical path. A failed write must not fail paint that
    // already has network bytes; report so durable-store bugs stay observable
    // when the host opts into [ImageBytesDiagnostics].
    unawaited(
      _write(cache, key, bytes, cacheContext).catchError((Object error, StackTrace stackTrace) {
        _effectiveDiagnostics.report(
          ImageBytesLogEvent(
            level: ImageBytesLogLevel.error,
            message: 'ImageBytesResolver write-through failed for ${key.value}: $error',
            op: ImageBytesLogOp.writeThrough,
            stackTrace: stackTrace,
          ),
        );
      }),
    );
    return bytes;
  }

  /// Durable read. When [context] is set, requires [MiddlewareImageBytesCache]
  /// so [SkipCacheMiddleware] sees [CacheContext.skipCache]; otherwise public
  /// [IImageBytesCache.read] (empty context / no skip).
  Future<Uint8List?> _read(
    IImageBytesCache cache,
    ImageCacheKey key,
    CacheContext? context,
  ) async {
    switch (context) {
      case null:
        return cache.read(key);
      case final ctx:
        if (cache case final MiddlewareImageBytesCache mw) {
          final result = await mw.execute(CacheOperation$Read(key), ctx);
          return switch (result) {
            CacheOperationResult$Read(:final hit?) => hit.bytes,
            CacheOperationResult$Read() => null,
            _ => throw StateError(
              'Cache middleware returned ${result.runtimeType} for read; '
              'expected CacheOperationResult.Read',
            ),
          };
        }
        // Plain store: skipCache has no effect without middleware that honors it.
        return cache.read(key);
    }
  }

  /// Durable write-through. Same context story as [_read].
  Future<void> _write(
    IImageBytesCache cache,
    ImageCacheKey key,
    Uint8List bytes,
    CacheContext? context,
  ) async {
    switch (context) {
      case null:
        await cache.write(key, bytes);
      case final ctx:
        if (cache case final MiddlewareImageBytesCache mw) {
          final result = await mw.execute(
            CacheOperation$Write(key, bytes),
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
        await cache.write(key, bytes);
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
