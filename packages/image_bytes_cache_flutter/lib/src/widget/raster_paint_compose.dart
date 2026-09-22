import 'package:flutter/widgets.dart';
import 'package:image_bytes_cache/image_bytes_cache.dart';

import 'image_fade_policy.dart';

/// [Image.frameBuilder] / [Image.loadingBuilder] pair from [RasterPaintCompose].
///
/// Closures share one compose session. Create once per image identity (e.g. in
/// [State]). Rebuilding a new [RasterPaintBuilders] every [State.build] resets
/// fade bookkeeping mid-flight.
@immutable
final class RasterPaintBuilders {
  const RasterPaintBuilders({
    required this.frameBuilder,
    this.loadingBuilder,
  });

  final ImageFrameBuilder frameBuilder;

  /// Non-null only when a progress builder was supplied.
  final ImageLoadingBuilder? loadingBuilder;
}

/// Placeholder, progress, and fade on [Image] builders.
///
/// Works with bare [Image] + any [ImageProvider], not only
/// [CachedNetworkBytesImage]. Widgets-level only (no Material). Keep-previous
/// across identity changes stays [Image.gaplessPlayback].
///
/// While `frame == null`: [placeholderBuilder] or an empty box. When
/// [progressBuilder] is set and chunks arrive, progress **replaces** the
/// placeholder. Quiet resolves keep the placeholder.
///
/// Fade-in is the image; fade-out is placeholder chrome. Either duration may
/// be zero (default out is zero). [ImageFadePolicy.shouldSkip] jumps both
/// alphas to final.
///
/// [originOf] feeds [ImageFadeSkip.bytesCache]. `null` / omitted never matches
/// that bit; only [ImageFadeSkip.imageCache] can skip until origin is known.
abstract final class RasterPaintCompose {
  /// Default image fade-in when high-level chrome is on.
  static const Duration defaultFadeInDuration = Duration(milliseconds: 300);

  /// Default placeholder fade-out (raise for crossfade).
  static const Duration defaultFadeOutDuration = Duration.zero;

  /// Distinguishes package fade from Material route fades in tests.
  @visibleForTesting
  static const Key fadeTransitionKey = Key('image_bytes_cache.raster_fade');

  /// Builder closures for one compose session.
  static RasterPaintBuilders builders({
    WidgetBuilder? placeholderBuilder,
    Widget Function(BuildContext context, ImageChunkEvent progress)? progressBuilder,
    ImageFadePolicy fadePolicy = ImageFadePolicy.standard,
    Duration fadeInDuration = defaultFadeInDuration,
    Duration fadeOutDuration = defaultFadeOutDuration,
    ImageBytesOrigin? Function()? originOf,
  }) {
    assert(
      fadeInDuration >= Duration.zero,
      'fadeInDuration must be non-negative.',
    );
    assert(
      fadeOutDuration >= Duration.zero,
      'fadeOutDuration must be non-negative.',
    );

    final session = _RasterPaintComposeSession(
      placeholderBuilder: placeholderBuilder,
      progressBuilder: progressBuilder,
      fadePolicy: fadePolicy,
      fadeInDuration: fadeInDuration,
      fadeOutDuration: fadeOutDuration,
      originOf: originOf,
    );
    return RasterPaintBuilders(
      frameBuilder: session.frameBuilder,
      loadingBuilder: switch (progressBuilder) {
        null => null,
        _ => session.loadingBuilder,
      },
    );
  }
}

final class _RasterPaintComposeSession {
  _RasterPaintComposeSession({
    required this.placeholderBuilder,
    required this.progressBuilder,
    required this.fadePolicy,
    required this.fadeInDuration,
    required this.fadeOutDuration,
    required this.originOf,
  });

  final WidgetBuilder? placeholderBuilder;
  final Widget Function(BuildContext context, ImageChunkEvent progress)? progressBuilder;
  final ImageFadePolicy fadePolicy;
  final Duration fadeInDuration;
  final Duration fadeOutDuration;
  final ImageBytesOrigin? Function()? originOf;

