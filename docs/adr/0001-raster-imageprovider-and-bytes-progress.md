# Raster paint uses ImageProvider; bytes progress stays on the Future resolve path

Paint adapters for Flutter-decodable rasters (PNG/JPEG/WebP/GIF and siblings)
are founded on a custom [ImageProvider] over [IImageBytesResolver], not on an
SVG-style sealed StatefulWidget lifecycle. Optional decode size participates in
Flutter [ImageCache] identity only; durable identity remains [ImageCacheKey].
Raster does not use [PageStorage] for body copies. Determinate download
progress for [Image.loadingBuilder] is real fetcher byte progress hooked through
the existing `Future<Uint8List>` resolve contract — not a public streaming
resolve API, and not synthetic chunk events.

## Considered Options

- Widget-first raster (mirror [CachedNetworkSvgImage]) — rejected: fights
  Flutter's decode/[ImageCache] tools and blocks [DecorationImage] /
  [ResizeImage]-style composition.
- `ResizeImage` only for sized decode (size never on our provider) — rejected
  as the sole story: chat call sites need size in the provider key for
  non-[Image] slots; external composition remains allowed.
- Public streaming resolve for progress — rejected: overshoots
  [ImageChunkEvent] needs and complicates coalesce/write-through.
- Format-auto-detect one widget for SVG+raster — deferred/rejected as primary
  API; separate mechanisms; optional declared router later.

## Consequences

- Core and flutter land as one foundation train: progress hook + provider +
  thin [CachedNetworkBytesImage].
- [CachedNetworkSvgImage] stays; no forced shared paint controller in this
  change.
- Naming uses `CachedNetworkBytesImage(Provider)` — Flutter-shaped, distinct
  from pub.dev `cached_network_image`.
