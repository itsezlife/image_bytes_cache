# image_bytes_cache - Durable remote image bytes for Dart

[![Dart](https://img.shields.io/badge/Dart-%230175C2.svg?style=flat&logo=dart&logoColor=white)](https://dart.dev)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Caches remote image **bytes** with an identity key, a RAM meta mirror after
open, platform blob stores, and a resolve ladder: cache hit, then network with
in-flight coalesce, then fire-and-forget write-through.

## 🌟 Features

- **📦 Bytes product**: Store and resolve payloads. Decode stays with the host
  or paint adapters.
- **🔗 Resolve ladder**: Cache → pooled HTTP (coalesced in-flight) → unawaited
  write-through. Empty cached payloads count as a miss. A durable write failure
  never fails a successful network resolve.
- **🔑 Stable identity**: `ImageCacheKey` from the `Uri.base.resolve` canonical
  URL + canonical headers. Distinct URLs that share a basename do not collide on 
  disk. Explicit `cacheKey` is a full-identity escape hatch.
- **⚡ Hot-path reads**: After open, meta stays in a RAM mirror. Pure reads do
  not durable-commit and do not serialize against each other.
- **📝 Batched durable commits**: Write, evict, prune, TTL-delete, reclaim, and
  close share one exclusive mutate domain. Meta commits once per epoch.
- **⏳ Retention without a timer**: TTL on read; capacity on write or prune.
- **🌐 VM and web backends**: VM: versioned JSON index + one file per key on a
  long-lived isolate worker. Web: Cache API index; blobs under 64 KiB in Cache
  API, larger blobs in OPFS (same cut as VM transferable writes).
- **🩺 Soft diagnostics**: `silent`, `developer`, or `onEvent`. Process-wide
  policy at open/configure.
- **🛡️ Degraded open**: Hard storage failure falls back to
  `MemoryImageBytesCache` unless `throwOnOpenFailure: true`. Partial VM workers
  / web handles are closed before degrade or rethrow.

## 🚀 Quick Start

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
    url: 'https://cdn.example.com/logo.png',
  ),
);
```

For Flutter paint, use
[`image_bytes_cache_flutter`](../image_bytes_cache_flutter/) after the same
`open` / `configure` call.

## 🔗 Resolve ladder

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

## ⏳ Retention

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

## 🩺 Diagnostics

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

## 📊 Performance

`image_bytes_cache` is built for paint-adjacent resolve: after open, meta lives
in a RAM mirror so a warm hit does not durable-commit and does not serialize
against other pure reads. Mutates share one exclusive epoch with a single meta
commit. In-flight HTTP for the same `ImageCacheKey` coalesces under a small
pool so a burst of identical URLs is one GET, not N.

Head-to-head against `cached_network_image_ce` (Hive) and stock
`cached_network_image` (sqflite) on the same machine (Apple Silicon, Flutter
3.41.7) measuring **URL → bytes ready** only (no decode / ImageProvider paint)
— full tables and methodology in
[`../image_bytes_cache_flutter/benchmark_compare/RESULTS.md`](../image_bytes_cache_flutter/benchmark_compare/RESULTS.md):

- **Warm hit** — **~1.5–1.6× faster than CE (Hive) and ~1.8× faster than stock
  (sqflite)** on small and large bodies (~185 µs/op vs ~280–335 µs/op).
- **Cold miss** — **~2.8–3.1× faster than CE and ~4.8–5.2× faster than stock**
  (~420–470 µs/op vs ~1.2–2.2 ms/op), including MockClient fetch + store.
- **Same-URL burst** — **~2.5× faster than CE** (and ~1.6× faster than stock)
  when many resolves share one key.
- **Many distinct keys** — **~2.9× faster than CE and ~6.6× faster than stock**
  under the HTTP pool.
- **Scrolling** (profile matrix on Android 16) — **zero missed build
  frames** across the full 18-cell factorial; medium/medium ordinary +
  complicated stay clean on raster (**0/0** misses, build 99th **~2.1–2.4 ms**).
  Fast scroll is where raster pressure shows (99th ~27–32 ms) — host-feel
  evidence, not a substitute for the bytes ratios.

```bash
# Package-local store + ladder microbenches (before/after on one machine):
dart test benchmark/compare_test.dart --dart-define=SAVE_BASELINE=true
dart test benchmark/compare_test.dart

# Optional RSS fill / prune lane (noisy; same-machine deltas only):
dart test benchmark/compare_test.dart --dart-define=MEMORY_LANE=true

# Head-to-head vs CE (Hive) & stock CNI (sqflite) — bytes ready:
cd ../image_bytes_cache_flutter/benchmark_compare && flutter pub get
flutter test test/bytes_compare_test.dart
```

Baseline file for the package-local suite: `benchmark/.baseline.txt`
(gitignored). Suite detail: [`docs/development.md`](docs/development.md).

## 📱 Platform Support

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

## 🤝 Contributing

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

Store and ladder microbenches — see [Performance](#-performance).

More detail: [`AGENTS.md`](AGENTS.md), [`CONTEXT.md`](CONTEXT.md),
[`docs/architecture.md`](docs/architecture.md),
[`docs/storage.md`](docs/storage.md),
[`docs/resolve-ladder.md`](docs/resolve-ladder.md),
[`docs/development.md`](docs/development.md).

## 📝 Changelog

Refer to the [Changelog](CHANGELOG.md) to get all release notes.

## 👥 Maintainers

- [Zulufov Emil](https://github.com/itsezlife)

## 📄 License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file
for details.

Copyright (c) 2026 Zulufov Emil <emilzulufov566@gmail.com>
