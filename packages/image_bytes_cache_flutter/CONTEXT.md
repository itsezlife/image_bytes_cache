# image_bytes_cache_flutter

Flutter paint adapters for the durable bytes engine in sibling
[`image_bytes_cache`](../image_bytes_cache/CONTEXT.md). Adapters resolve via
[IImageBytesResolver]; they do not open stores or own HTTP coalesce.

Bootstrap stays on core: `ImageBytesCache.open` / `configure` / diagnostics.
Design-system hosts may re-export paint types for call-site stability;
implementation and widget tests live here.

Raster and SVG are separate paint mechanisms that share the same bytes
resolver. A format-routing facade that picks SVG vs raster at one call site is
not part of this context until real dual call sites force it.
_Avoid_: auto-detecting format from URL or magic bytes as the primary API;
one mega-widget that owns both SVG and Flutter decode lifecycles

## Language

### Raster (Flutter decode)

**CachedNetworkBytesImageProvider**:
[ImageProvider] that resolves remote image **bytes** through
[IImageBytesResolver], then decodes with Flutter's image pipeline (whatever
codecs the engine accepts — PNG, JPEG, WebP, multi-frame GIF, and siblings).
Flutter [ImageCache] identity is [ImageCacheKey] plus scale and optional
decode size; durable store identity stays [ImageCacheKey] alone. Optional
injected resolver for tests. Does not mirror bodies into [PageStorage].
_Avoid_: opening files/sockets; forking the durable key by decode size;
PageStorage-of-bytes on this path; inventing a sealed load state beside
[ImageStream]

**CachedNetworkBytesImage**:
Thin [Image] convenience over [CachedNetworkBytesImageProvider]. Call-site
surface near [Image.network] (builders, gapless playback, semantics, fit,
sized decode). Soft failures via [Image.errorBuilder] and optional [onError];
no sealed load hierarchy and no product logger.
_Avoid_: chat/avatar chrome, clip shapes, or design tokens in this type;
SVG-style sealed [loading]/[populated]/[failure] state for raster

### SVG

**CachedNetworkSvgImage**:
Remote SVG paint from resolver bytes. Optional short-lived [PageStorage] copy
under the same [ImageCacheKey] as the shared store, bounded by
[pageStorageMaxBytes] (default 64 KiB) and gated by [persistInPageStorage].
Reload gating follows [ImageCacheKey] identity (not raw header map equality).
Soft failures — resolve **and** SVG parse/paint — only via [onError] /
[errorBuilder]; no product logger. Keep-previous picture across in-state
identity changes (and sync PageStorage hits) so those paths do not mandate a
placeholder flash; a remount without PageStorage still awaits resolve.
Optional injected resolver for tests.
_Avoid_: opening files/sockets in the widget; dual implementations in host
design-system packages; unbounded PageStorage of full SVG bodies; treating
decode failure as endless [placeholderBuilder]

**CachedNetworkSvgImageState** (`loading` / `populated` / `failure`):
Sealed load lifecycle for the SVG widget. [failure] covers resolver errors and
SVG decode/paint errors. Use [CachedNetworkSvgImageState.map] so each variant
owns its widget tree.
_Avoid_: boolean loading/error flags beside the sealed hierarchy; applying this
hierarchy to raster [CachedNetworkBytesImage]
