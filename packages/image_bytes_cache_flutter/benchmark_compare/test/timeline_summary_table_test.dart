import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_bytes_cache_benchmark_compare/timeline_summary_table.dart';

Map<String, Object?> _summary({
  double buildAvg = 1.25,
  int frames = 120,
}) => <String, Object?>{
  'average_frame_build_time_millis': buildAvg,
  '90th_percentile_frame_build_time_millis': 2.0,
  '99th_percentile_frame_build_time_millis': 3.5,
  'worst_frame_build_time_millis': 4.0,
  'average_frame_rasterizer_time_millis': 0.8,
  '90th_percentile_frame_rasterizer_time_millis': 1.1,
  '99th_percentile_frame_rasterizer_time_millis': 1.4,
  'worst_frame_rasterizer_time_millis': 1.9,
  'missed_frame_build_budget_count': 0,
  'missed_frame_rasterizer_budget_count': 1,
  'frame_count': frames,
};

void main() {
  group('formatTimelineSummaryMarkdown', () {
    test('prints paste-ready metric rows for default scroll_ours', () {
      final data = <String, Object?>{
        'scroll_ours': _summary(),
      };

      final md = formatTimelineSummaryMarkdown(
        data,
        adapters: const <String>['ours'],
        cellId: 'default',
      );

      expect(md, contains('default'));
      expect(md, contains('| metric'));
      expect(md, contains('ours'));
      expect(md, contains('frame build avg (ms)'));
      expect(md, contains('1.25'));
      expect(md, contains('missed raster frames'));
      expect(md, contains('|                1 |'));
      expect(md, contains('frame count'));
    });

    test('reads curated report keys for named cells', () {
      final data = <String, Object?>{
        'scroll_ours__pressure-scroll': _summary(buildAvg: 3.5),
      };

      final md = formatTimelineSummaryMarkdown(
        data,
        adapters: const <String>['ours'],
        cellId: 'pressure-scroll',
      );

      expect(md, contains('pressure-scroll'));
      expect(md, contains('3.50'));
    });

    test('accepts string-encoded TimelineSummary JSON', () {
      final encoded = json.encode(<String, Object?>{
        'average_frame_build_time_millis': 2.5,
        'frame_count': 10,
      });
      final md = formatTimelineSummaryMarkdown(
        <String, Object?>{'scroll_ours': encoded},
        adapters: const <String>['ours'],
      );
      expect(md, contains('2.50'));
      expect(md, contains('|               10 |'));
    });

    test('missing adapter cell is a dash', () {
      final md = formatTimelineSummaryMarkdown(
        const <String, Object?>{},
        adapters: const <String>['ours'],
      );
      expect(md, contains('|                - |'));
    });
  });

  group('formatAllTimelineSummariesMarkdown', () {
    test('emits one named table per discovered curated cell', () {
      final data = <String, Object?>{
        'scroll_ours__warm-scroll': _summary(buildAvg: 1.0),
        'scroll_ours__cold-scroll': _summary(buildAvg: 2.0),
        'scroll_ce_hive__warm-scroll': _summary(buildAvg: 1.5),
      };

      final md = formatAllTimelineSummariesMarkdown(
        data,
        preferredAdapters: const <String>['ours', 'ce_hive', 'stock_cni'],
      );

      expect(md, contains('warm-scroll'));
      expect(md, contains('cold-scroll'));
      expect(md, contains('ce_hive'));
      expect(md, contains('|                1 |'));
      expect(md, contains('|                2 |'));
    });

    test('--cell filter keeps a single matrix table', () {
      final data = <String, Object?>{
        'scroll_ours__warm-scroll': _summary(buildAvg: 1.0),
        'scroll_ours__cold-scroll': _summary(buildAvg: 2.0),
      };

      final md = formatAllTimelineSummariesMarkdown(
        data,
        cellId: 'warm-scroll',
      );

      expect(md, contains('warm-scroll'));
      expect(md, isNot(contains('cold-scroll')));
    });
  });

  group('discoverTimelineReportKeys', () {
    test('maps curated and default keys to cell ids', () {
      final keys = discoverTimelineReportKeys(<String, Object?>{
        'scroll_ours__pressure-scroll': _summary(),
        'scroll_ours': _summary(),
        'scroll_stock_cni__warm-scroll': _summary(),
      });
      expect(
        keys,
        containsAll(<(String, String)>[
          ('default', 'ours'),
          ('pressure-scroll', 'ours'),
          ('warm-scroll', 'stock_cni'),
        ]),
      );
    });
  });
}
