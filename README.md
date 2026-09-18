# image_bytes_cache

Fetch a remote image once, keep the bytes on disk (or in the browser), and hand them back on the next request. Works in plain Dart and in Flutter.

Two packages live here:

| Package | What you get |
| --- | --- |
| [`image_bytes_cache`](packages/image_bytes_cache/) | Open the cache, resolve URLs to bytes |
| [`image_bytes_cache_flutter`](packages/image_bytes_cache_flutter/) | Widgets that paint those bytes (SVG today) |

The core package stores bytes only. Decoding and drawing stay with you or with the Flutter package.

## Install

```yaml
dependencies:
  image_bytes_cache: latest
```

For Flutter, also pull in `image_bytes_cache_flutter` the same way.

Then `dart pub get` or `flutter pub get`.

## Quick start

Open the cache once at process start. On mobile and desktop, pass a reclaimable cache directory. Web ignores `directory`.

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

In Flutter, after the same `open` / `configure`:

```dart
import 'package:image_bytes_cache_flutter/image_bytes_cache_flutter.dart';

CachedNetworkSvgImage(
  'https://cdn.example.com/logo.svg',
  width: 48,
  height: 48,
);
```

What happens on resolve: look in the cache, fetch over the network if missing, then save in the background. Duplicate in-flight requests for the same URL share one download.

Default retention is 14 days, 500 entries, and 50 MiB. Limits apply on read and write. There is no background timer.

## Where to read more

- Core API, retention, diagnostics: [`packages/image_bytes_cache/README.md`](packages/image_bytes_cache/README.md)
- Flutter widget options: [`packages/image_bytes_cache_flutter/README.md`](packages/image_bytes_cache_flutter/README.md)
- Internals for contributors: [`packages/image_bytes_cache/AGENTS.md`](packages/image_bytes_cache/AGENTS.md), [`docs/`](packages/image_bytes_cache/docs/)

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

MIT. See [LICENSE](LICENSE).

Copyright (c) 2026 Zulufov Emil <emilzulufov566@gmail.com>
