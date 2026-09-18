## 0.0.2

- **FIXED**: VM blob isolate death fails in-flight RPCs with `StateError`
  instead of hanging, drops the dead worker so later ops can respawn, and
  keeps the exclusive mutate gate from stalling on a dead worker.
- **FIXED**: Ladder soft-failure hygiene — empty durable writes are not retained
  (treated as eviction); sticky empty rows scrub on read; non-positive
  `maxEntries` / `maxBytes` assert; throwing diagnostics `onEvent` is swallowed
  so write-through catch cannot become an unhandled async error; HTTP timeout
  uses `AbortableRequest` (releases sockets when the client honors abort) while
  pool-wait before a slot remains intentionally unbounded.
- **FIXED**: Ladder identity — coalesce uses `ImageCacheKey` (no ambiguous
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

- **ADDED**: Initial standalone release — durable remote image bytes with RAM
  meta mirror, platform blob stores (VM files / web Cache+OPFS), resolve
  ladder, store microbenches, and docs.
