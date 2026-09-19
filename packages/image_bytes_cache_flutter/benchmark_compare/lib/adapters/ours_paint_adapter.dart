/// Ours paint: durable cache + resolver → [CachedNetworkBytesImage].
///
/// VM: temp directory for the file store. Web: [ImageBytesCache.open] ignores
/// [directory] (Cache API + OPFS).
library;

import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:image_bytes_cache/image_bytes_cache.dart';
import 'package:image_bytes_cache_benchmark_compare/corpus_http.dart';
import 'package:image_bytes_cache_benchmark_compare/paint_adapter.dart';
import 'package:image_bytes_cache_flutter/image_bytes_cache_flutter.dart';

/// Opens an isolated ours paint adapter.
Future<IPaintFeedAdapter> openOursPaintAdapter({
  Duration responseDelay = Duration.zero,
  int maxConcurrent = 6,
}) async {
  final httpHarness = corpusHttpClient(responseDelay: responseDelay);
  final httpBytesClient = HttpBytesClient(
    client: httpHarness.client,
    maxConcurrent: maxConcurrent,
  );
  final Directory? root;
  final IImageBytesCache cache;
  if (kIsWeb) {
    root = null;
    cache = await ImageBytesCache.open(throwOnOpenFailure: true);
  } else {
    root = await Directory.systemTemp.createTemp('ibc_ours_paint_');
    cache = await ImageBytesCache.open(
      directory: root.path,
      throwOnOpenFailure: true,
    );
  }
  final resolver = ImageBytesResolver(cache: cache, client: httpBytesClient);
  return _OursPaintAdapter(
    id: 'ours',
    label: 'image_bytes_cache',
    root: root,
    cache: cache,
    httpBytesClient: httpBytesClient,
    resolver: resolver,
    httpClient: httpHarness.client,
  );
}

final class _OursPaintAdapter implements IPaintFeedAdapter {
  _OursPaintAdapter({
    required this.id,
    required this.label,
    required Directory? root,
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

  final Directory? _root;
  final IImageBytesCache _cache;
  final HttpBytesClient _httpBytesClient;
  final ImageBytesResolver _resolver;
  final http.Client _httpClient;
  final _seen = <ImageCacheKey>{};
  var _closed = false;

  @override
  Widget buildImage(
    String url, {
    required double width,
    required double height,
  }) {
    final key = ImageCacheKey.fromUrl(url);
    _seen.add(key);
    final decodePx = width.round().clamp(1, 4096);
    return CachedNetworkBytesImage(
      url,
      width: width,
      height: height,
      fit: BoxFit.cover,
      cacheWidth: decodePx,
      cacheHeight: decodePx,
      resolver: _resolver,
      gaplessPlayback: true,
      loadingBuilder: (context, child, progress) {
        if (progress == null) return child;
        return ColoredBox(
          color: const Color(0xFFE0E0E0),
          child: SizedBox(width: width, height: height),
        );
      },
      errorBuilder: (_, __, ___) => ColoredBox(
        color: const Color(0xFFFFCDD2),
        child: SizedBox(width: width, height: height),
      ),
    );
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
    final root = _root;
    if (root != null && root.existsSync()) {
      await root.delete(recursive: true);
    }
  }
}
