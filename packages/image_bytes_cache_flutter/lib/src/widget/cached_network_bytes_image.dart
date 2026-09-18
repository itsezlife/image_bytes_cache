import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:image_bytes_cache/image_bytes_cache.dart';

import '../image_provider/cached_network_bytes_image_provider.dart';

/// Thin [Image] convenience over [CachedNetworkBytesImageProvider].
///
/// When [cacheWidth] and/or [cacheHeight] are set, they go onto the provider
/// (Flutter [ImageCache] identity includes decode size). Do not also wrap this
/// widget's image in [ResizeImage] — two decode-size layers assert.
///
/// Soft failures surface via [errorBuilder] and optional [onError]. [onError]
/// runs once per distinct failure object for the current image identity; it is
/// not a product logger. Resolve, empty-body, and decode failures all take
/// this path.
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

  /// See [Image.loadingBuilder]. Receives honest network-miss [ImageChunkEvent]s;
  /// durable cache hits do not invent mid-download percents.
  final ImageLoadingBuilder? loadingBuilder;

  /// Built when the [ImageStream] reports a failure. Defaults to an empty box
  /// when [onError] is set and this is null; when both are null, Flutter's
  /// default error reporting applies.
  final ImageErrorWidgetBuilder? errorBuilder;

  /// Invoked once per distinct failure for the current image identity.
  ///
  /// When null, failures stay silent here aside from [errorBuilder] / Flutter
  /// debug reporting. Not a product logger.
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
  Object? _reportedError;

  @override
  void didUpdateWidget(covariant CachedNetworkBytesImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldProvider = _providerFor(oldWidget);
    final newProvider = _providerFor(widget);
    if (oldProvider != newProvider) {
      _reportedError = null;
    }
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
    );
  }

  void _reportError(Object error, StackTrace? stackTrace) {
    final onError = widget.onError;
    if (onError == null) return;
    if (identical(_reportedError, error)) return;
    _reportedError = error;
    onError(error, stackTrace ?? StackTrace.empty);
  }

  /// Bridges [Image.errorBuilder] so optional [CachedNetworkBytesImage.onError]
  /// fires once per distinct failure without running host side-effects mid-build.
  ImageErrorWidgetBuilder? get _bridgedErrorBuilder {
    if (widget.errorBuilder == null && widget.onError == null) {
      return null;
    }
    return (context, error, stackTrace) {
      // Image invokes errorBuilder during build while holding the failure;
      // defer onError so hosts never mutate mid-build.
      if (widget.onError != null && !identical(_reportedError, error)) {
        scheduleMicrotask(() => _reportError(error, stackTrace));
      }
      return widget.errorBuilder?.call(context, error, stackTrace) ?? const SizedBox.shrink();
    };
  }

  @override
  Widget build(BuildContext context) {
    return Image(
      image: _providerFor(widget),
      frameBuilder: widget.frameBuilder,
      loadingBuilder: widget.loadingBuilder,
      errorBuilder: _bridgedErrorBuilder,
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
