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
/// [context] is shared across middleware for this send.
typedef HttpBytesHandler =
    Future<HttpBytesResponse> Function(
      HttpBytesRequest request,
      HttpBytesContext context,
    );

/// A function that takes an [HttpBytesHandler] and returns an [HttpBytesHandler].
typedef HttpBytesMiddleware = HttpBytesHandler Function(HttpBytesHandler innerHandler);

/// Ad-hoc [HttpBytesMiddleware] from optional request/response/error hooks,
/// plus [merge] for outermost-first chains.
// ignore: avoid-implicitly-nullable-extension-types, prefer-declaring-const-constructor
extension type HttpBytesMiddlewareWrapper._(HttpBytesMiddleware _fn) {
  /// Creates a new [HttpBytesMiddleware] from the given callbacks.
  factory HttpBytesMiddlewareWrapper({
    Future<void> Function(HttpBytesRequest request, HttpBytesContext context)? onRequest,
    Future<void> Function(HttpBytesResponse response, HttpBytesContext context)? onResponse,
    Future<void> Function(
      Object error,
      StackTrace stackTrace,
      HttpBytesContext context,
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

/// Per-send middleware context: typed slots over a shared [Map].
extension type HttpBytesContext(Map<String, Object?> _map) implements Map<String, Object?> {
  /// Empty context for a new send.
  factory HttpBytesContext.empty() => HttpBytesContext(<String, Object?>{});

  /// Shared flight [CancelToken] (AbortableRequest abort + Timeout).
  static const cancelTokenKey = 'cancelToken';

  /// Per-caller [CancelToken] for coalesce-aware cancel.
  static const callerCancelTokenKey = 'callerCancelToken';

  /// Connect timeout override ([Duration] / `int` ms / [DateTime] deadline).
  static const connectTimeoutKey = 'connect-timeout';

  /// Receive idle-gap timeout override ([Duration] / `int` ms / [DateTime]).
  static const receiveTimeoutKey = 'receive-timeout';

  /// Progress callback while the response body is read.
  static const onBytesProgressKey = 'on-bytes-progress';

  /// Success predicate; default is 2xx.
  static const validateStatusKey = 'validate-status';

  /// When `true`, [HttpBytesRetryMiddleware] skips retry for this send.
  static const noRetryKey = 'no-retry';

  /// Override [HttpBytesRetryBackoff.maxRetries] (`int` > 0).
  static const retriesKey = 'retries';

  /// When `true`, allow retry even if the method is not idempotent.
  static const retryNonIdempotentKey = 'retry-non-idempotent';

  /// Shared flight [CancelToken] for this send (AbortableRequest abort + Timeout).
  ///
  /// Set when a flight starts (after post-middleware identity). Coalesced
  /// subscribers each keep their own [callerCancelToken]; Timeout cancels this
  /// flight token. Last-subscriber cancel also cancels it.
  CancelToken? get cancelToken => switch (_map[cancelTokenKey]) {
    final CancelToken t => t,
    _ => null,
  };
  set cancelToken(CancelToken? value) => _set(cancelTokenKey, value);

  /// Per-caller [CancelToken] for coalesce-aware cancel (not the flight abort).
  CancelToken? get callerCancelToken => switch (_map[callerCancelTokenKey]) {
    final CancelToken t => t,
    _ => null,
  };
  set callerCancelToken(CancelToken? value) => _set(callerCancelTokenKey, value);

  /// Connect timeout override ([Duration] / `int` ms / [DateTime] deadline).
  Object? get connectTimeout => _map[connectTimeoutKey];
  set connectTimeout(Object? value) => _set(connectTimeoutKey, value);

  /// Receive idle-gap timeout override ([Duration] / `int` ms / [DateTime]).
  Object? get receiveTimeout => _map[receiveTimeoutKey];
  set receiveTimeout(Object? value) => _set(receiveTimeoutKey, value);

  /// Progress sink while the response body is read.
  ImageBytesProgressCallback? get onBytesProgress => switch (_map[onBytesProgressKey]) {
    final ImageBytesProgressCallback cb => cb,
    _ => null,
  };
  set onBytesProgress(ImageBytesProgressCallback? value) => _set(onBytesProgressKey, value);

  /// Success predicate; default is 2xx.
  bool Function(int statusCode)? get validateStatus => switch (_map[validateStatusKey]) {
    final bool Function(int statusCode) predicate => predicate,
    _ => null,
  };
  set validateStatus(bool Function(int statusCode)? value) => _set(validateStatusKey, value);

  /// When `true`, [HttpBytesRetryMiddleware] skips retry for this send.
  bool get noRetry => _map[noRetryKey] == true;
  set noRetry(bool value) => _set(noRetryKey, value ? true : null);

  /// Override [HttpBytesRetryBackoff.maxRetries] (`int` > 0).
  int? get retries => switch (_map[retriesKey]) {
    final int r when r > 0 => r,
    _ => null,
  };
  set retries(int? value) => _set(retriesKey, value);

  /// When `true`, allow retry even if the method is not idempotent.
  bool get retryNonIdempotent => _map[retryNonIdempotentKey] == true;
  set retryNonIdempotent(bool value) => _set(retryNonIdempotentKey, value ? true : null);

  void _set(String key, Object? value) {
    if (value == null) {
      _map.remove(key);
    } else {
      _map[key] = value;
    }
  }
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
  bool get canBeRetried => switch (_request) {
    http.Request() => true,
    _ => false,
  };

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
    final abortTrigger = switch (source) {
      http.Abortable(:final abortTrigger?) => abortTrigger,
      _ => null,
    };
    final newRequest = switch (abortTrigger) {
      null => http.Request(method ?? source.method, url ?? source.url),
      final trigger => http.AbortableRequest(
        method ?? source.method,
        url ?? source.url,
        abortTrigger: trigger,
      ),
    };

    newRequest.headers.addAll(source.headers);
    if (headers case final h?) {
      newRequest.headers.addAll(h);
    }

    if (source case http.Request(:final bodyBytes)) {
      newRequest.bodyBytes = bodyBytes;
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
  Future<Uint8List> toBytes() => switch (body) {
    final cached? => Future<Uint8List>.value(cached),
    null => stream.toBytes(),
  };

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
///
/// Concurrent callers that share the same **post-middleware** coalesce identity
/// join one in-flight GET. Identity is `ImageCacheKey` from the request URL +
/// headers after request-mutating middleware (e.g. Bearer) runs. Each caller may
/// pass its own [CancelToken]:
/// - canceling one subscriber completes only that caller with
///   [HttpBytesException$Cancelled] and leaves the flight running;
/// - canceling the last subscriber cancels the shared flight token (socket
///   abort). Timeout middleware cancels that same flight token and still
///   surfaces [HttpBytesException$Timeout], not Cancelled.
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
    // User middlewares (Bearer, Retry, Timeout, …) wrap coalesce+send so
    // identity sees post-middleware headers; joiners do not hold a pool slot.
    _handler = pipeline(_coalesceThenSend(validateStatus));
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

  final Map<String, _HttpBytesInFlight> _inFlight = {};

  var _closed = false;

  /// Immutable list of middlewares to apply for each send.
  final List<HttpBytesMiddleware> middlewares;

  /// Decides whether a response [statusCode] is a success. Defaults to 2xx.
  /// Overridable per request via [HttpBytesContext.validateStatus].
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

  /// Seeds caller context and runs the middleware chain (coalesce at the center).
  ///
  /// Coalesce identity is taken from the request **after** request-mutating
  /// middleware. The flight [CancelToken] and [http.AbortableRequest] are
  /// created only when starting a new flight (not when joining). Starters
  /// return a streaming response through Timeout (receive idle works); the
  /// body is buffered here and fan-out to joiners uses that buffer.
  Future<HttpBytesResponse> _sendUnstreamed({
    required Uri url,
    Map<String, String>? headers,
    Map<String, Object?>? context,
    CancelToken? cancelToken,
    ImageBytesProgressCallback? onBytesProgress,
  }) async {
    if (_closed) {
      throw const HttpBytesException$Internal(
        code: 'closed',
        message: 'HttpBytesFetcher is closed.',
        statusCode: 0,
      );
    }

    final callerToken = cancelToken ?? CancelToken();
    if (callerToken.isCancelled) {
      throw HttpBytesException$Cancelled(
        error: CancelledException(callerToken.reason),
        data: <String, Object?>{'url': url.toString()},
      );
    }

    final ctx = HttpBytesContext(context ?? <String, Object?>{})
      ..callerCancelToken = callerToken
      ..onBytesProgress = onBytesProgress;

    // Plain Request through middleware so Bearer/Retry can mutate/clone headers
    // before coalesce; AbortableRequest is built when a flight starts.
    final request = http.Request('GET', url);
    if (headers case final h?) {
      request.headers.addAll(h);
    }

    try {
      // Race the caller's CancelToken so starters (who buffer after Timeout)
      // observe Cancelled even while blocked in send/toBytes. Joiners already
      // get Cancelled from their subscriber Future; racing twice is harmless.
      //
      // CancelToken.track is not used: CancelableOperation.fromFuture reports
      // error completions in a way that surfaces as uncaught async errors under
      // package:test even when op.value is awaited (wrong precision for our
      // $Cancelled mapping). Homemade race keeps one Future and typed errors.
      return await _raceCallerCancel(callerToken, url, () async {
        final response = await _handler(HttpBytesRequest(request), ctx);
        // Joiner: flight already completed with a buffered body.
        if (response.body != null) return response;

        final bytes = await response.toBytes();
        final flight = switch (ctx[_kInFlight]) {
          final _HttpBytesInFlight f => f,
          _ => null,
        };
        if (bytes.isEmpty) {
          final error = HttpBytesException$Internal(
            code: 'empty_body',
            message: 'Downloaded body is empty: $url',
            statusCode: response.statusCode,
            data: <String, Object?>{'url': url.toString()},
          );
          flight?.completeError(error, StackTrace.current);
          throw error;
        }
        final buffered = response.clone(
          stream: http.ByteStream.fromBytes(bytes),
          body: bytes,
        );
        flight?.completeSuccess(buffered);
        return buffered;
      });
    } on Object catch (error, stackTrace) {
      // Per-caller cancel must not fail remaining coalesce joiners.
      if (error case HttpBytesException$Cancelled()) {
        rethrow;
      }
      if (ctx[_kInFlight] case final _HttpBytesInFlight flight) {
        flight.completeError(error, stackTrace);
      }
      rethrow;
    }
  }

  /// Innermost handler: post-middleware identity → join or pool+Client.send.
  ///
  /// Starters return the streaming [HttpBytesResponse] so Timeout can wrap
  /// receive-idle on the body; [_sendUnstreamed] buffers and completes the
  /// flight. Joiners return a subscriber [Future] of the buffered result.
  HttpBytesHandler _coalesceThenSend(
    bool Function(int statusCode)? validateStatusDefault,
  ) {
    final clientSend = _createClientSend(_client, validateStatusDefault);

    return (request, context) async {
      final callerToken = context.callerCancelToken ?? CancelToken();

      final key = ImageCacheKey.fromUrl(
        request.url.toString(),
        headers: request.headers,
      ).value;

      final existing = _inFlight[key];
      if (existing != null) {
        return existing.addSubscriber(callerToken, request.url);
      }

      final flightToken = CancelToken();
      context.cancelToken = flightToken;

      final abortable = http.AbortableRequest(
        'GET',
        request.url,
        abortTrigger: flightToken.whenCancel,
      )..headers.addAll(request.headers);

      final flight = _HttpBytesInFlight(
        flightToken: flightToken,
        onAbandoned: () => _inFlight.remove(key),
      );
      _inFlight[key] = flight;
      context[_kInFlight] = flight;
      // Starter: cancel interest only (result comes from streaming → buffer).
      // Do not attach a subscriber Future — that would uncaught-error on
      // completeError while getBytes already rethrows the same failure.
      flight.trackCaller(callerToken);

      unawaited(
        flight.done.whenComplete(() {
          _inFlight.remove(key);
        }),
      );

      try {
        return await _pool.withResource(
          () => clientSend(HttpBytesRequest(abortable), context),
        );
      } on Object catch (error, stackTrace) {
        flight.completeError(error, stackTrace);
        rethrow;
      }
    };
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

/// Context slot for the in-flight entry started by coalesce (starter path).
const _kInFlight = 'httpBytesInFlight';

/// One coalesced in-flight GET with N caller subscribers.
///
/// [flightToken] is the AbortableRequest abort signal and the context token
/// Timeout cancels. The starter [trackCaller]s for last-subscriber abort only;
/// joiners [addSubscriber] and await a Future. Canceling one caller drops that
/// subscriber; canceling the last cancels [flightToken] so the socket aborts.
final class _HttpBytesInFlight {
  _HttpBytesInFlight({
    required this.flightToken,
    required this.onAbandoned,
  });

  final CancelToken flightToken;
  final void Function() onAbandoned;

  final Completer<HttpBytesResponse> _flight = Completer<HttpBytesResponse>();
  final Set<_HttpBytesSubscriber> _subscribers = <_HttpBytesSubscriber>{};

  /// Completes when the shared GET finishes (success or error), after fan-out.
  Future<void> get done => _flight.future.then<void>((_) {}, onError: (_, _) {});

  /// Starter: count toward last-subscriber abort without a result Future.
  void trackCaller(CancelToken callerToken) {
    final subscriber = _HttpBytesSubscriber(token: callerToken);
    _subscribers.add(subscriber);
    unawaited(
      callerToken.whenCancel.then((_) {
        _removeSubscriber(subscriber);
      }),
    );
  }

  /// Joiner: track cancel + Future of the buffered flight result.
  Future<HttpBytesResponse> addSubscriber(CancelToken callerToken, Uri url) {
    final completer = Completer<HttpBytesResponse>();
    final subscriber = _HttpBytesSubscriber(
      token: callerToken,
      completer: completer,
    );
    _subscribers.add(subscriber);

    // Fan-out flight result to this subscriber if still waiting.
    _flight.future.then(
      (response) {
        if (!completer.isCompleted) {
          completer.complete(response);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      },
    );

    // Per-caller cancel: drop this subscriber; abort flight only when last.
    unawaited(
      callerToken.whenCancel.then((_) {
        if (completer.isCompleted) return;
        completer.completeError(
          HttpBytesException$Cancelled(
            error: CancelledException(callerToken.reason),
            data: <String, Object?>{'url': url.toString()},
          ),
        );
        _removeSubscriber(subscriber);
      }),
    );

    return completer.future;
  }

  void completeSuccess(HttpBytesResponse response) {
    if (_flight.isCompleted) return;
    _flight.complete(response);
    _subscribers.clear();
  }

  void completeError(Object error, StackTrace stackTrace) {
    if (_flight.isCompleted) return;
    final wrapped = switch (error) {
      final HttpBytesException e => e,
      _ => HttpBytesException$Internal(
        code: 'unknown_error',
        message: 'Unknown error.',
        statusCode: 0,
        error: error,
      ),
    };
    _flight.completeError(wrapped, stackTrace);
    _subscribers.clear();
  }

  void _removeSubscriber(_HttpBytesSubscriber subscriber) {
    if (!_subscribers.remove(subscriber)) return;
    if (_subscribers.isNotEmpty || _flight.isCompleted) return;
    // Last live subscriber cancelled before the flight finished — abort socket
    // and drop the coalesce key so a new caller starts a fresh GET.
    onAbandoned();
    flightToken.cancel();
  }
}

final class _HttpBytesSubscriber {
  _HttpBytesSubscriber({
    required this.token,
    this.completer,
  });

  final CancelToken token;

  /// Non-null for joiners; starters track cancel only.
  final Completer<HttpBytesResponse>? completer;
}

/// Completes with [HttpBytesException$Cancelled] when [token] cancels, or with
/// [work]'s result otherwise. Late work errors after cancel are swallowed so
/// an abandoned starter send cannot surface as an uncaught async error.
///
/// Prefer this over [CancelToken.track]: `CancelableOperation.fromFuture` can
/// report completions as uncaught zone errors under test even when `.value` is
/// awaited, and it does not map cancel to [HttpBytesException$Cancelled].
Future<T> _raceCallerCancel<T>(
  CancelToken token,
  Uri url,
  Future<T> Function() work,
) {
  if (token.isCancelled) {
    return Future<T>.error(
      HttpBytesException$Cancelled(
        error: CancelledException(token.reason),
        data: <String, Object?>{'url': url.toString()},
      ),
    );
  }

  final done = Completer<T>();
  unawaited(
    token.whenCancel.then((_) {
      if (!done.isCompleted) {
        done.completeError(
          HttpBytesException$Cancelled(
            error: CancelledException(token.reason),
            data: <String, Object?>{'url': url.toString()},
          ),
        );
      }
    }),
  );
  work().then(
    (value) {
      if (!done.isCompleted) done.complete(value);
    },
    onError: (Object error, StackTrace stackTrace) {
      if (!done.isCompleted) {
        done.completeError(error, stackTrace);
      }
    },
  );
  return done.future;
}

/// Client.send + status map + progress. Pool/coalesce live in
/// [HttpBytesFetcher._coalesceThenSend]; user middlewares wrap that.
HttpBytesHandler _createClientSend(
  http.Client internalClient,
  bool Function(int statusCode)? validateStatusDefault,
) {
  void throwError(
    Completer<HttpBytesResponse> completer,
    Object error,
    StackTrace stackTrace,
  ) {
    if (completer.isCompleted) return;
    completer.completeError(
      switch (error) {
        final HttpBytesException e => e,
        _ => HttpBytesException$Internal(
          code: 'unknown_error',
          message: 'Unknown error.',
          statusCode: 0,
          error: error,
        ),
      },
      stackTrace,
    );
  }

  Future<HttpBytesResponse> httpHandler(
    HttpBytesRequest request,
    HttpBytesContext context,
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
        final isSuccess = context.validateStatus ?? validateStatusDefault ?? _defaultValidateStatus;
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
        if (context.onBytesProgress case final onBytesProgress?) {
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

  return httpHandler;
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
sealed class HttpBytesException implements Exception {
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

/// {@template http_bytes_exception_timeout}
/// Client timeout exception — thrown when a connect or receive timeout fires.
/// {@endtemplate}
final class HttpBytesException$Timeout extends HttpBytesException implements TimeoutException {
  /// {@macro http_bytes_exception_timeout}
  const HttpBytesException$Timeout({
    required this.code,
    required this.message,
    required this.statusCode,
    required this.duration,
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

  /// The duration that was exceeded.
  @override
  final Duration? duration;
}
