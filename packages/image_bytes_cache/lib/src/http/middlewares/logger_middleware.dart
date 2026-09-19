import 'dart:developer' as developer;

import 'package:image_bytes_cache/src/http/http_bytes_fetcher.dart';
import 'package:meta/meta.dart';

/// {@template http_bytes_logger_middleware_developer}
/// Opt-in HTTP logger that records method, URL, outcome, and latency via
/// [developer.log] (name `http_bytes`).
///
/// Place **outermost** in the middleware list so the stopwatch covers the full
/// inner chain (including [HttpBytesRetryMiddleware] when stacked inside).
///
/// ```dart
/// HttpBytesFetcher(
///   middlewares: <HttpBytesMiddleware>[
///     const HttpBytesLoggerMiddleware$Developer(), // outermost
///     HttpBytesRetryMiddleware(),
///     const HttpBytesTimeoutMiddleware(),
///   ],
/// );
/// ```
/// {@endtemplate}
@immutable
final class HttpBytesLoggerMiddleware$Developer {
  /// {@macro http_bytes_logger_middleware_developer}
  const HttpBytesLoggerMiddleware$Developer({
    this.logRequest = false,
    this.logResponse = true,
    this.logError = true,
    @visibleForTesting this.debugEmit,
  });

  /// When true, emits a line before the inner handler runs.
  final bool logRequest;

  /// When true, emits on a successful response.
  final bool logResponse;

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
  HttpBytesHandler call(
    HttpBytesHandler innerHandler,
  ) => (request, context) async {
    final stopwatch = Stopwatch()..start();
    final label = '[${request.method}] ${request.url}';
    try {
      if (logRequest) {
        _emit(label, level: 300);
      }
      final response = await innerHandler(request, context);
      if (logResponse) {
        _emit(
          '$label -> ${response.statusCode} | ${stopwatch.elapsedMilliseconds}ms',
          level: 300,
        );
      }
      return response;
    } on Object catch (e, s) {
      if (logError) {
        final code = switch (e) {
          HttpBytesException(:final code) => code,
          _ => 'error',
        };
        _emit(
          '$label -> $code | ${stopwatch.elapsedMilliseconds}ms',
          level: 900,
          stackTrace: s,
        );
      }
      rethrow;
    } finally {
      stopwatch.stop();
    }
  };

  void _emit(
    String message, {
    required int level,
    StackTrace? stackTrace,
  }) {
    try {
      final emit = debugEmit;
      if (emit != null) {
        emit(message, level: level, stackTrace: stackTrace);
        return;
      }
      developer.log(
        message,
        name: 'http_bytes',
        time: DateTime.now(),
        level: level,
        stackTrace: stackTrace,
      );
    } on Object {
      // Log sinks are best-effort — never fail the send.
    }
  }
}
