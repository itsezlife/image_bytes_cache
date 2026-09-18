## Unreleased

- **ADDED**: `CachedNetworkBytesImageProvider` — ImageProvider over
  `IImageBytesResolver` for Flutter-decodable rasters (PNG/JPEG/WebP/GIF and
  siblings). Maps honest ladder `onBytesProgress` to `ImageChunkEvent`; Flutter
  `ImageCache` identity is `ImageCacheKey` + scale (durable key stays
  `ImageCacheKey` only); no PageStorage body mirror. Injected resolver for
  tests. Thin `CachedNetworkBytesImage` and sized-decode key still land later
  in this foundation train.

## 0.0.2

- **FIXED**: `CachedNetworkSvgImage` forwards SVG parse/paint failures through
  `onError` / `errorBuilder` (no endless placeholder disguise). Reload gating
  follows `ImageCacheKey` identity so `null` vs `{}` and header key casing do
  not force needless reloads while Authorization value changes still reload.
  PageStorage of SVG bodies is opt-out (`persistInPageStorage`) and size-bounded
  (`pageStorageMaxBytes`, default 64 KiB). Keep-previous picture while a new
  identity resolves avoids a mandatory loading flash when a prior frame is
  already painted.

## 0.0.1

- **ADDED**: Initial standalone release — Flutter paint adapters for
  `image_bytes_cache`, including `CachedNetworkSvgImage` and the optional
  `benchmark_compare` harness.
