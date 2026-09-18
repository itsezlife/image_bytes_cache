/// Stock CNI: [CacheManager] + sqflite/[JsonCacheInfoRepository] + MockClient.
library;

import 'dart:io' as io;
import 'dart:typed_data';

import 'package:file/file.dart' as pf;
import 'package:file/local.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;
import 'package:image_bytes_cache_benchmark_compare/adapter.dart';
import 'package:image_bytes_cache_benchmark_compare/corpus_http.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Opens an isolated stock CNI adapter (sqflite meta via CacheObjectProvider).
///
/// Desktop / VM tests initialize [databaseFactoryFfi] once so
/// [CacheObjectProvider] can open without a mobile plugin registrant.
Future<IBytesReadyAdapter> openStockCniAdapter({
  Duration responseDelay = Duration.zero,
}) async {
  _ensureSqfliteFfi();
  final root = await io.Directory.systemTemp.createTemp('ibc_stock_');
  final httpHarness = corpusHttpClient(responseDelay: responseDelay);
  final client = httpHarness.client;
  final cacheKey = 'stock_${root.path.hashCode}';
  final dbPath = p.join(root.path, '$cacheKey.db');
  final manager = CacheManager(
    Config(
      cacheKey,
      stalePeriod: const Duration(days: 30),
      maxNrOfCacheObjects: 500,
      // Absolute .db path keeps meta under [root]. Do not assert SQL plans.
      repo: CacheObjectProvider(path: dbPath),
      fileSystem: _RootFileSystem(root.path),
      fileService: HttpFileService(httpClient: client),
    ),
  );
  return _StockAdapter(
    id: 'stock_cni',
    label: 'cached_network_image (sqflite)',
    root: root,
    manager: manager,
    client: client,
  );
}

var _sqfliteFfiReady = false;

void _ensureSqfliteFfi() {
  if (_sqfliteFfiReady) return;
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  _sqfliteFfiReady = true;
}

final class _StockAdapter implements IBytesReadyAdapter {
  _StockAdapter({
    required this.id,
    required this.label,
    required io.Directory root,
    required CacheManager manager,
    required http.Client client,
  }) : _root = root,
       _manager = manager,
       _client = client;

  @override
  final String id;

  @override
  final String label;

  final io.Directory _root;
  final CacheManager _manager;
  final http.Client _client;
  var _closed = false;

  @override
  Future<Uint8List> getBytes(String url) async {
    final file = await _manager.getSingleFile(url);
    return file.readAsBytes();
  }

  @override
  Future<void> evict(String url) => _manager.removeFile(url);

  @override
  Future<void> empty() => _manager.emptyCache();

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _manager.dispose();
    _client.close();
    if (_root.existsSync()) {
      await _root.delete(recursive: true);
    }
  }
}

/// Cache-manager [FileSystem] rooted at a fixed temp directory.
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
