import 'dart:math' as math;

import 'package:image_bytes_cache/src/http/http_bytes_fetcher.dart';
import 'package:image_bytes_cache/src/http/retry_backoff.dart';
import 'package:meta/meta.dart';

/// HTTP methods safe to retry automatically.
const _kIdempotentMethods = <String>{
  'GET',
  'HEAD',
  'PUT',
  'DELETE',
  'OPTIONS',
  'TRACE',
};

/// Upper bound on a server-provided `Retry-After` delay (server is authoritative;
/// [HttpBytesRetryBackoff.maxElapsed] is the real ceiling).
const _kMaxRetryAfter = Duration(seconds: 60);

/// Parses a delta-seconds `Retry-After` from a 429/503 [HttpBytesException]
/// (capped at [_kMaxRetryAfter]). Returns `null` when absent or not delta-seconds.
///
/// The HTTP-date form is intentionally not parsed: rare in
/// practice; callers fall back to full-jitter backoff.
Duration? _retryAfter(Object error) {
  if (error case HttpBytesException(:final data)) {
    if (data case <String, Object?>{'retry-after': final String ra}) {
      final seconds = int.tryParse(ra.trim());
      if (seconds != null && seconds >= 0) {
        final d = Duration(seconds: seconds);
        return d > _kMaxRetryAfter ? _kMaxRetryAfter : d;
      }
    }
  }
  return null;
}

/// {@template http_bytes_retry}
/// Transient-retry layer for image HTTP GETs: retries idempotent requests with
/// full-jitter exponential backoff ([HttpBytesRetryBackoff]), honoring `Retry-After`
/// and a total time budget.
///
/// Opt-in — not part of the default [HttpBytesFetcher] middleware list. Place
/// **outside** [HttpBytesTimeoutMiddleware] so each attempt gets a fresh connect/receive
/// budget:
/// ```dart
/// HttpBytesFetcher(
///   middlewares: [
///     HttpBytesRetryMiddleware(),
///     const HttpBytesTimeoutMiddleware(),
///   ],
/// );
/// ```
///
/// Classification: [retryEvaluator] or [defaultRetryEvaluator]. Do not nest
/// another retry layer above the ladder.
/// {@endtemplate}
@immutable
class HttpBytesRetryMiddleware {
  /// {@macro http_bytes_retry}
  HttpBytesRetryMiddleware({
    this.backoff = const HttpBytesRetryBackoff(),
    this.retryEvaluator,
    math.Random? random,
  }) : _random = random ?? math.Random();

  /// Jitter source; injectable for deterministic tests.
  final math.Random _random;

  /// Backoff policy: max retries, full-jitter delays, total budget.
  final HttpBytesRetryBackoff backoff;

  /// Overrides [defaultRetryEvaluator] for deciding whether an error is retryable.
  final bool Function(Object error, int attempt)? retryEvaluator;

  /// Transient failures only. Used when [retryEvaluator] is omitted.
  ///
  /// `$Cancelled` / `$Timeout` are also blocked as a mechanic in [call] (their
  /// abort token is already completed). `$Authentication` is never retried.
  static bool defaultRetryEvaluator(
    Object error,
    int attempt,
  ) => switch (error) {
    HttpBytesException$Authentication() => false,
    HttpBytesException$Cancelled() || HttpBytesException$Timeout() => false,
    HttpBytesException(:final statusCode) => const <int>{
      0,
      408,
      425,
      429,
      500,
      502,
      503,
      504,
      509,
    }.contains(statusCode),
    _ => false,
  };

  /// Calls the inner handler with the modified request.
  HttpBytesHandler call(
    HttpBytesHandler innerHandler,
  ) => (request, context) async {
    final retries = context.retries ?? backoff.maxRetries;
    final idempotent = _kIdempotentMethods.contains(request.method.toUpperCase()) || context.retryNonIdempotent;

    final shouldNotRetry = context.noRetry || retries < 1 || !idempotent || !request.canBeRetried;
    if (shouldNotRetry) return innerHandler(request, context);

    final evaluate = retryEvaluator ?? defaultRetryEvaluator;
    var attempt = 0;
    var clonedRequest = request;
    final stopwatch = Stopwatch()..start();
    while (true) {
      try {
        return await innerHandler(clonedRequest, context);
      } on Object catch (e) {
        final mechanicForbidsRetry = switch (e) {
          HttpBytesException$Cancelled() || HttpBytesException$Timeout() => true,
          _ => false,
        };
        if (mechanicForbidsRetry || attempt >= retries || !evaluate(e, attempt)) {
          rethrow;
        }
        final delay = _retryAfter(e) ?? backoff.backoff(attempt, _random);
        if (!backoff.withinBudget(stopwatch.elapsed, delay)) rethrow;
        await Future<void>.delayed(delay);
        attempt++;
        clonedRequest = clonedRequest.clone();
      }
    }
  };
}
