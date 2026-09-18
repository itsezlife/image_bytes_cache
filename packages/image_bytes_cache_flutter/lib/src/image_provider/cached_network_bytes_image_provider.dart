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
/// Network-miss progress from [ImageBytesRequest.onBytesProgress] becomes
/// [ImageChunkEvent]s for [Image.loadingBuilder]. A durable cache hit stays
/// quiet; that silence is not 0% progress.
///
/// Flutter [ImageCache] equality is [cacheKey], [scale], and optional decode
/// size ([cacheWidth] / [cacheHeight] / [allowUpscaling]). Durable store and
/// HTTP coalesce identity stay [ImageCacheKey] alone. [resolver] and
/// [errorListener] are wiring only and do not participate in equality.
///
/// Prefer [cacheWidth] / [cacheHeight] (or [.sized]) when the host needs
/// display-sized bitmaps under [DecorationImage], [CircleAvatar], or any
/// non-[Image] slot. Wrapping an **unsized** provider in [ResizeImage] is
/// fine; stacking [ResizeImage] on a provider that already sets decode size
/// asserts.
///
/// Resolve, empty-body, and decode failures surface on the [ImageStream].
/// Optional [errorListener] reports those soft failures when the host has no
/// [Image.errorBuilder] (for example [DecorationImage] alone).
@immutable
class CachedNetworkBytesImageProvider extends ImageProvider<CachedNetworkBytesImageProvider> {
  /// Creates a provider for [url].
  ///
  /// When [resolver] is null, uses [ImageBytesResolver.shared]. Pass an
  /// explicit resolver in tests so the suite need not process-wide configure.
  ///
  /// When [cacheWidth] and [cacheHeight] are both null, decode is full
  /// resolution and external [ResizeImage] wrapping is valid. Supply either
  /// dimension to decode at display size and split Flutter [ImageCache]
  /// identity from the unsized case.
  const CachedNetworkBytesImageProvider(
    this.url, {
    this.scale = 1.0,
    this.headers,
    this.cacheWidth,
    this.cacheHeight,
    this.allowUpscaling = false,
    this.resolver,
    this.errorListener,
  }) : assert(
         cacheWidth == null || cacheWidth > 0,
         'cacheWidth must be null or > 0.',
       ),
       assert(
         cacheHeight == null || cacheHeight > 0,
         'cacheHeight must be null or > 0.',
       );

  /// Creates a provider that always requests a display-sized decode.
  ///
  /// At least one of [cacheWidth] and [cacheHeight] must be non-null. Same
  /// durable identity as the unnamed constructor; Flutter [ImageCache]
  /// identity includes the decode size.
  const CachedNetworkBytesImageProvider.sized(
    this.url, {
    this.scale = 1.0,
    this.headers,
    this.cacheWidth,
    this.cacheHeight,
    this.allowUpscaling = false,
    this.resolver,
    this.errorListener,
  }) : assert(
         cacheWidth != null || cacheHeight != null,
         'CachedNetworkBytesImageProvider.sized requires cacheWidth and/or '
         'cacheHeight.',
       ),
       assert(
         cacheWidth == null || cacheWidth > 0,
         'cacheWidth must be null or > 0.',
       ),
       assert(
         cacheHeight == null || cacheHeight > 0,
         'cacheHeight must be null or > 0.',
       );

  /// Absolute or [Uri.base]-relative image URL passed to [IImageBytesResolver].
  final String url;

  /// Linear scale for decoded [ImageInfo].
  ///
  /// Participates in Flutter [ImageCache] identity with [cacheKey] and decode
  /// size. Does not change the durable [ImageCacheKey] or coalesce key.
  final double scale;

  /// HTTP headers for the network hop; folded into [cacheKey] via
  /// [ImageCacheKey.fromUrl].
  final Map<String, String>? headers;

  /// Target decode width in pixels, or null for intrinsic / height-only sizing.
  ///
  /// Participates in Flutter [ImageCache] identity. Does not change durable
  /// [ImageCacheKey] or HTTP coalesce. Pass through [ui.TargetImageSize] using
  /// [ResizeImagePolicy.exact] semantics (clamp when [allowUpscaling] is false).
  final int? cacheWidth;