  Widget frameBuilder(
    BuildContext context,
    Widget child,
    int? frame,
    bool wasSynchronouslyLoaded,
  ) {
    if (frame == null) {
      return _placeholder(context);
    }

    final skip =
        fadePolicy.shouldSkip(
          wasSynchronouslyLoaded: wasSynchronouslyLoaded,
          origin: originOf?.call(),
        ) ||
        (fadeInDuration == Duration.zero && fadeOutDuration == Duration.zero);

    if (skip) {
      return child;
    }

    return _RasterFadeStack(
      fadeInDuration: fadeInDuration,
      fadeOutDuration: fadeOutDuration,
      image: child,
      chrome: _placeholder(context),
    );
  }

  Widget loadingBuilder(
    BuildContext context,
    Widget child,
    ImageChunkEvent? loadingProgress,
  ) {
    if (progressBuilder case final progressBuilder? when loadingProgress != null) {
      return progressBuilder(context, loadingProgress);
    }
    return child;
  }

  Widget _placeholder(BuildContext context) {
    return placeholderBuilder?.call(context) ?? const SizedBox.shrink();
  }
}

final class _RasterFadeStack extends StatelessWidget {
  const _RasterFadeStack({
    required this.fadeInDuration,
    required this.fadeOutDuration,
    required this.image,
    required this.chrome,
  });

  final Duration fadeInDuration;
  final Duration fadeOutDuration;
  final Widget image;
  final Widget chrome;

  @override
  Widget build(BuildContext context) {
    if (fadeOutDuration == Duration.zero) {
      return _RasterFade(
        duration: fadeInDuration,
        direction: _RasterFadeDirection.forward,
        child: image,
      );
    }
    return Stack(
      fit: StackFit.passthrough,
      alignment: Alignment.center,
      children: [
        _RasterFade(
          duration: fadeInDuration,
          direction: _RasterFadeDirection.forward,
          child: image,
        ),
        _RasterFade(
          duration: fadeOutDuration,
          direction: _RasterFadeDirection.reverse,
          child: chrome,
        ),
      ],
    );
  }
}

enum _RasterFadeDirection { forward, reverse }

final class _RasterFade extends StatefulWidget {
  const _RasterFade({
    required this.child,
    required this.duration,
    required this.direction,
  });

  final Widget child;
  final Duration duration;
  final _RasterFadeDirection direction;

  @override
  State<_RasterFade> createState() => _RasterFadeState();
}

final class _RasterFadeState extends State<_RasterFade> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late Animation<double> _opacity;
  var _hide = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration);
    _bindOpacity();
    if (widget.duration == Duration.zero) {
      _controller.value = 1.0;
      _hide = widget.direction == _RasterFadeDirection.reverse;
    } else {
      _controller.forward();
      if (widget.direction == _RasterFadeDirection.reverse) {
        _opacity.addStatusListener(_onStatus);
      }
    }
  }

  void _bindOpacity() {
    final curved = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    final begin = widget.direction == _RasterFadeDirection.forward ? 0.0 : 1.0;
    final end = widget.direction == _RasterFadeDirection.forward ? 1.0 : 0.0;
    _opacity = Tween<double>(begin: begin, end: end).animate(curved);
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && widget.direction == _RasterFadeDirection.reverse) {
      setState(() => _hide = true);
    }
  }

  @override
  void dispose() {
    _opacity.removeStatusListener(_onStatus);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_hide) {
      return const SizedBox.shrink();
    }
    return FadeTransition(
      key: switch (widget.direction) {
        _RasterFadeDirection.forward => RasterPaintCompose.fadeTransitionKey,
        _RasterFadeDirection.reverse => null,
      },
      opacity: _opacity,
      child: widget.child,
    );
  }
}
