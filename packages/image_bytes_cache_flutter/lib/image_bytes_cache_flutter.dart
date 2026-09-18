/// Flutter paint adapters above [package:image_bytes_cache].
///
/// Owns paint adapters that turn resolved **bytes** into Flutter paint:
/// [CachedNetworkBytesImageProvider] for engine-decodable rasters, and
/// [CachedNetworkSvgImage] for SVG. Does not open durable stores, own HTTP
/// coalesce, or set process-wide diagnostics. Hosts still call
/// [ImageBytesCache.open] / [ImageBytesCache.configure] on the core package.
///
/// Soft paint failures stay widget-local: raster via the [ImageStream] /
/// [Image.errorBuilder]; SVG via [CachedNetworkSvgImage.onError] /
/// [CachedNetworkSvgImage.errorBuilder].
library;

export 'src/image_provider/cached_network_bytes_image_provider.dart';
export 'src/widget/cached_network_svg_image.dart';
