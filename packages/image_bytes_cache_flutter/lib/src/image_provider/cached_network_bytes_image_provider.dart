import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:image_bytes_cache/image_bytes_cache.dart';

/// [ImageProvider] for remote rasters resolved through [IImageBytesResolver].
///
/// Asks [resolver] for bytes, then decodes with Flutter's image pipeline
/// (PNG, JPEG, WebP, multi-frame GIF, and any other codec the engine accepts).
/// Does not open files or sockets. Unlike [CachedNetworkSvgImage], does not
/// mirror bodies into [PageStorage]; remounts rely on the durable ladder plus
/// Flutter's [ImageCache].
///
/// Network-miss progress from [ImageBytesRequest.onBytesProgress] is forwarded
/// as [ImageChunkEvent]s for [Image.loadingBuilder]. A durable cache hit does
/// not invent mid-download percents: the sink stays quiet, and hosts must not
/// treat that silence as 0%.
///
/// Flutter [ImageCache] equality is [cacheKey] plus [scale]. Durable store and
/// HTTP coalesce identity stay [ImageCacheKey] alone, so [scale] never enters
/// [ImageBytesRequest]. [resolver] is wiring only and is not part of equality;
/// two providers that share [cacheKey] and [scale] collide in [ImageCache]
/// even if their injected resolvers differ.
///
/// Resolve, empty-body, and decode failures surface on the [ImageStream]
/// ([Image.errorBuilder]). This type does not log soft failures.
@immutable
class CachedNetworkBytesImageProvider extends ImageProvider<CachedNetworkBytesImageProvider> {
  /// Creates a provider for [url].
  ///
  /// When [resolver] is null, uses [ImageBytesResolver.shared]. Pass an
  /// explicit resolver in tests so the suite need not process-wide configure.
  const CachedNetworkBytesImageProvider(
    this.url, {
    this.scale = 1.0,
    this.headers,
    this.resolver,
  });

  /// Absolute or [Uri.base]-relative image URL passed to [IImageBytesResolver].
  final String url;

  /// Linear scale for decoded [ImageInfo].
  ///
  /// Participates in Flutter [ImageCache] identity with [cacheKey]. Does not
  /// change the durable [ImageCacheKey] or coalesce key.
  final double scale;

  /// HTTP headers for the network hop; folded into [cacheKey] via
  /// [ImageCacheKey.fromUrl].
  final Map<String, String>? headers;

  /// Ladder used to resolve bytes. Defaults to [ImageBytesResolver.shared].
  ///
  /// Omitted from [operator ==] / [hashCode] so injection does not split
  /// Flutter [ImageCache] entries for the same [cacheKey] and [scale].
  final IImageBytesResolver? resolver;

  /// Durable identity for [url] + [headers] ([ImageCacheKey.fromUrl]).
  ///
  /// Flutter [ImageCache] keys this provider as [cacheKey] plus [scale].
  ImageCacheKey get cacheKey => ImageCacheKey.fromUrl(url, headers: headers);

  IImageBytesResolver get _resolver => resolver ?? ImageBytesResolver.shared();

  @override
  Future<CachedNetworkBytesImageProvider> obtainKey(
    ImageConfiguration configuration,
  ) {
    return SynchronousFuture<CachedNetworkBytesImageProvider>(this);
  }

  @override
  ImageStreamCompleter loadImage(
    CachedNetworkBytesImageProvider key,
    ImageDecoderCallback decode,
  ) {
    // Ownership of this controller is handed off to [_loadAsync], which must
    // close it on every completion path (success or failure).
    final chunkEvents = StreamController<ImageChunkEvent>();

    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, chunkEvents, decode: decode),
      chunkEvents: chunkEvents.stream,
      scale: key.scale,
      debugLabel: key.url,
      informationCollector: () => <DiagnosticsNode>[
        DiagnosticsProperty<ImageProvider>('Image provider', this),
        DiagnosticsProperty<CachedNetworkBytesImageProvider>('Image key', key),
      ],
    );
  }

  Future<ui.Codec> _loadAsync(
    CachedNetworkBytesImageProvider key,
    StreamController<ImageChunkEvent> chunkEvents, {
    required ImageDecoderCallback decode,
  }) async {
    try {
      assert(
        key == this,
        'The provided key must match the current instance of CachedNetworkBytesImageProvider.',
      );

      final bytes = await key._resolver.resolve(
        ImageBytesRequest(
          url: key.url,
          headers: key.headers,
          onBytesProgress: (cumulative, total) {
            chunkEvents.add(
              ImageChunkEvent(
                cumulativeBytesLoaded: cumulative,
                expectedTotalBytes: total,
              ),
            );
          },
        ),
      );

      if (bytes.isEmpty) {
        throw StateError(
          'CachedNetworkBytesImageProvider resolved empty bytes for ${key.url}',
        );
      }

      return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
    } catch (error) {
      // Evict on the next microtask so the image cache can finish tracking
      // this key before removal; a sync evict can miss a still-pending entry.
      scheduleMicrotask(() {
        PaintingBinding.instance.imageCache.evict(key);
      });
      rethrow;
    } finally {
      // Fire-and-forget close: awaiting here can race the codec Future's
      // error path and drop the original resolve/decode failure.
      chunkEvents.close().catchError((Object error, StackTrace stack) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stack,
            library: 'image_bytes_cache_flutter',
            context: ErrorDescription(
              'while closing chunkEvents stream in '
              'CachedNetworkBytesImageProvider.loadImage',
            ),
          ),
        );
      }).ignore();
    }
  }

  @override
  bool operator ==(Object other) {
    if (other.runtimeType != runtimeType) {
      return false;
    }
    return other is CachedNetworkBytesImageProvider && other.cacheKey == cacheKey && other.scale == scale;
  }

  @override
  int get hashCode => Object.hash(cacheKey, scale);

  @override
  String toString() =>
      '${objectRuntimeType(this, 'CachedNetworkBytesImageProvider')}'
      '("$url", scale: ${scale.toStringAsFixed(1)}, cacheKey: $cacheKey)';
}
