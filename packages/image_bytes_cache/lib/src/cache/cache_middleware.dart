import 'dart:typed_data';

import 'package:image_bytes_cache/src/image_bytes_cache.dart';
import 'package:meta/meta.dart';

// --- Handler / middleware grammar ---

/// Takes a [CacheOperation] and returns a [CacheOperationResult].
///
/// [context] is shared across middleware for this dispatch.
typedef CacheHandler =
    Future<CacheOperationResult> Function(
      CacheOperation operation,
      CacheContext context,
    );

/// Wraps a [CacheHandler]. The outer layer receives the already-wrapped inner
/// handler and returns a new one.
typedef CacheMiddleware = CacheHandler Function(CacheHandler innerHandler);

/// Builds a [CacheMiddleware] from optional before/after/error hooks, or
/// merges a list with [CacheMiddlewareWrapper.merge].
extension type CacheMiddlewareWrapper._(CacheMiddleware _fn) {
  /// Hooks around the next handler. Any of [onOperation], [onResult], or
  /// [onError] may be omitted.
  factory CacheMiddlewareWrapper({
    Future<void> Function(CacheOperation operation, CacheContext context)? onOperation,
    Future<void> Function(CacheOperationResult result, CacheContext context)? onResult,
    Future<void> Function(
      Object error,
      StackTrace stackTrace,
      CacheContext context,
    )?
    onError,
  }) => CacheMiddlewareWrapper._(
    (innerHandler) => (operation, context) async {
      await onOperation?.call(operation, context);
      try {
        final result = await innerHandler(operation, context);
        await onResult?.call(result, context);
        return result;
      } on Object catch (error, stackTrace) {
        await onError?.call(error, stackTrace, context);
        rethrow;
      }
    },
  );

  /// Folds [middlewares] into one middleware.
  ///
  /// List order is outermost first: index 0 wraps everything after it.
  factory CacheMiddlewareWrapper.merge(
    List<CacheMiddleware> middlewares,
  ) => CacheMiddlewareWrapper._(switch (middlewares.length) {
    0 => (handler) => handler,
    1 => middlewares.single,
    _ => (handler) => middlewares.reversed.fold(
      handler,
      (handler, middleware) => middleware(handler),
    ),
  });

  /// Applies this middleware to [innerHandler].
  CacheHandler call(CacheHandler innerHandler) => _fn(innerHandler);
}

/// Mutable bag of typed slots for one [MiddlewareImageBytesCache.execute].
///
/// Public [IImageBytesCache] methods on the wrapper start from
/// [CacheContext.empty]. Seed [skipCache] (or other policy keys) via
/// [MiddlewareImageBytesCache.execute] so [ImageBytesSkipCacheMiddleware]
/// and later ladder plumbing share one story.
extension type CacheContext(Map<String, Object?> _map) implements Map<String, Object?> {
  /// Fresh map for a new dispatch.
  factory CacheContext.empty() => CacheContext(<String, Object?>{});

  /// When `true`, [ImageBytesSkipCacheMiddleware] forces read miss and write
  /// no-op for this dispatch.
  static const skipCacheKey = 'skip-cache';

  /// Whether [ImageBytesSkipCacheMiddleware] should skip durable read/write.
  bool get skipCache => _map[skipCacheKey] == true;
  set skipCache(bool value) => _set(skipCacheKey, value ? true : null);

  void _set(String key, Object? value) {
    if (value == null) {
      _map.remove(key);
    } else {
      _map[key] = value;
    }
  }
}

// --- Sealed operations (never reclaim) ---

/// One cache verb sent through [CacheMiddleware].
///
/// Variants: read, write, evict, prune, close.
///
/// There is no reclaim variant on purpose. Orphan reclaim lives only on
/// [IndexedImageBytesCache] under its exclusive mutate gate. If middleware
/// could call reclaim, it could delete a blob while a write still held the
/// gate open.
sealed class CacheOperation {
  const CacheOperation();
}

/// Read [key].
final class CacheOperation$Read extends CacheOperation {
  /// Creates a read of [key].
  const CacheOperation$Read(this.key);

  /// Entry identity.
  final ImageCacheKey key;
}

/// Write [bytes] under [key].
///
/// Bytes only. Empty [bytes] still means eviction at the store, matching
/// [IImageBytesCache.write]. HTTP cache fields are not part of this op until
/// a store knows how to keep [ImageHttpCacheMeta].
final class CacheOperation$Write extends CacheOperation {
  /// Creates a write of [bytes] under [key].
  const CacheOperation$Write(this.key, this.bytes);

