# image_bytes_cache

Durable remote **image bytes** for Dart and Flutter: identity key → RAM meta
mirror → platform blob stores, plus a resolve ladder (cache → network coalesce
→ write-through). Paint adapters live in a sibling Flutter package.

| Package | Role |
| --- | --- |
| [`image_bytes_cache`](packages/image_bytes_cache/) | Pure-Dart engine (stores, ladder, microbenches) |
| [`image_bytes_cache_flutter`](packages/image_bytes_cache_flutter/) | Flutter widgets / SVG paint; profile compare harness |

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

Core-only hosts may omit `image_bytes_cache_flutter`.

## Quick start

```dart
import 'package:image_bytes_cache/image_bytes_cache.dart';

await ImageBytesCache.configure(
  await ImageBytesCache.open(
    directory: cacheDirectory, // required on VM; ignored on web
    diagnostics: const ImageBytesDiagnostics.silent(),
  ),
);

final bytes = await ImageBytesResolver.shared().resolve(
  ImageBytesRequest(url: 'https://cdn.example.com/logo.svg'),
);
```

Flutter SVG paint (after the same `open` / `configure`):

```dart
import 'package:image_bytes_cache_flutter/image_bytes_cache_flutter.dart';

CachedNetworkSvgImage('https://cdn.example.com/logo.svg', width: 48, height: 48);
```

## Docs

- Core: [`packages/image_bytes_cache/README.md`](packages/image_bytes_cache/README.md),
  [`AGENTS.md`](packages/image_bytes_cache/AGENTS.md),
  [`docs/`](packages/image_bytes_cache/docs/)
- Flutter: [`packages/image_bytes_cache_flutter/README.md`](packages/image_bytes_cache_flutter/README.md)

## Development

```bash
# Core
cd packages/image_bytes_cache
dart pub get
dart test test/unit_test.dart
dart analyze lib test

# Flutter adapters
cd ../image_bytes_cache_flutter
flutter pub get
flutter test
flutter analyze
```

## License

MIT — see [LICENSE](LICENSE).

Copyright (c) 2026 Zulufov Emil <emilzulufov566@gmail.com>
