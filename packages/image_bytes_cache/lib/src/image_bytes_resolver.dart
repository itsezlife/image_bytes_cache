// ignore_for_file: one_member_abstracts

import 'dart:async';
import 'dart:typed_data';

import 'package:image_bytes_cache/src/http/http_bytes_fetcher.dart';
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
  /// but **not** folded into identity — see [cacheKey].
  final Map<String, String>? headers;

  /// Optional full durable identity escape hatch.
  ///
  /// When null, built with [ImageCacheKey.fromUrl] from the canonical URL and
  /// [headers]. When non-null, this value is the **entire** cache identity:
  /// [headers] still go on the GET but do not change the key. Hosts that vary
  /// `Authorization` (or any other header) across logical resources must either
  /// omit [cacheKey] so headers participate, or mint distinct override keys
  /// themselves — the ladder will not silently poison one override across
  /// different Authorization values.
  final ImageCacheKey? cacheKey;

  /// Optional sink for honest HTTP body progress on a network miss.
  ///
  /// Forwarded to [HttpBytesFetcher.getBytes] only when the ladder actually
  /// fetches. A durable non-empty cache hit returns bytes without invoking this
  /// callback — hosts must not treat silence as "0%" or invent mid-download
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
  /// the ladder. After a network hit, persistence runs off the critical path;
  /// a durable write failure is reported via [ImageBytesDiagnostics] and does
  /// not fail this future.
  ///
  /// When [ImageBytesRequest.onBytesProgress] is set, the ladder forwards it on
  /// a network miss only. Cache hits do not synthesize progress events.
  Future<Uint8List> resolve(ImageBytesRequest request);
}

/// Default ladder: [IImageBytesCache] then [HttpBytesFetcher].
///
/// Order: cache read → network on miss → fire-and-forget write-through.
/// Callers that already hold bytes from a successful GET should keep painting;
/// storage bugs surface through [ImageBytesDiagnostics] (default silent), not
/// by failing [resolve].
///
/// [ImageBytesResolver.shared] does **not** snapshot the process-wide cache or
/// fetcher. Each [resolve] reads [ImageBytesCache.shared] and
/// [HttpBytesFetcher.shared] (or their `debugShared` overrides) so configure
/// after first paint still enables durable caching, and [ImageBytesCache.resetShared]
/// / configure replacement cannot leave this ladder permanently bound to NoOp
/// or a closed previous store.
final class ImageBytesResolver implements IImageBytesResolver {
  /// Injected wiring for tests and hosts that own their own ladder instances.
  ImageBytesResolver({
    required IImageBytesCache cache,
    required HttpBytesFetcher fetcher,
    ImageBytesDiagnostics? diagnostics,
  }) : _cacheOf = (() => cache),
       _fetcherOf = (() => fetcher),
       _diagnostics = diagnostics;

  /// Process-wide ladder that re-reads shared cache/fetcher on every resolve.
  ImageBytesResolver._liveShared({ImageBytesDiagnostics? diagnostics})
    : _cacheOf = ImageBytesCache.shared,
      _fetcherOf = HttpBytesFetcher.shared,
      _diagnostics = diagnostics;

  /// Process-wide default when nothing is injected.
  ///
  /// Returns one shared instance, but that instance looks up the current
  /// [ImageBytesCache.shared] / [HttpBytesFetcher.shared] on each [resolve]
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
  final HttpBytesFetcher Function() _fetcherOf;
  final ImageBytesDiagnostics? _diagnostics;

  ImageBytesDiagnostics get _effectiveDiagnostics => _diagnostics ?? ImageBytesDiagnostics.current;

  @override
  Future<Uint8List> resolve(ImageBytesRequest request) async {
    final key = request.cacheKey ?? ImageCacheKey.fromUrl(request.url, headers: request.headers);
    final cache = _cacheOf();
    final fetcher = _fetcherOf();

    final cached = await cache.read(key);
    if (cached case final bytes? when bytes.isNotEmpty) {
      return bytes;
    }

    final bytes = await fetcher.getBytes(
      Uri.base.resolve(request.url),
      headers: request.headers,
      onBytesProgress: request.onBytesProgress,
    );

    // Persist off the critical path. A failed write must not fail paint that
    // already has network bytes; report so durable-store bugs stay observable
    // when the host opts into [ImageBytesDiagnostics].
    unawaited(
      cache.write(key, bytes).catchError((Object error, StackTrace stackTrace) {
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
}
