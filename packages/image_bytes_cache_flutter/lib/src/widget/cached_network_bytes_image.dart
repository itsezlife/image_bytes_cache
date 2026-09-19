import 'package:flutter/widgets.dart';
import 'package:image_bytes_cache/image_bytes_cache.dart';

import '../image_provider/cached_network_bytes_image_provider.dart';

/// Thin [Image] convenience over [CachedNetworkBytesImageProvider].
///
/// Call site near [Image.network]: builders, fit, semantics, gapless playback,
/// and optional display-sized decode. [cacheWidth] / [cacheHeight] go onto the
/// provider (Flutter [ImageCache] identity includes decode size). Do not also
/// wrap this widget's image in [ResizeImage].
///
/// Soft failures use [errorBuilder] for paint and optional [onError] for a
/// once-per-load callback (forwarded to
/// [CachedNetworkBytesImageProvider.errorListener]).
class CachedNetworkBytesImage extends StatefulWidget {
  /// Creates a thin raster image for [url].
  ///
  /// When [resolver] is null, uses [ImageBytesResolver.shared]. Pass an
  /// explicit resolver in tests so the suite need not process-wide configure.
  ///
  /// [cacheWidth] / [cacheHeight] request a display-sized decode on the
  /// provider; both null means full-resolution decode.
  const CachedNetworkBytesImage(
    this.url, {
    super.key,
    this.scale = 1.0,
    this.frameBuilder,
    this.loadingBuilder,
    this.errorBuilder,
    this.onError,
    this.semanticLabel,
    this.excludeFromSemantics = false,
    this.width,
    this.height,
    this.color,
    this.opacity,
    this.colorBlendMode,
    this.fit,
    this.alignment = Alignment.center,
    this.repeat = ImageRepeat.noRepeat,
    this.centerSlice,
    this.matchTextDirection = false,
    this.gaplessPlayback = false,
    this.isAntiAlias = false,
    this.filterQuality = FilterQuality.medium,
    this.headers,
    this.cacheWidth,
    this.cacheHeight,
    this.allowUpscaling = false,
    this.resolver,
  }) : assert(
         cacheWidth == null || cacheWidth > 0,
         'cacheWidth must be null or > 0.',
       ),
       assert(
         cacheHeight == null || cacheHeight > 0,
         'cacheHeight must be null or > 0.',
       );

  /// Absolute or [Uri.base]-relative image URL.
  final String url;

  /// Linear scale for decoded [ImageInfo]. Forwarded to the provider.
  final double scale;

  /// Defaults to [ImageBytesResolver.shared].
  final IImageBytesResolver? resolver;

  /// HTTP headers for the network hop; folded into [ImageCacheKey].
  final Map<String, String>? headers;

  /// Target decode width in pixels, or null for intrinsic / height-only sizing.
  ///
  /// Participates in Flutter [ImageCache] identity via the provider. Does not
  /// change durable [ImageCacheKey] or HTTP coalesce.
  final int? cacheWidth;

  /// Target decode height in pixels, or null for intrinsic / width-only sizing.
  ///
  /// Same identity and durable-key rules as [cacheWidth].
  final int? cacheHeight;

  /// Whether [cacheWidth] / [cacheHeight] may exceed intrinsic dimensions.
  ///
  /// Defaults to false. Forwarded to the provider; ignored when both dimensions
  /// are null.
  final bool allowUpscaling;

  /// See [Image.frameBuilder].
  final ImageFrameBuilder? frameBuilder;

  /// See [Image.loadingBuilder]. Network-miss [ImageChunkEvent]s are real
  /// client bytes; durable cache hits do not invent mid-download progress.
  final ImageLoadingBuilder? loadingBuilder;

  /// Built when the [ImageStream] reports a failure.
  ///
  /// When [onError] is set and this is null, paints an empty box. When both
  /// are null, Flutter's default error reporting applies.
  final ImageErrorWidgetBuilder? errorBuilder;

  /// Called once per failed load. Forwards to the provider [errorListener].
  ///
  /// Uses [StackTrace.empty] when the stream supplies a null stack.
  final void Function(Object error, StackTrace stackTrace)? onError;

  /// Accessibility label when semantics are enabled.
  final String? semanticLabel;

  /// When true, omits the semantics node.
  final bool excludeFromSemantics;

  /// Layout width passed to [Image].
  final double? width;

  /// Layout height passed to [Image].
  final double? height;

  /// See [Image.color].
  final Color? color;

  /// See [Image.opacity].
  final Animation<double>? opacity;

  /// See [Image.colorBlendMode].
  final BlendMode? colorBlendMode;

  /// How the image fits its box.
  final BoxFit? fit;

  /// Alignment inside the box.
  final AlignmentGeometry alignment;

  /// See [Image.repeat].
  final ImageRepeat repeat;

  /// See [Image.centerSlice].
  final Rect? centerSlice;

  /// See [Image.matchTextDirection].
  final bool matchTextDirection;

  /// See [Image.gaplessPlayback].
  final bool gaplessPlayback;

  /// See [Image.isAntiAlias].
  final bool isAntiAlias;

  /// See [Image.filterQuality].
  final FilterQuality filterQuality;

  @override
  State<CachedNetworkBytesImage> createState() => _CachedNetworkBytesImageState();
}

class _CachedNetworkBytesImageState extends State<CachedNetworkBytesImage> {
  // Stable tear-off: ImageCache may reuse an equal provider, so the ephemeral
  // listener registered on first load must read the current widget.onError.
  void _forwardOnError(Object error, StackTrace? stackTrace) {
    widget.onError?.call(error, stackTrace ?? StackTrace.empty);
  }

  CachedNetworkBytesImageProvider _providerFor(CachedNetworkBytesImage w) {
    return CachedNetworkBytesImageProvider(
      w.url,
      scale: w.scale,
      headers: w.headers,
      cacheWidth: w.cacheWidth,
      cacheHeight: w.cacheHeight,
      allowUpscaling: w.allowUpscaling,
      resolver: w.resolver,
      errorListener: w.onError == null ? null : _forwardOnError,
    );
  }

  /// [Image.errorBuilder] for paint only; [onError] is owned by the provider.
  ImageErrorWidgetBuilder? get _paintErrorBuilder {
    if (widget.errorBuilder == null && widget.onError == null) {
      return null;
    }
    return (context, error, stackTrace) {
      return widget.errorBuilder?.call(context, error, stackTrace) ?? const SizedBox.shrink();
    };
  }

  @override
  Widget build(BuildContext context) {
    return Image(
      image: _providerFor(widget),
      frameBuilder: widget.frameBuilder,
      loadingBuilder: widget.loadingBuilder,
      errorBuilder: _paintErrorBuilder,
      semanticLabel: widget.semanticLabel,
      excludeFromSemantics: widget.excludeFromSemantics,
      width: widget.width,
      height: widget.height,
      color: widget.color,
      opacity: widget.opacity,
      colorBlendMode: widget.colorBlendMode,
      fit: widget.fit,
      alignment: widget.alignment,
      repeat: widget.repeat,
      centerSlice: widget.centerSlice,
      matchTextDirection: widget.matchTextDirection,
      gaplessPlayback: widget.gaplessPlayback,
      isAntiAlias: widget.isAntiAlias,
      filterQuality: widget.filterQuality,
    );
  }
}
