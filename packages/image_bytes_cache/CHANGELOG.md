## Unreleased

## 0.2.0

- **ADDED**: HTTP middleware on `HttpBytesFetcher` (`src/http/`). List order is
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
- **CHANGED**: Fetcher file moved to `src/http/http_bytes_fetcher.dart`.
  Connect and receive idle timeouts are middleware, not fetcher fields. Waiting
  for a pool slot is still unbounded. In-flight coalesce uses the
  post-middleware `ImageCacheKey`, so Bearer-injected `Authorization` keeps
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
