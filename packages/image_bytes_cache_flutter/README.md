# image_bytes_cache_flutter

[![Dart](https://img.shields.io/badge/Dart-%230175C2.svg?style=flat&logo=dart&logoColor=white)](https://dart.dev)
[![Flutter](https://img.shields.io/badge/Flutter-%2302569B.svg?style=flat&logo=Flutter&logoColor=white)](https://flutter.dev)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Flutter paint adapters for
[`image_bytes_cache`](../image_bytes_cache/). Resolve remote image bytes through
the core ladder, then paint. Ships raster `CachedNetworkBytesImageProvider` /
`CachedNetworkBytesImage` and SVG `CachedNetworkSvgImage`. Durable storage stays
in core.

Widgets here do not open files, sockets, or durable stores. Call
`ImageBytesCache.open` / `configure` on the core package once before paint.

## Features

- **Thin paint layer.** Depends on `IImageBytesResolver` / `ImageCacheKey` only.
  No second resolve tree in widgets.
- **Raster.** Provider for any `ImageProvider` slot (`Image`, `DecorationImage`,
  ...) plus a thin `Image`-shaped widget. Optional display-sized decode for
  Flutter `ImageCache`; durable keys stay `ImageCacheKey`. Optional
  placeholder / progress / fade chrome on the thin widget (or compose helpers
  under bare `Image`).
- **SVG.** `CachedNetworkSvgImage` with sealed load state, optional bounded
  `PageStorage` restore, and soft failures via `errorBuilder` / `onError`.
- **Testable.** Inject an `IImageBytesResolver` in tests.

## Installation

```yaml
dependencies:
  image_bytes_cache_flutter: latest
```

Then `flutter pub get`.

## Quick start

### 1. Bootstrap the core cache

Once at app start (VM needs a reclaimable cache directory; web ignores it):

```dart
import 'package:image_bytes_cache/image_bytes_cache.dart';

await ImageBytesCache.configure(
  await ImageBytesCache.open(
    directory: '$appCachePath/remote_image_bytes', // VM only
    diagnostics: const ImageBytesDiagnostics.silent(),
  ),
);
```

See the [core README](../image_bytes_cache/README.md) for retention,
diagnostics, and platform backends.

### 2. Paint a raster

Anywhere an `ImageProvider` is accepted:

```dart
import 'package:flutter/material.dart';
import 'package:image_bytes_cache_flutter/image_bytes_cache_flutter.dart';

Image(
  image: CachedNetworkBytesImageProvider(
    'https://cdn.example.com/photo.jpg',
    headers: const {'Authorization': 'Bearer ...'},
  ),
  loadingBuilder: (context, child, progress) {
    if (progress == null) return child;
    final total = progress.expectedTotalBytes;
    return CircularProgressIndicator(
      value: total == null ? null : progress.cumulativeBytesLoaded / total,
    );
  },
  errorBuilder: (context, error, stackTrace) => const Icon(Icons.broken_image),
);
```

For a display-sized bitmap (avatar vs preview of the same URL):

```dart
Image(
  image: CachedNetworkBytesImageProvider.sized(
    'https://cdn.example.com/photo.jpg',
    cacheWidth: 64,
    cacheHeight: 64,
  ),
  width: 64,
  height: 64,
);
```

Or the thin widget when you want near-`Image.network` knobs in one place:

```dart
CachedNetworkBytesImage(
  'https://cdn.example.com/photo.jpg',
  width: 64,
  height: 64,
  cacheWidth: 64,
  cacheHeight: 64,
  errorBuilder: (context, error, stackTrace) => const Icon(Icons.broken_image),
  onError: (error, stackTrace) {
    // Optional once-per-load callback.
  },
);
```

Under `DecorationImage` (no `Image.errorBuilder`), pass `errorListener` on the
provider if you want that same soft-failure callback.

### Placeholder, progress, and fade

High-level chrome on `CachedNetworkBytesImage` (or `RasterPaintCompose` under
bare `Image` + provider). When real download chunks arrive, progress replaces
the placeholder. Store hits stay quiet: no fake progress. Opt into any
high-level knob and you get `ImageFadePolicy.standard`, 300ms fade-in, and
zero fade-out unless you override them.

```dart
CachedNetworkBytesImage(
  'https://cdn.example.com/photo.jpg',
  width: 96,
  height: 96,
  placeholderBuilder: (context) => const ColoredBox(color: Color(0xFFE0E0E0)),
  progressBuilder: (context, progress) {
    final total = progress.expectedTotalBytes;
    return CircularProgressIndicator(
      value: total == null ? null : progress.cumulativeBytesLoaded / total,
    );
  },
  // standard skips Flutter ImageCache sync hits (imageCache) and store-served
  // bodies (bytesCache → ImageBytesOrigin.cache).
  fadePolicy: ImageFadePolicy.standard,
  fadeInDuration: const Duration(milliseconds: 300),
  fadeOutDuration: Duration.zero,
  errorBuilder: (context, error, stackTrace) => const Icon(Icons.broken_image),
);
```

| Fact | Public name | Meaning |
| --- | --- | --- |
| Sync decoded frame | `ImageFadeSkip.imageCache` | Flutter already had the bitmap (`wasSynchronouslyLoaded`) |
| Store-served body | `ImageFadeSkip.bytesCache` | Resolve origin is `ImageBytesOrigin.cache` (no new download) |

These are different facts. `standard` skips both. Force motion with
`ImageFadePolicy.always`, or turn fade off with `ImageFadePolicy.never` / zero
durations. Leave every high-level knob unset and the thin `Image` path stays
as before, with no default fade.

Do not combine high-level chrome with raw `frameBuilder` / `loadingBuilder`.
That asserts. If you want the raw path instead of the example above:

```dart
CachedNetworkBytesImage(
  'https://cdn.example.com/photo.jpg',
  frameBuilder: (context, child, frame, wasSynchronouslyLoaded) => child,
  loadingBuilder: (context, child, progress) {
    if (progress == null) return child;
    return const CircularProgressIndicator();
  },
);
```

`bytesCache` skip needs the load session the thin widget owns. Bare
`DecorationImage` without a session never sees store origin, so that skip bit
stays off unless you wire `RasterPaintCompose` and
`CachedNetworkBytesLoadSession` yourself.

### 3. Paint a SVG

```dart
import 'package:flutter/material.dart';
import 'package:image_bytes_cache_flutter/image_bytes_cache_flutter.dart';

CachedNetworkSvgImage(
  'https://cdn.example.com/logo.svg',
  width: 48,
  height: 48,
  placeholderBuilder: (context) => const SizedBox(
    width: 48,
    height: 48,
    child: CircularProgressIndicator(strokeWidth: 2),
  ),
  errorBuilder: (context, error, stackTrace) => const Icon(Icons.broken_image),
);
```

Defaults: shared resolver, `BoxFit.contain`, empty box when `errorBuilder` is
omitted.

## Performance

Bytes-ready ratios and three-way scroll tables live in the core
[`README`](../image_bytes_cache/README.md#performance) and
[`benchmark_compare/RESULTS.md`](benchmark_compare/RESULTS.md).

On a Galaxy S938B `pressure-scroll` run, `CachedNetworkBytesImage` missed 0
raster frames while CE / stock missed 4 / 8. Worst raster was about 2.6 ms vs
29-32 ms. The tradeoff is a slightly heavier frame-build path
(`StatefulWidget` + `loadingBuilder`).

Chrome web debug drive (same cells): pressure missed raster 0 / 0 / 0; build
averages about 4 ms across stacks. See RESULTS for the full tables.

## Platform support

Same targets as Flutter and the core package: Android, iOS, Web, Windows,
macOS, Linux. Persistence behavior is defined by core `ImageBytesCache.open`.

## Development

```bash
cd packages/image_bytes_cache_flutter
flutter pub get
flutter test
flutter analyze
```

Compare package (bytes + paint + profile drive):
[`benchmark_compare/`](benchmark_compare/). Core store / ladder benches stay in
[`../image_bytes_cache/`](../image_bytes_cache/).

Contributor orientation: [`AGENTS.md`](AGENTS.md), [`CONTEXT.md`](CONTEXT.md),
and core [`../image_bytes_cache/AGENTS.md`](../image_bytes_cache/AGENTS.md).

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

## Maintainers

- [Zulufov Emil](https://github.com/itsezlife)

## License

MIT. See [LICENSE](LICENSE).

Copyright (c) 2026 Zulufov Emil <emilzulufov566@gmail.com>
