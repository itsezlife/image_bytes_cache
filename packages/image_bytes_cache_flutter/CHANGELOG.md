## Unreleased

- **CHANGED**: Glossary and agent orientation now describe the planned raster
  paint surface (`CachedNetworkBytesImageProvider` /
  `CachedNetworkBytesImage`): ImageProvider-first decode, optional sized
  Flutter `ImageCache` identity, no PageStorage body mirror, and progress via
  core `onBytesProgress` — SVG remains a separate adapter. Implementation of
  those types follows in this foundation train.

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
