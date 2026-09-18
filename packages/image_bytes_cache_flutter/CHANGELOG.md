## Unreleased

- **ADDED**: `CachedNetworkBytesImageProvider` — ImageProvider over
  `IImageBytesResolver` for Flutter-decodable rasters (PNG/JPEG/WebP/GIF and
  siblings). Maps honest ladder `onBytesProgress` to `ImageChunkEvent`; Flutter
  `ImageCache` identity is `ImageCacheKey` + scale + optional decode size
  (`cacheWidth` / `cacheHeight` / `allowUpscaling`, also via `.sized`); durable
  key stays `ImageCacheKey` only. External `ResizeImage` wrapping remains valid
  on unsized providers. No PageStorage body mirror. Injected resolver for
  tests.
- **ADDED**: `CachedNetworkBytesImage` — thin `Image` convenience over the
  provider with near-`Image.network` knobs plus optional `onError`. Sized
  decode knobs wire into the provider (not a second `ResizeImage` layer).
  `loadingBuilder` sees the same honest network-miss `ImageChunkEvent`s as
  composing the provider directly; durable hits still invent no mid-download
  percents. No sealed raster load state and no product logger. Soft failures
  via `errorBuilder` / `onError`. Hosts still bootstrap via core
  `ImageBytesCache.open` / `configure` before paint.

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
