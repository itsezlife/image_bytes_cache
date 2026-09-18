import 'package:flutter_test/flutter_test.dart';
import 'package:image_bytes_cache_benchmark_compare/adapters/ce_adapter.dart';
import 'package:image_bytes_cache_benchmark_compare/adapters/ours_adapter.dart';
import 'package:image_bytes_cache_benchmark_compare/adapters/stock_cni_adapter.dart';
import 'package:image_bytes_cache_benchmark_compare/corpus.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('corpus', () {
    test('urlFor maps to payloadForUrl', () {
      for (final klass in PayloadClass.values) {
        final url = urlFor(klass, slot: 3);
        final payload = payloadForUrl(url);
        expect(payload, isNotNull);
        expect(payload, payloadFor(klass));
      }
    });

    test('unknown URL returns null', () {
      expect(payloadForUrl('https://example.com/x.png'), isNull);
    });
  });

  group('IBytesReadyAdapter seam', () {
    for (final entry in [
      ('ours', openOursAdapter),
      ('ce_hive', openCeHiveAdapter),
      ('stock_cni', openStockCniAdapter),
    ]) {
      test('${entry.$1} cold then warm returns corpus bytes', () async {
        final adapter = await entry.$2();
        addTearDown(adapter.close);
        final url = urlFor(PayloadClass.small);
        final expected = payloadFor(PayloadClass.small);

        await adapter.evict(url);
        final cold = await adapter.getBytes(url);
        expect(cold, expected);

        await awaitOursWriteThrough(adapter, url);
        final warm = await adapter.getBytes(url);
        expect(warm, expected);
      });
    }
  });
}
