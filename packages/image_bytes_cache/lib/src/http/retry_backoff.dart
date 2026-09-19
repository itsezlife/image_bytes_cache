import 'dart:math' as math;

import 'package:meta/meta.dart';

/// {@template http_bytes_retry_backoff}
/// Full-jitter exponential backoff for [HttpBytesRetryMiddleware].
///
/// Delay for attempt `n` (0-based, before the next try) is
/// `random(0, min(maxDelay, initialDelay × factorⁿ))`. [maxElapsed] is the
/// total wall-clock budget across sleeps; [maxRetries] caps attempt count.
/// {@endtemplate}
@immutable
final class HttpBytesRetryBackoff {
  /// {@macro http_bytes_retry_backoff}
  const HttpBytesRetryBackoff({
    this.maxRetries = 3,
    this.initialDelay = const Duration(milliseconds: 200),
    this.maxDelay = const Duration(seconds: 10),
    this.maxElapsed = const Duration(seconds: 30),
    this.factor = 2.0,
  }) : assert(maxRetries >= 0, 'maxRetries must be >= 0'),
       assert(factor >= 1.0, 'factor must be >= 1.0');

  /// Maximum number of **retries** after the first attempt (not total tries).
  final int maxRetries;

  /// Base delay before the first retry (attempt 0).
  final Duration initialDelay;

  /// Cap on any single backoff delay.
  final Duration maxDelay;

  /// Total wall-clock budget for all sleeps; if the next delay would exceed
  /// it, retry stops and the last error is rethrown.
  final Duration maxElapsed;

  /// Exponential growth multiplier (`initialDelay × factorⁿ`).
  final double factor;

  /// Full-jitter delay for [attempt] (0 = first retry).
  Duration backoff(int attempt, math.Random random) {
    final baseMicros = initialDelay.inMicroseconds * math.pow(factor, attempt);
    final capMicros = maxDelay.inMicroseconds.toDouble();
    final window = math.min(capMicros, baseMicros.toDouble());
    final jittered = random.nextDouble() * window;
    return Duration(microseconds: jittered.round());
  }

  /// Whether sleeping [delay] after [elapsed] still fits [maxElapsed].
  bool withinBudget(Duration elapsed, Duration delay) => elapsed + delay <= maxElapsed;
}
