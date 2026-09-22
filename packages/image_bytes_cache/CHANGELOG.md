## Unreleased

- **ADDED**: Before, hosts only got bytes from `resolve`. Now
  `IImageBytesResolver.resolveRich` returns `ImageBytesResolveResult` (same
  body + binary `ImageBytesOrigin`: `cache` | `network`). Bytes-only `resolve`
  still returns the same body; custom implementors must add `resolveRich`.
  Fresh store hit, 304 reuse, and stale-served body are `cache`. A downloaded
  body, including a full GET after stale, is `network`.

## 0.3.1

- **CHANGED**: `HttpBytesLoggerMiddleware$Developer` success lines include
  downloaded size (`384 B`, `12.4 KB`, …) between status and latency. Streaming
  responses count bytes as the body is read; buffered joiners use `body`
  length. Mid-stream errors log size received so far when `logError` is on.

## 0.3.0

- **ADDED**: Soft resolve-path diagnostics when audible: `resolve_revalidated`
  (debug) on 304 reuse + meta refresh; `resolve_unconditional` (debug) when the
  ladder held non-empty stale bytes and still issued a full GET (stale without
  validators, or 412 fallback). Cold misses stay quiet.
  `ImageBytesLogOp.resolveRevalidated` / `resolveUnconditional`.
- **CHANGED**: `ImageBytesResolver` returns non-empty cached bytes when the
  HTTP attempt fails with `$Network`, `$Timeout`, or `$Server`. If Retry is on
  the client, it has already finished before `$Server` reaches the ladder.
  Cancel, 401/403, and client errors such as 404 still fail resolve. Empty or
  missing cache still fails. Audible diagnostics emit `resolve_stale_used` at
  warning.
- **ADDED**: `ImageBytesLogOp.resolveStaleUsed`.
- **CHANGED**: `ImageBytesResolver` implements HTTP freshness revalidation.
  Fresh hits skip the network. Stale hits with ETag / Last-Modified issue a
  conditional GET when `HttpBytesConditionalMiddleware` is on the client; 304
  reuses cached bytes and refreshes meta; 200 write-through stores bytes plus
  response meta. Stale without validators and misses stay unconditional. 412
  after a conditional falls back to one unconditional GET. Default: validators
  without Cache-Control revalidate on use; no validators retain until
  `ImageBytesRetention`; honor `max-age` / `Expires` / `no-cache` /
  `must-revalidate` / `immutable`. Resolve stays `Future<Uint8List>` with no
  new open/configure ETag flags. Hosts that want conditional headers must
  include Conditional middleware (recommended outermost first: Logger, Retry,
  Timeout, Bearer, Conditional).
- **ADDED**: `ImageHttpCacheFreshness`: freshness policy and response-header
  meta helpers used by the ladder (`isFresh`, `fromResponseHeaders`,
  `afterNotModified`).
- **ADDED**: Opt-in `HttpBytesConditionalMiddleware`. Seed
  `HttpBytesContext.etag` and/or `lastModified` to send `If-None-Match` /
  `If-Modified-Since`. Empty context keeps an unconditional GET. Place after
  Bearer and before coalesce. Recommended order (outermost first): Logger,
  Retry, Timeout, Bearer, Conditional. Default client stack stays Timeout-only.
- **CHANGED**: `ImageBytesRequest.cacheKey` sets durable cache identity and
  HTTP coalesce identity (`HttpBytesContext.identityOverride`). Headers still
  go on the wire. If the request also carries `Authorization`, audible
  diagnostics emit `cache_key_authorization` at debug level.
- **ADDED**: `ImageBytesLogLevel.debug` and
  `ImageBytesLogOp.cacheKeyAuthorization`.
- **ADDED**: `ImageBytesRequest.skipCache`. When true, resolve seeds
  `CacheContext.skipCache` so `SkipCacheMiddleware` returns a miss and skips
  the write. Needs `MiddlewareImageBytesCache` with that middleware (or a host
  equivalent). Plain stores ignore the flag. HTTP still runs.
- **CHANGED**: `ImageBytesResolver` calls `HttpBytesClient.send` with
  `HttpBytesRequest`. Typed `HttpBytesException` failures come from that path.
  `getBytes` accepts an optional `context` map (same slots as `send`).

## 0.2.0

- **BREAKING**: Renamed `HttpBytesFetcher` to `HttpBytesClient` (file
  `src/http/http_bytes_client.dart`). `ImageBytesResolver` takes `client:`
  instead of `fetcher:`. Update imports, type names, and named args.
