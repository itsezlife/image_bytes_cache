## 0.3.0

- **ADDED**: Before, raster hosts wired raw `frameBuilder` / `loadingBuilder`
  for placeholder, progress, and fade, and could only skip motion on Flutter
  `ImageCache` sync hits. Now `CachedNetworkBytesImage` and
  `RasterPaintCompose` expose `placeholderBuilder`, `progressBuilder`,
  `ImageFadePolicy` / `ImageFadeSkip` (`imageCache` | `bytesCache`), and
  `fadeInDuration` / `fadeOutDuration` (defaults 300ms in / zero out when any
  high-level knob is set). Progress replaces placeholder on real chunks; quiet
  resolves invent none. High-level knobs are mutually exclusive with raw
  `frameBuilder` / `loadingBuilder`. Under `standard`, `ImageBytesOrigin.cache`
  skips fade even on async decode; missing origin does not skip for
  `bytesCache`.
- **ADDED**: `CachedNetworkBytesLoadSession` on
  `CachedNetworkBytesImageProvider` (thin widget wires it). Rich resolve
  records origin; compose reads via `originOf`. Omit for bare
  `DecorationImage`.

## 0.2.0

- **CHANGED**: Paint adapters surface sealed `HttpBytesException` from core
  on network miss failures. Catch `$Network` / `$Request` / `$Timeout` / … instead
  of `ClientException` or raw socket errors when handling `onError`. Aligns with
  core `HttpBytesClient`.

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
