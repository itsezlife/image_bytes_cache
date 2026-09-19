import 'dart:async';
import 'dart:typed_data';

import 'package:cancel_token/cancel_token.dart';
import 'package:http/http.dart' as http;
import 'package:image_bytes_cache/src/http/middlewares/timeout_middleware.dart';
import 'package:image_bytes_cache/src/image_bytes_cache.dart';
import 'package:meta/meta.dart';
import 'package:pool/pool.dart';

/// Observes cumulative HTTP body bytes while a network GET consolidates.
typedef ImageBytesProgressCallback = void Function(int cumulative, int? total);

/// A function that takes an [HttpBytesRequest] and returns an [HttpBytesResponse].
/// The [context] map stores data available to all middleware for this send.
typedef HttpBytesHandler =
    Future<HttpBytesResponse> Function(
      HttpBytesRequest request,
      Map<String, Object?> context,
    );

/// A function that takes an [HttpBytesHandler] and returns an [HttpBytesHandler].
typedef HttpBytesMiddleware = HttpBytesHandler Function(HttpBytesHandler innerHandler);

/// A wrapper for [HttpBytesMiddleware] that allows for optional handlers.
// ignore: avoid-implicitly-nullable-extension-types, prefer-declaring-const-constructor
extension type HttpBytesMiddlewareWrapper._(HttpBytesMiddleware _fn) {
  /// Creates a new [HttpBytesMiddleware] from the given callbacks.
  factory HttpBytesMiddlewareWrapper({
    Future<void> Function(
      HttpBytesRequest request,
      Map<String, Object?> context,
    )?
    onRequest,
    Future<void> Function(
      HttpBytesResponse response,
      Map<String, Object?> context,
    )?
    onResponse,
    Future<void> Function(
      Object error,
      StackTrace stackTrace,
      Map<String, Object?> context,
    )?
    onError,
  }) => HttpBytesMiddlewareWrapper._(
    (innerHandler) => (request, context) async {
      await onRequest?.call(request, context);
      try {
        final response = await innerHandler(request, context);
        await onResponse?.call(response, context);
        return response;
      } on Object catch (error, stackTrace) {
        await onError?.call(error, stackTrace, context);
        rethrow;
      }
    },
  );

  /// Merges [middlewares] into one [HttpBytesMiddleware].
  ///
  /// List order is outermost first: the first entry wraps every later one.
  factory HttpBytesMiddlewareWrapper.merge(
    List<HttpBytesMiddleware> middlewares,
  ) => HttpBytesMiddlewareWrapper._(switch (middlewares.length) {
    0 => (handler) => handler,
    1 => middlewares.single,
    _ => (handler) => middlewares.reversed.fold(
      handler,
      (handler, middleware) => middleware(handler),
    ),
  });

  /// Call the wrapped [HttpBytesMiddleware] with the given [innerHandler].
  HttpBytesHandler call(HttpBytesHandler innerHandler) => _fn(innerHandler);
}

/// Context keys shared across middleware for one send.
///
/// Values live on the per-send `context` map.
abstract final class HttpBytesContextKeys {
  /// Effective per-send [CancelToken] (abort signal for AbortableRequest).
  static const cancelToken = 'cancelToken';

  /// Per-request connect timeout override ([Duration] / `int` ms / [DateTime]).
  static const connectTimeout = 'connect-timeout';

  /// Per-request receive (idle-gap) timeout override ([Duration] / `int` ms).
  static const receiveTimeout = 'receive-timeout';

  /// Legacy/alias for [connectTimeout].
  static const timeout = 'timeout';

  /// Legacy/alias for [connectTimeout].
  static const duration = 'duration';

  /// `ImageBytesProgressCallback` invoked while the response body is read.
  static const onBytesProgress = 'on-bytes-progress';

  /// `bool Function(int statusCode)` success predicate; default is 2xx.
  static const validateStatus = 'validate-status';

  /// When `true`, [HttpBytesRetryMiddleware] skips retry for this send.
  static const noRetry = 'no-retry';

  /// Override [HttpBytesRetryBackoff.maxRetries] for this send (`int` > 0).
  static const retries = 'retries';

  /// When `true`, allow retry even if the method is not idempotent.
  static const retryNonIdempotent = 'retry-non-idempotent';
}

