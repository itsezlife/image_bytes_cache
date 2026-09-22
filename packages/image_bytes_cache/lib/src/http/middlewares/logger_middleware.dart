import 'dart:async';
import 'dart:developer' as developer;

import 'package:http/http.dart' as http;
import 'package:image_bytes_cache/src/http/http_bytes_client.dart';
import 'package:meta/meta.dart';

/// {@template http_bytes_logger_middleware_developer}
/// Opt-in HTTP logger that records method, URL, outcome, downloaded size, and
/// latency via [developer.log] (name `http_bytes`).
///
/// Place **outermost** in the middleware list so the stopwatch covers the full
/// inner chain (including [HttpBytesRetryMiddleware] when stacked inside).
///
/// For streaming starters, size is counted as the body is read (log emits when
/// the stream completes). Joiners with a buffered [HttpBytesResponse.body] log
/// immediately from that length.
///
/// ```dart
/// HttpBytesClient(
///   middlewares: <HttpBytesMiddleware>[
///     const HttpBytesLoggerMiddleware$Developer(), // outermost
///     HttpBytesRetryMiddleware(),
///     const HttpBytesTimeoutMiddleware(),
///     HttpBytesBearerMiddleware(getToken: getToken),
///     const HttpBytesConditionalMiddleware(),
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
      if (!logResponse) {
        stopwatch.stop();
        return response;
      }

      // Joiner / already-buffered body — log exact size now.
      if (response.body case final body?) {
        stopwatch.stop();
        _emit(
          '$label -> ${response.statusCode} | '
          '${_formatByteCount(body.lengthInBytes)} | '
          '${stopwatch.elapsedMilliseconds}ms',
          level: 300,
        );
        return response;
      }

      // Starter: count bytes as the body streams so the log reflects what was
      // actually downloaded (Content-Length alone can be missing or wrong).
      var received = 0;
      final counted = response.stream.transform(
        StreamTransformer<List<int>, List<int>>.fromHandlers(
          handleData: (data, sink) {
            received += data.length;
            sink.add(data);
          },
          handleDone: (sink) {
            stopwatch.stop();
            _emit(
              '$label -> ${response.statusCode} | '
              '${_formatByteCount(received)} | '
              '${stopwatch.elapsedMilliseconds}ms',
              level: 300,
            );
            sink.close();
          },
          handleError: (error, stackTrace, sink) {
            if (logError) {
              stopwatch.stop();
              final code = switch (error) {
                HttpBytesException(:final code) => code,
                _ => 'error',
              };
              _emit(
                '$label -> $code | '
                '${_formatByteCount(received)} | '
                '${stopwatch.elapsedMilliseconds}ms',
                level: 900,
                stackTrace: stackTrace,
              );
            }
            sink.addError(error, stackTrace);
          },
        ),
      );
      return response.clone(stream: http.ByteStream(counted));
    } on Object catch (e, s) {
      stopwatch.stop();
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

/// Compact, developer-friendly size: `384 B`, `12.4 KB`, `1.8 MB`, …
String _formatByteCount(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${_prettyFixed(kb)} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${_prettyFixed(mb)} MB';
  return '${_prettyFixed(mb / 1024)} GB';
}

String _prettyFixed(double value) => value < 10 ? value.toStringAsFixed(1) : value.round().toString();
