import 'package:cached_network_image/cached_network_image.dart' as stock;
import 'package:cached_network_image_ce/cached_network_image.dart' as ce;
import 'package:flutter_test/flutter_test.dart';
import 'package:image_bytes_cache_benchmark_compare/adapters/ce_paint_adapter.dart';
import 'package:image_bytes_cache_benchmark_compare/adapters/ours_paint_adapter.dart';
import 'package:image_bytes_cache_benchmark_compare/adapters/stock_cni_paint_adapter.dart';
import 'package:image_bytes_cache_benchmark_compare/feed_corpus.dart';
import 'package:image_bytes_cache_benchmark_compare/paint_adapter.dart';
import 'package:image_bytes_cache_flutter/image_bytes_cache_flutter.dart';

void main() {
  // Plain `test` (not testWidgets): opening durable stores / CacheManagers uses
  // isolates and real async. Pumping [CachedNetworkBytesImage] under FakeAsync
  // deadlocks the ladder — live paint belongs in integration_test/.

  group('IPaintFeedAdapter seam', () {
    test('ours buildImage returns CachedNetworkBytesImage', () async {
      final adapter = await openOursPaintAdapter();
      addTearDown(() => _closeBounded(adapter));
      final widget = adapter.buildImage(
        feedUrl(slot: 0),
        width: 56,
        height: 56,
      );
      expect(widget, isA<CachedNetworkBytesImage>());
      expect(adapter.id, 'ours');
    });

    test('ce_hive buildImage returns CachedNetworkImage', () async {
      final adapter = await openCeHivePaintAdapter();
      addTearDown(() => _closeBounded(adapter));
      final widget = adapter.buildImage(
        feedUrl(slot: 0),
        width: 56,
        height: 56,
      );
      expect(widget, isA<ce.CachedNetworkImage>());
      expect(adapter.id, 'ce_hive');
    });

    test('stock_cni buildImage returns CachedNetworkImage', () async {
      final adapter = await openStockCniPaintAdapter();
      addTearDown(() => _closeBounded(adapter));
      final widget = adapter.buildImage(
        feedUrl(slot: 0),
        width: 56,
        height: 56,
      );
      expect(widget, isA<stock.CachedNetworkImage>());
      expect(adapter.id, 'stock_cni');
    });
  });
}

Future<void> _closeBounded(IPaintFeedAdapter adapter) async {
  await adapter.close().timeout(
    const Duration(seconds: 5),
    onTimeout: () {},
  );
}
