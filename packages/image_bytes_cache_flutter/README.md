# image_bytes_cache_flutter

[![Dart](https://img.shields.io/badge/Dart-%230175C2.svg?style=flat&logo=dart&logoColor=white)](https://dart.dev)
[![Flutter](https://img.shields.io/badge/Flutter-%2302569B.svg?style=flat&logo=Flutter&logoColor=white)](https://flutter.dev)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Flutter paint adapters for
[`image_bytes_cache`](../image_bytes_cache/). Widgets resolve remote image
**bytes** through the core ladder, then paint. Ships `CachedNetworkSvgImage`
for remote SVG. Durable storage stays in the core package.

This package does not open files, sockets, or durable stores. Hosts still call
`ImageBytesCache.open` / `configure` on the core package before paint.

## Features

- **Thin paint layer.** Depends on `IImageBytesResolver` / `ImageCacheKey` only.
  No second resolve tree, no blob IO in widgets.
- **CachedNetworkSvgImage.** Loads via the shared resolver and draws with
  `SvgPicture.memory`.
- **Scroll-friendly identity.** Optional short-lived `PageStorage` copy under
  the same `ImageCacheKey` as the durable store, size-bounded
  (`pageStorageMaxBytes`, default 64 KiB) and disableable via
  `persistInPageStorage: false`.
- **Sealed load states.** `CachedNetworkSvgImageState` is
  `loading` / `populated` / `failure`. Use `map` so each variant owns its tree.
- **Soft failures stay local.** Resolve **and** SVG parse/paint failures go
  through `errorBuilder` / `onError` — never an endless `placeholderBuilder`.
  No product logger inside the widget.
- **Identity-aligned reloads.** `didUpdateWidget` gates on `ImageCacheKey`
  (canonical headers), not raw map equality. Keep-previous picture while a new
  URL resolves.
- **Testable.** Inject an `IImageBytesResolver`; leave durable open policy in
  the host or core test doubles.

## Installation

```yaml
dependencies:
  image_bytes_cache:
    git:
      url: https://github.com/itsezlife/image_bytes_cache.git
      path: packages/image_bytes_cache
      ref: main
  image_bytes_cache_flutter:
    git:
      url: https://github.com/itsezlife/image_bytes_cache.git
      path: packages/image_bytes_cache_flutter
      ref: main
```

Then `flutter pub get`.

## Quick start

### 1. Bootstrap the core cache

Do this once at app start (VM needs a reclaimable cache directory; web ignores
it):

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

### 2. Paint with `CachedNetworkSvgImage`

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
  onError: (error, stackTrace) {
    // Optional: report once per failure transition.
  },
);
```

Defaults: `ImageBytesResolver.shared()`, `BoxFit.contain`, empty box on failure
when `errorBuilder` is omitted.

## CachedNetworkSvgImage

| Argument | Notes |
| --- | --- |
| `url` | Absolute or `Uri.base`-relative SVG URL |
| `headers` | Sent on the network hop; folded into `ImageCacheKey` |
| `resolver` | Override for tests; default `ImageBytesResolver.shared()` |
| `width` / `height` / `fit` / `alignment` | Passed through to `SvgPicture` |
| `theme` / `colorFilter` | flutter_svg styling |
| `placeholderBuilder` | While `CachedNetworkSvgImageState.loading` (not reused during SVG decode) |
| `errorBuilder` | On `failure` (resolve or paint); default is an empty box |
| `onError` | Called once per failure transition |
| `persistInPageStorage` | Default `true`; set `false` to skip widget-local body cache |
| `pageStorageMaxBytes` | Max bytes written to PageStorage (default 64 KiB) |

```dart
CachedNetworkSvgImage(
  url,
  headers: const {'Authorization': 'Bearer …'},
  colorFilter: ColorFilter.mode(scheme.onSurface, BlendMode.srcIn),
  semanticsLabel: 'Company logo',
);
```

## Load state

```dart
state.map(
  loading: (_) => const PlaceholderPulse(),
  populated: (s) => SvgPicture.memory(s.imageBytes),
  failure: (s) => ErrorGlyph(error: s.error),
);
```

Prefer `map` over boolean loading/error flags. The widget already does this
internally for placeholder / picture / error chrome.

## Architecture

```
CachedNetworkSvgImage
        │
        ▼
IImageBytesResolver  (image_bytes_cache)
        │
        ├─ IImageBytesCache   durable / memory / no-op
        └─ HttpBytesFetcher   pool + coalesce
```

| Package | Owns |
| --- | --- |
| `image_bytes_cache` | Open/configure, retention, blob stores, resolve ladder, store microbenches |
| `image_bytes_cache_flutter` (this) | Paint widgets, widget tests, Flutter-side profile benches |

Do not keep a second resolve/paint implementation in a design-system
package. Re-export from here if call sites need a stable host import.

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

Core store / ladder benches and Chrome open smoke stay in
[`../image_bytes_cache/`](../image_bytes_cache/).

Contributor orientation:

- [`AGENTS.md`](AGENTS.md)
- [`CONTEXT.md`](CONTEXT.md)
- Core: [`../image_bytes_cache/AGENTS.md`](../image_bytes_cache/AGENTS.md)

## Changelog

Refer to the [Changelog](CHANGELOG.md) to get all release notes.

## Maintainers

- [Zulufov Emil](https://github.com/itsezlife)

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file
for details.

Copyright (c) 2026 Zulufov Emil <emilzulufov566@gmail.com>