  /// Entry identity.
  final ImageCacheKey key;

  /// Payload. Empty lists evict [key] instead of retaining a zero-length row.
  final Uint8List bytes;
}

/// Delete [key] if present.
final class CacheOperation$Evict extends CacheOperation {
  /// Creates an eviction of [key].
  const CacheOperation$Evict(this.key);

  /// Entry identity.
  final ImageCacheKey key;
}

/// Run TTL and capacity eviction on the store.
final class CacheOperation$Prune extends CacheOperation {
  /// Creates a prune.
  const CacheOperation$Prune();
}

/// Release resources the store owns. Idempotent where the inner store is.
final class CacheOperation$Close extends CacheOperation {
  /// Creates a close.
  const CacheOperation$Close();
}

// --- Sealed results ---

/// Outcome of one [CacheOperation].
///
/// Middleware that returns the wrong variant for an op makes
/// [MiddlewareImageBytesCache] throw [StateError] on the public method that
/// expected a match.
sealed class CacheOperationResult {
  const CacheOperationResult();
}

/// [CacheOperation$Read] outcome. [hit] is null on miss.
final class CacheOperationResult$Read extends CacheOperationResult {
  /// Pass [hit] null for a miss.
  const CacheOperationResult$Read(this.hit);

  /// Bytes plus optional meta, or null when absent / expired / empty.
  final CacheReadHit? hit;
}

/// [CacheOperation$Write] completed.
final class CacheOperationResult$Write extends CacheOperationResult {
  /// Empty success marker.
  const CacheOperationResult$Write();
}

/// [CacheOperation$Evict] completed.
final class CacheOperationResult$Evict extends CacheOperationResult {
  /// Empty success marker.
  const CacheOperationResult$Evict();
}

/// [CacheOperation$Prune] completed with [report].
final class CacheOperationResult$Prune extends CacheOperationResult {
  /// Carries what the store removed.
  const CacheOperationResult$Prune(this.report);

  /// Keys and byte count the inner store dropped.
  final ImageBytesPruneReport report;
}

/// [CacheOperation$Close] completed.
final class CacheOperationResult$Close extends CacheOperationResult {
  /// Empty success marker.
  const CacheOperationResult$Close();
}

// --- Rich read hit + HTTP cache meta ---

/// What a cache read returns inside the middleware chain.
///
/// [IImageBytesCache.read] on [MiddlewareImageBytesCache] keeps returning
/// [Uint8List]? by taking [bytes] and dropping the rest. The ladder and
/// observing middleware need the optional timestamps and [httpCacheMeta]
/// without forcing every host call site to care.
@immutable
final class CacheReadHit {
  /// Non-empty [bytes] required. Stores scrub empty rows to miss first.
  const CacheReadHit({
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

  /// Validators / freshness. Null means the entry predates HTTP cache meta
  /// or the store has none yet.
  final ImageHttpCacheMeta? httpCacheMeta;
}

/// HTTP validators and freshness for one cached body.
///
/// Do not confuse this with [ImageBytesRetention] or [ImageBytesRecord]
/// timestamps. Those drive capacity and age eviction. This type is about
/// ETag / Last-Modified / Cache-Control style revalidation.
///
/// Every field is optional. Missing fields are a pre-ETag entry, not an
/// error. Index codecs that round-trip these fields land separately; rich
/// hits already use this shape in memory.
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

  /// `ETag` value, quotes included when the origin sent them.
  final String? etag;

  /// Raw `Last-Modified` header.
  final String? lastModified;

  /// Parsed `Date` when known.
  final DateTime? date;

  /// Parsed `Expires` when known.
  final DateTime? expires;

  /// Raw `Cache-Control`, or a lightly normalized copy of it.
  final String? cacheControl;

  /// `Age` as a duration when known.
  final Duration? age;

  /// When this entry was last confirmed still current after a 200 write or a
  /// 304.
  final DateTime? lastValidatedAt;
}

// --- Wrapper store ---

/// {@template middleware_image_bytes_cache}
/// [IImageBytesCache] that runs every call through a [CacheMiddleware] chain
/// and then into [inner].
///
/// Fold order: [middlewares] is outermost first. With an empty list,
/// [execute] and the public methods hit [inner] through the identity fold.
///
/// [read] still returns [Uint8List]?. A [CacheReadHit] from the chain is
/// unwrapped to its bytes; a null hit is a miss. Call [execute] when you need
/// the sealed result or a shared [CacheContext].
///
/// Reclaim is not a [CacheOperation]. If [inner] is [IndexedImageBytesCache],
/// reclaim stays behind that type's exclusive gate. This wrapper never
/// invents a reclaim path.
///
/// Wrong result variant for an op throws [StateError]. A write result on a
/// read is middleware breaking the grammar, not a store miss.
/// {@endtemplate}
final class MiddlewareImageBytesCache implements IImageBytesCache {
  /// {@macro middleware_image_bytes_cache}
  MiddlewareImageBytesCache({
    required this.inner,
    Iterable<CacheMiddleware>? middlewares,
  }) : middlewares = List<CacheMiddleware>.unmodifiable(
         middlewares ?? const <CacheMiddleware>[],
       ) {
    final pipeline = CacheMiddlewareWrapper.merge([...this.middlewares]);
    _handler = pipeline(_terminal(inner));
  }

