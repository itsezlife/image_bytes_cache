# Additive resolve origin; raster fade chrome via compose + skip mask

Paint needs to know whether a body came from the bytes store without a network
download so fade can be skipped like a warm Flutter [ImageCache] hit — without
lying about “cache” when only `wasSynchronouslyLoaded` is available. Core keeps
bytes-only `IImageBytesResolver.resolve` and adds a rich resolve that returns
[ImageBytesResolveResult] (bytes + binary [ImageBytesOrigin] `network` |
`cache`). Ladder diagnostics stay the detailed channel; origin is paint-facing
only. Flutter raster DX is compose helpers plus optional knobs on
[CachedNetworkBytesImage] (`placeholderBuilder`, `progressBuilder`,
[ImageFadePolicy] with `imageCache` / `bytesCache` skip bits, `fadeInDuration` /
`fadeOutDuration`). Origin reaches compose through a load session, not a custom
[ImageInfo]. Default policy skips both skip bits; default motion is 300ms fade-in
and zero fade-out (placeholder crossfade is opt-in). Progress replaces
placeholder when chunks exist. High-level builders xor raw frame/loading
builders. No raster sealed load FSM; no Telegram-style inline thumb cold path in
this train.

## Considered Options

- Break `resolve` → result type — rejected: churn for every host/mock; additive
  rich method preserves the bytes contract.
- Request side-channel / diagnostics-only origin — rejected: easy to miss; soft
  channel unfit for paint policy.
- Ternary / ladder-mirror origins — rejected for public paint: hosts need
  “downloaded body or not,” not every `resolve_*` op.
- Thicken-only widget or second mega-widget — rejected: mechanism (compose)
  must stay reusable under bare `Image` / [DecorationImage]-adjacent call sites.
- Subclass [ImageInfo] for origin — rejected: fragile vs stock stream consumers.
- Fade-in only without `fadeOutDuration` — rejected after product ask; out fades
  the placeholder, in fades the image; either may be zero.
- Default skip sync-only or always-fade — rejected: cold remount after a store
  hit would still fade without `bytesCache`; always-fade fights Telegram-like
  warm feel and bench zero-fade competitors.
- `durableHit` public naming — rejected: “durable” stays docs-only; public bits
  are `imageCache` and `bytesCache`.

## Consequences

- Core and flutter ship as one train: rich resolve + provider load session +
  compose/fade chrome on the thin raster widget.
- [CachedNetworkSvgImage] sealed lifecycle unchanged; no forced shared paint
  controller.
- Inline thumbs / zero-frame cold UI (Telegram chat-cell pattern) remain a later
  escalation, not implied by fade policy alone.
