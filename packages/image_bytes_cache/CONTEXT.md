# image_bytes_cache

Durable remote image **bytes**. Pure-Dart engine in this repository. Not
Flutter's decoded [ImageCache], not a generic KV store, and not Hive.

Paint widgets live in sibling
[image_bytes_cache_flutter](../image_bytes_cache_flutter/CONTEXT.md). Hosts
bootstrap this package with `ImageBytesCache.open` / `configure`, then paint
through the flutter adapters.

Deep docs: [AGENTS.md](AGENTS.md) (agent orientation),
[docs/architecture.md](docs/architecture.md),
[docs/storage.md](docs/storage.md),
[docs/resolve-ladder.md](docs/resolve-ladder.md),
[docs/development.md](docs/development.md).

## Language

**ImageCacheKey**:
Filename-safe identity for a remote image body. Derived from the
`Uri.base.resolve` canonical URL + canonical headers (lowercase keys, sorted).
Fingerprint material is length-prefixed (not a `url|headers` join). Distinct
URLs that share a basename do not collide. Relative and absolute forms of the
same resource share one key. Explicit `ImageBytesRequest.cacheKey` is a full
identity escape hatch: headers still go on the wire but are not folded in.
_Avoid_: basename-only disk keys, header casing as identity, delimiter joins
for coalesce/fingerprint, assuming override keys fold Authorization

**IImageBytesCache** / **IndexedImageBytesCache**:
Bytes store contract and the indexed composition over meta + blob halves.
Hot path: concurrent reads on the RAM index mirror; write / evict / prune /
TTL-delete / meta commit / orphan reclaim share one exclusive domain. Durable
meta commits once per mutate epoch. If that commit throws, the RAM mirror
rolls back to the pre-epoch snapshot (no optimistic durable hit); write-through
still reports without failing resolve. Memory and NoOp implementations exist
for tests and pre-configure.
_Avoid_: Hive for this path; SQL SELECT on every read; bodies in SQLite BLOB
columns; serializing pure reads; reclaim outside the exclusive domain;
leaving "write failed but RAM hit" after a thrown commit

**IImageBytesIndex** / **IImageBytesBlobStore**:
Split ports: retention meta vs payload bytes. Index is a RAM mirror after
open: put/delete do not persist; `commit` writes the durable document once per
epoch. VM: versioned JSON index file + one file per key behind
IsolateController; large blob writes use TransferableTypedData above a
documented threshold. Worker death fails in-flight blob RPCs (no hang) and
drops the dead controller so later ops can respawn. Web: Cache API index document; blobs under 64 KiB use
Cache API with synthetic `.invalid` keys; blobs at or above 64 KiB use OPFS
files (same cut as the VM transferable threshold). Hot-path reads pass index
`byteLength` so large bodies skip a guaranteed Cache API miss and go to OPFS.
Index document bytes go
through [ImageBytesIndexDocumentCodec] (`Map` ↔ UTF-8 JSON bytes via fused
converters); adapters do not call `jsonEncode` / `utf8.encode` directly.
_Avoid_: sidecar `.meta.json` per blob; SharedPreferences for image blobs;
peeling UTF-8/JSON around the document codec at call sites; per-key full index
rewrite during soft-LRU flush; per-write `compute` on VM; all-OPFS or
all-Cache-API when the size split is the documented policy; IsolateController
on web; importing `package:shared` for the isolate helper; Cache-then-OPFS on
every large hit when meta already knows the body is above the cut

**ImageBytesRetention**:
Sealed eviction policy. TTL checked on read; capacity trimmed on write/prune.
No background timer. Default `standard` caps age, entry count, and total bytes.
Non-positive `maxEntries` / `maxBytes` are asserted invalid.
_Avoid_: background eviction timers; entry-count-only budgets for large payloads;
zero or negative capacity caps

**ImageBytesResolver** / **ImageBytesRequest**:
Resolve ladder: cache read → network on miss → fire-and-forget write-through.
Empty cached payloads count as a miss. Empty durable writes are not retained
(evict). Write-through failures do not fail paint; throwing diagnostics
`onEvent` is swallowed so it cannot become an unhandled async error.
Resolve remains a single [Future] of the full body — not a public byte stream.
Optional bytes-progress reporting (cumulative / optional total) may ride with
the request so paint adapters can surface honest download progress; cache hits
do not invent mid-flight percents.
_Avoid_: failing resolve when durable write fails; sticky empty capacity waste;
replacing resolve with a streaming public API for progress alone; fake
progress events that are not tied to real fetch bytes

**HttpBytesFetcher**:
HTTP GET with concurrency pool and in-flight coalesce by `ImageCacheKey` identity
(canonical URL + canonical headers). Timeout after pool slot via
`AbortableRequest` (aborts when the client honors it). Pool wait for a slot is
intentionally unbounded. When a progress sink is supplied, reports cumulative
bytes as the response body is read (total when the response provides it).
Process-wide `configure` / `shared` / `resetShared` mirror the cache facade so
hosts can inject a custom `http.Client` once at bootstrap.
_Avoid_: homemade download queues; Mutex for N-way downloads; `url|headers`
string joins for coalesce; assuming timeout covers pool queue time; synthetic
chunk percents after the body is already fully buffered

**ImageBytesDiagnostics**:
Soft-failure policy (silent / developer log / onEvent). Process-wide `current`
set by open/configure. Covers write-through, index wipe, and degraded open.
`onEvent` must not throw; throws are swallowed in `report`.
Package does not depend on a product logger.
_Avoid_: `package:l` inside the ladder; `enableLogging` bool soup; throwing
host callbacks that escalate soft failures

**ImageBytesCache.open / configure / shared / resetShared**:
Host wiring. VM `directory` must be under a reclaimable cache root. Web ignores
`directory`. Hard open failure degrades to in-memory with a warning unless
`throwOnOpenFailure` is set; platform open closes any partial worker / web
handles first. Missing VM directory still throws. `configure` closes the
previous instance before assign; `resetShared` closes then clears, including
`ImageBytesResolver` and `HttpBytesFetcher` shared wiring. `ImageBytesResolver.shared`
looks up the current shared cache/fetcher on each resolve (not a one-shot
snapshot).
_Avoid_: documents/support paths for remote image bytes; Config paths inside
package open code; letting open throw kill bootstrap when storage is optional;
assuming first `shared().resolve` permanently binds NoOp

## Web smoke

Chrome integration: from the package root,

`dart test -p chrome test/open/image_bytes_cache_open_web_test.dart`

Covers Cache vs OPFS routing by size, close/reopen, and orphan reclaim on both
backends. CI runs this as a merge gate; also run it locally when iterating on
web blob / open code.
