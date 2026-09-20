import 'dart:developer' as developer;

import 'package:image_bytes_cache/src/cache/cache_middleware.dart';
import 'package:meta/meta.dart';

/// {@template image_bytes_cache_logger_middleware_developer}
/// Opt-in cache logger that records hit / miss / evict / prune via
/// [developer.log] (name `image_bytes_cache`).
///
/// Observes only — does not alter stored bytes, open its own durable IO, or
/// invent a reclaim path (reclaim is not a [CacheOperation]).
///
/// Place **outermost** in the middleware list so the stopwatch covers the full
/// inner chain (including [ImageBytesSkipCacheMiddleware] when stacked inside).
///
/// ```dart
/// MiddlewareImageBytesCache(
///   inner: store,
///   middlewares: <CacheMiddleware>[
///     const ImageBytesCacheLoggerMiddleware$Developer(), // outermost
///     const ImageBytesSkipCacheMiddleware(),
///   ],
/// );
/// ```
/// {@endtemplate}
@immutable
final class ImageBytesCacheLoggerMiddleware$Developer {
  /// {@macro image_bytes_cache_logger_middleware_developer}
  const ImageBytesCacheLoggerMiddleware$Developer({
    this.logOperation = false,
    this.logResult = true,
    this.logError = true,
    @visibleForTesting this.debugEmit,
  });

  /// When true, emits a line before the inner handler runs.
  final bool logOperation;

  /// When true, emits on a successful result (hit/miss/evict/prune/…).
  final bool logResult;

  /// When true, emits on a thrown error (then rethrows).
  final bool logError;

  /// Test override for [developer.log]. Production code leaves this null.
  @visibleForTesting
  final void Function(
    String message, {
    required int level,
    StackTrace? stackTrace,
  })?
  debugEmit;

  /// Calls the inner handler, logging around it.
  CacheHandler call(CacheHandler innerHandler) => (operation, context) async {
    final stopwatch = Stopwatch()..start();
    final label = _label(operation);
    try {
      if (logOperation) {
        _emit(label, level: 300);
      }
      final result = await innerHandler(operation, context);
      if (logResult) {
        _emit(
          '$label -> ${_outcome(operation, result)} | '
          '${stopwatch.elapsedMilliseconds}ms',
          level: 300,
        );
      }
      return result;
    } on Object catch (e, s) {
      if (logError) {
        _emit(
          '$label -> error($e) | ${stopwatch.elapsedMilliseconds}ms',
          level: 900,
          stackTrace: s,
        );
      }
      rethrow;
    } finally {
      stopwatch.stop();
    }
  };

  static String _label(CacheOperation operation) => switch (operation) {
    CacheOperation$Read(:final key) => 'read ${key.value}',
    CacheOperation$Write(:final key) => 'write ${key.value}',
    CacheOperation$Evict(:final key) => 'evict ${key.value}',
    CacheOperation$Prune() => 'prune',
    CacheOperation$Close() => 'close',
  };

  static String _outcome(CacheOperation operation, CacheOperationResult result) {
    return switch ((operation, result)) {
      (CacheOperation$Read(), CacheOperationResult$Read(:final hit?)) => 'read hit (${hit.bytes.length} bytes)',
      (CacheOperation$Read(), CacheOperationResult$Read()) => 'read miss',
      (CacheOperation$Write(), CacheOperationResult$Write()) => 'write ok',
      (CacheOperation$Evict(), CacheOperationResult$Evict()) => 'evict ok',
      (CacheOperation$Prune(), CacheOperationResult$Prune(:final report)) =>
        'prune ok (keys=${report.evictedKeys.length}, '
            'bytes=${report.freedBytes})',
      (CacheOperation$Close(), CacheOperationResult$Close()) => 'close ok',
      _ => 'unexpected ${result.runtimeType}',
    };
  }

  void _emit(
    String message, {
    required int level,
    StackTrace? stackTrace,
  }) {
    try {
      if (debugEmit case final emit?) {
        emit(message, level: level, stackTrace: stackTrace);
        return;
      }
      developer.log(
        message,
        name: 'image_bytes_cache',
        time: DateTime.now(),
        level: level,
        stackTrace: stackTrace,
      );
    } on Object {
      // Log sinks are best-effort — never fail the cache op.
    }
  }
}
