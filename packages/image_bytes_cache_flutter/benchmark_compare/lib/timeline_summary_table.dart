/// Formats `flutter drive` TimelineSummary JSON into paste-ready Markdown.
///
/// Expects the map written by `integrationDriver()` (typically
/// `build/integration_response_data.json`). Report keys follow
/// [ProfileReportKey]: curated cells use `scroll_<adapter>__<cell-id>`
/// (e.g. `scroll_ours__warm-scroll`); an unlabeled single run uses
/// `scroll_<adapter>` (cell id `default`).
///
/// This lane is **not** a CI merge gate and does not replace core store
/// microbenches or the bytes-ready doctrine tables.
library;

import 'dart:convert';

import 'package:image_bytes_cache_benchmark_compare/profile_report_key.dart';

/// Metric rows: display label → TimelineSummary JSON key.
const List<(String, String)> kTimelineSummaryMetrics = <(String, String)>[
  ('frame build avg (ms)', 'average_frame_build_time_millis'),
  ('frame build 90th (ms)', '90th_percentile_frame_build_time_millis'),
  ('frame build 99th (ms)', '99th_percentile_frame_build_time_millis'),
  ('frame build worst (ms)', 'worst_frame_build_time_millis'),
  ('raster avg (ms)', 'average_frame_rasterizer_time_millis'),
  ('raster 90th (ms)', '90th_percentile_frame_rasterizer_time_millis'),
  ('raster 99th (ms)', '99th_percentile_frame_rasterizer_time_millis'),
  ('raster worst (ms)', 'worst_frame_rasterizer_time_millis'),
  ('missed build frames', 'missed_frame_build_budget_count'),
  ('missed raster frames', 'missed_frame_rasterizer_budget_count'),
  ('frame count', 'frame_count'),
];

/// Discovers `(cellId, adapterId)` pairs from driver [data] keys.
List<(String cellId, String adapterId)> discoverTimelineReportKeys(
  Map<String, Object?> data,
) {
  final found = <(String, String)>[];
  for (final key in data.keys) {
    if (ProfileReportKey.tryParse(key) case final parsed?) {
      found.add(parsed);
    }
  }
  found.sort((a, b) {
    final byCell = a.$1.compareTo(b.$1);
    if (byCell != 0) return byCell;
    return a.$2.compareTo(b.$2);
  });
  return found;
}

/// Builds Markdown for every discovered cell in [data].
///
/// When [cellId] is set, only that cell is rendered. Missing adapter columns
/// render as `-`. Competitor paint columns appear only when their report keys
/// are present; otherwise the table stays ours-only (N/A is the honest
/// unfairness call — do not invent paint-inclusive competitor numbers).
String formatAllTimelineSummariesMarkdown(
  Map<String, Object?> data, {
  String? cellId,
  List<String> preferredAdapters = const <String>[
    'ours',
    'ce_hive',
    'stock_cni',
  ],
}) {
  final discovered = discoverTimelineReportKeys(data);
  final cellIds = <String>{
    for (final (cell, _) in discovered) cell,
  };
  if (cellId != null) {
    cellIds.retainWhere((id) => id == cellId);
  }
  if (cellIds.isEmpty) {
    // Still emit a placeholder table so harvest docs stay paste-shaped.
    return formatTimelineSummaryMarkdown(
      data,
      adapters: preferredAdapters,
      cellId: cellId ?? ProfileReportKey.defaultCellId,
    );
  }

  final orderedCells = cellIds.toList()..sort();
  final buf = StringBuffer();
  for (final cell in orderedCells) {
    final adapters =
        <String>{
          ...preferredAdapters,
          for (final (c, adapter) in discovered)
            if (c == cell) adapter,
        }.toList()..sort((a, b) {
          if (a == 'ours' && b != 'ours') return -1;
          if (b == 'ours' && a != 'ours') return 1;
          return a.compareTo(b);
        });
    buf.write(
      formatTimelineSummaryMarkdown(
        data,
        adapters: adapters,
        cellId: cell,
      ),
    );
  }
  return buf.toString();
}

/// Builds a Markdown table from driver [data] for one cell.
///
/// [adapters] are column ids. [cellId] labels the run when present; keys are
/// resolved via [ProfileReportKey.encode].
String formatTimelineSummaryMarkdown(
  Map<String, Object?> data, {
  required List<String> adapters,
  String? cellId,
}) {
  final effectiveCell = cellId ?? ProfileReportKey.defaultCellId;
  final summaries = <String, Map<String, Object?>>{};
  for (final id in adapters) {
    final raw =
        data[ProfileReportKey.encode(
          adapter: id,
          cellId: effectiveCell,
        )];
    switch (raw) {
      case final Map<String, Object?> map:
        summaries[id] = map;
      case final Map map:
        summaries[id] = map.cast<String, Object?>();
      case final String encoded:
        switch (json.decode(encoded)) {
          case final Map<String, Object?> map:
            summaries[id] = map;
          case final Map map:
            summaries[id] = map.cast<String, Object?>();
          default:
            break;
        }
      default:
        break;
    }
  }

  final buf = StringBuffer()..writeln();
  if (cellId case final id?) {
    buf.writeln(
      'Profile-mode image feed — cell `$id` '
      '(real frame timings; lower is better)',
    );
  } else {
    buf.writeln(
      'Profile-mode image feed — real frame timings (lower is better)',
    );
  }
  buf.writeln();

  final header = StringBuffer('| metric                  |');
  final sep = StringBuffer('| ----------------------- |');
  for (final id in adapters) {
    header.write(' ${id.padLeft(16)} |');
    sep.write(' ---------------: |');
  }
  buf
    ..writeln(header)
    ..writeln(sep);

  for (final (label, key) in kTimelineSummaryMetrics) {
    final row = StringBuffer('| ${label.padRight(23)} |');
    for (final id in adapters) {
      final summary = summaries[id];
      final value = summary == null ? null : _num(summary, key);
      row.write(' ${_cell(value).padLeft(16)} |');
    }
    buf.writeln(row);
  }
  buf.writeln();
  return buf.toString();
}

double? _num(Map<String, Object?> map, String key) {
  return switch (map[key]) {
    final num n => n.toDouble(),
    _ => null,
  };
}

String _cell(double? value) {
  if (value == null) return '-';
  if (value == value.roundToDouble()) {
    return value.toStringAsFixed(0);
  }
  return value.toStringAsFixed(2);
}
