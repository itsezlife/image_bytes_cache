/// CE paint: [CachedNetworkImage] over an isolated [DefaultCacheManager].
///
/// VM: Hive file-store IO manager under a temp root.
/// Web: Hive-in-IndexedDB web manager (no dart:io directories).
library;

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:image_bytes_cache_benchmark_compare/corpus_http.dart';
import 'package:image_bytes_cache_benchmark_compare/paint_adapter.dart';

import 'ce_paint_manager_io.dart'
    if (dart.library.js_interop) 'ce_paint_manager_web.dart' as ce_mgr;

/// Opens an isolated CE paint adapter.
Future<IPaintFeedAdapter> openCeHivePaintAdapter({
  Duration responseDelay = Duration.zero,
}) async {
  final httpHarness = corpusHttpClient(responseDelay: responseDelay);
  final client = httpHarness.client;
  final opened = await ce_mgr.openCeManager(client: client);
  return _CePaintAdapter(
    id: 'ce_hive',
    label: kIsWeb
        ? 'cached_network_image_ce (Hive/IndexedDB)'
        : 'cached_network_image_ce (Hive)',
    manager: opened.manager,
    client: client,
    onClose: opened.onClose,
  );
}

final class _CePaintAdapter implements IPaintFeedAdapter {
  _CePaintAdapter({
    required this.id,
    required this.label,
    required BaseCacheManager manager,
    required http.Client client,
    required Future<void> Function() onClose,
  }) : _manager = manager,
       _client = client,
       _onClose = onClose;

  @override
  final String id;

  @override
  final String label;

  final BaseCacheManager _manager;
  final http.Client _client;
  final Future<void> Function() _onClose;
  var _closed = false;

  @override
  Widget buildImage(
    String url, {
    required double width,
    required double height,
  }) {
    final decodePx = width.round().clamp(1, 4096);
    return CachedNetworkImage(
      imageUrl: url,
      cacheManager: _manager,
      width: width,
      height: height,
      fit: BoxFit.cover,
      memCacheWidth: decodePx,
      memCacheHeight: decodePx,
      fadeInDuration: Duration.zero,
      fadeOutDuration: Duration.zero,
      // Keep MockClient in path on web (default HtmlImage hits the network).
      imageRenderMethodForWeb: ImageRenderMethodForWeb.HttpGet,
      placeholder: (_, __) => ColoredBox(
        color: const Color(0xFFE0E0E0),
        child: SizedBox(width: width, height: height),
      ),
      errorBuilder: (_, __, ___) => ColoredBox(
        color: const Color(0xFFFFCDD2),
        child: SizedBox(width: width, height: height),
      ),
    );
  }

  @override
  Future<void> empty() => _manager.emptyCache();

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _onClose();
    _client.close();
  }
}
