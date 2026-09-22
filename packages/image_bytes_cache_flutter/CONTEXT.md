# image_bytes_cache_flutter

Flutter paint adapters for the durable bytes engine in sibling
[`image_bytes_cache`](../image_bytes_cache/CONTEXT.md). Adapters resolve via
[IImageBytesResolver]; they do not open stores or own HTTP coalesce.

Bootstrap stays on core: `ImageBytesCache.open` / `configure` / diagnostics.
Design-system hosts may re-export paint types; implementation and widget
tests live here.

Raster and SVG are separate paint mechanisms that share the same bytes
resolver. A format-routing facade is out of scope until real dual call sites
force it.
_Avoid_: auto-detect format from URL or magic bytes as the primary API; one
mega-widget that owns both SVG and Flutter decode lifecycles

## Language

### Raster (Flutter decode)

**CachedNetworkBytesImageProvider**:
[ImageProvider] over [IImageBytesResolver] + Flutter decode (PNG, JPEG, WebP,
GIF, …). Flutter [ImageCache] identity is [ImageCacheKey] + scale + optional
decode size; store identity stays [ImageCacheKey] alone. Public `cacheKey` is
always `ImageCacheKey.fromUrl(url, headers)` (not a request override). Uses
rich resolve; optional [CachedNetworkBytesLoadSession] records
[ImageBytesOrigin]. Optional injected resolver and [errorListener]. No
PageStorage of bodies.
_Avoid_: opening files/sockets; forking the store key by decode size;
PageStorage on this path; sealed load state beside [ImageStream]; subclassing
[ImageInfo] for origin; treating [errorListener] as a product logger

**CachedNetworkBytesLoadSession**:
Holds [ImageBytesOrigin] for one provider load. Same instance goes to the
provider and to compose `originOf`. Omitted from Flutter [ImageCache]
identity. Bare [DecorationImage] may omit it; `bytesCache` then stays inert.
_Avoid_: subclassing [ImageInfo] for origin; putting session into provider `==`

**CachedNetworkBytesImage**:
Thin [Image] over the provider ([Image.network]-like surface). Optional
compose chrome: [placeholderBuilder], [progressBuilder], [ImageFadePolicy],
fade durations. High-level builders xor raw frame/loading builders. Soft
failures via [Image.errorBuilder] / [onError]. Owns a load session in State.
_Avoid_: chat/avatar chrome or design tokens here; SVG-style sealed load state
for raster; stacking high-level and raw builders; baking Material progress
into the package

**ImageFadeSkip** (`imageCache` / `bytesCache`):
Skip reasons. `imageCache` = sync Flutter [ImageCache] hit. `bytesCache` =
[ImageBytesOrigin.cache].
_Avoid_: `durable` / `durableHit` in public names; one bool per reason;
conflating Flutter [ImageCache] with the bytes store

**ImageFadePolicy**:
Skip presets over [ImageFadeSkip] (`standard` skips both; `always` / `never`
/ custom). Defaults: short fade-in, zero fade-out. Skip jumps both alphas to
final.
_Avoid_: fade bool soup; treating gapless keep-previous as a second fade
system; Telegram inline thumbs as part of this policy

**Raster paint compose**:
Wires placeholder / progress / fade onto [Image] builders (bare `Image` +
provider too). Progress replaces placeholder when chunks exist. Origin for
`bytesCache` comes from the load session, not a custom [ImageInfo]. `null`
origin never matches `bytesCache`.
_Avoid_: stacked placeholder+progress; raster sealed load FSM; diagnostics
events as the origin channel

### SVG

**CachedNetworkSvgImage**:
Remote SVG from resolver bytes. Optional short-lived [PageStorage] under the
same [ImageCacheKey], bounded by [pageStorageMaxBytes] (default 64 KiB) and
gated by [persistInPageStorage]. Reload follows [ImageCacheKey] identity.
Soft failures (resolve and SVG parse/paint) via [onError] / [errorBuilder]
only. Keep-previous across in-state identity changes and sync PageStorage
hits; remount without PageStorage still awaits resolve. Optional injected
resolver.
_Avoid_: opening files/sockets in the widget; dual host design-system copies;
unbounded PageStorage of SVG bodies; decode failure as endless
[placeholderBuilder]

**CachedNetworkSvgImageState** (`loading` / `populated` / `failure`):
Sealed SVG load lifecycle. [failure] covers resolver and SVG decode/paint
errors. Use [CachedNetworkSvgImageState.map] so each variant owns its tree.
_Avoid_: boolean loading/error flags beside the sealed hierarchy; applying
this hierarchy to raster [CachedNetworkBytesImage]
