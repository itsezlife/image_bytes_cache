// ignore_for_file: one_member_abstracts

import 'dart:async';
import 'dart:typed_data';

import 'package:image_bytes_cache/src/http_bytes_fetcher.dart';
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
  });

  /// Absolute or [Uri.base]-relative URL.
  final String url;

  /// Sent on the network hop and folded into the default [ImageCacheKey].
  final Map<String, String>? headers;

  /// When null, built with [ImageCacheKey.fromUrl].
  final ImageCacheKey? cacheKey;
}

/// Looks up bytes in a cache, then fetches, then write-through.
abstract interface class IImageBytesResolver {
  /// Resolves [request] to bytes.
  ///
  /// Empty cached payloads count as a miss so a bad empty write cannot poison
  /// the ladder. After a network hit, persistence runs off the critical path;
  /// a durable write failure is reported via [ImageBytesDiagnostics] and does
  /// not fail this future.
  Future<Uint8List> resolve(ImageBytesRequest request);
}

/// Default ladder: [IImageBytesCache] then [HttpBytesFetcher].
///
/// Order: cache read → network on miss → fire-and-forget write-through.
/// Callers that already hold bytes from a successful GET should keep painting;
/// storage bugs surface through [ImageBytesDiagnostics] (default silent), not
/// by failing [resolve].
final class ImageBytesResolver implements IImageBytesResolver {
  ImageBytesResolver({
    required IImageBytesCache cache,
    required HttpBytesFetcher fetcher,
    ImageBytesDiagnostics? diagnostics,
  }) : _cache = cache,
       _fetcher = fetcher,
       _diagnostics = diagnostics;

  /// Process-wide default when nothing is injected.
  factory ImageBytesResolver.shared() =>
      debugShared ??
      (_shared ??= ImageBytesResolver(
        cache: ImageBytesCache.shared(),
        fetcher: HttpBytesFetcher.shared(),
      ));

  static ImageBytesResolver? _shared;

  /// Test override for [ImageBytesResolver.shared]. Set to `null` to clear.
  @visibleForTesting
  static ImageBytesResolver? debugShared;

  final IImageBytesCache _cache;
  final HttpBytesFetcher _fetcher;
  final ImageBytesDiagnostics? _diagnostics;

  ImageBytesDiagnostics get _effectiveDiagnostics => _diagnostics ?? ImageBytesDiagnostics.current;

  @override
  Future<Uint8List> resolve(ImageBytesRequest request) async {
    final key = request.cacheKey ?? ImageCacheKey.fromUrl(request.url, headers: request.headers);

    final cached = await _cache.read(key);
    if (cached case final bytes? when bytes.isNotEmpty) {
      return bytes;
    }

    final bytes = await _fetcher.getBytes(
      Uri.base.resolve(request.url),
      headers: request.headers,
    );

    // Persist off the critical path. A failed write must not fail paint that
    // already has network bytes; report so durable-store bugs stay observable
    // when the host opts into [ImageBytesDiagnostics].
    unawaited(
      _cache.write(key, bytes).catchError((Object error, StackTrace stackTrace) {
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
