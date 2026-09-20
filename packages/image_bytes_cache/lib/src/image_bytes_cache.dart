// ignore_for_file: one_member_abstracts

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:image_bytes_cache/src/environment_specific/cache_open.dart' as environment_specific;
import 'package:image_bytes_cache/src/image_bytes_diagnostics.dart';
import 'package:meta/meta.dart';

/// Cache identity for remote image bytes (disk / durable store / PageStorage).
///
/// Filename-safe string: host + last path segment + a short fingerprint of the
/// [Uri.base.resolve] canonical URL and canonical headers (length-prefixed
/// material — not a `url|headers` join). Shared with [HttpBytesClient]
/// coalesce via [value]. Without the fingerprint, two URLs that share a
/// basename would collide on disk.
@immutable
final class ImageCacheKey {
  /// Wraps an already-safe [value] (tests, restore from storage).
  const ImageCacheKey(this.value);

  /// Derives [value] from [url] and optional [headers].
  ///
  /// [url] is resolved with [Uri.base.resolve] before host/basename extraction
  /// and fingerprinting, so a relative path and its absolute form against the
  /// same base produce one key — matching the URI [ImageBytesResolver] GETs.
  ///
  /// Header keys are lowercased and sorted before hashing so casing and map
  /// iteration order do not change identity (parity with
  /// [HttpBytesClient] coalesce). Values stay as given. Fingerprint material
  /// is a length-prefixed encoding of URL + canonical headers so a `|` (or any
  /// other character) inside the URL or a header value cannot forge another
  /// (url, headers) pair.
  ///
  /// Distinct URLs that share a basename still produce distinct keys via the
  /// fingerprint. [value] is capped at [_maxValueLength] so hosts with long
  /// path segments stay safe as filenames and web store keys (basename
  /// truncated; fingerprint and host still distinguish collisions).
  factory ImageCacheKey.fromUrl(
    String url, {
    Map<String, String>? headers,
  }) {
    final canonicalUrl = Uri.base.resolve(url).toString();
    final uri = Uri.tryParse(canonicalUrl);
    final host = switch (uri?.host) {
      final h? when h.isNotEmpty => h.replaceAll('.', '_'),
      _ => 'unknown',
    };
    final pathSeg = switch (uri?.pathSegments) {
      final segments? when segments.isNotEmpty => segments.last,
      _ => 'asset',
    };
    var safeName = pathSeg.replaceAll(RegExp('[^a-zA-Z0-9._-]'), '_').replaceAll('..', '_');
    final fingerprint = sha1.convert(_fingerprintMaterial(canonicalUrl, headers)).toString().substring(0, 12);
    // Reserve room for host + '_' + '_' + 12-char fingerprint.
    final maxNameLen = (_maxValueLength - host.length - fingerprint.length - 2).clamp(8, _maxBasenameLength);
    if (safeName.length > maxNameLen) {
      safeName = safeName.substring(0, maxNameLen);
    }
    var value = '${host}_${safeName}_$fingerprint';
    if (value.length > _maxValueLength) {
      // Extreme host length: keep trailing fingerprint; truncate from the front of the stem.
      value = value.substring(value.length - _maxValueLength);
    }
    return ImageCacheKey(value);
  }

  /// Filename-safe identity string.
  final String value;

  /// Soft ceiling for filesystem and typical web cache key limits.
  static const int _maxValueLength = 180;

  /// Cap on the basename segment before host/fingerprint are applied.
  static const int _maxBasenameLength = 64;

  /// Lowercase keys, last-wins on case duplicates, then sorted `k=v` join.
  ///
  /// Shared with [HttpBytesClient] coalesce so header casing and map order
  /// cannot split cache identity from in-flight GET dedupe.
  static String canonicalHeaders(Map<String, String>? headers) {
    if (headers == null || headers.isEmpty) return '';
    final normalized = <String, String>{
      for (final MapEntry(:key, :value) in headers.entries) key.toLowerCase(): value,
    };
    final keys = normalized.keys.toList()..sort();
    return keys.map((k) => '$k=${normalized[k]}').join('&');
  }

  /// Length-prefixed UTF-8 of canonical URL then canonical headers.
  ///
  /// Without length prefixes, a delimiter join such as `url|headers` lets a
  /// URL that embeds `|…` forge the same fingerprint bytes as a clean URL plus
  /// those headers (or a header value that embeds further `|` fields).
  static List<int> _fingerprintMaterial(String canonicalUrl, Map<String, String>? headers) {
    final urlBytes = const Utf8Encoder().convert(canonicalUrl);
    final headerBytes = const Utf8Encoder().convert(canonicalHeaders(headers));
    return <int>[
      ..._u32be(urlBytes.length),
      ...urlBytes,
      ..._u32be(headerBytes.length),
      ...headerBytes,
    ];
  }

  static List<int> _u32be(int length) => <int>[
    (length >> 24) & 0xff,
    (length >> 16) & 0xff,
    (length >> 8) & 0xff,
    length & 0xff,
  ];

  @override
  bool operator ==(Object other) => identical(this, other) || other is ImageCacheKey && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'ImageCacheKey($value)';
}

/// How long / how much an [IImageBytesCache] keeps entries.
///
/// TTL is checked on [IImageBytesCache.read]. Capacity is trimmed on
/// [IImageBytesCache.write] and [IImageBytesCache.prune]. There is no
/// background timer: without those calls, entries stay until the host deletes
/// them.
@immutable
sealed class ImageBytesRetention {
  const ImageBytesRetention();

  /// No automatic eviction (still removable via [IImageBytesCache.evict]).
  const factory ImageBytesRetention.unlimited() = ImageBytesRetentionUnlimited;

  /// Drop when [ImageBytesRecord.writtenAt] is older than [maxAge].
  const factory ImageBytesRetention.maxAge(Duration maxAge) = ImageBytesRetentionMaxAge;

  /// Keep at most [maxEntries] (LRU by last access).
  ///
  /// [maxEntries] must be positive — a zero or negative cap is nonsense
  /// retention that would either retain nothing useful or never trim.
  const factory ImageBytesRetention.maxEntries(int maxEntries) = ImageBytesRetentionMaxEntries;

