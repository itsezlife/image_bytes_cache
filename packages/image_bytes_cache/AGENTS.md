# AGENTS.md

High-signal orientation for LLMs/agents working in **`image_bytes_cache`**
(pure-Dart core in this repo under `packages/image_bytes_cache/`).
Read this first, every time. Deep detail lives in [`docs/`](docs/), linked per
section. Glossary: [`CONTEXT.md`](CONTEXT.md).

`image_bytes_cache` is a durable remote **image bytes** engine: identity key →
RAM meta mirror → platform blob stores, plus a resolve ladder (cache → network
coalesce → write-through).

## Commands (run before you claim done)

```shell
# Tests — test/unit_test.dart is the single aggregate entrypoint for VM suites.
dart test test/unit_test.dart
dart analyze lib test
dart format lib test   # page_width 120

# Web smoke (Chrome), required before merging web blob / open changes:
dart test -p chrome test/open/image_bytes_cache_open_web_test.dart

# Store + ladder microbenches (not a CI gate) — baseline deltas:
dart test benchmark/compare_test.dart --dart-define=SAVE_BASELINE=true
dart test benchmark/compare_test.dart
# Optional RSS fill/prune lane (noisy; one-machine deltas only):
# dart test benchmark/compare_test.dart --dart-define=MEMORY_LANE=true
```

More: [`docs/development.md`](docs/development.md).

## Module map (`lib/src/`)

| Path | What | Doc |
| --- | --- | --- |
| `image_bytes_cache.dart` | `ImageCacheKey`, retention, ports, `IndexedImageBytesCache`, Memory/NoOp, `ImageBytesCache` open/configure | [architecture](docs/architecture.md), [storage](docs/storage.md) |
| `image_bytes_resolver.dart` | Ladder: cache → fetch → write-through | [resolve-ladder](docs/resolve-ladder.md) |
| `http_bytes_fetcher.dart` | Pool + in-flight coalesce GET | [resolve-ladder](docs/resolve-ladder.md) |
| `image_bytes_diagnostics.dart` | Soft-failure policy (`silent` / `developer` / `onEvent`) | [resolve-ladder](docs/resolve-ladder.md) |
| `image_bytes_index_document.dart` | Versioned index JSON codec (`v:1`) | [storage](docs/storage.md) |
| `image_bytes_web_keys.dart` | Synthetic `.invalid` Cache URLs + OPFS dir names | [storage](docs/storage.md) |
| `isolate_controller.dart` | Long-lived isolate spawn/add/stream/close (VM blob IO) | [storage](docs/storage.md) |
| `environment_specific/image_bytes_cache_open*.dart` | Conditional `open` (VM files / web Cache+OPFS) | [storage](docs/storage.md) |
| `environment_specific/*_vm.dart` | File index + isolate blob worker | [storage](docs/storage.md) |
| `environment_specific/*_js.dart` | Cache API index; Cache/OPFS blobs by 64 KiB cut | [storage](docs/storage.md) |

Public API is the barrel `lib/image_bytes_cache.dart`. See
[`docs/architecture.md`](docs/architecture.md).

## Hard rules (do not violate)

1. **Storage grows here**, not in host UI util trees. Widgets depend on
   `IImageBytesResolver` / `IImageBytesCache` only.
2. **No Hive** on this path. No image bodies in SQLite BLOB columns. No live
   SQL `SELECT` on the resolve hot path.
3. **RAM meta after open.** Pure `read` must not durable-commit and must not
   serialize against other pure reads. Mutate epochs call `IImageBytesIndex.commit`
   **once**.
4. **Orphan reclaim only under the exclusive mutate gate** (wired into
   `IndexedImageBytesCache`). Wrappers must not reclaim outside it.
5. **Conditional imports** via `dart.library.js_interop` for web vs VM. Do not
   select this package’s platform stubs with `dart.library.html`.
6. **Index wire format** only through `ImageBytesIndexDocumentCodec`. Wipe on
   unsupported version / corrupt decode (remote bytes are disposable).
7. **One VM test entrypoint:** a new `test/**/foo_test.dart` (except Chrome-only
   open) must be wired into `test/unit_test.dart` (import + `main()` inside
   `group('Unit', …)`) or the default suite run skips it.
