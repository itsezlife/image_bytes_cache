## 0.1.0

- **ADDED**: Raster paint adapters:
  `CachedNetworkBytesImageProvider` and thin `CachedNetworkBytesImage` over
  `IImageBytesResolver`. Display-sized decode (`cacheWidth` / `cacheHeight` /
  `.sized`) splits Flutter `ImageCache` entries without changing durable
  `ImageCacheKey`. Optional `errorListener` on the provider (widget `onError`
  forwards into it) for soft resolve / empty-body / decode failures when the
  host has no `Image.errorBuilder`. Network-miss progress maps to
  `ImageChunkEvent`; cache hits invent no mid-download percents. No PageStorage
  body mirror and no sealed raster load state. Hosts still
  `ImageBytesCache.open` / `configure` before paint.
- **CHANGED**: `benchmark_compare` retargeted to slim bytes tables plus
  three-way **raster** (PNG) integration and curated profile cells
  (`warm-scroll` / `cold-scroll` / `pressure-scroll`) against
  `cached_network_image_ce` and stock `cached_network_image`. SVG feed and the
  18-cell factorial profile matrix are removed from the harness (SVG paint
  widgets remain in the package).

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

- **ADDED**: Initial standalone release: Flutter paint adapters for
  `image_bytes_cache`, including `CachedNetworkSvgImage` and the optional
  `benchmark_compare` harness.