  /// Keep total payload size at or under [maxBytes] (LRU by last access).
  ///
  /// [maxBytes] must be positive — a non-positive byte budget cannot describe
  /// a usable capacity policy.
  const factory ImageBytesRetention.maxBytes(int maxBytes) = ImageBytesRetentionMaxBytes;

  /// Combine optional TTL and capacity limits.
  ///
  /// Null fields are ignored. Use this when you need more than one constraint.
  /// When set, [maxEntries] and [maxBytes] must be positive (same invariant as
  /// the dedicated factories).
  const factory ImageBytesRetention.compound({
    Duration? maxAge,
    int? maxEntries,
    int? maxBytes,
  }) = ImageBytesRetentionCompound;

  /// Default used by [ImageBytesCache.open].
  ///
  /// Caps age (14 days), entry count (500), and total payload size (50 MiB).
  /// Entry count alone would let a few large assets fill the device; the byte
  /// budget bounds that without needing a background eviction timer.
  static const ImageBytesRetention standard = ImageBytesRetentionCompound(
    maxAge: Duration(days: 14),
    maxEntries: 500,
    maxBytes: 50 * 1024 * 1024,
  );

  /// Flattened view of this policy for implementers.
  ({Duration? maxAge, int? maxEntries, int? maxBytes}) get limits => switch (this) {
    ImageBytesRetentionUnlimited() => (
      maxAge: null,
      maxEntries: null,
      maxBytes: null,
    ),
    ImageBytesRetentionMaxAge(:final maxAge) => (
      maxAge: maxAge,
      maxEntries: null,
      maxBytes: null,
    ),
    ImageBytesRetentionMaxEntries(:final maxEntries) => (
      maxAge: null,
      maxEntries: maxEntries,
      maxBytes: null,
    ),
    ImageBytesRetentionMaxBytes(:final maxBytes) => (
      maxAge: null,
      maxEntries: null,
      maxBytes: maxBytes,
    ),
    ImageBytesRetentionCompound(
      :final maxAge,
      :final maxEntries,
      :final maxBytes,
    ) =>
      (maxAge: maxAge, maxEntries: maxEntries, maxBytes: maxBytes),
  };
}

/// Variant of [ImageBytesRetention.unlimited].
@immutable
final class ImageBytesRetentionUnlimited extends ImageBytesRetention {
  /// See [ImageBytesRetention.unlimited].
  const ImageBytesRetentionUnlimited();
}

/// Variant of [ImageBytesRetention.maxAge].
@immutable
final class ImageBytesRetentionMaxAge extends ImageBytesRetention {
  /// See [ImageBytesRetention.maxAge].
  const ImageBytesRetentionMaxAge(this.maxAge);

  /// Maximum age since [ImageBytesRecord.writtenAt].
  final Duration maxAge;
}

/// Variant of [ImageBytesRetention.maxEntries].
@immutable
final class ImageBytesRetentionMaxEntries extends ImageBytesRetention {
  /// See [ImageBytesRetention.maxEntries].
  const ImageBytesRetentionMaxEntries(this.maxEntries) : assert(maxEntries > 0, 'maxEntries must be > 0');

  /// Maximum number of keys retained.
  final int maxEntries;
}

/// Variant of [ImageBytesRetention.maxBytes].
@immutable
final class ImageBytesRetentionMaxBytes extends ImageBytesRetention {
  /// See [ImageBytesRetention.maxBytes].
  const ImageBytesRetentionMaxBytes(this.maxBytes) : assert(maxBytes > 0, 'maxBytes must be > 0');

  /// Maximum sum of [ImageBytesRecord.byteLength] across entries.
  final int maxBytes;
}

/// Variant of [ImageBytesRetention.compound].
@immutable
final class ImageBytesRetentionCompound extends ImageBytesRetention {
  /// See [ImageBytesRetention.compound].
  const ImageBytesRetentionCompound({
    this.maxAge,
    this.maxEntries,
    this.maxBytes,
  }) : assert(maxEntries == null || maxEntries > 0, 'maxEntries must be > 0 when set'),
       assert(maxBytes == null || maxBytes > 0, 'maxBytes must be > 0 when set');

  /// Optional TTL since write.
  final Duration? maxAge;

  /// Optional max key count.
  final int? maxEntries;

  /// Optional max total payload bytes.
  final int? maxBytes;
}

/// Keys removed and bytes freed by [IImageBytesCache.prune].
@immutable
final class ImageBytesPruneReport {
  /// Snapshot of one prune pass.
  const ImageBytesPruneReport({
    required this.evictedKeys,
    required this.freedBytes,
  });

  /// Keys deleted in this prune (order is implementation-defined).
  final List<ImageCacheKey> evictedKeys;

  /// Sum of [ImageBytesRecord.byteLength] for those keys.
  final int freedBytes;
}

/// HTTP validators and freshness for one cached body.
///
/// Separate from [ImageBytesRetention] and from [ImageBytesRecord.writtenAt] /
/// [ImageBytesRecord.accessedAt]. Retention evicts by age and capacity. This
/// type is what a later revalidation path needs: ETag, Last-Modified,
/// Cache-Control, and friends.
///
/// Every field is optional. A row with all nulls (or a null [ImageBytesRecord.httpCacheMeta])
/// is a pre-ETag entry, not a decode error. The durable index codec keeps these
/// fields additive on `v:1`. [ImageCacheKey] never hashes them.
@immutable
final class ImageHttpCacheMeta {
  /// All fields default to null.
  const ImageHttpCacheMeta({
    this.etag,
    this.lastModified,
    this.date,
    this.expires,
    this.cacheControl,
    this.age,
    this.lastValidatedAt,
  });

  /// `ETag` response value. Keeps surrounding quotes when the origin sent them.
  final String? etag;

  /// Raw `Last-Modified` header string.
  final String? lastModified;

  /// Parsed `Date` header, when the store recorded one.
  final DateTime? date;

  /// Parsed `Expires` header, when the store recorded one.
  final DateTime? expires;

