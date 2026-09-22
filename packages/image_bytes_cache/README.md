# image_bytes_cache - Durable remote image bytes for Dart

[![Dart](https://img.shields.io/badge/Dart-%230175C2.svg?style=flat&logo=dart&logoColor=white)](https://dart.dev)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Caches remote image bytes behind an identity key. After open, meta sits in RAM.
Blobs live on disk (VM) or Cache API / OPFS (web). Resolve is a short ladder:
fresh cache hit, conditional or unconditional GET with in-flight coalesce, then
fire-and-forget write-through. Opt-in HTTP and cache middleware customize the
stack without open/configure flag piles.

## Features

- **Bytes product.** Store and resolve payloads. Decode stays with the host or
  paint adapters.
- **Resolve ladder.** Fresh hit skips the network. Stale hits revalidate when
  Conditional middleware is on the client (304 reuses bytes). Misses and
  validator-less stale entries full-fetch. Empty cached payloads count as a
  miss. A durable write failure never fails a successful network resolve.
  Transient `$Network` / `$Timeout` / `$Server` can return held non-empty
  cached bytes.
- **Middleware.** Same outermost-first fold on HTTP and cache. Default HTTP
  stack is Timeout-only. Opt-in Retry, Bearer, Conditional, Logger. Cache wrap
  adds Skip-cache and Cache Logger. No reclaim as a cache op.
- **Stable identity.** `ImageCacheKey` from the `Uri.base.resolve` canonical URL
  plus canonical headers. Distinct URLs that share a basename do not collide on
  disk. Explicit `cacheKey` is a full-identity escape hatch.
- **Hot-path reads.** After open, meta stays in a RAM mirror. Pure reads do not
  durable-commit and do not serialize against each other.
- **Batched durable commits.** Write, evict, prune, TTL-delete, reclaim, and
  close share one exclusive mutate domain. Meta commits once per epoch.
- **Retention without a timer.** TTL on read; capacity on write or prune.
  Separate from HTTP freshness.
- **VM and web backends.** VM: versioned JSON index + one file per key on a
  long-lived isolate worker. Web: Cache API index; blobs under 64 KiB in Cache
  API, larger blobs in OPFS (same cut as VM transferable writes).
- **Soft diagnostics.** `silent`, `developer`, or `onEvent`. Process-wide policy
  at open/configure. Covers write-through, wipe, degraded open, revalidated,
  stale-used, and unconditional soft paths.
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
// Omit to use the default `http.Client()` with Timeout-only middleware.
// For ETag revalidation, add Conditional (and usually Bearer before it):
// await HttpBytesClient.configure(
//   HttpBytesClient(
//     client: myClient,
//     middlewares: <HttpBytesMiddleware>[
//       const HttpBytesTimeoutMiddleware(),
//       const HttpBytesConditionalMiddleware(),
//     ],
//   ),
// );
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
   ├─ rich cache read     fresh hit → return bytes
   ├─ empty payload       treat as miss
   ├─ stale + validators  conditional GET (needs Conditional middleware)
   │                         304 → reuse bytes + soft meta refresh
   │                         200 → write-through bytes + meta
   ├─ stale / miss        unconditional GET
   ├─ flaky network       non-empty cache + $Network/$Timeout/$Server → stale bytes
   └─ unawaited write     failure → diagnostics only
```

| Piece | Role |
| --- | --- |
| `ImageCacheKey` | Filename-safe identity; shared with HTTP coalesce |
| `IImageBytesCache` | `read` / `write` / `evict` / `prune` / `close` |
| `ImageBytesResolver` | Ladder above the store |
| `HttpBytesClient` | GET only; pool 6; timeout 15s after a slot (`AbortableRequest`); pool wait unbounded |
| `ImageBytesDiagnostics` | Soft paths: write-through, wipe, degraded open, revalidated / stale-used / unconditional |

Inject cache and client in tests. Production code usually uses
`ImageBytesResolver.shared()`, which re-reads `ImageBytesCache.shared()` and
`HttpBytesClient.shared()` on every resolve (not a one-shot snapshot at first
call).

## Middleware

HTTP and cache share one composition rule: list order is outermost first.
`null` on `HttpBytesClient.middlewares` installs Timeout only; `[]` installs
none.

### HTTP stack

Default client is Timeout-only. That is enough for a plain fetch. Conditional
revalidation needs `HttpBytesConditionalMiddleware` on the process client, or
validators never leave the resolver context.

```dart
await HttpBytesClient.configure(
  HttpBytesClient(
    client: myClient, // optional Cronet / Cupertino / shared IOClient
    middlewares: <HttpBytesMiddleware>[
      const HttpBytesLoggerMiddleware$Developer(), // outermost
      HttpBytesRetryMiddleware(),
      const HttpBytesTimeoutMiddleware(),
      HttpBytesBearerMiddleware(getToken: getToken),
      const HttpBytesConditionalMiddleware(), // after Bearer, before coalesce
    ],
  ),
);
```

| Middleware | Default? | Notes |
| --- | --- | --- |
| Logger$Developer | no | Outermost so logs include retry time |
| Retry | no | Outside Timeout; never retries 304 / cancel / timeout / auth |
| Timeout | yes | Connect + receive idle after a pool slot; queue wait is unbounded |
| Bearer | no | Sets `Authorization` from `getToken` only; no refresh / logout |
| Conditional | no | Seeds `If-None-Match` / `If-Modified-Since` from context |

Conditional headers are excluded from coalesce identity. Bearer-injected
`Authorization` still participates, so different tokens do not share a flight.

### Cache stack

Wrap the store from `open` when you need skip-cache or cache logging. Orphan
reclaim stays on `IndexedImageBytesCache`; there is no reclaim cache op.

```dart
final durable = await ImageBytesCache.open(directory: cacheDirectory);
await ImageBytesCache.configure(
  MiddlewareImageBytesCache(
    inner: durable,
    middlewares: <CacheMiddleware>[
      const CacheLoggerMiddleware$Developer(), // outermost
      const SkipCacheMiddleware(),
    ],
  ),
);
```

`ImageBytesRequest.skipCache: true` only works when Skip-cache is on that
wrapper. Plain stores ignore the flag; HTTP still runs.

### Freshness vs retention

`ImageHttpCacheFreshness` decides whether a hit is fresh enough to skip the
network. `ImageBytesRetention` only caps durable age, entry count, and total
bytes. Do not treat retention TTL as Cache-Control `max-age`.

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

Default is `silent`. Use `developer` for `developer.log`, or `onEvent` to
route yourself. Soft-path ops at debug/warning do not change resolve results.

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
