// ignore_for_file: avoid_print
//
// Formats profile-mode image-feed TimelineSummary JSON into Markdown.
// Discovers named matrix cells (`scroll_ours__large_fast_complicated` →
// `large/fast/complicated`) and prints one table per cell.
//
//   dart run tool/summarize_timeline.dart
//   dart run tool/summarize_timeline.dart --cell medium/medium/ordinary

import 'dart:convert';
import 'dart:io';

import 'package:image_bytes_cache_benchmark_compare/timeline_summary_table.dart';

const String _kInput = 'build/integration_response_data.json';

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
      'Default MATRIX=subset (medium/medium/ordinary+complicated). '
      'Full factorial: --dart-define=MATRIX=full',
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
        preferredAdapters: const <String>['ours'],
      ),
    );
    return;
  }
  if (decoded case final Map map) {
    stdout.write(
      formatAllTimelineSummariesMarkdown(
        map.cast<String, Object?>(),
        cellId: cellId,
        preferredAdapters: const <String>['ours'],
      ),
    );
    return;
  }

  stderr.writeln('Expected a JSON object in $_kInput');
  exitCode = 1;
}