  /// Raw `Cache-Control` string, or a lightly normalized copy of it.
  final String? cacheControl;

  /// `Age` header as a duration, when known.
  final Duration? age;

  /// Wall time of the last successful confirm: a 200 write-through or a 304.
  final DateTime? lastValidatedAt;

  /// True when every field is null. Encoders skip writing an empty `h` object.
  bool get isEmpty =>
      etag == null &&
      lastModified == null &&
      date == null &&
      expires == null &&
      cacheControl == null &&
      age == null &&
      lastValidatedAt == null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ImageHttpCacheMeta &&
          other.etag == etag &&
          other.lastModified == lastModified &&
          other.date == date &&
          other.expires == expires &&
          other.cacheControl == cacheControl &&
          other.age == age &&
          other.lastValidatedAt == lastValidatedAt;

  @override
  int get hashCode => Object.hash(
    etag,
    lastModified,
    date,
    expires,
    cacheControl,
    age,
    lastValidatedAt,
  );
}

/// Bytes plus retention timestamps and optional [ImageHttpCacheMeta].
///
/// [IImageBytesCache.read] still returns [Uint8List]?. Call
/// [IImageBytesRichCache.readRich], or run a middleware read through
/// `execute`, when you need the meta beside the body.
@immutable
final class ImageBytesRichHit {
  /// [bytes] must be non-empty. Empty rows are scrubbed to a miss before this
  /// type is built.
  const ImageBytesRichHit({
    required this.bytes,
    this.writtenAt,
    this.accessedAt,
    this.httpCacheMeta,
  });

  /// Payload. Never empty on a successful hit.
  final Uint8List bytes;

  /// Last write time when the store tracked it.
  final DateTime? writtenAt;

  /// Soft LRU access time when the store tracked it.
  final DateTime? accessedAt;

  /// Validators / freshness. Null when the row never stored any, including
  /// older durable documents that predate these fields.
  final ImageHttpCacheMeta? httpCacheMeta;
}

/// Optional rich-read half for stores that keep meta beside bytes.
///
/// [MemoryImageBytesCache] and [IndexedImageBytesCache] implement this.
/// Middleware terminals call [readRich] when the inner store implements it.
/// Hosts that only call [IImageBytesCache.read] never see this type.
abstract interface class IImageBytesRichCache {
  /// Same miss, TTL, and empty-scrub rules as [IImageBytesCache.read], plus
  /// timestamps and [ImageHttpCacheMeta] when present.
  Future<ImageBytesRichHit?> readRich(ImageCacheKey key);
}

/// Metadata for one stored entry: timestamps, size, optional HTTP cache meta.
@immutable
final class ImageBytesRecord {
  /// Builds a record for [key].
  const ImageBytesRecord({
    required this.key,
    required this.writtenAt,
    required this.accessedAt,
    required this.byteLength,
    this.httpCacheMeta,
  });

  /// Entry identity.
  final ImageCacheKey key;

  /// When the payload was last written (UTC preferred).
  final DateTime writtenAt;

  /// Last access time used for LRU. Soft-updated by [IndexedImageBytesCache].
  final DateTime accessedAt;

  /// Payload length in bytes (used for [ImageBytesRetention.maxBytes]).
  final int byteLength;

  /// HTTP validators / freshness for this body, or null for a pre-ETag row.
  ///
  /// Not part of [ImageCacheKey]. [ImageBytesRetention] still looks only at
  /// [writtenAt], [accessedAt], and [byteLength].
  final ImageHttpCacheMeta? httpCacheMeta;

  /// Copy with selected fields replaced.
  ImageBytesRecord copyWith({
    DateTime? writtenAt,
    DateTime? accessedAt,
    int? byteLength,
    ImageHttpCacheMeta? httpCacheMeta,
  }) => ImageBytesRecord(
    key: key,
    writtenAt: writtenAt ?? this.writtenAt,
    accessedAt: accessedAt ?? this.accessedAt,
    byteLength: byteLength ?? this.byteLength,
    httpCacheMeta: httpCacheMeta ?? this.httpCacheMeta,
  );
}

/// Metadata half of [IndexedImageBytesCache].
///
/// Kept separate from [IImageBytesBlobStore] so prune and LRU can scan records
/// without reading every payload. After [IndexedImageBytesCache] opens, the
/// hot path treats this as a **RAM mirror**: [get] / [put] / [delete] /
/// [values] must not hit durable meta IO. Durable backends persist only in
/// [commit], once per exclusive mutate epoch (after soft-LRU flush and
/// in-memory puts/deletes/trim), never once per key during a multi-key flush.
///
/// Memory-only fakes may no-op [commit]. Platform adapters (file snapshot on
/// VM, Cache API document on web) load into RAM on open and rewrite the
/// durable document only from [commit].
abstract interface class IImageBytesIndex {
  /// Returns the record for [key], or `null` if missing. RAM mirror only.
  Future<ImageBytesRecord?> get(ImageCacheKey key);

  /// Inserts or replaces the record for [record.key] in the RAM mirror.
  ///
  /// Does not persist. [IndexedImageBytesCache] calls [commit] once after the
  /// mutate epoch finishes mutating the mirror.
  Future<void> put(ImageBytesRecord record);

  /// Removes the record for [key] from the RAM mirror if present.
  ///
  /// Does not persist. See [put].
  Future<void> delete(ImageCacheKey key);

  /// All records in the RAM mirror (used by prune / capacity trim).
  Future<Iterable<ImageBytesRecord>> values();

  /// Persists the current RAM mirror once (atomic snapshot or txn).
  ///
  /// Called at most once per exclusive mutate epoch. No-op when there is no
  /// durable backend.
  Future<void> commit();
}

/// Payload half of [IndexedImageBytesCache].
///
/// Bytes only. Retention and timestamps live on [IImageBytesIndex].
abstract interface class IImageBytesBlobStore {
  /// Returns payload bytes for [key], or `null` if missing.
  ///
  /// [knownByteLength] is an optional hint from the RAM index row already
  /// probed by [IndexedImageBytesCache]. Web size-routed stores use it to skip
  /// a guaranteed Cache API miss when the body lives in OPFS; other backends
  /// ignore it. Callers that do not know the length omit the argument and get
  /// the store's default probe order.
  Future<Uint8List?> read(ImageCacheKey key, {int? knownByteLength});

