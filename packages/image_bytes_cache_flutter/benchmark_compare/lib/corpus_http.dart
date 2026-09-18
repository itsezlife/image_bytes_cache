/// Shared MockClient that serves corpus bodies (bytes tables and/or feed SVG).
library;

import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_bytes_cache_benchmark_compare/corpus.dart';
import 'package:image_bytes_cache_benchmark_compare/feed_corpus.dart';

/// Counts GETs while returning corpus bytes (404 when URL is unknown).
///
/// [resolvePayload] defaults to bytes-table [payloadForUrl], then feed SVG via
/// [feedPayloadForUrl], so one client can serve both lanes when needed.
({MockClient client, int Function() fetchCount}) corpusHttpClient({
  Duration responseDelay = Duration.zero,
  Uint8List? Function(String url)? resolvePayload,
}) {
  var fetches = 0;
  final resolve = resolvePayload ?? (String url) => payloadForUrl(url) ?? feedPayloadForUrl(url);
  final client = MockClient((request) async {
    fetches++;
    if (responseDelay > Duration.zero) {
      await Future<void>.delayed(responseDelay);
    }
    final payload = resolve(request.url.toString());
    if (payload == null) {
      return http.Response('not found', 404);
    }
    return http.Response.bytes(
      payload,
      200,
      headers: {'content-type': 'application/octet-stream'},
    );
  });
  return (client: client, fetchCount: () => fetches);
}
