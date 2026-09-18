// ignore_for_file: avoid_print
//
// Formats profile-mode image-feed TimelineSummary JSON into Markdown.
// Discovers curated cells (`scroll_ours__warm-scroll` → `warm-scroll`) and
// prints one table per cell with discovered adapter columns.
//
//   dart run tool/summarize_timeline.dart
//   dart run tool/summarize_timeline.dart --cell warm-scroll

import 'dart:convert';
import 'dart:io';

import 'package:image_bytes_cache_benchmark_compare/timeline_summary_table.dart';

const String _kInput = 'build/integration_response_data.json';

const List<String> _kPreferredAdapters = <String>[
  'ours',
  'ce_hive',
  'stock_cni',
];

void main(List<String> args) {
  String? cellId;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--cell' && i + 1 < args.length) {
      cellId = args[i + 1];
      i++;
    }
  }

  final file = File(_kInput);
  if (!file.existsSync()) {
    stderr.writeln(
      'Not found: $_kInput\n'
      'Run the profile-mode feed first (real device, not a CI gate):\n'
      '  flutter drive --driver=test_driver/perf_driver.dart '
      '--target=integration_test/scroll_perf_test.dart '
      '--profile --no-dds -d <device>\n'
      'Default cells: warm-scroll, cold-scroll, pressure-scroll. '
      'Single cell: --dart-define=CELL=warm-scroll',
    );
    exitCode = 1;
    return;
  }

  final decoded = json.decode(file.readAsStringSync());
  if (decoded case final Map<String, Object?> map) {
    stdout.write(
      formatAllTimelineSummariesMarkdown(
        map,
        cellId: cellId,
        preferredAdapters: _kPreferredAdapters,
      ),
    );
    return;
  }
  if (decoded case final Map map) {
    stdout.write(
      formatAllTimelineSummariesMarkdown(
        map.cast<String, Object?>(),
        cellId: cellId,
        preferredAdapters: _kPreferredAdapters,
      ),
    );
    return;
  }

  stderr.writeln('Expected a JSON object in $_kInput');
  exitCode = 1;
}
