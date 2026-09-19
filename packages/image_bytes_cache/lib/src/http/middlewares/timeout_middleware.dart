import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:image_bytes_cache/src/http/http_bytes_fetcher.dart';
import 'package:meta/meta.dart';

/// {@template http_bytes_timeout}
/// Bounds a send with two independent timeouts:
/// - [connectTimeout] — time to receive the response **headers** (`.timeout()` on the send);
/// - [receiveTimeout] — max **idle** gap while the response body is being read (a steady
///   download never trips it; a stalled server does).
///
/// On either timeout the request's [CancelToken] is cancelled (aborting the
/// socket) and an [HttpBytesException$Timeout] is surfaced. The caller sees
/// timeout, not cancellation, because we stopped awaiting or errored the stream.
///
/// Defaults are 15 seconds each. Per-request overrides via
/// [HttpBytesContext.connectTimeout] / [HttpBytesContext.receiveTimeout].
/// {@endtemplate}
@immutable
class HttpBytesTimeoutMiddleware {
  /// {@macro http_bytes_timeout}
  const HttpBytesTimeoutMiddleware({
    this.connectTimeout = const Duration(seconds: 15),
    this.receiveTimeout = const Duration(seconds: 15),
    this.duration,
    this.onTimeout,
  });

  /// Time allowed to receive the response headers. Overridable per request via
  /// [HttpBytesContext.connectTimeout].
  final Duration connectTimeout;

  /// Max idle gap allowed between response-body chunks. Overridable per request via
  /// [HttpBytesContext.receiveTimeout].
  final Duration receiveTimeout;

  /// Back-compat alias for [connectTimeout]: when provided it overrides the connect default.
  final Duration? duration;

  /// Optional callback invoked with the elapsed limit when a timeout fires.
  final void Function(Duration duration)? onTimeout;

  /// Calls the inner handler with the modified request.
  HttpBytesHandler call(
    HttpBytesHandler innerHandler,
  ) => (request, context) async {
    final connect = _resolve(
      context.connectTimeout,
      duration ?? connectTimeout,
    );
    final receive = _resolve(
      context.receiveTimeout,
      receiveTimeout,
    );

    // --- connect timeout: request → response headers ---
    final HttpBytesResponse response;
    final inner = innerHandler(request, context);
    if (connect == null) {
      response = await inner;
    } else {
      try {
        response = await inner.timeout(connect);
      } on TimeoutException catch (e, s) {
        // Abort the underlying socket so it stops consuming bandwidth —
        // `.timeout()` alone only stops awaiting.
        context.cancelToken?.cancel(e);
        onTimeout?.call(connect);
        Error.throwWithStackTrace(
          HttpBytesException$Timeout(
            code: 'timeout',
            message: 'Request timed out after ${connect.inMilliseconds}ms',
            statusCode: 408,
            duration: connect,
            error: e,
            data: <String, Object?>{'url': request.url.toString()},
          ),
          s,
        );
      }
    }

    // --- receive timeout: idle gap while reading the body ---
    // Wrap the body stream with an idle timer; it fires only while the caller
    // consumes the body (after this middleware returns).
    if (receive == null) return response;
    final wrapped = response.stream.timeout(
      receive,
      onTimeout: (sink) {
        context.cancelToken?.cancel();
        onTimeout?.call(receive);
        sink.addError(
          HttpBytesException$Timeout(
            code: 'receive_timeout',
            message: 'No data received for ${receive.inMilliseconds}ms',
            statusCode: 408,
            duration: receive,
            data: <String, Object?>{'url': request.url.toString()},
          ),
        );
      },
    );
    return response.clone(stream: http.ByteStream(wrapped));
  };

  /// Resolves a context timeout value ([Duration] / `int` ms / [DateTime] deadline)
  /// to a [Duration], or `null` to disable. Missing/unknown falls back to [fallback].
  static Duration? _resolve(Object? raw, Duration fallback) => switch (raw) {
    final Duration d when d > Duration.zero => d,
    final int ms when ms > 0 => Duration(milliseconds: ms),
    final DateTime d when d.isAfter(DateTime.now()) => d.difference(DateTime.now()).abs(),
    Duration() || int() || DateTime() => null, // explicit zero/past ⇒ disabled
    _ => fallback,
  };
}
