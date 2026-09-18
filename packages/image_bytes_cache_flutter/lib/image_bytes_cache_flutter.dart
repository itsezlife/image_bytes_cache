/// Flutter paint adapters above [package:image_bytes_cache].
///
/// Turns resolved **bytes** into Flutter paint:
/// [CachedNetworkBytesImageProvider] / [CachedNetworkBytesImage] for
/// engine-decodable rasters, and [CachedNetworkSvgImage] for SVG. Does not
/// open durable stores, own HTTP coalesce, or set process-wide diagnostics.
/// Hosts still call [ImageBytesCache.open] / [ImageBytesCache.configure] on
/// the core package.
library;

export 'src/image_provider/cached_network_bytes_image_provider.dart';
export 'src/widget/cached_network_bytes_image.dart';
export 'src/widget/cached_network_svg_image.dart';