// --- Request / response ---

/// HTTP request wrapping a [http.BaseRequest].
///
/// Middlewares may [clone] to adjust method, URL, or headers while keeping the
/// same abort trigger when the underlying request is [http.Abortable].
extension type const HttpBytesRequest(http.BaseRequest _request) implements http.BaseRequest {
  /// Whether [clone] can replay this request for [HttpBytesRetryMiddleware].
  ///
  /// True for [http.Request] / [http.AbortableRequest] (buffered body). False
  /// for streamed/multipart bodies that cannot be re-sent after the first pass.
  bool get canBeRetried => _request is http.Request;

  /// Creates a clone with optional parameter overrides.
  ///
  /// Preserves cancellation: rebuilds an [http.AbortableRequest] carrying the
  /// same [http.Abortable.abortTrigger] when present. Copies a buffered body
  /// when [source] is an [http.Request] so retries replay the same payload.
  HttpBytesRequest clone({
    String? method,
    Uri? url,
    Map<String, String>? headers,
    int? maxRedirects,
  }) {
    final source = _request;
    final abortTrigger = source is http.Abortable ? source.abortTrigger : null;
    final newRequest = abortTrigger == null
        ? http.Request(method ?? source.method, url ?? source.url)
        : http.AbortableRequest(
            method ?? source.method,
            url ?? source.url,
            abortTrigger: abortTrigger,
          );

    newRequest.headers.addAll(source.headers);
    if (headers != null) {
      newRequest.headers.addAll(headers);
    }

    if (source is http.Request) {
      newRequest.bodyBytes = source.bodyBytes;
    }

    newRequest
      ..maxRedirects = maxRedirects ?? source.maxRedirects
      ..followRedirects = source.followRedirects;

    return HttpBytesRequest(newRequest);
  }
}

/// HTTP response from [HttpBytesFetcher]: status, headers, and body stream.
///
/// [stream] is single-subscription. After [_sendUnstreamed] finishes the body
/// for coalesce, [body] holds the same bytes so joiners can call [toBytes]
/// without re-listening.
@immutable
final class HttpBytesResponse {
  /// Create a new HTTP response.
  const HttpBytesResponse({
    required this.statusCode,
    required this.headers,
    required this.contentLength,
    required this.request,
    required this.stream,
    this.body,
  });

  /// HTTP status code.
  final int statusCode;

  /// Response headers as received.
  final Map<String, String> headers;

  /// Declared Content-Length when present; otherwise `0`.
  final int contentLength;

  /// The request that produced this response.
  final HttpBytesRequest request;

  /// Byte stream of the response body (single-subscription).
  final http.ByteStream stream;

  /// Consolidated body when the fetcher has already consumed [stream].
  final Uint8List? body;

  /// Returns the response body as bytes.
  ///
  /// Prefers [body] when present; otherwise consumes [stream] (read once).
  Future<Uint8List> toBytes() {
    final cached = body;
    if (cached != null) return Future<Uint8List>.value(cached);
    return stream.toBytes();
  }

  /// Creates a clone with optional parameter overrides.
  HttpBytesResponse clone({
    int? statusCode,
    Map<String, String>? headers,
    int? contentLength,
    HttpBytesRequest? request,
    http.ByteStream? stream,
    Uint8List? body,
  }) => HttpBytesResponse(
    statusCode: statusCode ?? this.statusCode,
    headers: headers ?? Map<String, String>.of(this.headers),
    contentLength: contentLength ?? this.contentLength,
    request: request ?? this.request,
    stream: stream ?? this.stream,
    body: body ?? this.body,
  );
}

// --- Fetcher ---

/// {@template http_bytes_fetcher}
/// HTTP GET for response bodies, with middlewares, concurrency cap, and
/// in-flight coalescing.
/// {@endtemplate}
final class HttpBytesFetcher {
  /// {@macro http_bytes_fetcher}
  HttpBytesFetcher({
    http.Client? client,
    int maxConcurrent = 6,
    Iterable<HttpBytesMiddleware>? middlewares,
    this.validateStatus,
  }) : assert(maxConcurrent > 0, 'maxConcurrent must be > 0'),
       middlewares = List<HttpBytesMiddleware>.unmodifiable(
         middlewares ?? <HttpBytesMiddleware>[const HttpBytesTimeoutMiddleware()],
       ) {
    final internalClient = client ?? http.Client();
    _ownsClient = client == null;
    _client = internalClient;
    _pool = Pool(maxConcurrent);
    final pipeline = HttpBytesMiddlewareWrapper.merge([...this.middlewares]);
    _handler = _createHandler(
      internalClient,
      pipeline,
      validateStatus,
    );
  }

