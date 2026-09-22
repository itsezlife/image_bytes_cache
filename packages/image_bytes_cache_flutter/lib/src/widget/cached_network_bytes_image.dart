import 'package:flutter/widgets.dart';
import 'package:image_bytes_cache/image_bytes_cache.dart';

import '../image_provider/cached_network_bytes_image_provider.dart';
import 'image_fade_policy.dart';
import 'raster_paint_compose.dart';

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
///
/// ## High-level chrome vs raw builders
///
/// Optional [placeholderBuilder], [progressBuilder], [fadePolicy],
/// [fadeInDuration], and [fadeOutDuration] call [RasterPaintCompose]. Those
/// knobs are mutually exclusive with raw [frameBuilder] / [loadingBuilder] —
/// stacking both would double-wrap fade or loading trees. Omitting all
/// high-level knobs keeps today's thin [Image] path (no default fade).
///
/// When any high-level knob is set, defaults are [ImageFadePolicy.standard],
/// 300ms fade-in, and zero fade-out. Progress replaces placeholder when real
/// [ImageChunkEvent]s exist; quiet resolves invent no progress.
///
/// This convenience path does not yet supply [ImageBytesOrigin] to compose, so
/// [ImageFadeSkip.bytesCache] never matches here even under [ImageFadePolicy.standard].
/// [ImageFadeSkip.imageCache] still skips on a synchronous Flutter decode.
/// Bare [Image] + [RasterPaintCompose.builders] can pass [originOf] today.
class CachedNetworkBytesImage extends StatefulWidget {
  /// Creates a thin raster image for [url].
  ///
  /// When [resolver] is null, uses [ImageBytesResolver.shared]. Pass an
  /// explicit resolver in tests so the suite need not process-wide configure.
  ///
  /// [cacheWidth] / [cacheHeight] request a display-sized decode on the
  /// provider; both null means full-resolution decode.
  ///
  /// High-level chrome ([placeholderBuilder] / [progressBuilder] / fade knobs)
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
  ///
  /// Mutually exclusive with high-level chrome knobs.
  final ImageFrameBuilder? frameBuilder;

  /// See [Image.loadingBuilder]. Network-miss [ImageChunkEvent]s are real
  /// client bytes; durable cache hits do not invent mid-download progress.
  ///
  /// Mutually exclusive with high-level chrome knobs.
  final ImageLoadingBuilder? loadingBuilder;

  /// Built while waiting for the first frame when high-level chrome is on.
  ///
  /// Replaced by [progressBuilder] when real chunk events exist. Defaults to
  /// an empty box when null but other high-level knobs are set.
  final WidgetBuilder? placeholderBuilder;

  /// Built from real [ImageChunkEvent]s when high-level chrome is on.
  ///
  /// Replaces [placeholderBuilder] for the duration of chunk progress. Quiet
  /// resolves never call this.
  final RasterProgressBuilder? progressBuilder;

  /// Skip policy when high-level chrome is on. Defaults to
  /// [ImageFadePolicy.standard].
  ///
  /// On this widget, [ImageFadeSkip.bytesCache] stays inert (no origin yet);
  /// only [ImageFadeSkip.imageCache] can skip until compose receives origin.
  final ImageFadePolicy? fadePolicy;

  /// Image fade-in when high-level chrome is on. Defaults to 300ms.
  final Duration? fadeInDuration;

  /// Placeholder fade-out when high-level chrome is on. Defaults to zero.
  final Duration? fadeOutDuration;

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
  // Stable tear-off: ImageCache may reuse an equal provider, so the ephemeral
  // listener registered on first load must read the current widget.onError.
  void _forwardOnError(Object error, StackTrace? stackTrace) {
    widget.onError?.call(error, stackTrace ?? StackTrace.empty);
  }

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
      // Without origin, bytesCache never matches (fail-safe). imageCache still
      // honors wasSynchronouslyLoaded via compose's frameBuilder.
      originOf: null,
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
