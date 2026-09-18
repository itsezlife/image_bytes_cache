# Resolve ladder

How hosts turn a URL into bytes without opening files, Cache API, or sockets
from paint code.

## Identity: `ImageCacheKey`

Filename-safe string: host + safe basename + short fingerprint of URL and
headers.

`ImageCacheKey.fromUrl` lowercases header keys, last-wins on case duplicates,
then sorts keys before hashing (`canonicalHeaders`). That matches
`HttpBytesFetcher` coalesce, so header casing and map iteration order cannot
split one logical download into two cache identities or two in-flight GETs.

Distinct URLs that share a basename still produce distinct keys via the
fingerprint. Values are capped (~180 chars) so they stay safe as filesystem
names and web store keys.

Do not use basename-only disk keys. Do not treat header key casing as identity.

## Request and resolve

`ImageBytesRequest` carries `url`, optional `headers`, and optional
`cacheKey`. When `cacheKey` is null, the resolver builds one with
`ImageCacheKey.fromUrl`.

`ImageBytesResolver` order:

1. `cache.read(key)`. Non-empty hit returns immediately.
2. Empty cached payload counts as a **miss** (bad empty write must not poison
   the ladder).
3. `HttpBytesFetcher.getBytes` on miss.
4. Return network bytes; schedule `cache.write` with `unawaited`. Write failure
   reports through `ImageBytesDiagnostics` and does **not** fail `resolve`.

Inject cache and fetcher in tests. Production paint usually uses
`ImageBytesResolver.shared()`, which reads `ImageBytesCache.shared()` and
`HttpBytesFetcher.shared()` (or `debugShared` overrides).

## HTTP: `HttpBytesFetcher`

GET bodies only. Callers own disk cache and decode.

| Knob | Default | Notes |
| --- | --- | --- |
| `maxConcurrent` | 6 | Further callers wait in `Pool` |
| `timeout` | 15s | Starts after a pool slot is acquired; wait for a slot is not timed |

Concurrent calls with the same URI and canonical headers share one in-flight
`Future`. Non-2xx → `ClientException`. Empty body → `StateError`. After
`close`, new `getBytes` calls throw; in-flight work may still finish or fail.
If the fetcher created its own `http.Client`, `close` closes that client.

## Diagnostics

`ImageBytesDiagnostics` does not change resolve or wipe behavior. It only
controls whether soft failures are audible. Default is `silent`. Process-wide
`ImageBytesDiagnostics.current` is set by `ImageBytesCache.open` /
`configure`.

| Policy | Effect |
| --- | --- |
| `silent` | No emission |
| `developer` | `developer.log` name `image_bytes` |
| `onEvent` | Host callback (logger, Crashlytics, …) |

Ops on `ImageBytesLogEvent`:

| Op | When |
| --- | --- |
| `write_through` | Durable write failed after a successful network fetch |
| `index_wipe` | Corrupt / unrecognized index recovered by wipe |
| `open_degraded` | Hard open failed; host received Memory store instead of throw |

The package does not depend on a product logger. Hosts bridge
`onEvent` at bootstrap if they want ambient logging.

## Open, configure, shared

`ImageBytesCache.open` selects the environment-specific durable composition
(`dart.library.js_interop` web vs VM stub).

| Concern | Contract |
| --- | --- |
| VM `directory` | Required; prefer app cache root, not documents |
| Web `directory` | Ignored |
| `diagnostics` | Installed on `current` before open so wipe can report |
| Hard open failure | Degrades to `MemoryImageBytesCache` + `open_degraded` unless `throwOnOpenFailure` |
| Missing VM directory | Still throws `ArgumentError` (host wiring bug) |

`configure(cache)` closes any previous non-identical shared instance **before**
assign so workers and Cache handles do not leak across reconfigure.
`shared()` returns `NoOpImageBytesCache` until configure (or `debugShared`).
`resetShared` (tests) closes, clears configure and debug overrides, and resets
diagnostics to silent.

Bootstrap order: open (with diagnostics) → configure → paint via
`ImageBytesResolver.shared()` (typically from `image_bytes_cache_flutter`
widgets or an injected resolver). Resolver and fetcher shared factories stay
thin; do not invent a fourth process-wide global for the same ladder.