  /// Process-wide default when nothing is injected.
  factory HttpBytesFetcher.shared() {
    _$ensureResetSharedCleanup();
    return debugShared ?? (_shared ??= HttpBytesFetcher());
  }

  static HttpBytesFetcher? _shared;

  /// Test override for [HttpBytesFetcher.shared]. Set to `null` to clear.
  @visibleForTesting
  static HttpBytesFetcher? debugShared;

  /// Sets the process-wide fetcher (bootstrap).
  static Future<void> configure(HttpBytesFetcher fetcher) async {
    _$ensureResetSharedCleanup();
    final previous = _shared;
    if (previous != null && !identical(previous, fetcher)) {
      await previous.close();
    }
    _shared = fetcher;
  }

  /// Closes the previous shared instance, then clears [configure] and [debugShared].
  @visibleForTesting
  static Future<void> resetShared() async {
    final previous = _shared;
    debugShared = null;
    await previous?.close();
    _shared = null;
  }

  static var _$resetSharedCleanupInstalled = false;

  static void _$ensureResetSharedCleanup() {
    if (_$resetSharedCleanupInstalled) return;
    _$resetSharedCleanupInstalled = true;
    ImageBytesCache.addAfterResetShared(resetShared);
  }

  late final http.Client _client;
  late final bool _ownsClient;
  late final Pool _pool;

  /// Composed middleware chain ending at [http.Client.send].
  late final HttpBytesHandler _handler;

  final Map<String, Future<HttpBytesResponse>> _inFlight = {};

  var _closed = false;

  /// Immutable list of middlewares to apply for each send.
  final List<HttpBytesMiddleware> middlewares;

  /// Decides whether a response [statusCode] is a success. Defaults to 2xx.
  /// Overridable per request via [HttpBytesContextKeys.validateStatus].
  final bool Function(int statusCode)? validateStatus;

  /// Runs [request] through middlewares (delegates to [_sendUnstreamed]).
  Future<HttpBytesResponse> send(
    HttpBytesRequest request, {
    Map<String, Object?>? context,
    CancelToken? cancelToken,
    ImageBytesProgressCallback? onBytesProgress,
  }) => _sendUnstreamed(
    url: request.url,
    headers: request.headers,
    context: context,
    cancelToken: cancelToken,
    onBytesProgress: onBytesProgress,
  );

  /// GETs [url] and returns the response body (delegates to [_sendUnstreamed]).
  Future<Uint8List> getBytes(
    Uri url, {
    Map<String, String>? headers,
    ImageBytesProgressCallback? onBytesProgress,
    CancelToken? cancelToken,
  }) async {
    final response = await _sendUnstreamed(
      url: url,
      headers: headers,
      cancelToken: cancelToken,
      onBytesProgress: onBytesProgress,
    );
    return response.toBytes();
  }