  /// Store at the end of the chain. Tests usually pass [MemoryImageBytesCache].
  final IImageBytesCache inner;

  /// Outermost first. Immutable after construction.
  final List<CacheMiddleware> middlewares;

  late final CacheHandler _handler;

  /// Runs [operation] through the middleware chain.
  ///
  /// Omitting [context] uses [CacheContext.empty], same as [read] / [write]
  /// / [evict] / [prune] / [close] on this type.
  Future<CacheOperationResult> execute(
    CacheOperation operation, [
    CacheContext? context,
  ]) => _handler(operation, context ?? CacheContext.empty());

  /// Cached bytes for [key], or null on miss.
  ///
  /// Drops [CacheReadHit] meta. Use [execute] with [CacheOperation$Read] when
  /// you need [CacheReadHit.httpCacheMeta] or timestamps.
  @override
  Future<Uint8List?> read(ImageCacheKey key) async {
    final result = await execute(CacheOperation$Read(key));
    return switch (result) {
      CacheOperationResult$Read(:final hit?) => hit.bytes,
      CacheOperationResult$Read() => null,
      _ => throw StateError(
        'Cache middleware returned ${result.runtimeType} for read; '
        'expected CacheOperationResult.Read',
      ),
    };
  }

  /// Writes [bytes] under [key] as [CacheOperation$Write].
  @override
  Future<void> write(ImageCacheKey key, Uint8List bytes) async {
    final result = await execute(CacheOperation$Write(key, bytes));
    switch (result) {
      case CacheOperationResult$Write():
        return;
      case _:
        throw StateError(
          'Cache middleware returned ${result.runtimeType} for write; '
          'expected CacheOperationResult.Write',
        );
    }
  }

  /// Deletes [key] as [CacheOperation$Evict].
  @override
  Future<void> evict(ImageCacheKey key) async {
    final result = await execute(CacheOperation$Evict(key));
    switch (result) {
      case CacheOperationResult$Evict():
        return;
      case _:
        throw StateError(
          'Cache middleware returned ${result.runtimeType} for evict; '
          'expected CacheOperationResult.Evict',
        );
    }
  }

  /// Prunes via [CacheOperation$Prune] and returns the store's report.
  @override
  Future<ImageBytesPruneReport> prune() async {
    final result = await execute(const CacheOperation$Prune());
    return switch (result) {
      CacheOperationResult$Prune(:final report) => report,
      _ => throw StateError(
        'Cache middleware returned ${result.runtimeType} for prune; '
        'expected CacheOperationResult.Prune',
      ),
    };
  }

  /// Closes via [CacheOperation$Close].
  @override
  Future<void> close() async {
    final result = await execute(const CacheOperation$Close());
    switch (result) {
      case CacheOperationResult$Close():
        return;
      case _:
        throw StateError(
          'Cache middleware returned ${result.runtimeType} for close; '
          'expected CacheOperationResult.Close',
        );
    }
  }

  static CacheHandler _terminal(IImageBytesCache store) => (operation, _) async {
    // Reclaim is unreachable here. It is not a CacheOperation.
    switch (operation) {
      case CacheOperation$Read(:final key):
        return CacheOperationResult$Read(
          switch (await store.read(key)) {
            final bytes? => CacheReadHit(bytes: bytes),
            null => null,
          },
        );
      case CacheOperation$Write(:final key, :final bytes):
        await store.write(key, bytes);
        return const CacheOperationResult$Write();
      case CacheOperation$Evict(:final key):
        await store.evict(key);
        return const CacheOperationResult$Evict();
      case CacheOperation$Prune():
        return CacheOperationResult$Prune(await store.prune());
      case CacheOperation$Close():
        await store.close();
        return const CacheOperationResult$Close();
    }
  };
}
