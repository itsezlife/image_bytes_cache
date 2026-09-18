# image_bytes_cache - Durable remote image bytes for Dart

[![Dart](https://img.shields.io/badge/Dart-%230175C2.svg?style=flat&logo=dart&logoColor=white)](https://dart.dev)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Caches remote image **bytes** (SVG, PNG, and other payloads) with an identity
key, a RAM meta mirror after open, platform blob stores, and a resolve ladder:
cache hit, then network with in-flight coalesce, then fire-and-forget
write-through.

## Features

- **Bytes product.** Store and resolve payloads. Decode stays with the host or
  paint adapters.
- **Resolve ladder.** Cache → pooled HTTP (coalesced in-flight) → unawaited
  write-through. Empty cached payloads count as a miss. A durable write failure
  never fails a successful network resolve.
- **Stable identity.** `ImageCacheKey` from the `Uri.base.resolve` canonical URL
  + canonical headers (lowercase keys, sorted; length-prefixed fingerprint).
  Distinct URLs that share a basename do not collide on disk. Explicit
  `cacheKey` is a full-identity escape hatch.
- **Hot-path reads.** After open, meta stays in a RAM mirror. Pure reads do not
  durable-commit and do not serialize against each other.
- **Batched durable commits.** Write, evict, prune, TTL-delete, reclaim, and
  close share one exclusive mutate domain. Meta commits once per epoch.
- **Retention without a timer.** TTL on read; capacity on write or prune.
  Default `ImageBytesRetention.standard`: 14 days, 500 entries, 50 MiB.
- **VM and web backends.** VM: versioned JSON index + one file per key on a
  long-lived isolate worker. Web: Cache API index; blobs under 64 KiB in Cache
  API, larger blobs in OPFS (same cut as VM transferable writes).
- **Soft diagnostics.** `silent`, `developer`, or `onEvent`. Process-wide
  policy at open/configure. No product logger dependency.
- **Degraded open.** Hard storage failure falls back to
  `MemoryImageBytesCache` unless `throwOnOpenFailure: true`. Partial VM workers
  / web handles are closed before degrade or rethrow. A missing VM
  `directory` still throws.

## Quick start

### Installation

```yaml
dependencies:
  image_bytes_cache:
    git:
      url: https://github.com/itsezlife/image_bytes_cache.git
      path: packages/image_bytes_cache
      ref: main
```

Then `dart pub get` (or `flutter pub get` from a Flutter host).

### Bootstrap

Call once at process start. On VM, pass a reclaimable cache directory (not
documents or support). Web ignores `directory`.

```dart
import 'package:image_bytes_cache/image_bytes_cache.dart';

await ImageBytesCache.configure(
  await ImageBytesCache.open(
    directory: cacheDirectory, // required on VM; ignored on web
    diagnostics: const ImageBytesDiagnostics.silent(),
  ),
);
```

### Resolve bytes

```dart
final bytes = await ImageBytesResolver.shared().resolve(
  ImageBytesRequest(
    url: 'https://cdn.example.com/logo.svg',
    headers: const {'Accept': 'image/svg+xml'},
  ),
);
```

For Flutter paint (SVG today), use
[`image_bytes_cache_flutter`](../image_bytes_cache_flutter/) after the same
`open` / `configure` call.

## Resolve ladder

```
ImageBytesRequest
        │
        ▼
ImageBytesResolver
   ├─ cache.read(key)     hit → return bytes
   ├─ empty payload       treat as miss
   ├─ HttpBytesFetcher    pool + coalesce by ImageCacheKey identity
   └─ unawaited write     failure → diagnostics only
```

| Piece | Role |
| --- | --- |
| `ImageCacheKey` | Filename-safe identity; shared with HTTP coalesce |
| `IImageBytesCache` | `read` / `write` / `evict` / `prune` / `close` |
| `ImageBytesResolver` | Ladder above the store |
| `HttpBytesFetcher` | GET only; pool 6; timeout 15s after a slot (`AbortableRequest`); pool wait unbounded |
| `ImageBytesDiagnostics` | Soft failures: write-through, index wipe, degraded open |

Inject cache and fetcher in tests. Production code usually uses
`ImageBytesResolver.shared()`, which re-reads `ImageBytesCache.shared()` and
`HttpBytesFetcher.shared()` on every resolve (not a one-shot snapshot at first
call).

## Retention

```dart
// Default at open (14 days / 500 entries / 50 MiB):
await ImageBytesCache.open(
  directory: cacheDirectory,
  retention: ImageBytesRetention.standard,
);

// Or compose limits:
await ImageBytesCache.open(
  directory: cacheDirectory,
  retention: const ImageBytesRetention.compound(
    maxAge: Duration(days: 7),
    maxEntries: 200,
    maxBytes: 20 * 1024 * 1024,
  ),
);
```

TTL applies on read. Entry and byte caps apply on write and prune. There is no
background eviction timer.

## Diagnostics

```dart
await ImageBytesCache.configure(
  await ImageBytesCache.open(
    directory: cacheDirectory,
    diagnostics: ImageBytesDiagnostics.onEvent((event) {
      // Bridge to your logger / crash reporter.
    }),
  ),
);
```

| Policy | Effect |
| --- | --- |
| `silent` | No emission (default) |
| `developer` | `developer.log` name `image_bytes` |
| `onEvent` | Host callback |

Ops: `write_through`, `index_wipe`, `open_degraded`.

## Platform support

- Android
- iOS
- Web
- Windows
- macOS
- Linux

VM targets use a file index plus an isolate blob worker. Web uses a Cache API
index, Cache API blobs under 64 KiB, and OPFS for larger bodies. Conditional
imports select backends with `dart.library.js_interop` (not
`dart.library.html`).

## Contributing

Open a pull request. For large changes, open an issue first.

### Development setup

```bash
cd packages/image_bytes_cache
dart pub get
dart test test/unit_test.dart
dart analyze lib test
dart format lib test
```

Web open smoke (run before merging web blob or open changes):

```bash
dart test -p chrome test/open/image_bytes_cache_open_web_test.dart
```

Store and ladder microbenches (optional, not a CI gate):

```bash
dart test benchmark/compare_test.dart --dart-define=SAVE_BASELINE=true
dart test benchmark/compare_test.dart
```

More detail: [`AGENTS.md`](AGENTS.md), [`CONTEXT.md`](CONTEXT.md),
[`docs/architecture.md`](docs/architecture.md),
[`docs/storage.md`](docs/storage.md),
[`docs/resolve-ladder.md`](docs/resolve-ladder.md),
[`docs/development.md`](docs/development.md).

## Changelog

Refer to the [Changelog](CHANGELOG.md) to get all release notes.

## Maintainers

- [Zulufov Emil](https://github.com/itsezlife)

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file
for details.

Copyright (c) 2026 Zulufov Emil <emilzulufov566@gmail.com>
