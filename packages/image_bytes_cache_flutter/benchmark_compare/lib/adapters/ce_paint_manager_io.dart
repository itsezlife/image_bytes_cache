/// VM CE paint manager (Hive file store under a temp root).
library;

import 'dart:io' as io;

// Prefer the IO implementation so analyzer + VM share the Hive file-store API.
// ignore: implementation_imports
import 'package:cached_network_image_ce/src/cache/default_cache_manager.dart'
    as ce_io;
import 'package:http/http.dart' as http;

final class CeManagerOpen {
  const CeManagerOpen({required this.manager, required this.onClose});

  final ce_io.DefaultCacheManager manager;
  final Future<void> Function() onClose;
}

Future<CeManagerOpen> openCeManager({required http.Client client}) async {
  final root = await io.Directory.systemTemp.createTemp('ibc_ce_paint_');
  final meta = await io.Directory('${root.path}/hive').create(recursive: true);
  final manager = ce_io.DefaultCacheManager(
    httpClientFactory: () => client,
    cacheDirectoryProvider: () async => root,
    metadataDirectoryProvider: () async => meta,
    stalePeriod: const Duration(days: 30),
    maxNrOfCacheObjects: 500,
  );
  return CeManagerOpen(
    manager: manager,
    onClose: () async {
      await manager.dispose();
      if (root.existsSync()) {
        await root.delete(recursive: true);
      }
    },
  );
}
