// ignore_for_file: avoid_print
//
// THREE-WAY BYTES COMPARE — ours vs CE Hive vs stock CNI sqflite.
// Primary table = URL → bytes ready only (no decode / ImageProvider paint).
//
// Run from this package root:
//   flutter test test/bytes_compare_test.dart
//
// One adapter instance per stack is reused across rows (reopened only when the
// scenario’s HTTP delay changes). Closed after a short settle so
// flutter_cache_manager’s ~10s cleanup timer cannot hit a closed sqflite DB.
// Do not assert Hive box names or SQL plans.

import 'package:flutter_test/flutter_test.dart';
import 'package:image_bytes_cache_benchmark_compare/adapter.dart';
import 'package:image_bytes_cache_benchmark_compare/adapters/ce_adapter.dart';
import 'package:image_bytes_cache_benchmark_compare/adapters/ours_adapter.dart';
import 'package:image_bytes_cache_benchmark_compare/adapters/stock_cni_adapter.dart';
import 'package:image_bytes_cache_benchmark_compare/measure.dart';
import 'package:image_bytes_cache_benchmark_compare/scenarios.dart';

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  await runBytesCompare();
}

/// Opens each stack, times [bytesScenarios], prints Markdown tables.
Future<void> runBytesCompare() async {
  final scenarios = bytesScenarios();
  final columnMeta = <_Column>[
    _Column(id: 'ours', label: 'image_bytes_cache'),
    _Column(id: 'ce_hive', label: 'cached_network_image_ce (Hive)'),
    _Column(id: 'stock_cni', label: 'cached_network_image (sqflite)'),
  ];

  Future<IBytesReadyAdapter> openFor(
    String id,
    Duration responseDelay,
  ) => switch (id) {
    'ours' => openOursAdapter(responseDelay: responseDelay),
    'ce_hive' => openCeHiveAdapter(responseDelay: responseDelay),
    'stock_cni' => openStockCniAdapter(responseDelay: responseDelay),
    _ => throw StateError('unknown adapter $id'),
  };

  final cells = <String, Map<String, _Cell>>{};
  final live = <String, IBytesReadyAdapter>{};
  final liveDelay = <String, Duration>{};

  try {
    for (final scenario in scenarios) {
      cells[scenario.name] = {};
      for (final col in columnMeta) {
        try {
          final current = live[col.id];
          final needReopen = current == null || liveDelay[col.id] != scenario.responseDelay;
          if (needReopen) {
            if (current != null) {
              // Stock FCM schedules cleanup ~10s after meta reads; wait so
              // dispose does not race a closed sqflite handle.
              if (col.id == 'stock_cni') {
                await Future<void>.delayed(const Duration(seconds: 11));
              }
              await _safeClose(current);
            }
            live[col.id] = await openFor(col.id, scenario.responseDelay);
            liveDelay[col.id] = scenario.responseDelay;
          }
          final adapter = live[col.id]!;
          await adapter.empty();
          final seed = scenario.seed;
          if (seed != null) await seed(adapter);
          final us = await measureUsPerOp(
            () => scenario.run(adapter),
            beforeEach: scenario.beforeEach == null ? null : () => scenario.beforeEach!(adapter),
            warmupMs: scenario.responseDelay > Duration.zero ? 400 : 200,
          );
          cells[scenario.name]![col.id] = _Cell.ok(us);
        } on Object catch (error) {
          cells[scenario.name]![col.id] = _Cell.na('$error');
        }
      }
    }
  } finally {
    // Let flutter_cache_manager’s scheduled cleanup (~10s) finish while DBs
    // are still open, then dispose.
    await Future<void>.delayed(const Duration(seconds: 11));
    for (final adapter in live.values) {
      await _safeClose(adapter);
    }
  }

  if (measureSink == 0x7fffffff) print('(unreachable sink marker)');

  _printAbsoluteTable(scenarios, columnMeta, cells);
  _printRatioTable(scenarios, columnMeta, cells);
}

Future<void> _safeClose(IBytesReadyAdapter adapter) async {
  try {
    await adapter.close();
  } on Object catch (error, stackTrace) {
    // Teardown is best-effort after the suite; log so failures are not silent.
    print('adapter close failed (${adapter.id}): $error\n$stackTrace');
  }
}

void _printAbsoluteTable(
  List<BytesScenario> scenarios,
  List<_Column> columns,
  Map<String, Map<String, _Cell>> cells,
) {
  print('');
  print('## URL → bytes ready (µs/op, min-of-batches)');
  print('');
  print(
    'Lower is better. Same synthetic corpus; no decode / ImageProvider paint. '
    'Adapters reused across rows; closed after a settle for stock cleanup.',
  );
  print('');

  final header = StringBuffer('| scenario | bytes |');
  final sep = StringBuffer('| -------- | ----: |');
  for (final col in columns) {
    header.write(' ${col.label} |');
    sep.write(' ---------: |');
  }
  print(header);
  print(sep);

  for (final scenario in scenarios) {
    final row = StringBuffer('| ${scenario.name} | ${scenario.bytes} |');
    for (final col in columns) {
      final cell = cells[scenario.name]![col.id]!;
      row.write(' ${cell.render()} |');
    }
    print(row);
  }
  print('');
}

void _printRatioTable(
  List<BytesScenario> scenarios,
  List<_Column> columns,
  Map<String, Map<String, _Cell>> cells,
) {
  print('## Relative to ours (× = adapter / ours)');
  print('');
  print(
    '1.00× is parity. Values > 1 mean slower than image_bytes_cache on this '
    'machine. Ratios only — absolute µs are not portable.',
  );
  print('');

  final header = StringBuffer('| scenario |');
  final sep = StringBuffer('| -------- |');
  for (final col in columns) {
    header.write(' ${col.label} |');
    sep.write(' ---------: |');
  }
  print(header);
  print(sep);

  for (final scenario in scenarios) {
    final ours = cells[scenario.name]!['ours'];
    final row = StringBuffer('| ${scenario.name} |');
    for (final col in columns) {
      final cell = cells[scenario.name]![col.id]!;
      switch ((cell.us, ours?.us)) {
        case (final cellUs?, final oursUs?) when oursUs > 0:
          if (col.id == 'ours') {
            row.write(' 1.00x |');
          } else {
            row.write(' ${(cellUs / oursUs).toStringAsFixed(2)}x |');
          }
        case _:
          row.write(' ${cell.render()} |');
      }
    }
    print(row);
  }
  print('');
}

final class _Column {
  _Column({required this.id, required this.label});
  final String id;
  final String label;
}

final class _Cell {
  _Cell.ok(this.us) : reason = null;
  _Cell.na(this.reason) : us = null;

  final double? us;
  final String? reason;

  String render() => switch (us) {
    final value? => value.toStringAsFixed(1),
    null => 'N/A (${reason ?? 'unavailable'})',
  };
}
