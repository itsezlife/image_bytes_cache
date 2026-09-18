# Storage

How `IndexedImageBytesCache` keeps meta fast and payloads durable. Platform
adapters implement the ports; the brain owns concurrency and retention.

## Doctrine

After open, **meta lives in a RAM mirror**. Pure reads do not hit durable meta
IO and do not run exclusive against each other. Durable meta persists with
**one commit per exclusive mutate epoch**. Image bodies live on platform blob
stores (files on VM; Cache API and OPFS on web), never in Hive and never as
SQLite BLOB columns queried on the hot path.

Live SQL on every cache read is refused. Hive boxes for image payloads are
refused.

## Ports

### `IImageBytesIndex`

Records only: `writtenAt`, `accessedAt`, `byteLength` per `ImageCacheKey`.
`get` / `put` / `delete` / `values` mutate the RAM mirror. `commit` writes the
durable document once. Memory fakes may no-op `commit`.

### `IImageBytesBlobStore`

Bytes only. No timestamps. The brain pairs index rows with blobs and deletes
both on evict / TTL / trim.

Keeping the split lets prune and LRU scan sizes and access times without
loading every payload.

## Concurrent reads vs exclusive mutate

`IndexedImageBytesCache` uses language primitives only (shared/exclusive gate).
No Mutex package.

**Shared (concurrent):** pure `read` hits and soft misses. Soft LRU writes into
`_pendingAccess` only. No `commit`.

**Exclusive (serialized writers; drain readers first):**

- `write`, `evict`, `prune`
- TTL or orphan-index deletes upgraded from a shared `read` probe
- `reclaimOrphans`
- `close`

Mutate epoch shape:

```text
exclusiveMutate:
  flush soft access into RAM map
  apply puts / deletes / trim (including blob IO)
  commitDurableMetaOnce
  reclaimOrphanBlobs(indexedKeys)   // prune and explicit reclaim
```

Without the single-commit rule, a soft-LRU flush that touches N keys would
rewrite the durable index N times. Without the shared exclusive domain, orphan
reclaim can delete a blob mid-write. Open wrappers must pass reclaim into the
brain; they must not reclaim outside that gate.

After `close`, Indexed ops throw `StateError`. Platform wrappers close isolate
or Cache/OPFS handles around the brain.

## Soft LRU

Access times update in memory on successful read. They flush into the RAM
index at the start of a mutate epoch (`write` / `prune`), then one `commit`
persists them with any other meta changes. Paint does not force durable meta
IO.

## Retention

Sealed `ImageBytesRetention`. TTL is checked on `read`. Capacity is trimmed on
`write` and `prune`. There is no background eviction timer.

`ImageBytesRetention.standard` (default for `open`):

| Limit        | Value   |
| ------------ | ------- |
| `maxAge`     | 14 days |
| `maxEntries` | 500     |
| `maxBytes`   | 50 MiB  |

Entry count alone would let a few large assets fill the device. The byte
budget bounds that without a timer. Hosts may pass `compound`, `maxAge`,
`maxEntries`, `maxBytes`, or `unlimited`. When set, `maxEntries` and
`maxBytes` must be **positive** (asserted on the retention constructors);
non-positive caps are nonsense policy.

Empty payloads are not retained on `write` (treated as eviction of that key).
A sticky empty durable row still misses on `read` and is scrubbed so it cannot
waste entry capacity.

Capacity trim evicts least-recently-accessed records after soft access has
been flushed, so a just-read entry is not wrongly dropped when writing a new
one under `maxEntries`.

## Orphans

| Case               | When                              | Action                                           |
| ------------------ | --------------------------------- | ------------------------------------------------ |
| Index without blob | Shared `read` probe               | Upgrade to exclusive; delete index row; `commit` |
| Blob without index | Open / `prune` / `reclaimOrphans` | Platform reclaim under exclusive gate            |

Remote bytes are disposable: corrupt recovery prefers wipe over crash loops.

## Index document

`ImageBytesIndexDocumentCodec` owns the wire shape for VM file and web meta
Cache:

```text
{"v":1,"e":{"<key>":{"w":ms,"a":ms,"n":byteLength}}}
```

Unknown version or bad structure throws `FormatException`. Open paths delete
the document, wipe blobs via `onWipe`, and report `index_wipe`. Adapters must
encode/decode through the codec (fused UTF-8 JSON converters), not peel
`jsonEncode` / `utf8.encode` at call sites.

## VM durable path

| Half  | Implementation                                                        |
| ----- | --------------------------------------------------------------------- |
| Index | Versioned JSON file; RAM mirror; `commit` via the blob isolate worker |
| Blobs | One file per `ImageCacheKey.value` under the open directory           |

IO runs on a long-lived in-package `IsolateController` worker
(`lib/src/isolate_controller.dart`). Sync `dart:io` stays off the UI
isolate. Writes use temp then rename so a crash mid-write cannot leave a
truncated final path that `read` would treat as a hit.

When the worker dies (watchdog threshold, handler `#exit`, or an explicit
kill), `ImageBytesBlobStore$File$VM` fails in-flight RPC futures with
`StateError`, drops the dead controller, and allows a later op to respawn.
That fail-fast path keeps the exclusive mutate gate from stalling forever on
a hung blob future. Store `close` still fails pending with a closed
`StateError` and refuses further RPCs.

Bodies at or above `ImageBytesBlobStore$File$VM.transferByteThreshold`
(64 KiB) cross the isolate boundary as `TransferableTypedData`. Smaller bodies
stay plain `Uint8List` (transferable setup would cost more than it saves).
No per-write `compute`.

`directory` is required on VM and should sit under the app **cache** root
(reclaimable), not documents/support.

## Web durable path

| Half                     | Implementation                                                   |
| ------------------------ | ---------------------------------------------------------------- |
| Index                    | One Cache API JSON document (`ImageBytesWebKeys.indexCacheName`) |
| Blobs under 64 KiB       | Cache API Responses with synthetic `.invalid` URLs               |
| Blobs at or above 64 KiB | OPFS files under `opfsBlobsDirectoryName`                        |

`ImageBytesBlobStore$Routed$JS.opfsByteThreshold` is 64 KiB, matching the VM
transferable cut so “small chrome vs large raster” is one documented size
policy. Writes route by length and delete the key from the other backend so a
resize across the threshold cannot leave a stale twin. Reads check Cache then
OPFS.

Synthetic keys use host `image-bytes.invalid` so payload entries never share
identity with real network fetches and never invite accidental Cache `add()`
network hits. OPFS filenames are `ImageCacheKey.value` (already filename-safe).
No `IsolateController` on web.

API parity with VM means the same `IImageBytesCache` contract. Cost asymmetry
is expected: web is not a second copy of the isolate worker model.

## Memory and NoOp

`MemoryImageBytesCache` is an in-process map for tests and degraded open.
Access times update on every read (cheap in memory). `close` is a no-op; the
instance stays usable so tearDown can call `close` uniformly.

`NoOpImageBytesCache` always misses and discards writes. It is the default
`shared()` until bootstrap configures a real store. `close` is a no-op.

Neither is a durable platform backend.
