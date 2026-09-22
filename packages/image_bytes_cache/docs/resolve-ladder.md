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
case duplicates, then sorted before hashing (`canonicalHeaders`). Conditional
request headers (`If-None-Match`, `If-Modified-Since`, `If-Match`,
`If-Unmodified-Since`, `If-Range`) are **excluded** from that material so local
validators stay wire-only and do not fragment coalesce or durable keys;
`Authorization` and other representation headers still participate. Fingerprint
bytes are length-prefixed URL + canonical headers (not a `url|headers` string
join), so a `|` inside the URL or a header value cannot forge another
`(url, headers)` pair.

`HttpBytesClient` in-flight coalesce uses `ImageCacheKey.fromUrl(…).value`
after request-mutating middleware runs, so Bearer-injected `Authorization`
participates in the coalesce key (different tokens do not share a flight).
Unless `HttpBytesContext.identityOverride` is set (resolver `cacheKey`), in
which case the override wins for coalesce and durable identity together.
Without an override, durable identity still follows request headers /
`cacheKey`. Hosts that vary auth across users should put those headers on
`ImageBytesRequest` or mint distinct `cacheKey`s. Header casing / map order
still cannot split one logical download, and delimiter collisions cannot merge
two.

Distinct URLs that share a basename still produce distinct keys via the
fingerprint. Values are capped (~180 chars) so they stay safe as filesystem
names and web store keys.

Do not use basename-only disk keys. Do not treat header key casing as identity.
Do not join URL and headers with an ambiguous delimiter for coalesce or
fingerprinting. Do not fold conditional request headers into identity.

## Request and resolve

`ImageBytesRequest` carries `url`, optional `headers`, optional `cacheKey`,
optional `skipCache`, and optional `onBytesProgress`.

When `cacheKey` is null, the resolver builds one with `ImageCacheKey.fromUrl`
(canonical URL + headers). When set, that value is the full durable and HTTP
coalesce identity. Headers still go on the GET but are not folded into the key
(copied to `HttpBytesContext.identityOverride`). If you vary `Authorization`
across users, omit `cacheKey` or mint distinct overrides. Sharing one override
across tenants shares one slot. When override is set and request headers include
`Authorization`, audible diagnostics emit `cache_key_authorization` at debug
level (Bearer-injected tokens are not checked at resolve time).

`skipCache: true` sets `CacheContext.skipCache` on durable read/write. That only
takes effect on a `MiddlewareImageBytesCache` whose chain includes
`SkipCacheMiddleware` (or host middleware that reads the flag). Plain stores
ignore it. Skip forces a miss and write no-op; HTTP still runs.

`onBytesProgress` is an optional sink (`cumulative`, optional `total`) for
honest HTTP body progress. The ladder forwards it to `HttpBytesClient` on a
network miss only. A durable non-empty cache hit returns bytes without invoking
the sink. Do not invent mid-download percents from silence. Resolve remains a
single completed body (`Future<Uint8List>` or rich `ImageBytesResolveResult`);
there is no public streaming resolve API. The sink does not participate in
identity or coalesce.

`ImageBytesResolver` order:

1. Rich cache read (via `execute` with skip context when `skipCache` is set on a
   middleware store; otherwise `readRich` / public `read`). Empty bytes count as
   a miss.
2. Fresh hit returns bytes immediately with `ImageBytesOrigin.cache`. No
   network, no progress events. Freshness is `ImageHttpCacheFreshness`,
   separate from `ImageBytesRetention` eviction.
3. Stale hit with validators (`etag` / `lastModified`) issues a conditional GET.
   Seeds `HttpBytesContext.etag` / `lastModified` for
   `HttpBytesConditionalMiddleware`. Without that middleware on the client,
   validators never reach the wire and the GET stays unconditional.
4. Stale without validators, or miss: unconditional GET on
   `Uri.base.resolve(url)` via `HttpBytesClient.send` (`HttpBytesRequest`),
   with identity override from `cacheKey` and `onBytesProgress` when present.
   When the ladder already held non-empty stale bytes, audible diagnostics emit
   `resolve_unconditional` at debug. Cold misses stay quiet.
5. 304 returns cached bytes with `ImageBytesOrigin.cache` and soft-refreshes
   meta (`lastValidatedAt` plus any freshness headers on the 304). Bytes are
   not replaced. Audible diagnostics emit `resolve_revalidated` at debug.
6. 200 returns new bytes with `ImageBytesOrigin.network` and soft write-through
   of bytes plus response-derived HTTP meta.
7. 412 after a conditional GET: one unconditional GET, then same as 200 or fail
   (also emits `resolve_unconditional` when cached bytes were held).
8. `$Network` / `$Timeout` / `$Server` after a non-empty cache hit: return those
   bytes with `ImageBytesOrigin.cache` and emit `resolve_stale_used` when
   diagnostics are audible. Cancel, auth failures, 404-class `$Request`, and
   empty or missing cache still throw.
9. Other typed `HttpBytesException` failures propagate. Write-through failures
   report through `ImageBytesDiagnostics` and do not fail `resolve`. A throwing
   host `onEvent` is swallowed inside `report`.

