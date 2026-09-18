// PROFILE-MODE SCROLL-PRESSURE MATRIX (flutter-side compare)
//
// Headless `flutter_test` is not the frame-timing truth. This target scrolls a
// product-like image feed under **profile mode on a real device**, paints via
// `CachedNetworkSvgImage` (image_bytes_cache_flutter), and captures a
// TimelineSummary per matrix cell (build / raster percentiles + missed frames).
//
// Controlled local SVG corpus only — no public CDN.
//
// Matrix dimensions (dart-define):
//   MATRIX=subset|full   subset (default) = medium/medium/ordinary+complicated
//                        full = all list × speed × complexity (18 cells)
//   CELL=list/speed/complexity   optional single-cell override
//
// Density controls (orthogonal):
//   FEED=mixed|prose     mixed = complexity corpus; prose = one payload repeated
//   ITEM_MODE=natural|fixed  fixed clips every row to kFixedFeedItemHeight
//
// Cell ids appear in logs and report keys (`scroll_ours__large_fast_complicated`
// → summarize / RESULTS as `large/fast/complicated`).
//
// Three-way paint columns when fair; ours-only otherwise (competitors cannot
// consume this SVG corpus fairly yet — N/A, not a forced paint-inclusive lie).
//
// Run (real device / desktop runner; not a CI merge gate):
//   flutter create --platforms=linux \
//     --project-name image_bytes_cache_benchmark_compare .
//   flutter drive \
//     --driver=test_driver/perf_driver.dart \
//     --target=integration_test/scroll_perf_test.dart \
//     --profile -d linux
//   dart run tool/summarize_timeline.dart
//
// Full factorial:
//   flutter drive ... --dart-define=MATRIX=full
// Single cell:
//   flutter drive ... --dart-define=CELL=large/fast/complicated

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_bytes_cache/image_bytes_cache.dart';
import 'package:image_bytes_cache_benchmark_compare/corpus_http.dart';
import 'package:image_bytes_cache_benchmark_compare/feed_corpus.dart';
import 'package:image_bytes_cache_benchmark_compare/profile_matrix.dart';
import 'package:image_bytes_cache_flutter/image_bytes_cache_flutter.dart';
import 'package:integration_test/integration_test.dart';

const String _feedModeRaw = String.fromEnvironment(
  'FEED',
  defaultValue: 'mixed',
);
const String _itemModeRaw = String.fromEnvironment(
  'ITEM_MODE',
  defaultValue: 'natural',
);
const String _matrixModeRaw = String.fromEnvironment(
  'MATRIX',
  defaultValue: 'subset',
);
const String _cellOverride = String.fromEnvironment('CELL');

final FeedContentMode _feedMode = FeedContentMode.parse(_feedModeRaw);
final FeedItemMode _itemMode = FeedItemMode.parse(_itemModeRaw);
final MatrixRunMode _matrixMode = MatrixRunMode.parse(_matrixModeRaw);

const Key _feedKey = ValueKey<String>('feed');

const double _kAvatarSize = 56;

/// Modest fetch delay for complicated first-pass misses (local MockClient).
const Duration _kComplicatedHttpDelay = Duration(milliseconds: 2);

/// Frames to advance after a fling without waiting for image futures to settle.
const int _kComplicatedFlingPumps = 45;

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
    mode: _matrixMode,
  );

  for (final cell in cells) {
    testWidgets('scroll perf: ours (${cell.id})', (tester) async {
      final root = await Directory.systemTemp.createTemp('ibc_feed_');
      final httpHarness = corpusHttpClient(
        resolvePayload: feedPayloadForUrl,
        responseDelay: switch (cell.complexity) {
          FeedComplexity.complicated => _kComplicatedHttpDelay,
          FeedComplexity.ordinary => Duration.zero,
        },
      );
      final fetcher = HttpBytesFetcher(client: httpHarness.client);
      final cache = await ImageBytesCache.open(
        directory: root.path,
        throwOnOpenFailure: true,
      );
      final resolver = ImageBytesResolver(cache: cache, fetcher: fetcher);
      addTearDown(() async {
        await fetcher.close();
        await cache.close();
        httpHarness.client.close();
        if (root.existsSync()) {
          await root.delete(recursive: true);
        }
      });

      final urls = feedUrls(
        length: cell.listSize.itemCount,
        contentMode: _feedMode,
        complexity: cell.complexity,
      );

      // ignore: avoid_print
      print(
        'profile matrix cell=${cell.id} items=${urls.length} '
        'unique=${urls.toSet().length} MATRIX=${_matrixMode.name} '
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
                        CachedNetworkSvgImage(
                          url,
                          width: _kAvatarSize,
                          height: _kAvatarSize,
                          resolver: resolver,
                          placeholderBuilder: (_) => const SizedBox(
                            width: _kAvatarSize,
                            height: _kAvatarSize,
                            child: ColoredBox(color: Color(0xFFE0E0E0)),
                          ),
                          errorBuilder: (_, __, ___) => const SizedBox(
                            width: _kAvatarSize,
                            height: _kAvatarSize,
                            child: ColoredBox(color: Color(0xFFFFCDD2)),
                          ),
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

      switch (cell.complexity) {
        case FeedComplexity.ordinary:
          // Warm settle so ordinary mode is mostly cache hits under scroll.
          await tester.pumpAndSettle(const Duration(seconds: 5));
        case FeedComplexity.complicated:
          // First-pass misses: layout only, do not wait for resolve settle.
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
        reportKey: cell.reportKey,
      );
    });
  }
}
