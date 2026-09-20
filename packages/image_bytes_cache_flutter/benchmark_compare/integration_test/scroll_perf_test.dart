// PROFILE-MODE THREE-WAY RASTER SCROLL (flutter-side compare)
//
// Headless `flutter_test` is not the frame-timing truth. This target scrolls a
// product-like PNG feed under **profile mode on a real device**, paints via
// ours / CE Hive / stock CNI adapters, and captures a TimelineSummary per
// curated cell × adapter (build / raster percentiles + missed frames).
//
// Controlled local PNG corpus only — no public CDN.
//
// Curated cells (default all three):
//   warm-scroll      medium list, medium fling, ordinary, warm settle
//   cold-scroll      medium list, medium fling, complicated, first-pass misses
//   pressure-scroll  large list, fast fling, complicated
//
// Optional:
//   CELL=warm-scroll|cold-scroll|pressure-scroll
//   FEED=mixed|prose
//   ITEM_MODE=natural|fixed
//
// Run (real device / desktop runner; not a CI merge gate):
//   flutter create --platforms=linux \
//     --project-name image_bytes_cache_benchmark_compare .
//   flutter drive \
//     --driver=test_driver/perf_driver.dart \
//     --target=integration_test/scroll_perf_test.dart \
//     --profile -d linux
//   dart run tool/summarize_timeline.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_bytes_cache_benchmark_compare/adapters/ce_paint_adapter.dart';
import 'package:image_bytes_cache_benchmark_compare/adapters/ours_paint_adapter.dart';
import 'package:image_bytes_cache_benchmark_compare/adapters/stock_cni_paint_adapter.dart';
import 'package:image_bytes_cache_benchmark_compare/feed_corpus.dart';
import 'package:image_bytes_cache_benchmark_compare/paint_adapter.dart';
import 'package:image_bytes_cache_benchmark_compare/profile_matrix.dart';
import 'package:integration_test/integration_test.dart';

const String _feedModeRaw = String.fromEnvironment(
  'FEED',
  defaultValue: 'mixed',
);
const String _itemModeRaw = String.fromEnvironment(
  'ITEM_MODE',
  defaultValue: 'natural',
);
const String _cellOverride = String.fromEnvironment('CELL');

final FeedContentMode _feedMode = FeedContentMode.parse(_feedModeRaw);
final FeedItemMode _itemMode = FeedItemMode.parse(_itemModeRaw);

const Key _feedKey = ValueKey<String>('feed');

const double _kAvatarSize = 56;

/// Modest fetch delay for complicated first-pass misses (local MockClient).
const Duration _kComplicatedHttpDelay = Duration(milliseconds: 2);

/// Frames to advance after a fling without waiting for image futures to settle.
const int _kComplicatedFlingPumps = 45;

typedef _PaintOpen = Future<IPaintFeedAdapter> Function({Duration responseDelay});

final List<(String id, _PaintOpen open)> _stacks = <(String, _PaintOpen)>[
  ('ours', openOursPaintAdapter),
  ('ce_hive', openCeHivePaintAdapter),
  ('stock_cni', openStockCniPaintAdapter),
];

Widget _sizeItem(Widget child) {
  if (_itemMode != FeedItemMode.fixed) return child;
  return SizedBox(
    height: kFixedFeedItemHeight,
    child: ClipRect(
      child: OverflowBox(
        alignment: Alignment.topLeft,
        minHeight: 0,
        maxHeight: double.infinity,
        child: child,
      ),
    ),
  );
}

/// After a fling: ordinary waits for idle (warm hits); complicated advances a
/// fixed frame budget so resolve/miss work stays on the measured timeline.
Future<void> _afterFling(
  WidgetTester tester,
  FeedComplexity complexity,
) async {
  switch (complexity) {
    case FeedComplexity.ordinary:
      await tester.pumpAndSettle();
    case FeedComplexity.complicated:
      for (var i = 0; i < _kComplicatedFlingPumps; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final cells = ProfileMatrixCell.resolveCells(
    cellId: _cellOverride.isEmpty ? null : _cellOverride,
  );

  for (final cell in cells) {
    for (final (stackId, open) in _stacks) {
      testWidgets('scroll perf: $stackId (${cell.id})', (tester) async {
        final adapter = await open(
          responseDelay: switch (cell.complexity) {
            FeedComplexity.complicated => _kComplicatedHttpDelay,
            FeedComplexity.ordinary => Duration.zero,
          },
        );
        addTearDown(adapter.close);

        // Cold decode: clear Flutter's bitmap cache between cells/stacks.
        imageCache.clear();
        imageCache.clearLiveImages();

        final urls = feedUrls(
          length: cell.listSize.itemCount,
          contentMode: _feedMode,
          complexity: cell.complexity,
        );

        // ignore: avoid_print
        print(
          'profile matrix cell=${cell.id} adapter=$stackId '
          'items=${urls.length} unique=${urls.toSet().length} '
          'FEED=${_feedMode.name} ITEM_MODE=${_itemMode.name}',
        );

        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            home: Scaffold(
              body: ListView.builder(
                key: _feedKey,
                itemCount: urls.length,
                itemBuilder: (context, i) {
                  final url = urls[i];
                  return _sizeItem(
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      child: Row(
                        children: [
                          adapter.buildImage(
                            url,
                            width: _kAvatarSize,
                            height: _kAvatarSize,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Item $i',
                              style: const TextStyle(fontSize: 16),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        );

        if (cell.warmSettle) {
          await tester.pumpAndSettle(const Duration(seconds: 5));
        } else {
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 16));
        }

        final listFinder = find.byKey(_feedKey);
        final recipe = cell.scroll.recipe;
        final reverse = Offset(0, -recipe.dragOffset.dy);

        await binding.watchPerformance(
          () async {
            for (var i = 0; i < recipe.passCount; i++) {
              await tester.fling(
                listFinder,
                recipe.dragOffset,
                recipe.velocityPxPerSec,
              );
              await _afterFling(tester, cell.complexity);
              await tester.fling(
                listFinder,
                reverse,
                recipe.velocityPxPerSec,
              );
              await _afterFling(tester, cell.complexity);
            }
          },
          reportKey: cell.reportKeyFor(stackId),
        );
      });
    }
  }
}
