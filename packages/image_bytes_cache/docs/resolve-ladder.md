# Resolve ladder

How hosts turn a URL into bytes without opening files, Cache API, or sockets
from paint code.

## Identity: `ImageCacheKey`

Filename-safe string: host + safe basename + short fingerprint of the
**canonical URL** and headers.

`ImageCacheKey.fromUrl` resolves the input with `Uri.base.resolve` before
host/basename extraction and hashing, so a relative path and its absolute form
against the same base share one key — the same URI form
`ImageBytesResolver` uses for GET. Header keys are lowercased, last-wins on
case duplicates, then sorted before hashing (`canonicalHeaders`). Fingerprint
bytes are length-prefixed URL + canonical headers (not a `url|headers` string
join), so a `|` inside the URL or a header value cannot forge another
`(url, headers)` pair.

`HttpBytesClient` in-flight coalesce uses `ImageCacheKey.fromUrl(…).value`
**after** request-mutating middleware runs, so Bearer-injected `Authorization`
participates in the coalesce key (different tokens do not share a flight).
Durable resolve identity remains the request’s `ImageCacheKey` / `cacheKey`
(caller headers); hosts that vary auth across users should put those headers on
`ImageBytesRequest` or mint distinct `cacheKey`s. Header casing / map order
still cannot split one logical download, and delimiter collisions cannot merge
two.

Distinct URLs that share a basename still produce distinct keys via the
fingerprint. Values are capped (~180 chars) so they stay safe as filesystem
names and web store keys.

Do not use basename-only disk keys. Do not treat header key casing as identity.
Do not join URL and headers with an ambiguous delimiter for coalesce or
fingerprinting.

## Request and resolve

`ImageBytesRequest` carries `url`, optional `headers`, optional `cacheKey`,
and optional `onBytesProgress`. When `cacheKey` is null, the resolver builds
one with `ImageCacheKey.fromUrl` (canonical URL + headers). When `cacheKey` is
set, that value is the **full** durable identity: headers still go on the
network GET but are not folded into the key. Hosts that vary `Authorization`
across logical resources must omit `cacheKey` or mint distinct overrides — the
ladder will not silently share one override across different Authorization
values.

`onBytesProgress` is an optional sink (`cumulative`, optional `total`) for
honest HTTP body progress. The ladder forwards it to `HttpBytesClient` on a
**network miss** only. A durable non-empty cache hit returns bytes without
invoking the sink — do not invent mid-download percents from silence. Resolve
remains a single `Future<Uint8List>` of the full body; there is no public
streaming resolve API. The sink does not participate in `ImageCacheKey`
identity or in-flight coalesce.

`ImageBytesResolver` order:

1. `cache.read(key)`. Non-empty hit returns immediately (no progress events).
2. Empty cached payload counts as a **miss** (bad empty write must not poison
   the ladder). Durable stores also refuse to retain empty writes (evict the
   key instead) and scrub sticky empty rows on read so they cannot waste
   `maxEntries` capacity.
3. `HttpBytesClient.getBytes` on `Uri.base.resolve(url)` on miss, forwarding
   `onBytesProgress` when present.
4. Return network bytes; schedule `cache.write` with `unawaited`. Write failure
   reports through `ImageBytesDiagnostics` and does **not** fail `resolve`.
   A throwing host `onEvent` callback is swallowed inside `report` so the
   unawaited catch path cannot become a second unhandled async error.

Inject cache and client in tests. Production paint usually uses
`ImageBytesResolver.shared()`, which **re-reads** `ImageBytesCache.shared()`
and `HttpBytesClient.shared()` (or `debugShared` overrides) on every
`resolve`. It does not snapshot them at first call, so configure after an
early paint still enables durable caching, and configure replacement /
`resetShared` cannot leave the ladder bound to NoOp or a closed previous
store.

## Cache middleware

`MiddlewareImageBytesCache` implements `IImageBytesCache` and runs every call
through a `CacheMiddleware` chain into an inner store. Sealed `CacheOperation` /
`CacheOperationResult` cover read, write, evict, prune, and close. There is no
reclaim op. Orphan reclaim stays on `IndexedImageBytesCache` under its exclusive
gate.

A chain read yields `CacheReadHit`: bytes, optional retention timestamps, and
optional `ImageHttpCacheMeta`. Public `read` unwraps to `Uint8List?`. Call
`execute` for the full hit or a shared `CacheContext`. Stores that implement
`IImageBytesRichCache` fill timestamps and HTTP meta on the terminal read;
`write` accepts optional `httpCacheMeta` the same way.

Opt-in product middlewares (list outermost first):

| Middleware | Role |
| --- | --- |
| [ImageBytesCacheLoggerMiddleware$Developer] | Observes hit/miss/evict/prune via `developer.log` (`image_bytes_cache`); no durable IO; place outermost |
| [ImageBytesSkipCacheMiddleware] | When `CacheContext.skipCache` (or `shouldSkip`) is true: read returns miss, write is a no-op; evict/prune/close still forward |

Seed `CacheContext.skipCache` through `execute` (resolver plumbing will set it
end-to-end). Public `read` / `write` on the wrapper use an empty context, so
they only skip when `shouldSkip` decides without the flag.

## HTTP: `HttpBytesClient`

GET bodies only. Callers own disk cache and decode.

| Knob | Default | Notes |
| --- | --- | --- |
| `maxConcurrent` | 6 | Further callers wait in `Pool` |
| `middlewares` | Timeout only (~15s connect + receive) | `null` → default [HttpBytesTimeoutMiddleware]; `[]` → no Timeout. Connect bounds headers; receive bounds idle body gaps. Opt-in: [HttpBytesRetryMiddleware], [HttpBytesBearerMiddleware], [HttpBytesLoggerMiddleware$Developer] (outermost) |