  /// Writes or replaces payload bytes for [key].
  Future<void> write(ImageCacheKey key, Uint8List bytes);

  /// Removes payload bytes for [key] if present.
  Future<void> delete(ImageCacheKey key);
}

/// Store for remote image bytes (any image format).
///
/// Callers and widgets talk to this type. They should not know about durable
/// backends, files, or [IImageBytesIndex] / [IImageBytesBlobStore].
abstract interface class IImageBytesCache {
  /// Returns cached bytes for [key], or `null` on miss / expired TTL.
  Future<Uint8List?> read(ImageCacheKey key);

  /// Stores [bytes] under [key] and applies capacity retention.
  ///
  /// Empty [bytes] are not retained: the write is treated as eviction of [key]
  /// when present. An empty durable row would still count toward
  /// [ImageBytesRetention.maxEntries] while never painting, so hosts must not
  /// be able to stick zero-length capacity waste through this API.
  ///
  /// Pass [httpCacheMeta] when the store should keep validators next to the
  /// body ([MemoryImageBytesCache], [IndexedImageBytesCache]). Null (the
  /// default) clears any previous meta for [key]. That matches a bytes-only
  /// replace: the old ETag belonged to the old body. [ImageCacheKey] is
  /// unchanged either way.
  Future<void> write(
    ImageCacheKey key,
    Uint8List bytes, {
    ImageHttpCacheMeta? httpCacheMeta,
  });

  /// Deletes one key if present (index and payload when composed).
  Future<void> evict(ImageCacheKey key);

  /// Runs TTL and capacity eviction. Returns what was removed.
  Future<ImageBytesPruneReport> prune();

  /// Releases owned resources. Idempotent.
  ///
  /// [MemoryImageBytesCache] and [NoOpImageBytesCache] stay usable after close
  /// so tearDown can call this uniformly. [IndexedImageBytesCache] and durable
  /// compositions reject later ops with [StateError] (same idea as
  /// [HttpBytesClient.close]).
  Future<void> close();
}

/// [IImageBytesCache] that keeps metadata and payloads in separate stores.
///
/// ## Hot path
///
/// After open, [IImageBytesIndex] is a RAM mirror. Pure [read] hits (and soft
/// misses) run **concurrently**. They do not take the exclusive gate and do
/// not call [IImageBytesIndex.commit]. Soft LRU only notes access in
/// [_pendingAccess]; durable meta stays quiet on paint.
///
/// ## Mutate epoch
///
/// The following operations share a single, exclusive domain (all readers
/// complete first):
/// - [write]
/// - [evict]
/// - [prune]
/// - TTL or orphan-index deletes triggered during [read]
/// - [reclaimOrphans]
/// - [close]
///
/// Within a mutate epoch, the following steps are performed:
///  1. Snapshot the RAM mirror (last-good meta for rollback).
///  2. Flush soft access into the RAM mirror.
///  3. Apply puts, deletes, and capacity trim in RAM (including blob I/O).
///  4. Call [IImageBytesIndex.commit] **once**.
///  5. For [prune] (and explicit [reclaimOrphans]), run orphan blob reclamation.
///
/// Without that single-commit rule, a soft-LRU flush that touches N keys would
/// rewrite the durable index N times. Without the shared exclusive domain,
/// orphan reclaim can delete a blob mid-write.
///
/// ## Commit failure
///
/// If [IImageBytesIndex.commit] throws after the RAM (and possibly blob) half
/// has already mutated, the brain rolls the RAM mirror back to the pre-epoch
/// snapshot and rethrows. Later in-process [read]s must not treat the
/// optimistic put as a durable hit. Blob halves are not rolled back. A failed
/// write may leave an orphan blob. A failed commit after trim, evict, or TTL
/// may put index rows back whose payloads were already deleted; the next read
/// heals those as index-without-blob, and those victim bodies are not
/// recovered. We chose that over "write failed but RAM hit" and over
/// fail-closing the whole instance on a transient durable-meta error.
/// [ImageBytesResolver] write-through still sees the thrown [write] and
/// reports via diagnostics without failing a successful network resolve.
///
/// After [close], further operations throw [StateError].
///
/// Also implements [IImageBytesRichCache]: [readRich] returns the same hit or
/// miss as [read], and attaches [ImageBytesRecord] timestamps plus
/// [ImageHttpCacheMeta] when the index row has them.
final class IndexedImageBytesCache implements IImageBytesCache, IImageBytesRichCache {
  /// Wires [index] and [blobs] under [retention].
  ///
  /// [clock] is injectable for tests (defaults to UTC now).
  /// [reclaimOrphans] runs from [reclaimOrphans] and at the end of [prune]
  /// under the exclusive gate. Pass the platform blob store’s reclaim so
  /// wrappers never reclaim outside this domain.
  IndexedImageBytesCache({
    required IImageBytesIndex index,
    required IImageBytesBlobStore blobs,
    this.retention = ImageBytesRetention.standard,
    DateTime Function()? clock,
    Future<void> Function(Set<String> indexedKeys)? reclaimOrphans,
  }) : _index = index,
       _blobs = blobs,
       _clock = clock ?? _defaultClock,
       _reclaimOrphans = reclaimOrphans;

  final IImageBytesIndex _index;
  final IImageBytesBlobStore _blobs;
  final Future<void> Function(Set<String> indexedKeys)? _reclaimOrphans;

  /// Eviction policy for this instance.
  final ImageBytesRetention retention;
  final DateTime Function() _clock;

  final Map<ImageCacheKey, DateTime> _pendingAccess = {};

  /// Shared/exclusive gate. Language primitives only, no Mutex package.
  ///
  /// Writers serialize on [_exclusiveTail]. Readers briefly chain on that same
  /// tail to bump [_readerCount], then run concurrently without holding the
  /// tail for the read body, so a writer that arrives mid-read waits on
  /// [_readersIdle] instead of racing the count.
  Future<void> _exclusiveTail = Future.value();
  var _readerCount = 0;
  Completer<void>? _readersIdle;