  /// Builds the Abortable GET, seeds context, coalesces, and runs middlewares.
  ///
  /// Sole place that resolves [CancelToken] and constructs [http.AbortableRequest].
  /// Pool and in-flight coalesce wrap the call to [_handler].
  Future<HttpBytesResponse> _sendUnstreamed({
    required Uri url,
    Map<String, String>? headers,
    Map<String, Object?>? context,
    CancelToken? cancelToken,
    ImageBytesProgressCallback? onBytesProgress,
  }) {
    if (_closed) {
      throw const HttpBytesException$Internal(
        code: 'closed',
        message: 'HttpBytesFetcher is closed.',
        statusCode: 0,
      );
    }

    final ctx = context ?? <String, Object?>{};
    final effectiveToken = cancelToken ?? CancelToken();
    ctx[HttpBytesContextKeys.cancelToken] = effectiveToken;
    if (onBytesProgress != null) {
      ctx[HttpBytesContextKeys.onBytesProgress] = onBytesProgress;
    }

    final request = http.AbortableRequest(
      'GET',
      url,
      abortTrigger: effectiveToken.whenCancel,
    );
    if (headers != null) {
      request.headers.addAll(headers);
    }

    if (effectiveToken.isCancelled) {
      return Future<HttpBytesResponse>.error(
        HttpBytesException$Cancelled(
          error: CancelledException(effectiveToken.reason),
          data: <String, Object?>{'url': url.toString()},
        ),
      );
    }

    final key = ImageCacheKey.fromUrl(
      url.toString(),
      headers: request.headers,
    ).value;
    final existing = _inFlight[key];
    if (existing != null) return existing;

    final completer = Completer<HttpBytesResponse>();
    final flight = completer.future.whenComplete(() {
      _inFlight.remove(key);
    });
    _inFlight[key] = flight;

    void throwError(Object error, StackTrace stackTrace) {
      if (completer.isCompleted) return;
      if (error is HttpBytesException) {
        completer.completeError(error, stackTrace);
      } else {
        completer.completeError(
          HttpBytesException$Internal(
            code: 'unknown_error',
            message: 'Unknown error.',
            statusCode: 0,
            error: error,
          ),
          stackTrace,
        );
      }
    }

    runZonedGuarded<void>(
      () async {
        await _pool.withResource(() async {
          try {
            final response = await _handler(HttpBytesRequest(request), ctx);
            final bytes = await response.toBytes();
            if (bytes.isEmpty) {
              throwError(
                HttpBytesException$Internal(
                  code: 'empty_body',
                  message: 'Downloaded body is empty: $url',
                  statusCode: response.statusCode,
                  data: <String, Object?>{'url': url.toString()},
                ),
                StackTrace.current,
              );
              return;
            }
            if (!completer.isCompleted) {
              completer.complete(
                response.clone(
                  stream: http.ByteStream.fromBytes(bytes),
                  body: bytes,
                ),
              );
            }
          } on Object catch (error, stackTrace) {
            throwError(error, stackTrace);
          }
        });
      },
      throwError,
    );

    return flight;
  }

  /// Closes the pool and, when this instance created the client, the client.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _pool.close();
    if (_ownsClient) {
      _client.close();
    }
  }
}

/// Creates the middleware chain around wire [http.Client.send].
///
/// Isolated from pool, coalesce, and token assembly. Those live in
/// [HttpBytesFetcher._sendUnstreamed].
HttpBytesHandler _createHandler(
  http.Client internalClient,
  HttpBytesMiddleware middleware,
  bool Function(int statusCode)? validateStatusDefault,
) {
  void throwError(
    Completer<HttpBytesResponse> completer,
    Object error,
    StackTrace stackTrace,
  ) {
    if (completer.isCompleted) {
      return;
    } else if (error is HttpBytesException) {
      completer.completeError(error, stackTrace);
    } else {
      completer.completeError(
        HttpBytesException$Internal(
          code: 'unknown_error',
          message: 'Unknown error.',
          statusCode: 0,
          error: error,
        ),
        stackTrace,
      );
    }
  }

  Future<HttpBytesResponse> httpHandler(
    HttpBytesRequest request,
    Map<String, Object?> context,
  ) {
    final completer = Completer<HttpBytesResponse>();

    // runZonedGuarded routes async errors that escape the inner try/catch through throwError.
    runZonedGuarded<void>(
      () async {
        final http.StreamedResponse streamedResponse;
        try {
          streamedResponse = await internalClient.send(request._request);
        } on http.RequestAbortedException catch (error, stackTrace) {
          // The request was cancelled via a CancelToken — surface it distinctly
          // so callers and HttpBytesRetryMiddleware can tell it apart from a real failure.
          throwError(
            completer,
            HttpBytesException$Cancelled(
              error: error,
              data: <String, Object?>{'url': request.url.toString()},
            ),
            stackTrace,
          );
          return;
        } on Object catch (error, stackTrace) {
          throwError(
            completer,
            HttpBytesException$Network(
              code: 'network_error',
              message: 'Failed to send request due to a network error.',
              statusCode: 0,
              error: error,
              data: <String, Object?>{'url': request.url.toString()},
            ),
            stackTrace,
          );
          return;
        }

        final statusCode = streamedResponse.statusCode;
        final isSuccess = switch (context[HttpBytesContextKeys.validateStatus]) {
          final bool Function(int statusCode) predicate => predicate,
          _ => validateStatusDefault ?? _defaultValidateStatus,
        };
        if (!isSuccess(statusCode)) {
          unawaited(streamedResponse.stream.drain<void>());
          throwError(
            completer,
            _statusToException(
              statusCode,
              streamedResponse.headers,
              request.url,
            ),
            StackTrace.current,
          );
          return;
        }

        final contentLength = streamedResponse.contentLength ?? 0;
        var byteStream = streamedResponse.stream;

        // Report download progress as the body is consumed, if a callback was provided.
        // `total` is the Content-Length, or `null` when the server did not declare one.
        if (context[HttpBytesContextKeys.onBytesProgress] case final ImageBytesProgressCallback onBytesProgress) {
          final total = contentLength > 0 ? contentLength : null;
          var received = 0;
          byteStream = http.ByteStream(
            byteStream.map((chunk) {
              received += chunk.length;
              onBytesProgress(received, total);
              return chunk;
            }),
          );
        }

        if (!completer.isCompleted) {
          completer.complete(
            HttpBytesResponse(
              statusCode: statusCode,
              headers: Map<String, String>.from(streamedResponse.headers),
              contentLength: contentLength,
              request: request,
              stream: byteStream,
            ),
          );
        }
      },
      (error, stackTrace) {
        throwError(completer, error, stackTrace);
      },
    );

    return completer.future;
  }

  return middleware(httpHandler);
}

