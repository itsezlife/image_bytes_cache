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
codecs the engine accepts: PNG, JPEG, WebP, multi-frame GIF, and siblings).
Flutter [ImageCache] identity is [ImageCacheKey] plus scale and optional
decode size; store identity stays [ImageCacheKey] alone. The public
`cacheKey` getter is always `ImageCacheKey.fromUrl(url, headers)`. The
provider does not take an [ImageBytesRequest.cacheKey] override. Uses rich
resolve when origin is needed for fade policy; records [ImageBytesOrigin] on
the current load session. Optional injected resolver for tests. Optional
[errorListener] for soft resolve / empty-body / decode failures when the host
has no [Image.errorBuilder]. Does not mirror bodies into [PageStorage].
_Avoid_: opening files/sockets; forking the store key by decode size;
PageStorage-of-bytes on this path; inventing a sealed load state beside
[ImageStream]; subclassing [ImageInfo] to carry origin; treating
[errorListener] as a product logger; treating the provider `cacheKey` getter
as a request override

**CachedNetworkBytesImage**:
Thin [Image] convenience over [CachedNetworkBytesImageProvider]. Call-site
surface near [Image.network] (builders, gapless playback, semantics, fit,
sized decode). Optional friendly chrome via compose helpers:
[placeholderBuilder], [progressBuilder], [ImageFadePolicy] /
`fadeInDuration` / `fadeOutDuration`. High-level builders are mutually
exclusive with raw [Image.frameBuilder] / [Image.loadingBuilder]. Soft
failures via [Image.errorBuilder] and optional [onError] (forwards to the
provider [errorListener]). No sealed load hierarchy and no product logger.
_Avoid_: chat/avatar chrome, clip shapes, or design tokens in this type;
SVG-style sealed [loading]/[populated]/[failure] state for raster;
stacking high-level and raw builders; baking Material progress widgets into
the package

**ImageFadeSkip** (`imageCache` / `bytesCache`):
Bitmask reasons to skip fade motion. `imageCache` is a synchronous Flutter
[ImageCache] hit (`wasSynchronouslyLoaded`). `bytesCache` is resolve
[ImageBytesOrigin.cache] (body served without a network download).
_Avoid_: `durable` / `durableHit` in public names; one bool per reason without
a mask; conflating Flutter [ImageCache] with the bytes store

**ImageFadePolicy**:
Fade skip presets over [ImageFadeSkip] (`standard` skips `imageCache` and
`bytesCache`; `always` / `never` and custom masks for hosts). Paired with
fade-in (image) and fade-out (placeholder) durations; defaults favor a short
fade-in and zero fade-out. Skip forces both alphas to final without playing
motion.
_Avoid_: soup of independent fade bools; treating gapless keep-previous as a
second fade system; Telegram-style inline thumb layers as part of this policy

**Raster paint compose**:
Shared helpers that wire [placeholderBuilder] / [progressBuilder] / fade onto
[Image]'s builders (reusable with bare `Image` + provider). While loading,
chunk progress replaces the placeholder when [progressBuilder] is set;
otherwise placeholder. Keep-previous across identity changes stays
[Image.gaplessPlayback]. Origin for `bytesCache` skip is read from the load
session, not from a custom [ImageInfo].
_Avoid_: forcing a Stack overlay of placeholder+progress; inventing a raster
sealed load FSM; relying on diagnostics events for fade gating

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
