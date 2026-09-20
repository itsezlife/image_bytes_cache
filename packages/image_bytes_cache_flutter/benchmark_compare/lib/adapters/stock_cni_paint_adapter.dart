/// Stock CNI paint: [CachedNetworkImage] over an isolated [CacheManager].
///
/// VM / desktop / mobile: sqflite [CacheObjectProvider] + temp file root
/// (via [sqflite_common_ffi] where needed).
/// Web: stock CNI never uses sqflite — cache_manager defaults (IndexedDB)
/// with a unique key and the shared MockClient.
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:cached_network_image_platform_interface/cached_network_image_platform_interface.dart'
    show ImageRenderMethodForWeb;
import 'package:file/file.dart' as pf;
import 'package:file/local.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;
import 'package:image_bytes_cache_benchmark_compare/adapters/stock_cni_paint_sqflite_init.dart'
    if (dart.library.js_interop) 'package:image_bytes_cache_benchmark_compare/adapters/stock_cni_paint_sqflite_init_web.dart'
    as sqflite_init;
import 'package:image_bytes_cache_benchmark_compare/corpus_http.dart';
import 'package:image_bytes_cache_benchmark_compare/paint_adapter.dart';
import 'package:path/path.dart' as p;

/// Opens an isolated stock CNI paint adapter.
Future<IPaintFeedAdapter> openStockCniPaintAdapter({
  Duration responseDelay = Duration.zero,
}) async {
  final httpHarness = corpusHttpClient(responseDelay: responseDelay);
  final client = httpHarness.client;

  if (kIsWeb) {
    final cacheKey = 'stock_paint_web_${DateTime.now().microsecondsSinceEpoch}';
    final manager = CacheManager(
      Config(
        cacheKey,
        stalePeriod: const Duration(days: 30),
        maxNrOfCacheObjects: 500,
        fileService: HttpFileService(httpClient: client),
      ),
    );
    return _StockPaintAdapter(
      id: 'stock_cni',
      label: 'cached_network_image (web)',
      rootPath: null,
      manager: manager,
      client: client,
    );
  }

  sqflite_init.ensureSqfliteFfi();
  final root = await sqflite_init.createTempRoot('ibc_stock_paint_');
  final cacheKey = 'stock_paint_${root.hashCode}';
  final dbPath = p.join(root, '$cacheKey.db');
  final manager = CacheManager(
    Config(
      cacheKey,
      stalePeriod: const Duration(days: 30),
      maxNrOfCacheObjects: 500,
      repo: CacheObjectProvider(path: dbPath),
      fileSystem: _RootFileSystem(root),
      fileService: HttpFileService(httpClient: client),
    ),
  );
  return _StockPaintAdapter(
    id: 'stock_cni',
    label: 'cached_network_image (sqflite)',
    rootPath: root,
    manager: manager,
    client: client,
  );
}

final class _StockPaintAdapter implements IPaintFeedAdapter {
  _StockPaintAdapter({
    required this.id,
    required this.label,
    required String? rootPath,
    required CacheManager manager,
    required http.Client client,
  }) : _rootPath = rootPath,
       _manager = manager,
       _client = client;

  @override
  final String id;

  @override
  final String label;

  final String? _rootPath;
  final CacheManager _manager;
  final http.Client _client;
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
      // Default HtmlImage fetches the URL in the browser and bypasses our
      // MockClient (`bench.invalid` → DNS/network errors under pressure).
      imageRenderMethodForWeb: ImageRenderMethodForWeb.HttpGet,
      placeholder: (_, __) => ColoredBox(
        color: const Color(0xFFE0E0E0),
        child: SizedBox(width: width, height: height),
      ),
      errorWidget: (_, __, ___) => ColoredBox(
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
    try {
      await _manager.dispose();
    } on Object {
      // CacheObjectProvider.close NPEs when the DB was never opened (paint
      // seam tests that only buildImage).
    }
    _client.close();
    final root = _rootPath;
    if (root != null) {
      await sqflite_init.deleteRootIfExists(root);
    }
  }
}

/// Cache-manager [FileSystem] rooted at a fixed temp directory (VM only).
final class _RootFileSystem implements FileSystem {
  _RootFileSystem(this._rootPath);

  final String _rootPath;
  final _fs = const LocalFileSystem();

  @override
  Future<pf.File> createFile(String name) async {
    final dir = _fs.directory(_rootPath);
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return dir.childFile(name);
  }
}
