import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:image_bytes_cache/image_bytes_cache.dart';

/// Holds [ImageBytesOrigin] for one provider load so compose can honor
/// [ImageFadeSkip.bytesCache] without subclassing [ImageInfo].
///
/// Pass the same instance to [CachedNetworkBytesImageProvider.loadSession] and
/// to [RasterPaintCompose.builders] `originOf`. Omit it under
/// [DecorationImage]: resolve and decode still run; `bytesCache` stays inert.
/// Late completes from a superseded [loadImage] do not overwrite [origin].
/// Not part of Flutter [ImageCache] identity.
final class CachedNetworkBytesLoadSession {
  ImageBytesOrigin? _origin;
  int _generation = 0;

  /// Last recorded origin for the current load, or `null` until rich resolve
  /// finishes (and after each new [loadImage] begins).
  ImageBytesOrigin? get origin => _origin;

  // Bump generation and clear origin so a stale async complete cannot win.
  int _beginLoad() {
    _generation += 1;
    _origin = null;
    return _generation;
  }

  void _recordOrigin(int generation, ImageBytesOrigin origin) {
    if (generation != _generation) {
      return;
    }
    _origin = origin;
  }
}

/// How a decode box (`cacheWidth` × `cacheHeight`) maps onto the intrinsic
/// image size.
///
/// Only matters when both dims are set: with one dim, every policy scales the
/// other axis proportionally. Without `allowUpscaling`, the result never
/// exceeds the intrinsic size.
enum ImageDecodeSizePolicy {
  /// Decode at exactly the box; the aspect ratio follows the box.
  ///
  /// Same as [ResizeImagePolicy.exact] and [Image.network] `cacheWidth` /
  /// `cacheHeight`. Distorts an image whose aspect differs from the box.
  exact,

  /// Largest aspect-preserving size inside the box. Pair with [BoxFit.contain].
  ///
  /// Same as [ResizeImagePolicy.fit].
  fit,

  /// Smallest aspect-preserving size that covers the box. Pair with
  /// [BoxFit.cover], where [fit] would decode too small and blur.
  cover
  ;

  /// Decode target for an image of [intrinsicWidth] × [intrinsicHeight]
  /// requested at [width] × [height].
  ui.TargetImageSize targetSize({
    required int intrinsicWidth,
    required int intrinsicHeight,
    required int? width,
    required int? height,
    required bool allowUpscaling,
  }) {
    int? clamp(int? target, int intrinsic) => switch (target) {
      final target? when !allowUpscaling && target > intrinsic => intrinsic,
      _ => target,
    };

    // Passing a single axis lets the engine derive the other one from the
    // intrinsic aspect, so fit / cover never distort.
    ui.TargetImageSize byWidth(int width) => ui.TargetImageSize(width: clamp(width, intrinsicWidth));
    ui.TargetImageSize byHeight(int height) => ui.TargetImageSize(height: clamp(height, intrinsicHeight));

    return switch ((this, width, height)) {
      (ImageDecodeSizePolicy.fit, final width?, final height?) =>
        width / intrinsicWidth <= height / intrinsicHeight ? byWidth(width) : byHeight(height),
      (ImageDecodeSizePolicy.cover, final width?, final height?) =>
        width / intrinsicWidth >= height / intrinsicHeight ? byWidth(width) : byHeight(height),
      _ => ui.TargetImageSize(
        width: clamp(width, intrinsicWidth),
        height: clamp(height, intrinsicHeight),
      ),
    };
  }
}