Bytes-only `resolve` returns the body. Additive `resolveRich` returns the same
body plus binary `ImageBytesOrigin` (`cache` | `network`) for paint policy.
Ladder `resolve_*` diagnostics stay the detailed channel; origin does not mirror
every log op.
Default freshness when `Cache-Control` / `Expires` are absent: validators
revalidate on every use; no validators retain until retention would drop the
row. When those headers are present, honor `max-age` / `Expires` (with `Age` /
`Date` when known); `no-cache` / `must-revalidate` always revalidate;
`immutable` stays fresh until retention. No public ETag flags on `open` /
`configure`. There is no host `allowStale` switch either; stale-on-network-error
is the engine default.

Inject cache and client in tests. Production paint usually uses
`ImageBytesResolver.shared()`, which re-reads `ImageBytesCache.shared()` and
`HttpBytesClient.shared()` (or `debugShared` overrides) on every `resolve`. It
does not snapshot them at first call, so configure after an early paint still
enables durable caching, and configure replacement / `resetShared` cannot leave
the ladder bound to NoOp or a closed previous store.

Hosts that want conditional headers on the wire should include
`HttpBytesConditionalMiddleware` on the process client. Recommended order
(outermost first): Logger, Retry, Timeout, Bearer, Conditional.

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
| [CacheLoggerMiddleware$Developer] | Observes hit/miss/evict/prune via `developer.log` (`image_bytes_cache`); no durable IO; place outermost |
| [SkipCacheMiddleware] | When `CacheContext.skipCache` (or `shouldSkip`) is true: read returns miss, write is a no-op; evict/prune/close still forward |

Seed `CacheContext.skipCache` through `execute`.
`ImageBytesRequest.skipCache` does this via the resolver. Public `read` /
`write` on the wrapper use an empty context, so they only skip when
`shouldSkip` decides without the flag.

## HTTP: `HttpBytesClient`

GET bodies only. Callers own disk cache and decode.

| Knob | Default | Notes |
| --- | --- | --- |
| `maxConcurrent` | 6 | Further callers wait in `Pool` |
| `middlewares` | Timeout only (~15s connect + receive) | `null` → default [HttpBytesTimeoutMiddleware]; `[]` → no Timeout. Connect bounds headers; receive bounds idle body gaps. Opt-in: [HttpBytesRetryMiddleware], [HttpBytesBearerMiddleware], [HttpBytesConditionalMiddleware], [HttpBytesLoggerMiddleware$Developer] (outermost) |

Middleware list order is outermost first (first entry wraps the rest). Coalesce
runs inside the middleware chain (after request-mutating middleware, before
`Client.send`). Identity is `ImageCacheKey` from the post-middleware URL +
headers (Bearer-injected `Authorization` participates; conditional request
headers do not), unless `HttpBytesContext.identityOverride` is set. Then that
key wins. Concurrent calls that share that identity share one in-flight GET;
each caller still gets its own `Future` (so per-caller cancel can fail one
joiner without aborting the flight). Joiners do not hold a pool slot. The
starter returns a streaming response so Timeout can wrap receive-idle on the
body; `_sendUnstreamed` buffers afterward and fans the buffer out to joiners.

`send` / `getBytes` seed caller context and run the pipeline (user middlewares
wrap coalesce + `Client.send`). `getBytes` accepts an optional `context` map
(same slots as `send`). `_createClientSend` is Client.send-only: status,
progress `ByteStream.map`. Failures surface only as the sealed
`HttpBytesException` variants (`$Network`, `$Request`, `$Server`,
`$Authentication`, `$Timeout`, `$Cancelled`, `$Internal`), each with `code` /
`statusCode` / `message` / optional `error` / `data`. Default success is 2xx
or 304 Not Modified (headers present; body optional and ignored; illegal
non-empty 304 bodies are discarded). Empty-body-as-`$Internal` still applies
when a successful body was expected (non-304). Other non-success statuses map
by code: 401/403 → `$Authentication`, 5xx → `$Server`, else `$Request`.
`getBytes` remains a convenience over `send(HttpBytesRequest)` (body via
`toBytes` / cached `body`).

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
and never retries `$Timeout` / `$Cancelled` / `$Authentication`. 304 Not Modified
is a client success (no exception), so Retry does not retry it. Place it
**outside** Timeout. `HttpBytesBearerMiddleware` only sets
`Authorization: Bearer …` from `getToken` — no logout / refresh.
`HttpBytesConditionalMiddleware` (opt-in) reads `HttpBytesContext.etag` /
`lastModified` and sets `If-None-Match` / `If-Modified-Since` when non-empty;
missing validators leave the GET unconditional. Place it **after** Bearer and
**before** coalesce (innermost request-mutating layer). Conditionals stay
wire-only (identity exclusion above). Recommended host / revalidation stack
(outermost first): Logger → Retry → Timeout → Bearer → Conditional.
`HttpBytesLoggerMiddleware$Developer` (opt-in) logs method/URL/outcome/
downloaded size/latency via `developer.log` (`http_bytes`); place outermost to
include retry time.

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
| `cache_key_authorization` | `cacheKey` set with an `Authorization` request header (debug) |
| `resolve_stale_used` | Resolve completed with cached bytes after `$Network` / `$Timeout` / `$Server` (warning) |
| `resolve_revalidated` | 304 path reused cached bytes and soft-refreshed meta (debug) |
| `resolve_unconditional` | Held non-empty stale bytes and still issued an unconditional GET (debug; cold misses stay quiet) |

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
