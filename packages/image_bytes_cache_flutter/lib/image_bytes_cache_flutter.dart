/// Flutter paint adapters above [package:image_bytes_cache].
///
/// Owns widgets that turn resolved **bytes** into paint (including
/// [CachedNetworkSvgImage]). Does not open durable stores, own HTTP coalesce,
/// or set process-wide diagnostics. Hosts still call [ImageBytesCache.open] /
/// [ImageBytesCache.configure] on the core package.
///
/// Soft paint failures stay widget-local ([CachedNetworkSvgImage.onError] /
/// [CachedNetworkSvgImage.errorBuilder]); this package does not depend on a
/// product logger.
library;

export 'src/widget/cached_network_svg_image.dart';