/// [ImageProvider] that resolves remote bytes via [IImageBytesResolver], then
/// decodes with Flutter's codecs (PNG, JPEG, WebP, GIF, …).
///
/// Does not open files or sockets. Unlike [CachedNetworkSvgImage], does not
/// mirror bodies into [PageStorage].
///
/// Uses [IImageBytesResolver.resolveRich]. When [loadSession] is set, records
/// [ImageBytesOrigin] after resolve. Omitting the session is the bare
/// DecorationImage path: stock [ImageInfo], no origin side-channel.
///
/// Network-miss [ImageBytesRequest.onBytesProgress] becomes [ImageChunkEvent]s.
/// A store hit stays quiet; that silence is not 0% progress.
///
/// A two-axis decode box follows [decodeSizePolicy]: [ImageDecodeSizePolicy.exact]
/// by default ([Image.network] parity), or aspect-preserving
/// [ImageDecodeSizePolicy.fit] / [ImageDecodeSizePolicy.cover].
///
/// Flutter [ImageCache] identity is [cacheKey] + [scale] + optional decode size
/// ([cacheWidth] / [cacheHeight] / [allowUpscaling] / [decodeSizePolicy]). Durable store and HTTP
/// coalesce stay [ImageCacheKey] alone ([ImageCacheKey.fromUrl] of [url] +
/// [headers]). This type never takes an [ImageBytesRequest.cacheKey] override.
/// [resolver], [errorListener], and [loadSession] are wiring only and are
/// omitted from [operator ==].
///
/// Prefer [cacheWidth] / [cacheHeight] (or [.sized]) for display-sized bitmaps
/// under [DecorationImage] or other non-[Image] slots. Wrap an **unsized**
/// provider in [ResizeImage]; stacking [ResizeImage] on an already-sized
/// provider asserts.
///
/// Resolve, empty-body, and decode failures surface on the [ImageStream].
/// Optional [errorListener] covers slots without [Image.errorBuilder]
/// (DecorationImage alone).
///
/// A load cancels its resolve ([ImageBytesRequest.cancelToken]) once its
/// stream loses its last listener; the cancellation never reaches
/// [errorListener]. [ImageCache] itself listens to a pending load, so a host
/// that stops listening before the first frame should [evict] the provider to
/// let the request abort when nobody else waits on it.
@immutable
class CachedNetworkBytesImageProvider extends ImageProvider<CachedNetworkBytesImageProvider> {
  /// Creates a provider for [url].
  ///
  /// Null [resolver] uses [ImageBytesResolver.shared]. Both decode dims null
  /// means full-resolution decode (external [ResizeImage] is valid). Either
  /// dim set decodes at display size and splits Flutter [ImageCache] identity.
  /// Pass [loadSession] when compose needs origin for `bytesCache`.
  const CachedNetworkBytesImageProvider(
    this.url, {
    this.scale = 1.0,
    this.headers,
    this.cacheWidth,
    this.cacheHeight,
    this.allowUpscaling = false,
    this.decodeSizePolicy = ImageDecodeSizePolicy.exact,
    this.resolver,
    this.errorListener,
    this.loadSession,
  }) : assert(
         cacheWidth == null || cacheWidth > 0,
         'cacheWidth must be null or > 0.',
       ),
       assert(
         cacheHeight == null || cacheHeight > 0,
         'cacheHeight must be null or > 0.',
       );

  /// Display-sized decode. At least one of [cacheWidth] / [cacheHeight] required.
  /// Same durable identity as the unnamed constructor; Flutter [ImageCache]
  /// identity includes the decode size.
  const CachedNetworkBytesImageProvider.sized(
    this.url, {
    this.scale = 1.0,
    this.headers,
    this.cacheWidth,
    this.cacheHeight,
    this.allowUpscaling = false,
    this.decodeSizePolicy = ImageDecodeSizePolicy.exact,
    this.resolver,
    this.errorListener,
    this.loadSession,
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

  /// Absolute or [Uri.base]-relative URL for [IImageBytesResolver].
  final String url;

  /// Linear scale for decoded [ImageInfo]. Part of Flutter [ImageCache]
  /// identity; does not change the durable [ImageCacheKey].
  final double scale;

  /// HTTP headers for the network hop; folded into [cacheKey] via
  /// [ImageCacheKey.fromUrl].
  final Map<String, String>? headers;

  /// Target decode width in pixels, or null for intrinsic / height-only.
  ///
  /// Part of Flutter [ImageCache] identity, not durable [ImageCacheKey].
  /// Mapped onto the intrinsic size by [decodeSizePolicy] (clamp unless
  /// [allowUpscaling]).
  final int? cacheWidth;

  /// Target decode height in pixels, or null for intrinsic / width-only.
  /// Same identity rules as [cacheWidth].
  final int? cacheHeight;

  /// Whether decode dims may exceed intrinsic size. Default false.
  /// Part of Flutter [ImageCache] identity when a decode size is set; ignored
  /// when both dims are null.
  final bool allowUpscaling;

  /// How a two-axis decode box maps onto the intrinsic size. Default
  /// [ImageDecodeSizePolicy.exact]. Part of Flutter [ImageCache] identity only
  /// when both [cacheWidth] and [cacheHeight] are set; otherwise every policy
  /// decodes the same bitmap.
  final ImageDecodeSizePolicy decodeSizePolicy;

  /// Defaults to [ImageBytesResolver.shared]. Omitted from [operator ==].
  final IImageBytesResolver? resolver;

  /// Soft resolve / empty-body / decode failure. Matches [ImageErrorListener].
  /// Omitted from [operator ==]. Useful under [DecorationImage] without
  /// [Image.errorBuilder].
  final ImageErrorListener? errorListener;

  /// Receives [ImageBytesOrigin] after rich resolve. Omitted from
  /// [operator ==]. Null: resolve/decode only, no paint provenance.
  final CachedNetworkBytesLoadSession? loadSession;

  /// Durable identity for [url] + [headers] ([ImageCacheKey.fromUrl]).
  ///
  /// Not an [ImageBytesRequest.cacheKey] override: the provider always
  /// resolves with a null request override. Custom keys require calling
  /// [IImageBytesResolver] directly or injecting a resolver that does.
  ImageCacheKey get cacheKey => ImageCacheKey.fromUrl(url, headers: headers);

  bool get _hasDecodeSize => cacheWidth != null || cacheHeight != null;

  // Canonical form for identity: with fewer than two dims every policy decodes
  // the same bitmap, so a no-op policy must not split ImageCache.
  ImageDecodeSizePolicy get _effectiveDecodeSizePolicy =>
      cacheWidth != null && cacheHeight != null ? decodeSizePolicy : ImageDecodeSizePolicy.exact;

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
    // Handed to [_loadAsync], which must close on every completion path.
    final chunkEvents = StreamController<ImageChunkEvent>();
    final cancelToken = CancelToken();

    final completer = MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, chunkEvents, decode: decode, cancelToken: cancelToken),
      chunkEvents: chunkEvents.stream,
      scale: key.scale,
      debugLabel: key.url,
      informationCollector: () => <DiagnosticsNode>[
        DiagnosticsProperty<ImageProvider>('Image provider', this),
        DiagnosticsProperty<CachedNetworkBytesImageProvider>('Image key', key),
      ],
    )..addOnLastListenerRemovedCallback(() => cancelToken.cancel('no image stream listeners'));

