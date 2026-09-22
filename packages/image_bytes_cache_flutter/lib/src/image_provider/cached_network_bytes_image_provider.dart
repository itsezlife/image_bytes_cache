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
/// Flutter [ImageCache] identity is [cacheKey] + [scale] + optional decode size
/// ([cacheWidth] / [cacheHeight] / [allowUpscaling]). Durable store and HTTP
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
  /// [ResizeImagePolicy.exact] semantics (clamp unless [allowUpscaling]).
  final int? cacheWidth;

  /// Target decode height in pixels, or null for intrinsic / width-only.
  /// Same identity rules as [cacheWidth].
  final int? cacheHeight;

  /// Whether decode dims may exceed intrinsic size. Default false.
  /// Part of Flutter [ImageCache] identity when a decode size is set; ignored
  /// when both dims are null.
  final bool allowUpscaling;

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

    // Ephemeral: reportError without keep-alive. Do not also call from
    // _loadAsync's catch (double-fire).
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

      final sessionAndGeneration = switch (key.loadSession) {
        final session? => (session, session._beginLoad()),
        null => null,
      };

      final rich = await key._resolver.resolveRich(
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
        getTargetSize: (intrinsicWidth, intrinsicHeight) {
          // ResizeImagePolicy.exact: host dims as targets, clamp unless
          // allowUpscaling — same contract as Image.network / ResizeImage.
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
