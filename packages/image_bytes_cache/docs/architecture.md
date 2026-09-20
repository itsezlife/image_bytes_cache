# Architecture

`image_bytes_cache` is a durable store for **remote image bytes**. It is the
pure-Dart core package in this repository. Sibling `image_bytes_cache_flutter`
paints above it. This package owns identity, retention, platform persistence,
and the resolve ladder. It does not own decode, Flutter `ImageCache`, or UI
widgets.

```
image_bytes_cache_flutter widget
        │
        ▼
ImageBytesResolver ──► IImageBytesCache
        │                      │
        └─ HttpBytesClient     └─ IndexedImageBytesCache
                                      ├── IImageBytesIndex (RAM mirror)
                                      └── IImageBytesBlobStore (platform)
```

Glossary terms live in [`CONTEXT.md`](../CONTEXT.md). Storage mechanics:
[storage](storage.md). Ladder and host wiring: [resolve-ladder](resolve-ladder.md).

## Layers

1. **Identity** (`ImageCacheKey`). Filename-safe key from the
   `Uri.base.resolve` canonical URL + canonical headers. Shared with HTTP
   coalesce (`ImageCacheKey.value`) so casing, map order, and delimiter
   collisions cannot split or merge logical fetches.
2. **Cache contract** (`IImageBytesCache`). What paint code and the resolver
   call: `read` / `write` / `evict` / `prune` / `close`. Implementations:
   `IndexedImageBytesCache` (composition brain), `MemoryImageBytesCache`,
   `NoOpImageBytesCache`.
3. **Index / blob ports** (`IImageBytesIndex`, `IImageBytesBlobStore`).
   Metadata vs payload. Platform adapters implement these; the brain does not
   know about files, Cache API, or OPFS.
4. **Resolve ladder** (`ImageBytesResolver`, `HttpBytesClient`). Cache then
   network then fire-and-forget write-through. Soft failures go through
   `ImageBytesDiagnostics`.
5. **Host wiring** (`ImageBytesCache.open` / `configure` / `shared`).
   Process-wide store and diagnostics policy. Conditional-import open hooks
   live under `lib/src/environment_specific/`.

Dependency direction is one-way: widgets and hosts depend on the public barrel;
platform adapters are reached only through `open`.

## Data flow

**Bootstrap (host):**

```dart
await ImageBytesCache.configure(
  await ImageBytesCache.open(
    directory: cacheRoot.resolveFilePath('remote_image_bytes'), // VM only
    diagnostics: hostDiagnosticsPolicy,
  ),
);
// Optional: await HttpBytesClient.configure(HttpBytesClient(client: hostClient));
```

On web, `directory` is ignored. Hard storage failure returns
`MemoryImageBytesCache` and reports `open_degraded` unless
`throwOnOpenFailure: true`; platform open closes any partial VM worker or web
handles before that surface. Missing VM `directory` still throws
(`ArgumentError`).

**Paint path:**

`ImageBytesRequest` → `ImageBytesResolver.resolve` →

1. `cache.read(key)`. Hit returns bytes; empty payload counts as miss (and
   durable stores scrub sticky empty rows / refuse empty writes).
2. On miss, `HttpBytesClient.getBytes` (pool + in-flight coalesce; timeout
   after slot via `AbortableRequest`).
3. Return network bytes immediately; `cache.write` runs unawaited. Write
   failure reports diagnostics and does not fail the resolve future (throwing
   host `onEvent` is swallowed).

`ImageBytesResolver.shared()` re-reads `ImageBytesCache.shared()` /
`HttpBytesClient.shared()` on each resolve (not a one-shot snapshot).

**Durable hit (after open):**

`IndexedImageBytesCache.read` probes the RAM index mirror and blob store under
the shared (concurrent) gate. Soft LRU notes access in memory only. Durable
meta is quiet on this path. See [storage](storage.md).

## Public API surface

Everything public is re-exported from `lib/image_bytes_cache.dart`:

| Export | Role |
| --- | --- |
| `image_bytes_cache.dart` | Keys, retention, records, index/blob ports, `IImageBytesCache`, `IndexedImageBytesCache`, Memory/NoOp, `ImageBytesCache` facade |
| `cache/cache_middleware.dart` | Cache middleware grammar: sealed ops/results (no reclaim), fold wrapper, rich read hit / HTTP cache meta |
| `cache/middlewares/` | Opt-in Skip-cache + Cache Logger$Developer |
| `image_bytes_resolver.dart` | `ImageBytesRequest`, `IImageBytesResolver`, `ImageBytesResolver` |
| `http/http_bytes_client.dart` (+ `http/middlewares/`) | Network GET: middleware chain, typed `$` errors, pool, coalesce |
| `image_bytes_diagnostics.dart` | Soft-failure policy and events |

Deliberately **not** barrel-public (import via `src/` only when writing adapters
or tests): environment-specific stores, `ImageBytesIndexDocumentCodec`,
`ImageBytesWebKeys`. Treat additions to the barrel as permanent commitments.

## Engine vs flutter paint adapters

| Layer | Owns |
| --- | --- |
| `image_bytes_cache` (this package) | Durable bytes engine, ladder, open/configure, diagnostics; store / ladder microbenches |
| `image_bytes_cache_flutter` (sibling) | Flutter widgets that decode and paint from `IImageBytesResolver` bytes; PageStorage keys aligned with `ImageCacheKey`; UI/profile benches and `benchmark_compare/` under that package |

New storage code lands here. New paint widgets land in the flutter package, not
in a host UI util tree and not in this core.

## Where to make a change

| Change | Primary place | Doc |
| --- | --- | --- |
| Concurrent read / exclusive mutate / soft LRU / single commit | `IndexedImageBytesCache` | [storage](storage.md) |
| Retention limits | `ImageBytesRetention` | [storage](storage.md) |
| VM files / isolate worker | `environment_specific/*_vm.dart` | [storage](storage.md) |
| Web Cache API / OPFS routing | `environment_specific/*_js.dart` | [storage](storage.md) |
| Index wire format | `image_bytes_index_document.dart` | [storage](storage.md) |
| Resolve / write-through / empty miss | `ImageBytesResolver` | [resolve-ladder](resolve-ladder.md) |
| Pool / coalesce / Timeout middleware / typed HTTP errors | `HttpBytesClient` + `http/` | [resolve-ladder](resolve-ladder.md) |
| Cache middleware fold / rich hit unwrap / no reclaim op | `cache/cache_middleware.dart` | [resolve-ladder](resolve-ladder.md) |
| Skip-cache / Cache Logger middleware | `cache/middlewares/` | [resolve-ladder](resolve-ladder.md) |
| Open degrade / configure close | `ImageBytesCache` | [resolve-ladder](resolve-ladder.md) |
| Commands, tests, seams | (tests / tooling) | [development](development.md) |