/// Default success predicate for image GETs: 2xx only.
bool _defaultValidateStatus(int statusCode) => statusCode >= 200 && statusCode < 300;

/// Maps a non-success [statusCode] to a typed [HttpBytesException].
///
/// Total over every non-success code (caller needs no fallback): 401/403 →
/// [HttpBytesException$Authentication]; 5xx → [HttpBytesException$Server];
/// everything else (4xx and any other non-2xx) → [HttpBytesException$Request].
/// Transport failures with no HTTP response are [HttpBytesException$Network]
/// from the send catch, not here.
///
/// Image GETs do not parse an error body (payloads are drained); [data] still
/// carries `url`, `headers`, and `retry-after` when present on 429/503.
HttpBytesException _statusToException(
  int statusCode,
  Map<String, String> headers,
  Uri url,
) {
  final (code, message) = _codeAndMessageFor(statusCode);
  final data = <String, Object?>{
    'url': url.toString(),
    'headers': headers,
    if (statusCode == 429 || statusCode == 503) 'retry-after': ?headers['retry-after'],
  };
  return switch (statusCode) {
    401 || 403 => HttpBytesException$Authentication(
      code: code,
      message: message,
      statusCode: statusCode,
      data: data,
    ),
    >= 500 => HttpBytesException$Server(
      code: code,
      message: message,
      statusCode: statusCode,
      data: data,
    ),
    _ => HttpBytesException$Request(
      code: code,
      message: message,
      statusCode: statusCode,
      data: data,
    ),
  };
}

/// Per-code semantic `(code, message)` for a non-success HTTP [statusCode].
/// Unlisted codes fall back to a generic server (5xx) or client label.
(String, String) _codeAndMessageFor(int statusCode) => switch (statusCode) {
  503 => (
    'service_unavailable',
    'Service unavailable (HTTP 503). The server is currently unable to handle the request.',
  ),
  500 => ('internal_server_error', 'Internal server error (HTTP 500).'),
  >= 500 => ('server_error', 'Internal server error (HTTP $statusCode).'),
  429 => ('rate_limit', 'Rate limit exceeded (HTTP 429). Too many requests.'),
  404 => ('not_found', 'Resource not found (HTTP 404).'),
  403 => (
    'forbidden',
    'Forbidden access (HTTP 403). Insufficient permissions.',
  ),
  401 => (
    'unauthorized',
    'Unauthorized access (HTTP 401). Authentication required.',
  ),
  400 => (
    'bad_request',
    'Bad request (HTTP 400). The request was malformed or invalid.',
  ),
  _ => ('client_error', 'Client error (HTTP $statusCode).'),
};

// --- Errors ---