    // Ephemeral: reportError without keep-alive. Do not also call from
    // _loadAsync's catch (double-fire).
    final listener = errorListener;
    if (listener != null) {
      completer.addEphemeralErrorListener((error, stackTrace) {
        if (cancelToken.isCancelled) return;
        listener(error, stackTrace);
      });
    }

    return completer;
  }

  Future<ui.Codec> _loadAsync(
    CachedNetworkBytesImageProvider key,
    StreamController<ImageChunkEvent> chunkEvents, {
    required ImageDecoderCallback decode,
    required CancelToken cancelToken,
  }) async {
    try {
      assert(
        key == this,
        'The provided key must match the current instance of CachedNetworkBytesImageProvider.',
      );

      final sessionAndGeneration = switch (key.loadSession) {
        final session? => (session, session._beginLoad()),
        null => null,
      };

      final rich = await key._resolver.resolveRich(
        ImageBytesRequest(
          url: key.url,
          headers: key.headers,
          cancelToken: cancelToken,
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

      if (sessionAndGeneration case (final session, final generation)) {
        session._recordOrigin(generation, rich.origin);
      }

      final bytes = rich.bytes;

      if (bytes.isEmpty) {
        throw StateError(
          'CachedNetworkBytesImageProvider resolved empty bytes for ${key.url}',
        );
      }

      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      if (!key._hasDecodeSize) {
        // Leave getTargetSize unset so external ResizeImage wrapping works.
        // Await so decode failures enter catch (evict) instead of escaping.
        return await decode(buffer);
      }

      return await decode(
        buffer,
        getTargetSize: (intrinsicWidth, intrinsicHeight) => key.decodeSizePolicy.targetSize(
          intrinsicWidth: intrinsicWidth,
          intrinsicHeight: intrinsicHeight,
          width: key.cacheWidth,
          height: key.cacheHeight,
          allowUpscaling: key.allowUpscaling,
        ),
      );
    } catch (error) {
      // Next microtask: sync evict can miss a still-pending ImageCache entry.
      scheduleMicrotask(() {
        PaintingBinding.instance.imageCache.evict(key);
      });
      rethrow;
    } finally {
      // Fire-and-forget: awaiting can race the codec Future and drop the
      // original resolve/decode failure.
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
        (!_hasDecodeSize || other.allowUpscaling == allowUpscaling) &&
        other._effectiveDecodeSizePolicy == _effectiveDecodeSizePolicy;
  }

  @override
  int get hashCode => Object.hash(
    cacheKey,
    scale,
    cacheWidth,
    cacheHeight,
    _hasDecodeSize ? allowUpscaling : null,
    _effectiveDecodeSizePolicy,
  );

  @override
  String toString() =>
      '${objectRuntimeType(this, 'CachedNetworkBytesImageProvider')}'
      '("$url", scale: ${scale.toStringAsFixed(1)}'
      '${_hasDecodeSize ? ', cacheWidth: $cacheWidth, cacheHeight: $cacheHeight'
                ', allowUpscaling: $allowUpscaling'
                ', decodeSizePolicy: ${_effectiveDecodeSizePolicy.name}' : ''}'
      ', cacheKey: $cacheKey)';
}
