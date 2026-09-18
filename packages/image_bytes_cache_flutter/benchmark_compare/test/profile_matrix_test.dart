import 'package:flutter_test/flutter_test.dart';
import 'package:image_bytes_cache_benchmark_compare/profile_matrix.dart';

void main() {
  group('ProfileMatrixCell', () {
    test('id is list/speed/complexity', () {
      const cell = ProfileMatrixCell(
        listSize: FeedListSize.large,
        scroll: ScrollIntensity.fast,
        complexity: FeedComplexity.complicated,
      );
      expect(cell.id, 'large/fast/complicated');
      expect(cell.reportKey, 'scroll_ours__large_fast_complicated');
    });

    test('parseId round-trips known cells', () {
      final cell = ProfileMatrixCell.parseId('medium/medium/ordinary');
      expect(cell.listSize, FeedListSize.medium);
      expect(cell.scroll, ScrollIntensity.medium);
      expect(cell.complexity, FeedComplexity.ordinary);
      expect(cell.id, 'medium/medium/ordinary');
    });

    test('parseId rejects unknown tokens', () {
      expect(
        () => ProfileMatrixCell.parseId('huge/fast/ordinary'),
        throwsArgumentError,
      );
    });
  });

  group('ProfileReportKey', () {
    test('encodes and parses matrix keys including underscored adapters', () {
      final key = ProfileReportKey.encode(
        adapter: 'stock_cni',
        cellId: 'large/fast/complicated',
      );
      expect(key, 'scroll_stock_cni__large_fast_complicated');
      expect(
        ProfileReportKey.tryParse(key),
        ('large/fast/complicated', 'stock_cni'),
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

  group('matrix catalogs', () {
    test('default subset is medium × medium × ordinary+complicated', () {
      expect(
        ProfileMatrixCell.defaultSubset.map((c) => c.id).toList(),
        <String>[
          'medium/medium/ordinary',
          'medium/medium/complicated',
        ],
      );
    });

    test('full factorial is 3 × 3 × 2 named cells', () {
      final cells = ProfileMatrixCell.fullFactorial;
      expect(cells, hasLength(18));
      expect(cells.map((c) => c.id).toSet(), hasLength(18));
      expect(cells.any((c) => c.id == 'small/slow/ordinary'), isTrue);
      expect(cells.any((c) => c.id == 'large/fast/complicated'), isTrue);
    });

    test('resolveCells: subset by default, full when MatrixRunMode.full', () {
      expect(
        ProfileMatrixCell.resolveCells().map((c) => c.id),
        ProfileMatrixCell.defaultSubset.map((c) => c.id),
      );
      expect(
        ProfileMatrixCell.resolveCells(mode: MatrixRunMode.full),
        hasLength(18),
      );
    });

    test('resolveCells: CELL overrides to a single cell', () {
      final cells = ProfileMatrixCell.resolveCells(
        cellId: 'large/fast/complicated',
        mode: MatrixRunMode.full,
      );
      expect(cells, hasLength(1));
      expect(cells.single.id, 'large/fast/complicated');
    });

    test('MatrixRunMode.parse is fail-closed', () {
      expect(MatrixRunMode.parse('subset'), MatrixRunMode.subset);
      expect(MatrixRunMode.parse('full'), MatrixRunMode.full);
      expect(() => MatrixRunMode.parse('all'), throwsArgumentError);
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
