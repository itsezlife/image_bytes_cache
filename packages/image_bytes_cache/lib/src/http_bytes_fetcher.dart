import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:image_bytes_cache/src/image_bytes_cache.dart';
import 'package:meta/meta.dart';
import 'package:pool/pool.dart';

/// HTTP GET for response bodies, with a concurrency cap and in-flight coalescing.
///
/// Fetches bytes only. Callers own disk cache and decoding.
///
/// A list of remote SVGs can open dozens of sockets without [Pool]. Two widgets
/// that share the same [ImageCacheKey] identity (canonical URL + canonical
/// headers) while the first GET is still open would hit the network twice
/// without coalescing. Coalesce keys are [ImageCacheKey.value], not a
/// `url|headers` string join.
///
/// Pass an [http.Client] when you already have one. If omitted, this class
/// creates a client and closes it in [close].
final class HttpBytesFetcher {
  /// [maxConcurrent] caps parallel GETs (default 6). Further callers wait in
  /// [Pool] until a slot frees.
  ///
  /// [timeout] starts after a pool slot is acquired. Waiting for a slot is not
  /// timed out.
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

  /// Per-request timeout after a pool slot is acquired.
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
  /// [TimeoutException] when [timeout] elapses, and [StateError] after [close].
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
    final response = await _client.get(url, headers: headers).timeout(timeout);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw http.ClientException(
        'Failed to download: ${response.statusCode}',
        url,
      );
    }

    final bytes = response.bodyBytes;
    if (bytes.isEmpty) {
      throw StateError('Downloaded body is empty: $url');
    }

    return bytes;
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
