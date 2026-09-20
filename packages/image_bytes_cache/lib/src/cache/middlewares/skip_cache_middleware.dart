import 'package:image_bytes_cache/src/cache/cache_middleware.dart';
import 'package:meta/meta.dart';

/// {@template skip_cache_middleware}
/// Opt-in skip-cache policy: when [CacheContext.skipCache] is true (or
/// [shouldSkip] returns true), reads return a miss and writes are no-ops
/// without calling the inner store.
///
/// Evict, prune, and close still forward. Skip means do not read or retain
/// bytes for this dispatch, not disable the store. Does not disable HTTP; the
/// ladder still fetches. Composes with revalidation later: skip is no durable
/// store, not ignore validators on a store you skipped.
///
/// Seed via [MiddlewareImageBytesCache.execute] with a shared [CacheContext]
/// (resolver plumbing will set [CacheContext.skipCache] end-to-end). Public
/// [IImageBytesCache.read] / [IImageBytesCache.write] on the wrapper use an
/// empty context, so they only skip when [shouldSkip] decides without the flag.
///
/// ```dart
/// final cache = MiddlewareImageBytesCache(
///   inner: store,
///   middlewares: <CacheMiddleware>[const SkipCacheMiddleware()],
/// );
/// await cache.execute(
///   CacheOperation$Read(key),
///   CacheContext.empty()..skipCache = true,
/// );
/// ```
/// {@endtemplate}
@immutable
final class SkipCacheMiddleware {
  /// {@macro skip_cache_middleware}
  const SkipCacheMiddleware({this.shouldSkip});

  /// Optional host policy. Combined with [CacheContext.skipCache] via OR:
  /// either the context flag or a true predicate skips.
  final bool Function(CacheOperation operation, CacheContext context)? shouldSkip;

  /// Wraps [innerHandler] with skip-cache short-circuit on read/write.
  CacheHandler call(CacheHandler innerHandler) => (operation, context) async {
    if (!_skip(operation, context)) {
      return innerHandler(operation, context);
    }
    return switch (operation) {
      CacheOperation$Read() => const CacheOperationResult$Read(null),
      CacheOperation$Write() => const CacheOperationResult$Write(),
      CacheOperation$Evict() || CacheOperation$Prune() || CacheOperation$Close() => innerHandler(operation, context),
    };
  };

  bool _skip(CacheOperation operation, CacheContext context) {
    if (context.skipCache) return true;
    return shouldSkip?.call(operation, context) ?? false;
  }
}
