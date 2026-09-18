# image_bytes_cache_flutter

[![Dart](https://img.shields.io/badge/Dart-%230175C2.svg?style=flat&logo=dart&logoColor=white)](https://dart.dev)
[![Flutter](https://img.shields.io/badge/Flutter-%2302569B.svg?style=flat&logo=Flutter&logoColor=white)](https://flutter.dev)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Flutter paint adapters for
[`image_bytes_cache`](../image_bytes_cache/). Resolve remote image **bytes**
through the core ladder, then paint. This package ships raster
`CachedNetworkBytesImageProvider` / `CachedNetworkBytesImage` and SVG
`CachedNetworkSvgImage`. Durable storage stays in core.

Widgets here do not open files, sockets, or durable stores. Call
`ImageBytesCache.open` / `configure` on the core package once before paint.

## 🌟 Features

- **🪶 Thin paint layer**: Depends on `IImageBytesResolver` / `ImageCacheKey`
  only. No second resolve tree in widgets.
- **🖼️ Raster**: Provider for any `ImageProvider` slot (`Image`,
  `DecorationImage`, …) plus a thin `Image`-shaped widget. Optional display-
  sized decode for Flutter `ImageCache`; durable keys stay `ImageCacheKey`.
- **✏️ SVG**: `CachedNetworkSvgImage` with sealed load state, optional bounded
  `PageStorage` restore, and soft failures via `errorBuilder` / `onError`.
- **🧪 Testable**: Inject an `IImageBytesResolver` in tests.

## 📦 Installation

```yaml
dependencies:
  image_bytes_cache_flutter: latest
```

Then `flutter pub get`.

## 🚀 Quick Start

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
    headers: const {'Authorization': 'Bearer …'},
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

## 📱 Platform Support

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

Contributor orientation: [`AGENTS.md`](AGENTS.md), [`CONTEXT.md`](CONTEXT.md),
and core [`../image_bytes_cache/AGENTS.md`](../image_bytes_cache/AGENTS.md).

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

## Maintainers

- [Zulufov Emil](https://github.com/itsezlife)

## 📝 License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file
for details.

Copyright (c) 2026 Zulufov Emil <emilzulufov566@gmail.com>