8. **Pure Dart core:** no Flutter SDK / `flutter_test`, no `package:shared`,
   no `lints_tool`. No `package:flutter` or `package:shared` imports in
   `lib/`. Paint widgets and Flutter adapters belong in
   [`image_bytes_cache_flutter`](../image_bytes_cache_flutter/), not here.
   Store / ladder microbenches stay in this package; head-to-head compare and
   scroll-profile harnesses go under
   [`../image_bytes_cache_flutter/benchmark_compare/`](../image_bytes_cache_flutter/benchmark_compare/),
   never under core. Competitor deps must not land on this pubspec.

## Load-bearing invariants (don't break silently)

- **Hot path:** concurrent shared reads on the RAM index mirror + blob read;
  soft LRU in `_pendingAccess` only; no durable meta IO on paint hits.
- **Mutate epoch:** write / evict / prune / TTL-delete / reclaim / close share
  one exclusive domain; snapshot RAM → flush soft access → mutate RAM + blobs →
  one `commit` → reclaim when applicable. Thrown commit restores the RAM
  snapshot (no optimistic durable hit) and rethrows.
- **64 KiB cut:** VM transferable isolate writes and web OPFS vs Cache API use
  the same threshold. Do not collapse to all-OPFS or all-Cache without updating
  docs and tests. Web hot reads with known index `byteLength` ≥ cut go OPFS-first
  (skip Cache miss tax); twin-clear-before-write stays.
- **Empty cached payload = miss** in the resolver; empty durable writes are
  not retained (evict); sticky empty rows scrub on read; write-through failure
  never fails a successful network resolve (diagnostics only; throwing
  `onEvent` is swallowed).
- **Open:** hard storage failure degrades to `MemoryImageBytesCache` unless
  `throwOnOpenFailure`; partial VM worker / web handles are closed before
  degrade or rethrow. Missing VM `directory` still throws. `configure`
  closes the previous shared instance before assign. `ImageBytesResolver.shared`
  re-reads process-wide cache/fetcher on each resolve (no one-shot snapshot).
  `resetShared` also clears resolver shared wiring.
- **Retention:** TTL on read; capacity on write/prune; no background timer.
  `standard` = 14 days / 500 entries / 50 MiB. Non-positive `maxEntries` /
  `maxBytes` assert.

## Gotchas quick-reference

- Header key casing and map order must not change identity or coalesce keys
  (`ImageCacheKey.canonicalHeaders`).
- Coalesce and durable identity use `ImageCacheKey` (length-prefixed fingerprint
  material; no `url|headers` join). Relative vs absolute `Uri.base` equivalents
  share one key; explicit `cacheKey` is full identity (headers on wire only).
- Distinct URLs that share a basename must not collide on disk (fingerprint).
- VM store under app **cache** root, not documents. Web ignores `directory`.
- `MemoryImageBytesCache` / `NoOpImageBytesCache` stay usable after `close`;
  Indexed and durable wrappers throw after close.
- Web payload Cache keys are synthetic `https://image-bytes.invalid/...`, not
  the real fetch URL.
- `HttpBytesFetcher` timeout does not cover pool wait time (intentionally
  unbounded queue); timeout uses `AbortableRequest` after a slot is acquired.
- Chrome open test is the honesty check for Cache/OPFS; do not merge web blob
  changes on green VM tests alone.

## The docs

- [`docs/architecture.md`](docs/architecture.md): layers, data flow, public API, engine vs flutter adapters.
- [`docs/storage.md`](docs/storage.md): brain concurrency, retention, VM/web backends, index wipe.
- [`docs/resolve-ladder.md`](docs/resolve-ladder.md): key, resolver, fetcher, diagnostics, open/configure.
- [`docs/development.md`](docs/development.md): commands, seams, layout, store + ladder microbenches.
- [`CONTEXT.md`](CONTEXT.md): ubiquitous language glossary.
- [`CHANGELOG.md`](CHANGELOG.md): version history (`version:` in pubspec must match a `##` heading).
- [`benchmark/`](benchmark/): package-local store + ladder compare harness (`compare.dart`).
- Sibling paint package: [`../image_bytes_cache_flutter/`](../image_bytes_cache_flutter/)
  (`AGENTS.md`, `CONTEXT.md`).