Middleware list order is outermost first (first entry wraps the rest). Coalesce
runs **inside** the middleware chain (after request-mutating middleware, before
`Client.send`), so identity is `ImageCacheKey` from the **post-middleware** URL +
headers (Bearer-injected `Authorization` participates). Concurrent calls that
share that identity share one in-flight GET; each caller still gets its own
`Future` (so per-caller cancel can fail one joiner without aborting the flight).
Joiners do not hold a pool slot. The starter returns a streaming response so
Timeout can wrap receive-idle on the body; `_sendUnstreamed` buffers afterward
and fans the buffer out to joiners.

`send` / `getBytes` seed caller context and run the pipeline (user middlewares
wrap coalesce + `Client.send`). `_createClientSend` is Client.send-only: status,
progress `ByteStream.map`. Failures surface only as the sealed
`HttpBytesException` variants (`$Network`, `$Request`, `$Server`,
`$Authentication`, `$Timeout`, `$Cancelled`, `$Internal`), each with `code` /
`statusCode` / `message` / optional `error` / `data`. Non-2xx maps by status:
401/403 → `$Authentication`, 5xx → `$Server`, else `$Request`. `getBytes`
remains a convenience over `send(HttpBytesRequest)` (body via `toBytes` /
cached `body`).

Each `send` creates a **flight** [CancelToken] on `HttpBytesContext.cancelToken`
and uses it as the Abortable GET `abortTrigger`. Callers may pass their own
token: canceling one coalesced subscriber fails only that caller with
`$Cancelled` and leaves the shared GET running; canceling the **last**
subscriber cancels the flight token (socket abort). `HttpBytesTimeoutMiddleware`
cancels that same flight token and still surfaces `$Timeout` (not `$Cancelled`).
Connect bounds headers; receive bounds idle body gaps. Defaults are 15s each
(override via `HttpBytesContext.connectTimeout` / `receiveTimeout`).

Middleware chains merge with `HttpBytesMiddlewareWrapper.merge` (outermost
first). Ad-hoc hooks use `HttpBytesMiddlewareWrapper(onRequest: …)`.

`HttpBytesRetryMiddleware` (opt-in) retries idempotent GETs on transient failures
(`$Network` / 408 / 425 / 429 / selected 5xx), honors delta-seconds `Retry-After`,
and never retries `$Timeout` / `$Cancelled` / `$Authentication`. Place it
**outside** Timeout. `HttpBytesBearerMiddleware` only sets
`Authorization: Bearer …` from `getToken` — no logout / refresh.
`HttpBytesLoggerMiddleware$Developer` (opt-in) logs method/URL/outcome/latency
via `developer.log` (`http_bytes`); place outermost to include retry time.

When `onBytesProgress` is supplied on the caller that **starts** the in-flight
GET, the client reports cumulative bytes as the response body is read (`total`
from Content-Length when present). Without a sink, the body is consolidated
without inventing chunk events. Coalesced joiners each get their own Future to
the same buffered response; the progress sink does not change coalesce identity.

After `close`, new `send` / `getBytes` calls throw `HttpBytesException$Internal`;
in-flight work may still finish or fail. If the client created its own
`http.Client`, `close` closes that client. Pool wait before a slot is not timed
— raise `maxConcurrent` or reduce host concurrency if queue latency dominates.

## Diagnostics

`ImageBytesDiagnostics` does not change resolve or wipe behavior. It only
controls whether soft failures are audible. Default is `silent`. Process-wide
`ImageBytesDiagnostics.current` is set by `ImageBytesCache.open` /
`configure`.

| Policy | Effect |
| --- | --- |
| `silent` | No emission |
| `developer` | `developer.log` name `image_bytes` |
| `onEvent` | Host callback (logger, Crashlytics, …). Must not throw; throws are swallowed inside `report` so soft-failure paths cannot escalate to unhandled async errors |

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
| Hard open failure | Degrades to `MemoryImageBytesCache` + `open_degraded` unless `throwOnOpenFailure`; platform open closes any partial VM worker / web handles before that surface |
| Missing VM directory | Still throws `ArgumentError` (host wiring bug); no degrade and no worker spawn |

`configure(cache)` closes any previous non-identical shared instance **before**
assign so workers and Cache handles do not leak across reconfigure.
`shared()` returns `NoOpImageBytesCache` until configure (or `debugShared`).
`resetShared` (tests) closes, clears configure and debug overrides, resets
diagnostics to silent, and clears `ImageBytesResolver` / `HttpBytesClient`
shared wiring via registered hooks.

`HttpBytesClient.configure(client)` mirrors the same close-then-assign rule
for the process-wide HTTP client (pool + owned client). Hosts that want
Cronet / Cupertino / a shared `IOClient` bootstrap once here; paint widgets
that default to `ImageBytesResolver.shared()` pick it up without threading a
client. `HttpBytesClient.shared()` returns `debugShared`, else the
configured instance, else a lazily constructed default.

Bootstrap order: open (with diagnostics) → configure cache → optionally
configure client → paint via `ImageBytesResolver.shared()` (typically from
`image_bytes_cache_flutter` widgets or an injected resolver). Calling shared
resolve **before** configure is safe: later configure is visible on the next
resolve. Resolver and client shared factories stay thin; do not invent a
fourth process-wide global for the same ladder.
