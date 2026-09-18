import 'package:flutter_test/flutter_test.dart';
import 'package:image_bytes_cache_benchmark_compare/profile_matrix.dart';

void main() {
  group('ProfileMatrixCell curated catalog', () {
    test('warm / cold / pressure ids and contracts', () {
      expect(ProfileMatrixCell.warmScroll.id, 'warm-scroll');
      expect(ProfileMatrixCell.warmScroll.listSize, FeedListSize.medium);
      expect(ProfileMatrixCell.warmScroll.scroll, ScrollIntensity.medium);
      expect(ProfileMatrixCell.warmScroll.complexity, FeedComplexity.ordinary);
      expect(ProfileMatrixCell.warmScroll.warmSettle, isTrue);

      expect(ProfileMatrixCell.coldScroll.id, 'cold-scroll');
      expect(ProfileMatrixCell.coldScroll.complexity, FeedComplexity.complicated);
      expect(ProfileMatrixCell.coldScroll.warmSettle, isFalse);

      expect(ProfileMatrixCell.pressureScroll.id, 'pressure-scroll');
      expect(ProfileMatrixCell.pressureScroll.listSize, FeedListSize.large);
      expect(ProfileMatrixCell.pressureScroll.scroll, ScrollIntensity.fast);
      expect(
        ProfileMatrixCell.pressureScroll.complexity,
        FeedComplexity.complicated,
      );
    });

    test('reportKeyFor encodes adapter + hyphenated cell id', () {
      expect(
        ProfileMatrixCell.warmScroll.reportKeyFor('ours'),
        'scroll_ours__warm-scroll',
      );
      expect(
        ProfileMatrixCell.pressureScroll.reportKeyFor('stock_cni'),
        'scroll_stock_cni__pressure-scroll',
      );
    });

    test('parseId round-trips curated cells', () {
      for (final cell in ProfileMatrixCell.curated) {
        expect(ProfileMatrixCell.parseId(cell.id), cell);
      }
    });

    test('parseId rejects unknown tokens', () {
      expect(
        () => ProfileMatrixCell.parseId('large/fast/complicated'),
        throwsArgumentError,
      );
    });
  });

  group('ProfileReportKey', () {
    test('encodes and parses hyphenated curated keys', () {
      final key = ProfileReportKey.encode(
        adapter: 'ce_hive',
        cellId: 'cold-scroll',
      );
      expect(key, 'scroll_ce_hive__cold-scroll');
      expect(
        ProfileReportKey.tryParse(key),
        ('cold-scroll', 'ce_hive'),
      );
    });

    test('encodes and parses default cell keys', () {
      expect(
        ProfileReportKey.encode(adapter: 'ours', cellId: 'default'),
        'scroll_ours',
      );
      expect(
        ProfileReportKey.tryParse('scroll_ours'),
        ('default', 'ours'),
      );
    });
  });

  group('resolveCells', () {
    test('defaults to the three curated cells', () {
      expect(
        ProfileMatrixCell.resolveCells().map((c) => c.id).toList(),
        <String>['warm-scroll', 'cold-scroll', 'pressure-scroll'],
      );
    });

    test('CELL overrides to a single cell', () {
      final cells = ProfileMatrixCell.resolveCells(cellId: 'pressure-scroll');
      expect(cells, hasLength(1));
      expect(cells.single.id, 'pressure-scroll');
    });
  });

  group('ScrollIntensity gesture recipes', () {
    test('each intensity has concrete drag distance, velocity, passes', () {
      for (final intensity in ScrollIntensity.values) {
        final recipe = intensity.recipe;
        expect(recipe.dragOffset.dy.abs(), greaterThan(0));
        expect(recipe.velocityPxPerSec, greaterThan(0));
        expect(recipe.passCount, greaterThan(0));
      }
      expect(
        ScrollIntensity.slow.recipe.velocityPxPerSec,
        lessThan(ScrollIntensity.medium.recipe.velocityPxPerSec),
      );
      expect(
        ScrollIntensity.medium.recipe.velocityPxPerSec,
        lessThan(ScrollIntensity.fast.recipe.velocityPxPerSec),
      );
    });
  });

  group('FeedListSize counts', () {
    test('small < medium < large', () {
      expect(FeedListSize.small.itemCount, 24);
      expect(FeedListSize.medium.itemCount, 48);
      expect(FeedListSize.large.itemCount, 120);
    });
  });
}
