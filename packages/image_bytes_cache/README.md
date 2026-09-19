# image_bytes_cache - Durable remote image bytes for Dart

[![Dart](https://img.shields.io/badge/Dart-%230175C2.svg?style=flat&logo=dart&logoColor=white)](https://dart.dev)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Caches remote image bytes behind an identity key. After open, meta sits in RAM.
Blobs live on disk (VM) or Cache API / OPFS (web). Resolve is a short ladder:
cache hit, then network with in-flight coalesce, then fire-and-forget write-through.

## Features

- **Bytes product.** Store and resolve payloads. Decode stays with the host or
  paint adapters.
- **Resolve ladder.** Cache → pooled HTTP (coalesced in-flight) → unawaited
  write-through. Empty cached payloads count as a miss. A durable write failure
  never fails a successful network resolve.
- **Stable identity.** `ImageCacheKey` from the `Uri.base.resolve` canonical URL
  plus canonical headers. Distinct URLs that share a basename do not collide on
  disk. Explicit `cacheKey` is a full-identity escape hatch.
- **Hot-path reads.** After open, meta stays in a RAM mirror. Pure reads do not
  durable-commit and do not serialize against each other.
- **Batched durable commits.** Write, evict, prune, TTL-delete, reclaim, and
  close share one exclusive mutate domain. Meta commits once per epoch.
- **Retention without a timer.** TTL on read; capacity on write or prune.
- **VM and web backends.** VM: versioned JSON index + one file per key on a
  long-lived isolate worker. Web: Cache API index; blobs under 64 KiB in Cache
  API, larger blobs in OPFS (same cut as VM transferable writes).
- **Soft diagnostics.** `silent`, `developer`, or `onEvent`. Process-wide policy
  at open/configure.
- **Degraded open.** Hard storage failure falls back to `MemoryImageBytesCache`
  unless `throwOnOpenFailure: true`. Partial VM workers / web handles are closed
  before degrade or rethrow.

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

// Optional: process-wide HTTP client (Cronet / Cupertino / shared IOClient).
// Omit to use the default `http.Client()`.
// await HttpBytesClient.configure(HttpBytesClient(client: myClient));
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
`open` / `configure` call (and optional client configure).

## Resolve ladder

```
ImageBytesRequest
        │
        ▼
ImageBytesResolver
   ├─ cache.read(key)     hit → return bytes
   ├─ empty payload       treat as miss
   ├─ HttpBytesClient    pool + coalesce by ImageCacheKey identity
   └─ unawaited write     failure → diagnostics only
```

| Piece | Role |
| --- | --- |
| `ImageCacheKey` | Filename-safe identity; shared with HTTP coalesce |
| `IImageBytesCache` | `read` / `write` / `evict` / `prune` / `close` |
| `ImageBytesResolver` | Ladder above the store |
| `HttpBytesClient` | GET only; pool 6; timeout 15s after a slot (`AbortableRequest`); pool wait unbounded |
| `ImageBytesDiagnostics` | Soft failures: write-through, index wipe, degraded open |

Inject cache and client in tests. Production code usually uses
`ImageBytesResolver.shared()`, which re-reads `ImageBytesCache.shared()` and
`HttpBytesClient.shared()` on every resolve (not a one-shot snapshot at first
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

## Performance

After open, meta lives in RAM, so a warm hit does not durable-commit and does
not line up behind other pure reads. Mutates share one exclusive epoch with a
single meta commit. In-flight HTTP for the same `ImageCacheKey` coalesces under
a small pool, so a burst of identical URLs is one GET.

We run head-to-head against `cached_network_image_ce` (Hive) and stock
`cached_network_image` (sqflite). Full tables and how we measure:
[`../image_bytes_cache_flutter/benchmark_compare/RESULTS.md`](../image_bytes_cache_flutter/benchmark_compare/RESULTS.md).

### URL → bytes ready (Apple Silicon VM)

Same MockClient corpus. No decode / ImageProvider paint. Ratios are
`adapter / ours` (higher means slower than ours).

| Scenario | vs CE (Hive) | vs stock (sqflite) |
| -------- | ------------: | -----------------: |
| Cold miss | ~2.2× | ~4.5× |
| Warm hit | ~1.1× | ~1.3× |
| Same-URL burst | ~2.2× | ~1.7× |
| Many distinct keys | ~2.1× | ~4.8× |

Absolute microseconds move between runs. Trust the ratios on one quiet machine.

### Profile scroll: raster paint (SM S938B, Android 16)

Three-way feed: `CachedNetworkBytesImage` vs `CachedNetworkImage` (CE / stock).
Cells `warm-scroll` / `cold-scroll` / `pressure-scroll` (48 / 48 / 120 items).
Phone-specific frame timings. Do not treat them as a substitute for the bytes
ratios.

| Cell | Missed raster (ours / CE / stock) | Notes |
| ---- | --------------------------------: | ----- |
| `warm-scroll` | 0 / 0 / 0 | Clean; ours a bit heavier on frame build |
| `cold-scroll` | 0 / 0 / 0 | Same story |
| `pressure-scroll` | 0 / 4 / 8 | Ours raster worst about 2.6 ms; CE about 29 ms; stock about 32 ms |

Under pressure, CE and stock can look cheaper on widget build while the GPU
spikes. We pay a bit more on build and keep raster inside budget.

### Chrome web scroll (debug drive)

Same cells and adapters via `flutter drive -d web-server`. Competitors use
`HttpGet` so MockClient serves the corpus. On `pressure-scroll`, missed raster
was 0 / 0 / 0 (worst about 6-8 ms). Build averages sat near 4 ms. Debug Chrome
is noisier than device profile. Full tables live in RESULTS.

```bash
# Package-local store + ladder microbenches (before/after on one machine):
dart test benchmark/compare_test.dart --dart-define=SAVE_BASELINE=true
dart test benchmark/compare_test.dart

# Optional RSS fill / prune lane (noisy; same-machine deltas only):
dart test benchmark/compare_test.dart --dart-define=MEMORY_LANE=true

# Head-to-head vs CE (Hive) & stock CNI: bytes + paint + profile:
cd ../image_bytes_cache_flutter/benchmark_compare && flutter pub get
flutter test test/bytes_compare_test.dart
flutter test integration_test/paint_compare_test.dart -d <device>
flutter drive --driver=test_driver/perf_driver.dart \
  --target=integration_test/scroll_perf_test.dart --profile --no-dds -d <device>
dart run tool/summarize_timeline.dart

# Web paint + scroll (ChromeDriver on :4444):
flutter drive --driver=test_driver/perf_driver.dart \
  --target=integration_test/paint_compare_test.dart \
  -d web-server --browser-name=chrome --driver-port=4444
flutter drive --driver=test_driver/perf_driver.dart \
  --target=integration_test/scroll_perf_test.dart \
  -d web-server --browser-name=chrome --driver-port=4444
dart run tool/summarize_timeline.dart
```

Baseline file for the package-local suite: `benchmark/.baseline.txt`
(gitignored). Suite detail: [`docs/development.md`](docs/development.md).

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
dart test -p chrome test/open/open_web_test.dart
```

Store and ladder microbenches: [Performance](#performance).

More detail: [`AGENTS.md`](AGENTS.md), [`CONTEXT.md`](CONTEXT.md),
[`docs/architecture.md`](docs/architecture.md),
[`docs/storage.md`](docs/storage.md),
[`docs/resolve-ladder.md`](docs/resolve-ladder.md),
[`docs/development.md`](docs/development.md).

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

## Maintainers

- [Zulufov Emil](https://github.com/itsezlife)

## License

MIT. See [LICENSE](LICENSE).

Copyright (c) 2026 Zulufov Emil <emilzulufov566@gmail.com>