- **ADDED**: HTTP middleware on `HttpBytesClient` (`src/http/`). List order is
  outermost first. `null` middlewares installs Timeout only; `[]` installs none.
  Opt-in: `HttpBytesRetryMiddleware` (full-jitter backoff, honors `Retry-After`),
  `HttpBytesBearerMiddleware` (sets `Authorization` from `getToken`, no logout
  or refresh), `HttpBytesLoggerMiddleware$Developer` (`developer.log`, no
  bodies or headers). Barrel also exports `CancelToken` / `CancelledException`.
- **ADDED**: Sealed `HttpBytesException` variants: `$Network`, `$Request`,
  `$Server`, `$Authentication`, `$Timeout`, `$Cancelled`, `$Internal`. Non-2xx
  maps by status (401/403 → auth, 5xx → server, else request). No HTTP response
  is `$Network`. Catch these instead of `ClientException`, `SocketException`,
  or raw `TimeoutException`.
- **ADDED**: Coalesce-aware cancel. Same-identity callers share one GET.
  Canceling one leaves the others running; canceling the last aborts the
  socket. Timeout still throws `$Timeout`, not `$Cancelled`.
- **ADDED**: `HttpBytesContext` for per-send overrides (`connectTimeout`,
  `receiveTimeout`, `noRetry`, `retries`, and so on).
- **CHANGED**: Connect and receive idle timeouts are middleware, not client
  fields. Waiting for a pool slot is still unbounded. In-flight coalesce uses
  the post-middleware `ImageCacheKey`, so Bearer-injected `Authorization` keeps
  different tokens from sharing a flight. Durable resolve keys still follow
  request headers / `cacheKey`.

## 0.1.0

- **ADDED**: Optional honest bytes-progress reporting on the resolve ladder.
  `ImageBytesRequest.onBytesProgress` / `HttpBytesFetcher.getBytes(onBytesProgress:)`
  report cumulative bytes (and total when Content-Length is known) while the
  HTTP body is read on a network miss. Durable cache hits do not synthesize
  mid-download progress. Resolve stays a single `Future<Uint8List>`. No public
  streaming resolve API; coalesce and `ImageCacheKey` identity are unchanged.
- **ADDED**: `HttpBytesFetcher.configure` / `resetShared` for process-wide HTTP
  client bootstrap (mirrors `ImageBytesCache.configure`). Hosts inject a custom
  `http.Client` once; `ImageBytesResolver.shared` re-reads it on each resolve.
  `ImageBytesCache.resetShared` also clears fetcher shared wiring via hooks.

## 0.0.2

- **FIXED**: Web large-body hot reads skip a guaranteed Cache API miss when
  index `byteLength` is already at or above the OPFS threshold (64 KiB). The
  brain forwards that length into the blob store; twin-clear-before-write and
  the size cut are unchanged.
- **FIXED**: Failed durable index commit rolls the RAM meta mirror back to the
  pre-epoch snapshot and rethrows. In-process reads cannot treat an optimistic
  put as a durable hit. Blob orphans from the failed epoch heal via reclaim or
  index-without-blob cleanup. Write-through still reports via diagnostics
  without failing a successful network resolve.
- **FIXED**: VM blob isolate death fails in-flight RPCs with `StateError`
  instead of hanging, drops the dead worker so later ops can respawn, and
  keeps the exclusive mutate gate from stalling on a dead worker.
- **FIXED**: Ladder soft-failure hygiene: empty durable writes are not retained
  (treated as eviction); sticky empty rows scrub on read; non-positive
  `maxEntries` / `maxBytes` assert; throwing diagnostics `onEvent` is swallowed
  so write-through catch cannot become an unhandled async error; HTTP timeout
  uses `AbortableRequest` (releases sockets when the client honors abort) while
  pool-wait before a slot remains intentionally unbounded.
- **FIXED**: Ladder identity: coalesce uses `ImageCacheKey` (no ambiguous
  `url|headers` join); `fromUrl` fingerprints `Uri.base.resolve` canonical URLs
  with length-prefixed material; explicit `cacheKey` documented as full identity
  (headers on the wire do not silently change the key).
- **FIXED**: `ImageBytesResolver.shared()` re-reads the process-wide cache and
  fetcher on every `resolve` instead of snapshotting them at first call.
  Configure after an early paint enables durable caching; configure replacement
  and `resetShared` no longer leave the ladder bound to NoOp or a closed store.
  `ImageBytesCache.resetShared` also clears resolver shared wiring.
- **FIXED**: Failed durable open (degrade to memory or `throwOnOpenFailure`)
  closes any partially opened VM isolate worker or web Cache/OPFS handles so
  bootstrap cannot leak those resources. Missing VM `directory` still throws
  `ArgumentError` without degrading.

## 0.0.1

- **ADDED**: Initial standalone release: durable remote image bytes with RAM
  meta mirror, platform blob stores (VM files / web Cache+OPFS), resolve
  ladder, store microbenches, and docs.
