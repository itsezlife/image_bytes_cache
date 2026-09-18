// ignore_for_file: avoid_print

import 'dart:io';

import 'ladder_scenarios.dart';
import 'scenarios.dart';

/// Low-noise timing tool for store + resolve-ladder scenarios.
///
/// For each scenario: prepare → warmup → calibrate batch size → time batches →
/// report the *minimum* per-op microseconds (least sensitive to GC / scheduler
/// noise). Optional baseline at `benchmark/.baseline.txt` for delta %.
///
/// Optional memory lane (`MEMORY_LANE=true`): RSS before/after fill-to-standard
/// and after prune — printed separately; not a baseline key.
///
/// Run from the package root:
/// ```shell
/// dart test benchmark/compare_test.dart --dart-define=SAVE_BASELINE=true
/// dart test benchmark/compare_test.dart
/// dart test benchmark/compare_test.dart --dart-define=MEMORY_LANE=true
/// ```
/// Accumulators keep returned bytes from being optimized away.
int _sink = 0;

/// Entry used by [compare_test.dart]. Pass `--dart-define=SAVE_BASELINE=true`
/// to write `benchmark/.baseline.txt`. Pass `--dart-define=MEMORY_LANE=true`
/// for the optional RSS lane.
Future<void> runCompare() async {
  const save = bool.fromEnvironment('SAVE_BASELINE', defaultValue: false);
  const memoryLane = bool.fromEnvironment('MEMORY_LANE', defaultValue: false);
  final results = <String, ({int bytes, double us})>{};

  final scenarios = [...storeScenarios(), ...ladderScenarios()];
  for (final scenario in scenarios) {
    results[scenario.name] = (
      bytes: scenario.bytes,
      us: await _bench(scenario),
    );
  }

  if (_sink == 0x7fffffff) print('(unreachable sink marker)');

  final baseline = save ? null : _loadBaseline();

  print('scenario                          bytes    us/op       baseline    delta');
  print('--------------------------------  -------  ----------  ----------  ----------');
  var total = 0.0;
  var baseTotal = 0.0;
  for (final entry in results.entries) {
    final us = entry.value.us;
    total += us;
    final bytes = entry.value.bytes;
    final base = baseline?[entry.key];
    final baseStr = base == null ? '-' : base.toStringAsFixed(2);
    final deltaStr = base == null ? '-' : _delta(base, us);
    if (base != null) baseTotal += base;
    print(
      '${entry.key.padRight(32)}  '
      '${bytes.toString().padLeft(7)}  '
      '${us.toStringAsFixed(2).padLeft(10)}  '
      '${baseStr.padLeft(10)}  '
      '${deltaStr.padLeft(10)}',
    );
  }
  print('--------------------------------  -------  ----------  ----------  ----------');
  final totalDelta = baseTotal > 0 ? _delta(baseTotal, total) : '-';
  print(
    '${'TOTAL'.padRight(32)}  '
    '${' '.padLeft(7)}  '
    '${total.toStringAsFixed(2).padLeft(10)}  '
    '${(baseTotal > 0 ? baseTotal.toStringAsFixed(2) : '-').padLeft(10)}  '
    '${totalDelta.padLeft(10)}',
  );

  if (save) {
    _saveBaseline({for (final e in results.entries) e.key: e.value.us});
    print('\nSaved baseline to benchmark/.baseline.txt');
  }

  if (memoryLane) {
    await _printMemoryLane();
  }
}

Future<void> _printMemoryLane() async {
  final report = await runMemoryLane();
  final fillDelta = report.afterFillRss - report.beforeFillRss;
  final pruneDelta = report.afterPruneRss - report.afterFillRss;

  print('\n## Memory lane (optional, ProcessInfo.currentRss)');
  print(
    'Caveats: process-wide RSS (VM + isolates + OS freelists); GC and OS reclaim '
    'make absolute bytes noisy. Compare before/after deltas on one machine only. '
    'Not a baseline key.',
  );
  print(
    'fill: ${report.filledEntries} × ${report.payloadBytes} B under '
    'ImageBytesRetention.standard',
  );
  print('phase                         RSS bytes      delta vs prior');
  print('----------------------------  -------------  ----------------');
  print(
    '${'before_fill'.padRight(28)}  '
    '${_fmtRss(report.beforeFillRss).padLeft(13)}  '
    '${'-'.padLeft(16)}',
  );
  print(
    '${'after_fill_and_warm_reads'.padRight(28)}  '
    '${_fmtRss(report.afterFillRss).padLeft(13)}  '
    '${_fmtSigned(fillDelta).padLeft(16)}',
  );
  print(
    '${'after_prune'.padRight(28)}  '
    '${_fmtRss(report.afterPruneRss).padLeft(13)}  '
    '${_fmtSigned(pruneDelta).padLeft(16)}',
  );
  print(
    'prune report: freedBytes=${report.pruneFreedBytes} '
    'evicted=${report.pruneEvicted}',
  );
}

String _fmtRss(int bytes) => bytes.toString();

String _fmtSigned(int bytes) {
  final sign = bytes <= 0 ? '' : '+';
  return '$sign$bytes';
}

/// Minimum per-op time in microseconds for [scenario].
Future<double> _bench(
  StoreScenario scenario, {
  int warmupMs = 200,
  int batches = 25,
  int minBatchMs = 8,
}) async {
  final prepared = await scenario.prepare();
  try {
    final warmupSw = Stopwatch()..start();
    while (warmupSw.elapsedMilliseconds < warmupMs) {
      _sink ^= await prepared.op();
    }

    var iters = 1;
    while (true) {
      final sw = Stopwatch()..start();
      for (var i = 0; i < iters; i++) {
        _sink ^= await prepared.op();
      }
      sw.stop();
      if (sw.elapsedMicroseconds >= minBatchMs * 1000) break;
      iters = iters < 2 ? 2 : (iters * 2);
      if (iters > 1 << 16) break;
    }

    var best = double.infinity;
    for (var b = 0; b < batches; b++) {
      final sw = Stopwatch()..start();
      for (var i = 0; i < iters; i++) {
        _sink ^= await prepared.op();
      }
      sw.stop();
      final us = sw.elapsedMicroseconds / iters;
      if (us < best) best = us;
    }
    return best;
  } finally {
    await prepared.dispose();
  }
}

String _delta(double base, double now) {
  final pct = (now - base) / base * 100;
  final sign = pct <= 0 ? '' : '+';
  return '$sign${pct.toStringAsFixed(1)}%';
}

Map<String, double>? _loadBaseline() {
  final file = File('benchmark/.baseline.txt');
  if (!file.existsSync()) return null;
  final map = <String, double>{};
  for (final line in file.readAsLinesSync()) {
    final parts = line.split('\t');
    if (parts.length == 2) {
      final value = double.tryParse(parts[1]);
      if (value != null) map[parts[0]] = value;
    }
  }
  return map;
}

void _saveBaseline(Map<String, double> results) {
  final buffer = StringBuffer();
  for (final entry in results.entries) {
    buffer.writeln('${entry.key}\t${entry.value.toStringAsFixed(3)}');
  }
  File('benchmark/.baseline.txt').writeAsStringSync(buffer.toString());
}
