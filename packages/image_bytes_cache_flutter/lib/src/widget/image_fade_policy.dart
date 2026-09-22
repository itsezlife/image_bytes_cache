import 'package:flutter/foundation.dart';
import 'package:image_bytes_cache/image_bytes_cache.dart';

/// Bitmask of reasons to skip raster fade.
///
/// [imageCache]: Flutter already had a decoded frame
/// (`ImageFrameBuilder.wasSynchronouslyLoaded`).
/// [bytesCache]: resolve served without a network download
/// ([ImageBytesOrigin.cache]).
///
/// `null` origin never matches [bytesCache] (fail-safe when no load session).
extension type const ImageFadeSkip._(int value) implements int {
  static const ImageFadeSkip none = ImageFadeSkip._(0);

  /// Synchronous Flutter [ImageCache] hit.
  static const ImageFadeSkip imageCache = ImageFadeSkip._(1 << 0);

  /// Resolve origin is [ImageBytesOrigin.cache].
  static const ImageFadeSkip bytesCache = ImageFadeSkip._(1 << 1);

  static const ImageFadeSkip all = ImageFadeSkip._((1 << 0) | (1 << 1));

  ImageFadeSkip operator |(ImageFadeSkip other) => ImageFadeSkip._(value | other.value);

  bool contains(ImageFadeSkip other) => (value & other.value) == other.value;
}

/// When to skip fade, given [ImageFadeSkip] facts.
///
/// [standard] skips [ImageFadeSkip.imageCache] and [ImageFadeSkip.bytesCache].
/// [always] never skips. [never] always skips (jump alphas to final).
/// Custom: [ImageFadePolicy.new] with any mask.
///
/// `null` origin does not satisfy [ImageFadeSkip.bytesCache]. Zero
/// fade durations on compose also play no motion, independent of this policy.
@immutable
final class ImageFadePolicy {
  /// Custom skip mask. Empty mask never skips (same as [always] for skip).
  const ImageFadePolicy(this.skip) : _forceSkip = false;

  const ImageFadePolicy._({
    required this.skip,
    required bool forceSkip,
  }) : _forceSkip = forceSkip;

  /// Skip warm Flutter decode and store-served bodies.
  static const ImageFadePolicy standard = ImageFadePolicy._(
    skip: ImageFadeSkip.all,
    forceSkip: false,
  );

  /// Play fade whenever durations are non-zero.
  static const ImageFadePolicy always = ImageFadePolicy._(
    skip: ImageFadeSkip.none,
    forceSkip: false,
  );

  /// Force final alphas immediately.
  static const ImageFadePolicy never = ImageFadePolicy._(
    skip: ImageFadeSkip.none,
    forceSkip: true,
  );

  /// Skip bits that fire when their physical fact is present.
  final ImageFadeSkip skip;

  final bool _forceSkip;

  /// Whether fade should be skipped for this load outcome.
  ///
  /// [wasSynchronouslyLoaded] is Flutter's frame-builder flag. [origin] is
  /// resolve provenance; `null` means unknown, so [ImageFadeSkip.bytesCache]
  /// does not match.
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
