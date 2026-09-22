import 'package:flutter/widgets.dart';
import 'package:image_bytes_cache/image_bytes_cache.dart';

import '../image_provider/cached_network_bytes_image_provider.dart';
import 'image_fade_policy.dart';
import 'raster_paint_compose.dart';

/// Thin [Image] over [CachedNetworkBytesImageProvider].
///
/// Call site near [Image.network]: builders, fit, semantics, gapless playback,
/// optional display-sized decode. [cacheWidth] / [cacheHeight] go on the
/// provider. Do not also wrap this widget in [ResizeImage].
///
/// Soft failures: [errorBuilder] for paint, optional [onError].
///
/// Optional [placeholderBuilder], [progressBuilder], [fadePolicy],
/// [fadeInDuration], [fadeOutDuration] call [RasterPaintCompose]. Those knobs
/// xor raw [frameBuilder] / [loadingBuilder]. Omitting all high-level knobs
/// keeps the thin [Image] path with no default fade.
///
/// High-level defaults: [ImageFadePolicy.standard], 300ms fade-in, zero
/// fade-out. Progress replaces placeholder when real [ImageChunkEvent]s exist.
/// State owns a [CachedNetworkBytesLoadSession] shared with the provider and
/// compose so [ImageFadeSkip.bytesCache] works under [ImageFadePolicy.standard].
class CachedNetworkBytesImage extends StatefulWidget {
  /// Creates a thin raster image for [url].
  ///
  /// Null [resolver] uses [ImageBytesResolver.shared]. High-level chrome knobs
  /// must not be combined with [frameBuilder] / [loadingBuilder].
  const CachedNetworkBytesImage(
    this.url, {
    super.key,
    this.scale = 1.0,
    this.frameBuilder,
    this.loadingBuilder,
    this.placeholderBuilder,
    this.progressBuilder,
    this.fadePolicy,
    this.fadeInDuration,
    this.fadeOutDuration,
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
       ),
       assert(
         fadeInDuration == null || fadeInDuration >= Duration.zero,
         'fadeInDuration must be null or non-negative.',
       ),
       assert(
         fadeOutDuration == null || fadeOutDuration >= Duration.zero,
         'fadeOutDuration must be null or non-negative.',
       ),
       assert(
         (placeholderBuilder == null &&
                 progressBuilder == null &&
                 fadePolicy == null &&
                 fadeInDuration == null &&
                 fadeOutDuration == null) ||
             (frameBuilder == null && loadingBuilder == null),
         'High-level placeholderBuilder/progressBuilder/fade knobs are '
         'mutually exclusive with frameBuilder/loadingBuilder.',
       );

  static bool _hasHighLevelChrome({
    required WidgetBuilder? placeholderBuilder,
    required RasterProgressBuilder? progressBuilder,
    required ImageFadePolicy? fadePolicy,
    required Duration? fadeInDuration,
    required Duration? fadeOutDuration,
  }) {
    return placeholderBuilder != null ||
        progressBuilder != null ||
        fadePolicy != null ||
        fadeInDuration != null ||
        fadeOutDuration != null;
  }

  /// Absolute or [Uri.base]-relative image URL.
  final String url;

  /// Linear scale for decoded [ImageInfo].
  final double scale;

  /// Defaults to [ImageBytesResolver.shared].
  final IImageBytesResolver? resolver;

  /// HTTP headers for the network hop; folded into [ImageCacheKey].
  final Map<String, String>? headers;

  /// Display-sized decode width, or null for intrinsic / height-only.
  /// Part of Flutter [ImageCache] identity via the provider.
  final int? cacheWidth;

  /// Display-sized decode height, or null for intrinsic / width-only.
  final int? cacheHeight;

  /// Whether decode dims may exceed intrinsic size. Default false.
  final bool allowUpscaling;

  /// See [Image.frameBuilder]. Xor with high-level chrome knobs.
  final ImageFrameBuilder? frameBuilder;

  /// See [Image.loadingBuilder]. Store hits invent no mid-download progress.
  /// Xor with high-level chrome knobs.
  final ImageLoadingBuilder? loadingBuilder;

  /// Waiting chrome when high-level knobs are on. Replaced by
  /// [progressBuilder] on real chunks. Empty box when null but other chrome
  /// knobs are set.
  final WidgetBuilder? placeholderBuilder;

  /// Real [ImageChunkEvent] chrome when high-level knobs are on. Quiet
  /// resolves never call this.
  final RasterProgressBuilder? progressBuilder;

  /// Defaults to [ImageFadePolicy.standard] when high-level chrome is on.
  final ImageFadePolicy? fadePolicy;

  /// Image fade-in when high-level chrome is on. Defaults to 300ms.
  final Duration? fadeInDuration;

  /// Placeholder fade-out when high-level chrome is on. Defaults to zero.
  final Duration? fadeOutDuration;

  /// Built when the [ImageStream] fails. With [onError] alone, paints an empty
  /// box. Both null: Flutter's default error reporting.
  final ImageErrorWidgetBuilder? errorBuilder;

  /// Once per failed load. Forwards to the provider [errorListener].
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

  bool get _usesHighLevelChrome => _hasHighLevelChrome(
    placeholderBuilder: placeholderBuilder,
    progressBuilder: progressBuilder,
    fadePolicy: fadePolicy,
    fadeInDuration: fadeInDuration,
    fadeOutDuration: fadeOutDuration,
  );

  @override
  State<CachedNetworkBytesImage> createState() => _CachedNetworkBytesImageState();
}

class _CachedNetworkBytesImageState extends State<CachedNetworkBytesImage> {
  // ImageCache may reuse an equal provider; the ephemeral listener must read
  // the current widget.onError.
  void _forwardOnError(Object error, StackTrace? stackTrace) {
    widget.onError?.call(error, stackTrace ?? StackTrace.empty);
  }

  // Survives rebuilds that mint a new equal provider so compose still sees
  // origin from the first loadImage.
  final CachedNetworkBytesLoadSession _loadSession = CachedNetworkBytesLoadSession();

  RasterPaintBuilders? _composed;

  @override
  void initState() {
    super.initState();
    _syncCompose();
  }

  @override
  void didUpdateWidget(CachedNetworkBytesImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.placeholderBuilder != widget.placeholderBuilder ||
        oldWidget.progressBuilder != widget.progressBuilder ||
        oldWidget.fadePolicy != widget.fadePolicy ||
        oldWidget.fadeInDuration != widget.fadeInDuration ||
        oldWidget.fadeOutDuration != widget.fadeOutDuration ||
        oldWidget._usesHighLevelChrome != widget._usesHighLevelChrome) {
      _syncCompose();
    }
  }

  void _syncCompose() {
    if (!widget._usesHighLevelChrome) {
      _composed = null;
      return;
    }
    _composed = RasterPaintCompose.builders(
      placeholderBuilder: widget.placeholderBuilder,
      progressBuilder: widget.progressBuilder,
      fadePolicy: widget.fadePolicy ?? ImageFadePolicy.standard,
      fadeInDuration: widget.fadeInDuration ?? RasterPaintCompose.defaultFadeInDuration,
      fadeOutDuration: widget.fadeOutDuration ?? RasterPaintCompose.defaultFadeOutDuration,
      originOf: () => _loadSession.origin,
    );
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
      loadSession: _loadSession,
    );
  }

  // Paint only; onError is owned by the provider.
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
    final composed = _composed;
    return Image(
      image: _providerFor(widget),
      frameBuilder: composed?.frameBuilder ?? widget.frameBuilder,
      loadingBuilder: composed?.loadingBuilder ?? widget.loadingBuilder,
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
