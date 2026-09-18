import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:image_bytes_cache/image_bytes_cache.dart';

/// Load lifecycle for [CachedNetworkSvgImage].
///
/// Use [map] so loading / failure / populated each get their own widget tree.
sealed class CachedNetworkSvgImageState {
  const CachedNetworkSvgImageState();

  /// Bytes not ready yet.
  const factory CachedNetworkSvgImageState.loading() = CachedNetworkSvgImageLoading;

  /// Ready to paint.
  const factory CachedNetworkSvgImageState.populated(Uint8List imageBytes) = CachedNetworkSvgImagePopulated;

  /// Resolve failed. [error] is whatever the resolver or PageStorage path threw.
  const factory CachedNetworkSvgImageState.failure(
    Object error,
    StackTrace stackTrace,
  ) = CachedNetworkSvgImageFailure;

  /// Exhaustive dispatch on the variant.
  T map<T>({
    required T Function(CachedNetworkSvgImageLoading loading) loading,
    required T Function(CachedNetworkSvgImagePopulated populated) populated,
    required T Function(CachedNetworkSvgImageFailure failure) failure,
  }) {
    return switch (this) {
      final CachedNetworkSvgImageLoading s => loading(s),
      final CachedNetworkSvgImagePopulated s => populated(s),
      final CachedNetworkSvgImageFailure s => failure(s),
    };
  }
}

/// Waiting for PageStorage, shared cache, or network.
final class CachedNetworkSvgImageLoading extends CachedNetworkSvgImageState {
  const CachedNetworkSvgImageLoading();
}

/// Ready to paint with [imageBytes].
final class CachedNetworkSvgImagePopulated extends CachedNetworkSvgImageState {
  const CachedNetworkSvgImagePopulated(this.imageBytes);

  /// SVG bytes from [IImageBytesResolver].
  final Uint8List imageBytes;
}

/// Resolve failed before paint.
final class CachedNetworkSvgImageFailure extends CachedNetworkSvgImageState {
  const CachedNetworkSvgImageFailure(this.error, this.stackTrace);

  /// From cache, HTTP, or empty-body checks.
  final Object error;

  final StackTrace stackTrace;
}

/// Paints a remote SVG from [IImageBytesResolver] bytes.
///
/// Does not open files or sockets. Asks [resolver] for bytes, keeps a
/// short-lived copy in [PageStorage] under the same [ImageCacheKey] as the
/// shared store, then draws with [SvgPicture.memory].
///
/// Register the [ValueNotifier] listener before the first load. Otherwise a
/// synchronous PageStorage hit skips [onError] and PageStorage writes.
///
/// Soft failures surface only through [onError] / [errorBuilder] — this widget
/// does not depend on a product logger.
class CachedNetworkSvgImage extends StatefulWidget {
  const CachedNetworkSvgImage(
    this.url, {
    super.key,
    this.width,
    this.height,
    this.headers,
    this.fit = BoxFit.contain,
    this.alignment = Alignment.center,
    this.matchTextDirection = false,
    this.allowDrawingOutsideViewBox = false,
    this.semanticsLabel,
    this.excludeFromSemantics = false,
    this.theme = const SvgTheme(),
    this.colorFilter,
    this.placeholderBuilder,
    this.errorBuilder,
    this.onError,
    this.resolver,
  });

  /// Absolute or [Uri.base]-relative SVG URL.
  final String url;

  /// Defaults to [ImageBytesResolver.shared].
  final IImageBytesResolver? resolver;

  /// Layout width passed to [SvgPicture].
  final double? width;

  /// Layout height passed to [SvgPicture].
  final double? height;

  /// HTTP headers for the network hop. Also folded into [ImageCacheKey].
  final Map<String, String>? headers;

  /// How the SVG fits its box.
  final BoxFit fit;

  /// Alignment inside the box.
  final AlignmentGeometry alignment;

  /// Mirrors [SvgPicture.matchTextDirection].
  final bool matchTextDirection;

  /// Mirrors [SvgPicture.allowDrawingOutsideViewBox].
  final bool allowDrawingOutsideViewBox;

  /// Accessibility label when semantics are enabled.
  final String? semanticsLabel;

