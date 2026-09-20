/// Web CE paint manager (Hive boxes → IndexedDB).
library;

// ignore: implementation_imports
import 'package:cached_network_image_ce/src/cache/default_cache_manager_web.dart' as ce_web;
import 'package:http/http.dart' as http;

final class CeManagerOpen {
  const CeManagerOpen({required this.manager, required this.onClose});

  final ce_web.DefaultCacheManager manager;
  final Future<void> Function() onClose;
}

Future<CeManagerOpen> openCeManager({required http.Client client}) async {
  final manager = ce_web.DefaultCacheManager(
    httpClientFactory: () => client,
    stalePeriod: const Duration(days: 30),
    maxNrOfCacheObjects: 500,
  );
  return CeManagerOpen(
    manager: manager,
    onClose: () async {
      await manager.dispose();
    },
  );
}
