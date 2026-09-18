# Development

Commands, test seams, layout, and conventions for package `image_bytes_cache`
(`0.0.1`). SDK `>=3.11.0`.

Layout: this package sits beside sibling `image_bytes_cache_flutter` under
`packages/` in this repository. Core stays bytes-only; paint widgets and
UI/profile benches live in the flutter package (and flutter-side
`benchmark_compare`), not here.

## Commands

From the package root:

```shell
dart pub get

# Unit + VM integration — single aggregate entrypoint
dart test test/unit_test.dart

# Analyzer (standalone analysis_options; infos/warnings should stay clean)
dart analyze lib test

# Format, page_width 120 (analysis_options), not 80
dart format lib test
```

`test/unit_test.dart` imports each suite's `main()` inside `group('Unit', …)`.
A new VM `*_test.dart` must be wired there or the default run skips it.
Chrome-only open stays a separate entrypoint (see below).

### Web smoke (Chrome)

```shell
dart test -p chrome test/open/image_bytes_cache_open_web_test.dart
```

Covers Cache vs OPFS routing by size, close/reopen, and orphan reclaim on both
backends. If CI cannot host Chrome, run that file locally before merging web
blob changes. `test/storage/image_bytes_web_store_test.dart` covers the index
codec and web key helpers on the VM harness; use the Chrome open test for real
Cache/OPFS composition.

## Test seams

Assert external behavior through public contracts. Do not assert temp
filenames, private lock maps, IsolateController internals, or Hive (forbidden
on this path).

| Seam | What to cover |
| --- | --- |
| `IImageBytesCache` / `IndexedImageBytesCache` | Hit/miss, soft LRU, TTL, capacity (entries + bytes), concurrent read vs exclusive mutate integrity, orphan healing, close; commit throw rolls RAM back (no optimistic hit) |
| `ImageBytesCache.open` (VM) | Real temp directory round-trip, batch commit after close/reopen, orphan reclaim, degraded open |
| `ImageBytesCache.open` (web / Chrome) | Size routing, reopen, reclaim on Cache and OPFS |
| `ImageBytesBlobStore$File$VM` | Worker death fails pending RPC (timeout-bounded); respawn after death; exclusive gate not stuck |
| `ImageBytesResolver` | Hit skips network; empty cache misses; write-through failure (incl. index commit throw) still returns bytes; throwing `onEvent` is not unhandled |
| `HttpBytesFetcher` | Coalesce, pool, non-2xx, empty body, timeout (+ abort when client honors), close |
| `ImageCacheKey` | Canonical headers; distinct URLs with same basename |

Prefer fakes for `IImageBytesIndex` / `IImageBytesBlobStore` when testing the
brain. Use real open for durability integration.

## Package layout

```text
lib/
  image_bytes_cache.dart          # public barrel
  src/
    image_bytes_cache.dart        # brain + facade + Memory/NoOp
    image_bytes_resolver.dart
    http_bytes_fetcher.dart
    image_bytes_diagnostics.dart
    image_bytes_index_document.dart
    image_bytes_web_keys.dart
    isolate_controller.dart       # VM worker lifecycle (not exported)
    environment_specific/
      image_bytes_cache_open.dart     # conditional stub
      image_bytes_cache_open_vm.dart
      image_bytes_cache_open_js.dart
      *_file_vm.dart / *_js.dart      # index + blob adapters
benchmark/
  compare.dart                    # warmup / calibrate / baseline deltas
  compare_test.dart               # dart test entry
  scenarios.dart                  # named Memory + durable VM store rows
  ladder_scenarios.dart           # resolve ladder + optional RSS memory lane
  payloads.dart                   # small / ≥64 KiB synthetic bodies
  sink.dart                       # shared anti-DCE byte fold
test/
  unit_test.dart                  # aggregate VM entrypoint
  cache/ open/ resolve/ storage/  # suites by mechanism
```

Platform selection uses `dart.library.js_interop` (Wasm-safe). Do not gate this
package on `dart.library.html`.

## Conventions

- Grow storage and ladder code in this package, not in host UI util trees and
  not in `image_bytes_cache_flutter`.
- Conditional imports for platform IO; no `if (kIsWeb)` inside shared brain
  files.
- Index document encode/decode only through `ImageBytesIndexDocumentCodec`.
- Orphan reclaim only under `IndexedImageBytesCache`’s exclusive domain.
- Public members keep contract-grade `///` docs (see existing types).
- Core `lib/` must not import `package:flutter` or `package:shared`.
- Do not add Flutter widgets or profile-feed harnesses here —
  those belong in `image_bytes_cache_flutter` / flutter-side compare.

## Benchmarks

Package-local microbenches live under `benchmark/`. Two latency suites share
one runner / baseline file:

1. **Store** (`scenarios.dart`) — `IImageBytesCache` (Memory and durable VM
   open): warm hit, cold durable round-trip, concurrent reads, write epoch,
   prune/evict, small vs ≥64 KiB bodies.
2. **Resolve ladder** (`ladder_scenarios.dart`) — `ImageBytesResolver` over
   in-process `MockClient` HTTP (no public internet): miss → write-through →
   warm hit, same-URL burst coalesce, distinct-key grid under the HTTP pool
   cap. Scenario bodies use local cache/fetcher/resolver only (never
   process-wide shared). `compare_test.dart` clears shared cache / resolver /
   fetcher in setUp/tearDown so a leaked configure from another harness cannot
   poison the suite.

Optional **memory lane** (`MEMORY_LANE=true`): RSS via
`ProcessInfo.currentRss` before fill-to-`ImageBytesRetention.standard`
capacity, after fill + many-key warm reads, and after prune (clock advanced
past standard `maxAge` so prune actually drops the filled set). Process-wide
and OS/GC noisy — use before/after deltas on one machine; not a baseline key
and not a CI gate.

Not a CI merge gate — run locally when iterating on the store or ladder.

Durable VM IO uses the in-package `IsolateController` (`lib/src/isolate_controller.dart`), so
store microbenches run under plain `dart test` (no Flutter SDK).

```shell
# Low-noise table + optional baseline deltas (from package root)
dart test benchmark/compare_test.dart --dart-define=SAVE_BASELINE=true
dart test benchmark/compare_test.dart

# Optional RSS fill / prune table (documented caveats in the printed header)
dart test benchmark/compare_test.dart --dart-define=MEMORY_LANE=true
```

Baseline file: `benchmark/.baseline.txt` (gitignored). Methodology: warmup,
auto-calibrated batch size, min-of-batches estimator, sink on returned bytes.
Relative deltas on one machine are the PR signal; absolute microseconds are
not portable. Unit tests remain correctness-only.

Head-to-head competitor tables, real-device profile feeds, and scroll-pressure
matrices are **not** package-local. They live under
[`image_bytes_cache_flutter/benchmark_compare/`](../../image_bytes_cache_flutter/benchmark_compare/).
See that package’s [`AGENTS.md`](../../image_bytes_cache_flutter/AGENTS.md).