  var _closed = false;

  /// Reads payload after TTL check. Soft-touches access time (see class docs).
  ///
  /// Concurrent with other pure reads. TTL expiry and index-without-blob
  /// cleanup upgrade to the exclusive mutate path.
  @override
  Future<Uint8List?> read(ImageCacheKey key) async => (await readRich(key))?.bytes;

  /// Same probe as [read], then retention timestamps and [ImageHttpCacheMeta]
  /// from the index row when the hit succeeds.
  @override
  Future<ImageBytesRichHit?> readRich(ImageCacheKey key) async {
    final probe = await _runShared(() async {
      _ensureOpen();
      final record = await _index.get(key);
      if (record == null) return const _ReadProbe.miss();

      final now = _clock();
      if (retention.limits.maxAge case final maxAge? when now.difference(record.writtenAt) > maxAge) {
        return const _ReadProbe.needsDelete();
      }

      final bytes = await _blobs.read(key, knownByteLength: record.byteLength);
      if (bytes == null) return const _ReadProbe.needsIndexDelete();
      // Legacy / corrupt empty rows still count toward capacity; scrub as miss.
      if (bytes.isEmpty) return const _ReadProbe.needsDelete();

      _pendingAccess[key] = now;
      return _ReadProbe.hit(
        bytes,
        writtenAt: record.writtenAt,
        accessedAt: now,
        httpCacheMeta: record.httpCacheMeta,
      );
    });

    return switch (probe) {
      _ReadProbeHit(
        :final bytes,
        :final writtenAt,
        :final accessedAt,
        :final httpCacheMeta,
      ) =>
        ImageBytesRichHit(
          bytes: bytes,
          writtenAt: writtenAt,
          accessedAt: accessedAt,
          httpCacheMeta: httpCacheMeta,
        ),
      _ReadProbeMiss() => null,
      _ReadProbeNeedsDelete() => _runExclusive(() async {
        _ensureOpen();
        final preEpoch = await _captureIndexSnapshot();
        // Re-check under the exclusive gate: a write may have refreshed the
        // entry after the shared probe decided it was expired.
        final record = await _index.get(key);
        if (record == null) return null;
        final now = _clock();
        final expired = switch (retention.limits.maxAge) {
          final maxAge? => now.difference(record.writtenAt) > maxAge,
          null => false,
        };
        if (!expired) {
          return _finishSharedRichHit(key, now, preEpoch, record);
        }
        await _deleteBoth(key);
        await _commitOrRollback(preEpoch);
        return null;
      }),
      _ReadProbeNeedsIndexDelete() => _runExclusive(() async {
        _ensureOpen();
        final preEpoch = await _captureIndexSnapshot();
        // Re-check: a write may have restored the blob after the shared probe.
        final record = await _index.get(key);
        if (record == null) return null;
        final bytes = await _blobs.read(key, knownByteLength: record.byteLength);
        switch (bytes) {
          case final b? when b.isNotEmpty:
            final now = _clock();
            _pendingAccess[key] = now;
            return ImageBytesRichHit(
              bytes: b,
              writtenAt: record.writtenAt,
              accessedAt: now,
              httpCacheMeta: record.httpCacheMeta,
            );
          case final b? when b.isEmpty:
            _pendingAccess.remove(key);
            await _deleteBoth(key);
            await _commitOrRollback(preEpoch);
            return null;
          case null:
            _pendingAccess.remove(key);
            await _index.delete(key);
            await _commitOrRollback(preEpoch);
            return null;
        }
      }),
    };
  }

  /// Blob hit after meta was already confirmed present and not expired.
  Future<ImageBytesRichHit?> _finishSharedRichHit(
    ImageCacheKey key,
    DateTime now,
    Map<ImageCacheKey, ImageBytesRecord> preEpoch,
    ImageBytesRecord record,
  ) async {
    final bytes = await _blobs.read(key, knownByteLength: record.byteLength);
    if (bytes == null || bytes.isEmpty) {
      _pendingAccess.remove(key);
      await _deleteBoth(key);
      await _commitOrRollback(preEpoch);
      return null;
    }
    _pendingAccess[key] = now;
    return ImageBytesRichHit(
      bytes: bytes,
      writtenAt: record.writtenAt,
      accessedAt: now,
      httpCacheMeta: record.httpCacheMeta,
    );
  }

  /// Writes payload and RAM meta, flushes soft access, trims, commits once.
  ///
  /// Empty [bytes] evict [key] instead of storing a zero-length row that would
  /// still occupy an entry slot under capacity retention.
  ///
  /// [httpCacheMeta] is written onto the index row. Null clears prior HTTP meta
  /// for [key] (bytes-only replace of a body that may have had validators).
  @override
  Future<void> write(
    ImageCacheKey key,
    Uint8List bytes, {
    ImageHttpCacheMeta? httpCacheMeta,
  }) {
    if (bytes.isEmpty) {
      return evict(key);
    }
    return _runExclusive(() async {
      _ensureOpen();
      final preEpoch = await _captureIndexSnapshot();
      await _flushPendingAccess();
      final now = _clock();
      await _blobs.write(key, bytes);
      await _index.put(
        ImageBytesRecord(
          key: key,
          writtenAt: now,
          accessedAt: now,
          byteLength: bytes.length,
          httpCacheMeta: httpCacheMeta,
        ),
      );
      await _trimCapacity();
      await _commitOrRollback(preEpoch);
    });
  }

  /// Removes index row, payload, and any pending access for [key].
  @override
  Future<void> evict(ImageCacheKey key) => _runExclusive(() async {
    _ensureOpen();
    final preEpoch = await _captureIndexSnapshot();
    _pendingAccess.remove(key);
    await _deleteBoth(key);
    await _commitOrRollback(preEpoch);
  });