  /// Target decode height in pixels, or null for intrinsic / width-only sizing.
  ///
  /// Same identity and durable-key rules as [cacheWidth].
  final int? cacheHeight;

  /// Whether [cacheWidth] / [cacheHeight] may exceed the intrinsic dimensions.
  ///
  /// Defaults to false (clamp to intrinsic). Participates in Flutter
  /// [ImageCache] identity with the decode size; ignored when both dimensions
  /// are null.
  final bool allowUpscaling;

  /// Ladder used to resolve bytes. Defaults to [ImageBytesResolver.shared].
  ///
  /// Omitted from [operator ==] / [hashCode] so injection does not split
  /// Flutter [ImageCache] entries for the same Flutter identity.
  final IImageBytesResolver? resolver;

  /// Called once when resolve, empty-body, or decode fails.
  ///
  /// Signature matches [ImageErrorListener]. Omitted from [operator ==] /
  /// [hashCode] so a new closure on rebuild does not split Flutter
  /// [ImageCache]. Useful under [DecorationImage] and other slots without
  /// [Image.errorBuilder]; stream [onError] / [DecorationImage.onError] still
  /// work on their own.
  final ImageErrorListener? errorListener;

  /// Durable identity for [url] + [headers] ([ImageCacheKey.fromUrl]).
  ///
  /// Flutter [ImageCache] keys this provider as [cacheKey], [scale], and
  /// optional decode size — not this getter alone.
  ImageCacheKey get cacheKey => ImageCacheKey.fromUrl(url, headers: headers);

  bool get _hasDecodeSize => cacheWidth != null || cacheHeight != null;

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

    final completer = MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, chunkEvents, decode: decode),
      chunkEvents: chunkEvents.stream,
      scale: key.scale,
      debugLabel: key.url,
      informationCollector: () => <DiagnosticsNode>[
        DiagnosticsProperty<ImageProvider>('Image provider', this),
        DiagnosticsProperty<CachedNetworkBytesImageProvider>('Image key', key),
      ],
    );

    // Ephemeral: participates in reportError handling without keep-alive.
    // Do not also invoke errorListener from _loadAsync's catch (double-fire).
    final listener = errorListener;
    if (listener != null) {
      completer.addEphemeralErrorListener(listener);
    }

    return completer;
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

      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      if (!key._hasDecodeSize) {
        // Leave getTargetSize unset so external ResizeImage wrapping works.
        // Await so decode failures enter catch (evict) instead of escaping the
        // try as an unawaited Future.
        return await decode(buffer);
      }

      return await decode(
        buffer,
        getTargetSize: (intrinsicWidth, intrinsicHeight) {
          // ResizeImagePolicy.exact: host dims as targets, clamp unless
          // allowUpscaling — same contract Image.network / ResizeImage use.
          var targetWidth = key.cacheWidth;
          var targetHeight = key.cacheHeight;

          if (!key.allowUpscaling) {
            if (targetWidth != null && targetWidth > intrinsicWidth) {
              targetWidth = intrinsicWidth;
            }
            if (targetHeight != null && targetHeight > intrinsicHeight) {
              targetHeight = intrinsicHeight;
            }
          }

          return ui.TargetImageSize(width: targetWidth, height: targetHeight);
        },
      );
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
    return other is CachedNetworkBytesImageProvider &&
        other.cacheKey == cacheKey &&
        other.scale == scale &&
        other.cacheWidth == cacheWidth &&
        other.cacheHeight == cacheHeight &&
        // allowUpscaling is meaningless without a decode size; ignore it so
        // unsized providers do not split ImageCache on a no-op flag.
        (!_hasDecodeSize || other.allowUpscaling == allowUpscaling);
  }

  @override
  int get hashCode => Object.hash(
    cacheKey,
    scale,
    cacheWidth,
    cacheHeight,
    _hasDecodeSize ? allowUpscaling : null,
  );

  @override
  String toString() =>
      '${objectRuntimeType(this, 'CachedNetworkBytesImageProvider')}'
      '("$url", scale: ${scale.toStringAsFixed(1)}'
      '${_hasDecodeSize ? ', cacheWidth: $cacheWidth, cacheHeight: $cacheHeight'
                ', allowUpscaling: $allowUpscaling' : ''}'
      ', cacheKey: $cacheKey)';
}
