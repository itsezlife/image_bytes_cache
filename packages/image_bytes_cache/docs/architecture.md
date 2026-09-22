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
4. **Resolve ladder** (`ImageBytesResolver`, `HttpBytesClient`). Rich cache
   read, freshness check, conditional or unconditional GET, soft write-through.
   Soft failures and soft paths go through `ImageBytesDiagnostics`.
5. **Middleware** (HTTP + cache). Same fold grammar (list outermost first).
   HTTP: Timeout by default; opt-in Retry, Bearer, Conditional, Logger. Cache:
   `MiddlewareImageBytesCache` over sealed ops; opt-in Skip-cache and Logger.
   Reclaim is never a cache op.
6. **Host wiring** (`ImageBytesCache.open` / `configure` / `shared`).
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
// Optional: await HttpBytesClient.configure(HttpBytesClient(
//   client: hostClient,
//   middlewares: <HttpBytesMiddleware>[
//     const HttpBytesTimeoutMiddleware(),
//     const HttpBytesConditionalMiddleware(),
//   ],
// ));
```

On web, `directory` is ignored. Hard storage failure returns
`MemoryImageBytesCache` and reports `open_degraded` unless
`throwOnOpenFailure: true`; platform open closes any partial VM worker or web
handles before that surface. Missing VM `directory` still throws
(`ArgumentError`).

**Paint path:**

`ImageBytesRequest` → `ImageBytesResolver.resolve` /
`ImageBytesResolver.resolveRich` →

1. Rich cache read (skip context when `skipCache` is set on a middleware
   store). Empty payload counts as miss.
2. Fresh hit returns bytes with no network (`ImageBytesOrigin.cache`). Stale
   with validators → conditional GET when Conditional middleware is on the
   client; 304 reuses bytes (`cache`). Stale without validators or miss →
   unconditional GET; a downloaded 200 body is `network`.
3. Soft write-through of bytes+meta (200) or meta-only refresh (304). Write
   failure reports diagnostics and does not fail resolve (throwing host
   `onEvent` is swallowed). Transient `$Network` / `$Timeout` / `$Server` may
   return held non-empty cached bytes (`resolve_stale_used`, origin `cache`).
   Bytes-only `resolve` returns the body; `resolveRich` adds
   `ImageBytesOrigin` for paint. Ladder `resolve_*` diagnostics stay separate.

`ImageBytesResolver.shared()` re-reads `ImageBytesCache.shared()` /
`HttpBytesClient.shared()` on each resolve (not a one-shot snapshot).

**Durable hit (after open):**

`IndexedImageBytesCache.read` probes the RAM index mirror and blob store under
the shared (concurrent) gate. Soft LRU notes access in memory only. Durable
meta is quiet on this path. See [storage](storage.md).

HTTP freshness meta (`ImageHttpCacheMeta` under index `h`) is separate from
`ImageBytesRetention` eviction. See [resolve-ladder](resolve-ladder.md) and
[CONTEXT.md](../CONTEXT.md).

## Public API surface

Everything public is re-exported from `lib/image_bytes_cache.dart`:

| Export | Role |
| --- | --- |
| `image_bytes_cache.dart` | Keys, retention, records, index/blob ports, `IImageBytesCache`, `IndexedImageBytesCache`, Memory/NoOp, `ImageBytesCache` facade |
| `cache/cache_middleware.dart` | Cache middleware grammar: sealed ops/results (no reclaim), fold wrapper, rich read hit / HTTP cache meta |
| `cache/middlewares/` | Opt-in Skip-cache + Cache Logger$Developer |
| `image_bytes_resolver.dart` | `ImageBytesRequest`, `ImageBytesOrigin`, `ImageBytesResolveResult`, `IImageBytesResolver`, `ImageBytesResolver` |
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