  /// Flushes soft access, drops expired entries, capacity-trims, commits once,
  /// then reclaims orphan blobs under the same exclusive gate.
  @override
  Future<ImageBytesPruneReport> prune() => _runExclusive(() async {
    _ensureOpen();
    final preEpoch = await _captureIndexSnapshot();
    await _flushPendingAccess();
    final evicted = <ImageCacheKey>[];
    var freed = 0;
    final now = _clock();

    if (retention.limits.maxAge case final maxAge?) {
      final expired = [
        for (final record in await _index.values())
          if (now.difference(record.writtenAt) > maxAge) record,
      ];
      for (final record in expired) {
        freed += record.byteLength;
        evicted.add(record.key);
        await _deleteBoth(record.key);
      }
    }

    freed += await _trimCapacity(evicted: evicted);
    await _commitOrRollback(preEpoch);
    await _reclaimOrphansUnlocked();
    return ImageBytesPruneReport(evictedKeys: evicted, freedBytes: freed);
  });

  /// Drops blob keys absent from the index, under the exclusive mutate gate.
  ///
  /// No-op when no [reclaimOrphans] callback was supplied. Hosts / open paths
  /// call this after open; [prune] already reclaims at epoch end.
  Future<void> reclaimOrphans() => _runExclusive(() async {
    _ensureOpen();
    await _reclaimOrphansUnlocked();
  });

  /// Marks this instance closed and drops soft-access state.
  ///
  /// Idempotent. Waits for in-flight shared and exclusive work. Platform
  /// compositions may wrap this type for IO handles; this brain holds none.
  @override
  Future<void> close() => _runExclusive(() async {
    if (_closed) return;
    _closed = true;
    _pendingAccess.clear();
  });

  /// Registers as a reader on [_exclusiveTail], then runs [action] without
  /// holding the tail so other readers can overlap.
  Future<T> _runShared<T>(Future<T> Function() action) {
    final ready = Completer<void>();
    final previous = _exclusiveTail;
    _exclusiveTail = previous.catchError((Object _, StackTrace __) {}).then((_) {
      _readerCount++;
      ready.complete();
    });
    return ready.future.then((_) async {
      try {
        return await action();
      } finally {
        _readerCount--;
        if (_readerCount == 0) {
          _readersIdle?.complete();
          _readersIdle = null;
        }
      }
    });
  }

  /// Exclusive mutate: serialize writers, drain readers, then run.
  ///
  /// Ignores prior failures so one thrown op does not permanently stall the
  /// queue.
  Future<T> _runExclusive<T>(Future<T> Function() action) {
    final done = Completer<void>();
    final previous = _exclusiveTail;
    _exclusiveTail = done.future;
    return previous.catchError((Object _, StackTrace __) {}).then((_) async {
      while (_readerCount > 0) {
        final idle = Completer<void>();
        _readersIdle = idle;
        // Reader may have drained between the while check and assign.
        if (_readerCount == 0) {
          _readersIdle = null;
          break;
        }
        await idle.future;
      }
      try {
        return await action();
      } finally {
        if (!done.isCompleted) done.complete();
      }
    });
  }

  void _ensureOpen() {
    if (_closed) {
      throw StateError('IndexedImageBytesCache is closed');
    }
  }

  /// Last-good RAM meta before this mutate epoch touches the mirror.
  ///
  /// [ImageBytesRecord] is immutable, so holding the instances is a faithful
  /// snapshot of the pre-epoch map.
  Future<Map<ImageCacheKey, ImageBytesRecord>> _captureIndexSnapshot() async => {
    for (final record in await _index.values()) record.key: record,
  };

