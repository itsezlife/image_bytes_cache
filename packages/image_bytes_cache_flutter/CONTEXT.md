# image_bytes_cache_flutter

Flutter paint adapters for the durable bytes engine in sibling
[`image_bytes_cache`](../image_bytes_cache/CONTEXT.md). Widgets resolve via
[IImageBytesResolver]; they do not open stores or own HTTP coalesce.

Bootstrap stays on core: `ImageBytesCache.open` / `configure` / diagnostics.
Design-system hosts may re-export paint types for call-site stability;
implementation and widget tests live here.

## Language

**CachedNetworkSvgImage**:
Remote SVG paint from resolver bytes. Short-lived [PageStorage] copy under the
same [ImageCacheKey] as the shared store. Soft failures only via [onError] /
[errorBuilder] — no product logger. Optional injected resolver for tests.
_Avoid_: opening files/sockets in the widget; dual implementations in host
design-system packages; growing durable storage beside paint

**CachedNetworkSvgImageState** (`loading` / `populated` / `failure`):
Sealed load lifecycle for the SVG widget. Use [CachedNetworkSvgImageState.map]
so each variant owns its widget tree.
_Avoid_: boolean loading/error flags beside the sealed hierarchy
