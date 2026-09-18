/// CE Hive: [DefaultCacheManager] with MockClient and isolated temp dirs.
library;

import 'dart:io' as io;
import 'dart:typed_data';

import 'package:cached_network_image_ce/cached_network_image.dart';
// Prefer the IO implementation so analyzer + VM share the Hive file-store API
// (the package barrel's stub lacks directory / httpClientFactory params).
// ignore: implementation_imports
import 'package:cached_network_image_ce/src/cache/default_cache_manager.dart' as ce_io;
import 'package:http/http.dart' as http;
import 'package:image_bytes_cache_benchmark_compare/adapter.dart';
import 'package:image_bytes_cache_benchmark_compare/corpus_http.dart';

/// Opens an isolated CE (Hive metadata + file blobs) adapter.
Future<IBytesReadyAdapter> openCeHiveAdapter({
  Duration responseDelay = Duration.zero,
}) async {
  final root = await io.Directory.systemTemp.createTemp('ibc_ce_');
  final meta = await io.Directory('${root.path}/hive').create(recursive: true);
  final httpHarness = corpusHttpClient(responseDelay: responseDelay);
  final client = httpHarness.client;
  final manager = ce_io.DefaultCacheManager(
    httpClientFactory: () => client,
    cacheDirectoryProvider: () async => root,
    metadataDirectoryProvider: () async => meta,
    stalePeriod: const Duration(days: 30),
    maxNrOfCacheObjects: 500,
  );
  return _CeAdapter(
    id: 'ce_hive',
    label: 'cached_network_image_ce (Hive)',
    root: root,
    manager: manager,
    client: client,
  );
}

final class _CeAdapter implements IBytesReadyAdapter {
  _CeAdapter({
    required this.id,
    required this.label,
    required io.Directory root,
    required ce_io.DefaultCacheManager manager,
    required http.Client client,
  }) : _root = root,
       _manager = manager,
       _client = client;

  @override
  final String id;

  @override
  final String label;

  final io.Directory _root;
  final ce_io.DefaultCacheManager _manager;
  final http.Client _client;
  var _closed = false;

  @override
  Future<Uint8List> getBytes(String url) async {
    await for (final response in _manager.getFileStream(url)) {
      switch (response) {
        case FileInfo(:final file):
          return file.readAsBytes();
        default:
          continue;
      }
    }
    throw StateError('CE adapter: no FileInfo for $url');
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
