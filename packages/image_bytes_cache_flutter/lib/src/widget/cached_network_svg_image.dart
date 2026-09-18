import 'dart:async';
import 'dart:typed_data';

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

  /// Resolve or SVG parse/paint failed.
  ///
  /// [error] is whatever the resolver, PageStorage path, or [SvgPicture]
  /// decode threw.
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

/// Resolve or paint failed before a usable picture.
final class CachedNetworkSvgImageFailure extends CachedNetworkSvgImageState {
  const CachedNetworkSvgImageFailure(this.error, this.stackTrace);

  /// From cache, HTTP, empty-body checks, or SVG decode/paint.
  final Object error;

  final StackTrace stackTrace;
}

/// Paints a remote SVG from [IImageBytesResolver] bytes.
///
/// Does not open files or sockets. Asks [resolver] for bytes, optionally keeps
/// a short-lived copy in [PageStorage] under the same [ImageCacheKey] as the
/// shared store (see [persistInPageStorage] / [pageStorageMaxBytes]), then
/// draws with [SvgPicture.memory].
///
/// Register the [ValueNotifier] listener before the first load. Otherwise a
/// synchronous PageStorage hit skips [onError] and PageStorage writes.
///
/// Soft failures — resolve **and** SVG parse/paint — surface only through
/// [onError] / [errorBuilder]. Decode failures are forwarded from
/// [SvgPicture.errorBuilder] into [CachedNetworkSvgImageState.failure] so hosts
/// never see an endless [placeholderBuilder] disguise.
///
/// Reload gating follows [ImageCacheKey] identity (canonical URL + canonical
/// headers), not raw [Map] equality: `null` vs `{}` and header key casing do
/// not force a reload; a real [Authorization] value change does.
class CachedNetworkSvgImage extends StatefulWidget {
  /// Default ceiling for [PageStorage] SVG body copies (64 KiB).
  ///
  /// Aligns with the core large-body threshold so scroll restore stays cheap
  /// for typical icons while a long-lived route cannot accumulate a second
  /// unbounded RAM cache of full payloads. Override per widget with
  /// [pageStorageMaxBytes], or disable with [persistInPageStorage].
  static const int defaultPageStorageMaxBytes = 64 * 1024;

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
    this.persistInPageStorage = true,
    this.pageStorageMaxBytes = defaultPageStorageMaxBytes,
  }) : assert(
         pageStorageMaxBytes >= 0,
         'pageStorageMaxBytes must be non-negative (got $pageStorageMaxBytes).',
       );

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
  ///
  /// Not reused as [SvgPicture.placeholderBuilder] after bytes resolve — that
  /// would flash the loading chrome again during decode and disguise paint
  /// failures as endless loading when [SvgPicture.errorBuilder] is unwired.
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

  /// When true (default), successful resolves may write a short-lived SVG body
  /// into [PageStorage] under [ImageCacheKey.value] for scroll remount restore.
  ///
  /// Disable to avoid any widget-local body cache on long-lived routes; durable
  /// hits still go through [IImageBytesResolver].
  final bool persistInPageStorage;

  /// Max UTF-8 / byte length written to [PageStorage] when
  /// [persistInPageStorage] is true.
  ///
  /// Bodies larger than this still resolve and paint; they are simply not
  /// mirrored into [PageStorage]. Defaults to [defaultPageStorageMaxBytes].
  final int pageStorageMaxBytes;

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
    final oldKey = ImageCacheKey.fromUrl(oldWidget.url, headers: oldWidget.headers);
    if (oldKey == _cacheKey && oldWidget.resolver == widget.resolver) {
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
        _clearPageStorage();
        widget.onError?.call(error, stackTrace);
      case CachedNetworkSvgImagePopulated(:final imageBytes):
        _writePageStorage(imageBytes);
    }
  }

  void _writePageStorage(Uint8List imageBytes) {
    if (!widget.persistInPageStorage) return;
    if (imageBytes.length > widget.pageStorageMaxBytes) return;
    PageStorage.of(context).writeState(context, imageBytes, identifier: _cacheKey.value);
  }

  void _clearPageStorage() {
    if (!widget.persistInPageStorage) return;
    PageStorage.of(context).writeState(context, null, identifier: _cacheKey.value);
  }

  Future<void> _loadImage() async {
    final generation = ++_loadGeneration;

    try {
      if (PageStorage.of(context).readState(
            context,
            identifier: _cacheKey.value,
          )
          case final Uint8List bytes when bytes.isNotEmpty && widget.persistInPageStorage) {
        if (generation != _loadGeneration) return;
        _updateState(CachedNetworkSvgImagePopulated(bytes));
        return;
      }

      // Keep previous picture while a new identity resolves so warm remounts /
      // URL changes do not mandate a placeholder flash when we already have
      // something to paint.
      if (_state.value is! CachedNetworkSvgImagePopulated) {
        _updateState(const CachedNetworkSvgImageLoading());
      }

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

  void _reportPaintFailure(Object error, StackTrace stackTrace) {
    if (!mounted) return;
    if (_state.value is CachedNetworkSvgImageFailure) return;
    _updateState(CachedNetworkSvgImageFailure(error, stackTrace));
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
            theme: widget.theme,
            excludeFromSemantics: widget.excludeFromSemantics,
            errorBuilder: (context, error, stackTrace) {
              // SvgPicture invokes this during build; defer the sealed-state
              // transition so we do not mutate the notifier mid-build. Return
              // empty here — [errorBuilder] / [onError] run from the failure
              // branch after the microtask, not twice.
              scheduleMicrotask(() => _reportPaintFailure(error, stackTrace));
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
  }
}
