## 0.0.2

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
