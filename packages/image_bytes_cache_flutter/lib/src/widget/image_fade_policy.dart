import 'package:flutter/foundation.dart';
import 'package:image_bytes_cache/image_bytes_cache.dart';

/// Bitmask reasons to skip raster fade motion.
///
/// Two physical facts:
/// - [imageCache] — Flutter already had a decoded frame
///   (`ImageFrameBuilder`'s `wasSynchronouslyLoaded`)
/// - [bytesCache] — resolve served a body without a network download
///   ([ImageBytesOrigin.cache])
///
/// Without a known [ImageBytesOrigin], [ImageFadePolicy.shouldSkip] does
/// **not** treat [bytesCache] as matched (fail-safe). That keeps cold paint
/// from silently skipping when origin is not wired yet.
extension type const ImageFadeSkip._(int value) implements int {
  /// No skip reasons.
  static const ImageFadeSkip none = ImageFadeSkip._(0);

  /// Skip when Flutter reports a synchronous [ImageCache] hit.
  static const ImageFadeSkip imageCache = ImageFadeSkip._(1 << 0);

  /// Skip when resolve origin is [ImageBytesOrigin.cache].
  static const ImageFadeSkip bytesCache = ImageFadeSkip._(1 << 1);

  /// Both skip reasons.
  static const ImageFadeSkip all = ImageFadeSkip._((1 << 0) | (1 << 1));

  /// Union of this mask and [other].
  ImageFadeSkip operator |(ImageFadeSkip other) => ImageFadeSkip._(value | other.value);

  /// Whether every bit in [other] is set on this mask.
  bool contains(ImageFadeSkip other) => (value & other.value) == other.value;
}

/// Fade skip policy over [ImageFadeSkip], plus always/never presets.
///
/// - [standard] — skip [ImageFadeSkip.imageCache] and [ImageFadeSkip.bytesCache]
/// - [always] — never skip; always play motion when durations are non-zero
/// - [never] — always skip; jump both alphas to final without playing
/// - custom — [ImageFadePolicy.new] with any [ImageFadeSkip] mask
///
/// Skip evaluation is [shouldSkip]. Missing/`null` origin does not satisfy
/// [ImageFadeSkip.bytesCache]. Zero [fadeInDuration] / [fadeOutDuration] on
/// the compose path also plays no motion, independent of this policy.
@immutable
final class ImageFadePolicy {
  /// Custom skip mask. Empty mask fades whenever durations allow (same as
  /// [always] for skip purposes).
  const ImageFadePolicy(this.skip) : _forceSkip = false;

  const ImageFadePolicy._({
    required this.skip,
    required bool forceSkip,
  }) : _forceSkip = forceSkip;

  /// Default chrome policy: skip warm Flutter decode and store-served bodies.
  static const ImageFadePolicy standard = ImageFadePolicy._(
    skip: ImageFadeSkip.all,
    forceSkip: false,
  );

  /// Always play fade when durations are non-zero (ignore skip bits).
  static const ImageFadePolicy always = ImageFadePolicy._(
    skip: ImageFadeSkip.none,
    forceSkip: false,
  );

  /// Never play fade; force final alphas immediately.
  static const ImageFadePolicy never = ImageFadePolicy._(
    skip: ImageFadeSkip.none,
    forceSkip: true,
  );

  /// Reasons that skip motion when their physical fact is present.
  final ImageFadeSkip skip;

  final bool _forceSkip;

  /// Whether fade motion should be skipped for this load outcome.
  ///
  /// [wasSynchronouslyLoaded] is Flutter's frame-builder flag.
  /// [origin] is paint-facing resolve provenance; `null` means unknown —
  /// [ImageFadeSkip.bytesCache] does not match until origin is known.
  bool shouldSkip({
    required bool wasSynchronouslyLoaded,
    ImageBytesOrigin? origin,
  }) {
    if (_forceSkip) {
      return true;
    }
    if (skip.contains(ImageFadeSkip.imageCache) && wasSynchronouslyLoaded) {
      return true;
    }
    if (skip.contains(ImageFadeSkip.bytesCache) && origin == ImageBytesOrigin.cache) {
      return true;
    }
    return false;
  }

  @override
  bool operator ==(Object other) {
    return other is ImageFadePolicy && other.skip == skip && other._forceSkip == _forceSkip;
  }

  @override
  int get hashCode => Object.hash(skip, _forceSkip);

  @override
  String toString() {
    if (identical(this, standard)) return 'ImageFadePolicy.standard';
    if (identical(this, always)) return 'ImageFadePolicy.always';
    if (identical(this, never)) return 'ImageFadePolicy.never';
    return 'ImageFadePolicy($skip)';
  }
}