  /// When true, omits the semantics node.
  final bool excludeFromSemantics;

  /// flutter_svg theme applied while painting.
  final SvgTheme theme;

  /// Optional tint / blend. Prefer this over ad-hoc color arguments.
  final ColorFilter? colorFilter;

  /// Built while [CachedNetworkSvgImageState.loading] is active.
  final WidgetBuilder? placeholderBuilder;

  /// Built on [CachedNetworkSvgImageState.failure]. Defaults to an empty box.
  final Widget Function(
    BuildContext context,
    Object error,
    StackTrace stackTrace,
  )?
  errorBuilder;

  /// Invoked once per failure transition. When null, failures stay silent here.
  final void Function(Object error, StackTrace stackTrace)? onError;

  @override
  State<CachedNetworkSvgImage> createState() => _CachedNetworkSvgImageState();
}

class _CachedNetworkSvgImageState extends State<CachedNetworkSvgImage> {
  late final _state = ValueNotifier<CachedNetworkSvgImageState>(
    const CachedNetworkSvgImageLoading(),
  );

  var _loadGeneration = 0;

  ImageCacheKey get _cacheKey => ImageCacheKey.fromUrl(widget.url, headers: widget.headers);

  IImageBytesResolver get _resolver => widget.resolver ?? ImageBytesResolver.shared();

  @override
  void initState() {
    super.initState();
    // Listener first: PageStorage hits update state before any await.
    _state.addListener(_onStateChanged);
    _loadImage();
  }

  @override
  void didUpdateWidget(covariant CachedNetworkSvgImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url == widget.url &&
        mapEquals(oldWidget.headers, widget.headers) &&
        oldWidget.resolver == widget.resolver) {
      return;
    }
    _loadImage();
  }

  void _updateState(CachedNetworkSvgImageState state) {
    if (!mounted) return;
    _state.value = state;
  }

  void _onStateChanged() {
    final state = _state.value;

    switch (state) {
      case CachedNetworkSvgImageLoading():
        break;
      case CachedNetworkSvgImageFailure(:final error, :final stackTrace):
        widget.onError?.call(error, stackTrace);
      case CachedNetworkSvgImagePopulated(:final imageBytes):
        PageStorage.of(
          context,
        ).writeState(context, imageBytes, identifier: _cacheKey.value);
    }
  }

  Future<void> _loadImage() async {
    final generation = ++_loadGeneration;

    try {
      if (PageStorage.of(context).readState(
            context,
            identifier: _cacheKey.value,
          )
          case final Uint8List bytes when bytes.isNotEmpty) {
        if (generation != _loadGeneration) return;
        _updateState(CachedNetworkSvgImagePopulated(bytes));
        return;
      }

      _updateState(const CachedNetworkSvgImageLoading());

      final bytes = await _resolver.resolve(
        ImageBytesRequest(url: widget.url, headers: widget.headers),
      );

      if (generation != _loadGeneration) return;
      _updateState(CachedNetworkSvgImagePopulated(bytes));
    } on Object catch (error, stackTrace) {
      if (generation != _loadGeneration) return;
      _updateState(CachedNetworkSvgImageFailure(error, stackTrace));
    }
  }

  @override
  void dispose() {
    _loadGeneration++;
    _state
      ..removeListener(_onStateChanged)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: ValueListenableBuilder(
        valueListenable: _state,
        builder: (_, state, _) => state.map(
          loading: (_) => widget.placeholderBuilder?.call(context) ?? const SizedBox.shrink(),
          failure: (s) => widget.errorBuilder?.call(context, s.error, s.stackTrace) ?? const SizedBox.shrink(),
          populated: (s) => SvgPicture.memory(
            s.imageBytes,
            fit: widget.fit,
            width: widget.width,
            height: widget.height,
            alignment: widget.alignment,
            matchTextDirection: widget.matchTextDirection,
            allowDrawingOutsideViewBox: widget.allowDrawingOutsideViewBox,
            semanticsLabel: widget.semanticsLabel,
            colorFilter: widget.colorFilter,
            placeholderBuilder: widget.placeholderBuilder,
            theme: widget.theme,
            excludeFromSemantics: widget.excludeFromSemantics,
          ),
        ),
      ),
    );
  }
}