/// {@template http_bytes_exception}
/// Base class for all HTTP bytes fetcher exceptions.
/// {@endtemplate}
@immutable
abstract class HttpBytesException implements Exception {
  /// {@macro http_bytes_exception}
  const HttpBytesException();

  /// HTTP status code. `0` when the request was not sent / no response.
  abstract final int statusCode;

  /// Machine-readable error code.
  abstract final String code;

  /// Human-readable detail.
  abstract final String message;

  /// The source error object.
  abstract final Object? error;

  /// Additional data (url, headers, …).
  abstract final Object? data;

  @override
  String toString() => message;
}

/// {@template http_bytes_exception_internal}
/// Internal (client-side) exception — empty body, closed fetcher, or unknown
/// error. This is NOT an HTTP "client error (4xx)" — those are
/// [HttpBytesException$Request]. [statusCode] is 0 unless a partial response
/// was already seen.
/// {@endtemplate}
final class HttpBytesException$Internal extends HttpBytesException {
  /// {@macro http_bytes_exception_internal}
  const HttpBytesException$Internal({
    required this.code,
    required this.message,
    required this.statusCode,
    this.error,
    this.data,
  });

  @override
  final String code;

  @override
  final String message;

  @override
  final int statusCode;

  @override
  final Object? error;

  @override
  final Object? data;
}

/// {@template http_bytes_exception_network}
/// Network (transport) exception — no HTTP response (DNS/TCP/TLS/socket).
/// HTTP error *responses* are [HttpBytesException$Request] /
/// [HttpBytesException$Server] / [HttpBytesException$Authentication], not this.
/// {@endtemplate}
final class HttpBytesException$Network extends HttpBytesException {
  /// {@macro http_bytes_exception_network}
  const HttpBytesException$Network({
    required this.code,
    required this.message,
    required this.statusCode,
    this.error,
    this.data,
  });

  @override
  final String code;

  @override
  final String message;

  @override
  final int statusCode;

  @override
  final Object? error;

  @override
  final Object? data;
}

/// {@template http_bytes_exception_request}
/// Request exception — non-auth client-error status (4xx, e.g. 400/404/429).
/// The request itself is at fault and is not treated as a transient server fault.
/// {@endtemplate}
final class HttpBytesException$Request extends HttpBytesException {
  /// {@macro http_bytes_exception_request}
  const HttpBytesException$Request({
    required this.code,
    required this.message,
    required this.statusCode,
    this.error,
    this.data,
  });

  @override
  final String code;

  @override
  final String message;

  @override
  final int statusCode;

  @override
  final Object? error;

  @override
  final Object? data;
}

/// {@template http_bytes_exception_server}
/// Server exception — the server responded with a 5xx status (e.g. 500/502/503).
/// {@endtemplate}
final class HttpBytesException$Server extends HttpBytesException {
  /// {@macro http_bytes_exception_server}
  const HttpBytesException$Server({
    required this.code,
    required this.message,
    required this.statusCode,
    this.error,
    this.data,
  });

  @override
  final String code;

  @override
  final String message;

  @override
  final int statusCode;

  @override
  final Object? error;

  @override
  final Object? data;
}

/// {@template http_bytes_exception_authentication}
/// Authentication exception — 401 or 403 from the server.
/// {@endtemplate}
final class HttpBytesException$Authentication extends HttpBytesException {
  /// {@macro http_bytes_exception_authentication}
  const HttpBytesException$Authentication({
    required this.code,
    required this.message,
    required this.statusCode,
    this.error,
    this.data,
  });

  @override
  final String code;

  @override
  final String message;

  @override
  final int statusCode;

  @override
  final Object? error;

  @override
  final Object? data;
}

/// {@template http_bytes_exception_cancelled}
/// Cancellation exception — aborted via a [CancelToken].
/// {@endtemplate}
final class HttpBytesException$Cancelled extends HttpBytesException {
  /// {@macro http_bytes_exception_cancelled}
  const HttpBytesException$Cancelled({
    this.code = 'cancelled',
    this.message = 'Request was cancelled.',
    this.statusCode = 0,
    this.error,
    this.data,
  });

  @override
  final String code;

  @override
  final String message;

  @override
  final int statusCode;

  @override
  final Object? error;

  @override
  final Object? data;
}