  /// Persists once; on failure restores the RAM mirror to [preEpoch] and rethrows.
  ///
  /// Without rollback, a thrown commit would leave optimistic puts/deletes as
  /// in-process hits that no longer match durable storage ("write failed but
  /// hit"). Blob IO is not rolled back. A failed write may leave an orphan
  /// blob. A failed commit after trim, evict, or TTL may put index rows back
  /// whose payloads were already deleted; the next read heals those as
  /// index-without-blob, and those previously durable bodies stay gone. That
  /// cost beats fail-closing the whole instance on a transient meta error.
  Future<void> _commitOrRollback(Map<ImageCacheKey, ImageBytesRecord> preEpoch) async {
    try {
      await _index.commit();
    } catch (error, stackTrace) {
      await _restoreIndexMirror(preEpoch);
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> _restoreIndexMirror(Map<ImageCacheKey, ImageBytesRecord> before) async {
    final current = (await _index.values()).toList();
    for (final record in current) {
      if (!before.containsKey(record.key)) {
        await _index.delete(record.key);
      }
    }
    for (final MapEntry(:key, :value) in before.entries) {
      final live = await _index.get(key);
      if (live == null ||
          live.writtenAt != value.writtenAt ||
          live.accessedAt != value.accessedAt ||
          live.byteLength != value.byteLength ||
          live.httpCacheMeta != value.httpCacheMeta) {
        await _index.put(value);
      }
    }
  }

  Future<void> _flushPendingAccess() async {
    if (_pendingAccess.isEmpty) return;
    final pending = Map<ImageCacheKey, DateTime>.of(_pendingAccess);
    _pendingAccess.clear();
    for (final MapEntry(:key, :value) in pending.entries) {
      final record = await _index.get(key);
      if (record == null) continue;
      await _index.put(record.copyWith(accessedAt: value));
    }
  }

  Future<void> _deleteBoth(ImageCacheKey key) async {
    _pendingAccess.remove(key);
    await _index.delete(key);
    await _blobs.delete(key);
  }

  Future<void> _reclaimOrphansUnlocked() async {
    final reclaim = _reclaimOrphans;
    if (reclaim == null) return;
    final keys = {for (final record in await _index.values()) record.key.value};
    await reclaim(keys);
  }

  Future<int> _trimCapacity({List<ImageCacheKey>? evicted}) async {
    final limits = retention.limits;
    var freed = 0;

    while (true) {
      final records = (await _index.values()).toList();
      final totalBytes = records.fold<int>(0, (s, e) => s + e.byteLength);
      final overEntries = switch (limits.maxEntries) {
        final max? => records.length > max,
        null => false,
      };
      final overBytes = switch (limits.maxBytes) {
        final max? => totalBytes > max,
        null => false,
      };
      if (!overEntries && !overBytes) break;
      if (records.isEmpty) break;

      records.sort((a, b) => a.accessedAt.compareTo(b.accessedAt));
      final victim = records.first;
      freed += victim.byteLength;
      evicted?.add(victim.key);
      await _deleteBoth(victim.key);
    }
    return freed;
  }
}

/// Outcome of a shared [IndexedImageBytesCache.readRich] probe before optional mutate.
@immutable
sealed class _ReadProbe {
  const _ReadProbe();

  const factory _ReadProbe.hit(
    Uint8List bytes, {
    required DateTime writtenAt,
    required DateTime accessedAt,
    ImageHttpCacheMeta? httpCacheMeta,
  }) = _ReadProbeHit;
  const factory _ReadProbe.miss() = _ReadProbeMiss;
  const factory _ReadProbe.needsDelete() = _ReadProbeNeedsDelete;
  const factory _ReadProbe.needsIndexDelete() = _ReadProbeNeedsIndexDelete;
}

@immutable
final class _ReadProbeHit extends _ReadProbe {
  const _ReadProbeHit(
    this.bytes, {
    required this.writtenAt,
    required this.accessedAt,
    this.httpCacheMeta,
  });

  final Uint8List bytes;
  final DateTime writtenAt;
  final DateTime accessedAt;
  final ImageHttpCacheMeta? httpCacheMeta;
}

@immutable
final class _ReadProbeMiss extends _ReadProbe {
  const _ReadProbeMiss();
}

@immutable
final class _ReadProbeNeedsDelete extends _ReadProbe {
  const _ReadProbeNeedsDelete();
}

@immutable
final class _ReadProbeNeedsIndexDelete extends _ReadProbe {
  const _ReadProbeNeedsIndexDelete();
}

DateTime _defaultClock() => DateTime.now().toUtc();

/// In-memory [IImageBytesCache] for tests (and rare L1 use).
///
/// Access times update on every [read] (cheap in memory). Prefer
/// [IndexedImageBytesCache] for the process store.
///
/// Keeps optional [ImageHttpCacheMeta] in the same map entry as the bytes.
/// [readRich] and a middleware `execute` read can return it without a durable
/// index.
final class MemoryImageBytesCache implements IImageBytesCache, IImageBytesRichCache {
  /// Creates an empty in-memory store.
  ///
  /// [clock] is injectable for tests (defaults to UTC now).
  MemoryImageBytesCache({
    this.retention = const ImageBytesRetention.unlimited(),
    DateTime Function()? clock,
  }) : _clock = clock ?? _defaultClock;

  /// Eviction policy for this instance.
  final ImageBytesRetention retention;
  final DateTime Function() _clock;

  final Map<ImageCacheKey, _MemoryEntry> _entries = {};

  /// Returns bytes or `null` if missing / past TTL / empty sticky payload.
  @override
  Future<Uint8List?> read(ImageCacheKey key) async => (await readRich(key))?.bytes;

  /// Same miss rules as [read], plus timestamps and [ImageHttpCacheMeta].
  @override
  Future<ImageBytesRichHit?> readRich(ImageCacheKey key) async {
    if (_entries[key] case final entry?) {
      final now = _clock();
      if (retention.limits.maxAge case final maxAge? when now.difference(entry.writtenAt) > maxAge) {
        _entries.remove(key);
        return null;
      }
      if (entry.bytes.isEmpty) {
        _entries.remove(key);
        return null;
      }

      entry.accessedAt = now;
      return ImageBytesRichHit(
        bytes: entry.bytes,
        writtenAt: entry.writtenAt,
        accessedAt: entry.accessedAt,
        httpCacheMeta: entry.httpCacheMeta,
      );
    }
    return null;
  }

  /// Stores [bytes] and trims capacity if needed.
  ///
  /// Empty [bytes] evict [key] instead of retaining a zero-length entry that
  /// still consumes [ImageBytesRetention.maxEntries] capacity.
  ///
  /// [httpCacheMeta] lives in the entry for [readRich]. Null clears prior meta.
  @override
  Future<void> write(
    ImageCacheKey key,
    Uint8List bytes, {
    ImageHttpCacheMeta? httpCacheMeta,
  }) async {
    if (bytes.isEmpty) {
      _entries.remove(key);
      return;
    }
    final now = _clock();
    _entries[key] = _MemoryEntry(
      bytes: bytes,
      writtenAt: now,
      accessedAt: now,
      httpCacheMeta: httpCacheMeta,
    );
    _trimCapacity();
  }

  /// Removes [key] if present.
  @override
  Future<void> evict(ImageCacheKey key) async {
    _entries.remove(key);
  }

  /// Drops expired entries then capacity-trims.
  @override
  Future<ImageBytesPruneReport> prune() async {
    final evicted = <ImageCacheKey>[];
    var freed = 0;
    final now = _clock();

    if (retention.limits.maxAge case final maxAge?) {
      final expired = _entries.entries
          .where((e) => now.difference(e.value.writtenAt) > maxAge)
          .map((e) => e.key)
          .toList();
      for (final key in expired) {
        if (_entries.remove(key) case final entry?) {
          freed += entry.bytes.length;
          evicted.add(key);
        }
      }
    }

    freed += _trimCapacity(evicted: evicted);
    return ImageBytesPruneReport(evictedKeys: evicted, freedBytes: freed);
  }

  /// No resources to release. Idempotent so tearDown can call [close] uniformly.
  @override
  Future<void> close() async {}

  int _trimCapacity({List<ImageCacheKey>? evicted}) {
    final limits = retention.limits;
    var freed = 0;

    bool overCapacity() {
      if (limits.maxEntries case final maxEntries? when _entries.length > maxEntries) {
        return true;
      }
      if (limits.maxBytes case final maxBytes?) {
        final total = _entries.values.fold<int>(0, (s, e) => s + e.bytes.length);
        if (total > maxBytes) return true;
      }
      return false;
    }

    while (overCapacity() && _entries.isNotEmpty) {
      final oldest = _entries.entries.reduce(
        (a, b) => a.value.accessedAt.isBefore(b.value.accessedAt) ? a : b,
      );
      freed += oldest.value.bytes.length;
      _entries.remove(oldest.key);
      evicted?.add(oldest.key);
    }
    return freed;
  }
}

final class _MemoryEntry {
  _MemoryEntry({
    required this.bytes,
    required this.writtenAt,
    required this.accessedAt,
    this.httpCacheMeta,
  });

  final Uint8List bytes;
  final DateTime writtenAt;
  DateTime accessedAt;
  final ImageHttpCacheMeta? httpCacheMeta;
}

/// Always misses. Used until bootstrap calls [ImageBytesCache.configure].
final class NoOpImageBytesCache implements IImageBytesCache {
  /// Shared no-op instance is fine; this type holds no state.
  const NoOpImageBytesCache();

  /// Always `null`.
  @override
  Future<Uint8List?> read(ImageCacheKey key) async => null;

  /// Discards [bytes] and [httpCacheMeta]. Nothing is stored.
  @override
  Future<void> write(
    ImageCacheKey key,
    Uint8List bytes, {
    ImageHttpCacheMeta? httpCacheMeta,
  }) async {}

  /// Nothing to remove.
  @override
  Future<void> evict(ImageCacheKey key) async {}

  /// Returns an empty [ImageBytesPruneReport].
  @override
  Future<ImageBytesPruneReport> prune() async => const ImageBytesPruneReport(evictedKeys: [], freedBytes: 0);

  /// No resources to release. Idempotent so tearDown can call [close] uniformly.
  @override
  Future<void> close() async {}
}

/// Process-wide [IImageBytesCache] and the way to open the durable store.
abstract final class ImageBytesCache {
  /// Shared instance. [NoOpImageBytesCache] until [configure] or [debugShared].
  static IImageBytesCache shared() => debugShared ?? _shared ?? const NoOpImageBytesCache();

  static IImageBytesCache? _shared;

  /// Opens the environment-specific durable store.
  ///
  /// On VM, [directory] is required (hosts should pass a path under the app
  /// cache root, not documents) and the store is a file index plus
  /// one-file-per-key blobs on a long-lived isolate worker.
  ///
  /// On web, [directory] is ignored; a Cache API index document plus Cache API
  /// blobs for small bodies and OPFS files for large ones back the same
  /// [IImageBytesCache] contract.
  ///
  /// [diagnostics] is installed on [ImageBytesDiagnostics.current] before the
  /// store opens so index wipe recovery can report under the same policy as
  /// later resolve write-through.
  ///
  /// Hard open failures (quota, private mode, filesystem / Cache / OPFS errors)
  /// degrade to [MemoryImageBytesCache] with a warning unless
  /// [throwOnOpenFailure] is true. Platform open hooks close any partially
  /// opened VM worker or web handles before the failure surfaces here, so
  /// neither degrade nor strict rethrow leaks isolates or Cache/OPFS quota.
  /// [ArgumentError] from a missing VM [directory] still throws: that is a
  /// host wiring bug, not storage unavailability.
  static Future<IImageBytesCache> open({
    String? directory,
    ImageBytesRetention retention = ImageBytesRetention.standard,
    DateTime Function()? clock,
    ImageBytesDiagnostics diagnostics = const ImageBytesDiagnostics.silent(),
    bool throwOnOpenFailure = false,
  }) async {
    ImageBytesDiagnostics.current = diagnostics;
    try {
      return await environment_specific.$openImageBytesCache(
        directory: directory,
        retention: retention,
        clock: clock,
      );
    } on Object catch (error, stackTrace) {
      // Missing VM directory is ArgumentError (host wiring), not storage failure.
      if (error case ArgumentError()) rethrow;
      if (throwOnOpenFailure) rethrow;
      diagnostics.report(
        ImageBytesLogEvent(
          level: ImageBytesLogLevel.warning,
          message: 'image bytes cache: open failed, using in-memory store: $error',
          op: ImageBytesLogOp.openDegraded,
          stackTrace: stackTrace,
        ),
      );
      return MemoryImageBytesCache(retention: retention, clock: clock);
    }
  }

  /// Sets the process-wide store (bootstrap).
  ///
  /// Closes any previous non-identical [_shared] instance **before** assign so
  /// workers and Cache handles do not leak across reconfigure, and two durable
  /// stores never share the same process slot at once.
  ///
  /// Pass [diagnostics] when the store was opened without one, or to replace
  /// the policy after open. Omit to keep the policy [open] already installed.
  static Future<void> configure(
    IImageBytesCache cache, {
    ImageBytesDiagnostics? diagnostics,
  }) async {
    if (diagnostics != null) {
      ImageBytesDiagnostics.current = diagnostics;
    }
    final previous = _shared;
    if (previous != null && !identical(previous, cache)) {
      await previous.close();
    }
    _shared = cache;
  }

  /// Test override. Set to `null` to clear.
  @visibleForTesting
  static IImageBytesCache? debugShared;

  /// Closes the previous shared instance, then clears [configure] and
  /// [debugShared], and resets diagnostics to silent.
  ///
  /// Also invokes registered ladder cleanup hooks (see
  /// [addAfterResetShared]) so resolver / client shared wiring can clear
  /// without this facade importing those libraries.
  @visibleForTesting
  static Future<void> resetShared() async {
    final previous = _shared;
    debugShared = null;
    ImageBytesDiagnostics.current = const ImageBytesDiagnostics.silent();
    await previous?.close();
    _shared = null;
    for (final hook in List<FutureOr<void> Function()>.of(_afterResetSharedHooks)) {
      await hook();
    }
  }

  static final List<FutureOr<void> Function()> _afterResetSharedHooks = [];

  /// Registers cleanup after [resetShared] (resolver memo, client shared, …).
  ///
  /// Hooks are package-internal so the store facade does not import the ladder
  /// above it. Idempotent registration is the caller's responsibility.
  @internal
  static void addAfterResetShared(FutureOr<void> Function() hook) {
    _afterResetSharedHooks.add(hook);
  }
}
