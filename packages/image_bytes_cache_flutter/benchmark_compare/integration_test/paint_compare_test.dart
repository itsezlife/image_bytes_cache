// THREE-WAY RASTER PAINT CORRECTNESS (flutter-side compare)
//
// Side-by-side integration proof that ours, cached_network_image_ce, and stock
// cached_network_image can resolve + paint the same controlled PNG corpus.
// Competitors do not ship this harness — it lives only here.
//
// Not a CI merge gate. Prefer a desktop/device runner when plugins require it:
//
//   flutter test integration_test/paint_compare_test.dart -d flutter-tester

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_bytes_cache_benchmark_compare/adapters/ce_paint_adapter.dart';
import 'package:image_bytes_cache_benchmark_compare/adapters/ours_paint_adapter.dart';
import 'package:image_bytes_cache_benchmark_compare/adapters/stock_cni_paint_adapter.dart';
import 'package:image_bytes_cache_benchmark_compare/feed_corpus.dart';
import 'package:image_bytes_cache_benchmark_compare/paint_adapter.dart';
import 'package:image_bytes_cache_benchmark_compare/profile_matrix.dart';
import 'package:integration_test/integration_test.dart';

const double _kSize = 56;
const Key _feedKey = ValueKey<String>('paint-feed');

typedef _PaintOpen = Future<IPaintFeedAdapter> Function();

final List<(String id, _PaintOpen open)> _stacks = <(String, _PaintOpen)>[
  ('ours', openOursPaintAdapter),
  ('ce_hive', openCeHivePaintAdapter),
  ('stock_cni', openStockCniPaintAdapter),
];

Widget _wrap(Widget child) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Scaffold(body: Center(child: child)),
  );
}

Widget _instrumented(IPaintFeedAdapter adapter, String url) {
  return KeyedSubtree(
    key: ValueKey<String>('img-${adapter.id}'),
    child: adapter.buildImage(url, width: _kSize, height: _kSize),
  );
}

Future<void> _pumpFrames(WidgetTester tester, {int frames = 20}) async {
  // Live binding: allow isolate/HTTP to progress between pumps.
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<void> _closeBounded(IPaintFeedAdapter adapter) async {
  await adapter.close().timeout(
    const Duration(seconds: 5),
    onTimeout: () {},
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  for (final (stackId, open) in _stacks) {
    group('paint compare: $stackId', () {
      testWidgets('cold load paints PNG without throwing', (tester) async {
        final adapter = await open();
        addTearDown(() => _closeBounded(adapter));
        imageCache.clear();
        imageCache.clearLiveImages();

        final url = feedUrl(slot: 0);
        await tester.pumpWidget(_wrap(_instrumented(adapter, url)));
        await _pumpFrames(tester);
        expect(tester.takeException(), isNull);
        expect(find.byKey(ValueKey<String>('img-$stackId')), findsOneWidget);
      });

      testWidgets('warm reload still paints after settle', (tester) async {
        final adapter = await open();
        addTearDown(() => _closeBounded(adapter));

        final url = feedUrl(slot: 1);
        await tester.pumpWidget(_wrap(_instrumented(adapter, url)));
        await _pumpFrames(tester);

        await tester.pumpWidget(_wrap(_instrumented(adapter, url)));
        await _pumpFrames(tester, frames: 20);

        expect(tester.takeException(), isNull);
        expect(find.byKey(ValueKey<String>('img-$stackId')), findsOneWidget);
      });

      testWidgets('short ordinary feed scrolls without throwing', (tester) async {
        final adapter = await open();
        addTearDown(() => _closeBounded(adapter));
        imageCache.clear();
        imageCache.clearLiveImages();

        final urls = feedUrls(length: 8, complexity: FeedComplexity.ordinary);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ListView.builder(
                key: _feedKey,
                itemCount: urls.length,
                itemBuilder: (context, i) {
                  return Padding(
                    padding: const EdgeInsets.all(8),
                    child: Row(
                      children: [
                        adapter.buildImage(
                          urls[i],
                          width: _kSize,
                          height: _kSize,
                        ),
                        Text('Item $i'),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        );
        await _pumpFrames(tester);
        await tester.fling(find.byKey(_feedKey), const Offset(0, -300), 1000);
        await _pumpFrames(tester, frames: 20);
        expect(tester.takeException(), isNull);
        expect(find.text('Item 0'), findsWidgets);
      });

      testWidgets('empty then reload paints miss path again', (tester) async {
        final adapter = await open();
        addTearDown(() => _closeBounded(adapter));

        final url = feedUrl(slot: 2);
        await tester.pumpWidget(_wrap(_instrumented(adapter, url)));
        await _pumpFrames(tester);

        await adapter.empty();
        imageCache.clear();
        imageCache.clearLiveImages();

        await tester.pumpWidget(_wrap(_instrumented(adapter, url)));
        await _pumpFrames(tester);
        expect(tester.takeException(), isNull);
        expect(find.byKey(ValueKey<String>('img-$stackId')), findsOneWidget);
      });
    });
  }
}
