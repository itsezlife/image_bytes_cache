import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:image_bytes_cache/src/image_bytes_cache.dart';
import 'package:meta/meta.dart';
import 'package:pool/pool.dart';

/// HTTP GET for response bodies, with a concurrency cap and in-flight coalescing.
///
/// Fetches bytes only. Callers own disk cache and decoding. Format is irrelevant
/// here: SVG, PNG, WebP, or anything else the ladder later paints or decodes.
///
/// A feed of remote images can open dozens of sockets without [Pool]. Two
/// callers that share the same [ImageCacheKey] identity (canonical URL +
/// canonical headers) while the first GET is still open would hit the network
/// twice without coalescing. Coalesce keys are [ImageCacheKey.value], not a
/// `url|headers` string join.
///
/// Pass an [http.Client] when you already have one. If omitted, this class
/// creates a client and closes it in [close].
///
/// ## Timeout and pool wait
///
/// [timeout] bounds work after a [Pool] slot is acquired. Waiting for a slot
/// is intentionally unbounded: under sustained overload callers queue rather
/// than fail with a second timeout class. Prefer raising [maxConcurrent] or
/// fixing upstream concurrency if queue wait dominates.
///
/// Once a slot is held, the GET uses [http.AbortableRequest] so clients that
/// honor [http.Abortable.abortTrigger] (VM [http.IOClient], browser client)
/// release the underlying connection when [timeout] elapses. Clients that do
/// not abort still fail the waiter via [TimeoutException]; any leftover
/// in-flight work is then a property of that client, not of this pool.
final class HttpBytesFetcher {
  /// [maxConcurrent] caps parallel GETs (default 6). Further callers wait in
  /// [Pool] until a slot frees. That wait is not covered by [timeout].
  ///
  /// [timeout] starts after a pool slot is acquired and aborts the GET via
  /// [http.AbortableRequest] when the client supports abortion.
  HttpBytesFetcher({
    http.Client? client,
    int maxConcurrent = 6,
    this.timeout = const Duration(seconds: 15),
  }) : assert(maxConcurrent > 0, 'maxConcurrent must be > 0'),
       _client = client ?? http.Client(),
       _ownsClient = client == null,
       _pool = Pool(maxConcurrent);

  /// Process-wide default when nothing is injected.
  factory HttpBytesFetcher.shared() => debugShared ?? (_shared ??= HttpBytesFetcher());

  static HttpBytesFetcher? _shared;

  /// Test override for [HttpBytesFetcher.shared]. Set to `null` to clear.
  @visibleForTesting
  static HttpBytesFetcher? debugShared;

  final http.Client _client;
  final bool _ownsClient;
  final Pool _pool;

  /// Per-request timeout after a pool slot is acquired (not while waiting for one).
  final Duration timeout;

  final Map<String, Future<Uint8List>> _inFlight = {};

  var _closed = false;

  /// GETs [url] and returns the response body.
  ///
  /// Concurrent calls that share the same [ImageCacheKey.fromUrl] identity
  /// (canonical URL form of [url] + canonical headers) share one in-flight
  /// [Future]. Header keys compare case-insensitively; values stay as given.
  /// Coalesce uses [ImageCacheKey.value], not a `url|headers` string join, so a
  /// URL that embeds `|…` cannot merge with a clean URL plus those headers.
  ///
  /// Throws [http.ClientException] on non-2xx, [StateError] on an empty body,
  /// [TimeoutException] when [timeout] elapses after a pool slot is acquired,
  /// and [StateError] after [close].
  Future<Uint8List> getBytes(
    Uri url, {
    Map<String, String>? headers,
  }) {
    if (_closed) {
      throw StateError('HttpBytesFetcher is closed');
    }

    final key = ImageCacheKey.fromUrl(url.toString(), headers: headers).value;
    final existing = _inFlight[key];
    if (existing != null) return existing;

    // One Future instance for coalesced callers. whenComplete clears the map
    // without swallowing the result or error.
    final future = _pool.withResource(() => _performGet(url, headers)).whenComplete(() {
      _inFlight.remove(key);
    });
    _inFlight[key] = future;
    return future;
  }

  Future<Uint8List> _performGet(
    Uri url,
    Map<String, String>? headers,
  ) async {
    final abort = Completer<void>();
    final timer = Timer(timeout, () {
      if (!abort.isCompleted) abort.complete();
    });

    try {
      final request = http.AbortableRequest('GET', url, abortTrigger: abort.future);
      if (headers != null) {
        request.headers.addAll(headers);
      }

      try {
        return await () async {
          final streamed = await _client.send(request);
          final bytes = await streamed.stream.toBytes();

          if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
            throw http.ClientException(
              'Failed to download: ${streamed.statusCode}',
              url,
            );
          }

          if (bytes.isEmpty) {
            throw StateError('Downloaded body is empty: $url');
          }

          return Uint8List.fromList(bytes);
        }().timeout(timeout);
      } on TimeoutException {
        // Non-abortable clients (e.g. MockClient): fail the waiter and still
        // complete abortTrigger so abort-capable stacks release sockets.
        if (!abort.isCompleted) abort.complete();
        throw TimeoutException(
          'HttpBytesFetcher GET timed out after $timeout: $url',
          timeout,
        );
      } on http.RequestAbortedException {
        throw TimeoutException(
          'HttpBytesFetcher GET timed out after $timeout: $url',
          timeout,
        );
      }
    } finally {
      timer.cancel();
    }
  }

  /// Closes the pool and, when this instance created the client, the client.
  ///
  /// Idempotent. In-flight GETs may still finish or fail after close; new
  /// [getBytes] calls throw.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _pool.close();
    if (_ownsClient) {
      _client.close();
    }
    if (identical(_shared, this)) {
      _shared = null;
    }
  }
}
