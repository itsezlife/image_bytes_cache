# image_bytes_cache_flutter

Flutter paint adapters for the durable bytes engine in sibling
[`image_bytes_cache`](../image_bytes_cache/CONTEXT.md). Widgets resolve via
[IImageBytesResolver]; they do not open stores or own HTTP coalesce.

Bootstrap stays on core: `ImageBytesCache.open` / `configure` / diagnostics.
Design-system hosts may re-export paint types for call-site stability;
implementation and widget tests live here.

## Language

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
_Avoid_: boolean loading/error flags beside the sealed hierarchy
