/// Ours: durable VM [ImageBytesCache] + [ImageBytesResolver] + MockClient.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:image_bytes_cache/image_bytes_cache.dart';
import 'package:image_bytes_cache_benchmark_compare/adapter.dart';
import 'package:image_bytes_cache_benchmark_compare/corpus_http.dart';

/// Opens an isolated durable ours adapter under a temp directory.
Future<IBytesReadyAdapter> openOursAdapter({
  Duration responseDelay = Duration.zero,
  int maxConcurrent = 6,
}) async {
  final root = await Directory.systemTemp.createTemp('ibc_ours_');
  final httpHarness = corpusHttpClient(responseDelay: responseDelay);
  final httpBytesClient = HttpBytesClient(
    client: httpHarness.client,
    maxConcurrent: maxConcurrent,
  );
  final cache = await ImageBytesCache.open(
    directory: root.path,
    throwOnOpenFailure: true,
  );
  final resolver = ImageBytesResolver(cache: cache, client: httpBytesClient);
  return _OursAdapter(
    id: 'ours',
    label: 'image_bytes_cache',
    root: root,
    cache: cache,
    httpBytesClient: httpBytesClient,
    resolver: resolver,
    httpClient: httpHarness.client,
  );
}

/// Waits until fire-and-forget write-through has landed a non-empty body.
Future<void> awaitOursWriteThrough(
  IBytesReadyAdapter adapter,
  String url,
) async {
  switch (adapter) {
    case final _OursAdapter ours:
      final key = ImageCacheKey.fromUrl(url);
      for (var i = 0; i < 2000; i++) {
        final bytes = await ours._cache.read(key);
        if (bytes case final b? when b.isNotEmpty) return;
        await Future<void>.delayed(Duration.zero);
      }
      throw StateError('write-through did not land for ${key.value}');
    default:
      return;
  }
}

final class _OursAdapter implements IBytesReadyAdapter {
  _OursAdapter({
    required this.id,
    required this.label,
    required Directory root,
    required IImageBytesCache cache,
    required HttpBytesClient httpBytesClient,
    required ImageBytesResolver resolver,
    required http.Client httpClient,
  }) : _root = root,
       _cache = cache,
       _httpBytesClient = httpBytesClient,
       _resolver = resolver,
       _httpClient = httpClient;

  @override
  final String id;

  @override
  final String label;

  final Directory _root;
  final IImageBytesCache _cache;
  final HttpBytesClient _httpBytesClient;
  final ImageBytesResolver _resolver;
  final http.Client _httpClient;
  final _seen = <ImageCacheKey>{};
  var _closed = false;

  @override
  Future<Uint8List> getBytes(String url) async {
    final key = ImageCacheKey.fromUrl(url);
    final bytes = await _resolver.resolve(ImageBytesRequest(url: url));
    _seen.add(key);
    return bytes;
  }

  @override
  Future<void> evict(String url) async {
    final key = ImageCacheKey.fromUrl(url);
    await _cache.evict(key);
    _seen.remove(key);
  }

  @override
  Future<void> empty() async {
    for (final key in _seen.toList()) {
      await _cache.evict(key);
    }
    _seen.clear();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _httpBytesClient.close();
    await _cache.close();
    _httpClient.close();
    if (_root.existsSync()) {
      await _root.delete(recursive: true);
    }
  }
}
